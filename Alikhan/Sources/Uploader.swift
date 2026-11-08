import Foundation
import UIKit
import UserNotifications

/// Үлкен видео фонда жүктеледі (background URLSession): қосымша жабылса да iOS жүктеп бітіреді.
final class Uploader: NSObject, URLSessionDataDelegate {
    static let shared = Uploader()
    static let sessionID = "kz.ersultan.alikhan.upload"

    var onProgress: ((Double) -> Void)?
    var onFinish: ((Result<ActionReply?, Error>) -> Void)?
    var backgroundCompletion: (() -> Void)?

    private var received = Data()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Uploader.sessionID)
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        return URLSession(configuration: c, delegate: self, delegateQueue: .main)
    }()

    /// multipart денесі файлға жазылады (background session тек файлдан жүктейді)
    func upload(file: URL, mime: String, to target: URL) throws {
        guard API.shared.isOwnServer(target) else { throw APIError.noServer }
        let boundary = "alikhan-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: body.path, contents: nil)
        let out = try FileHandle(forWritingTo: body)
        out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: file)
        while case let chunk = input.readData(ofLength: 1 << 20), !chunk.isEmpty { out.write(chunk) }
        try input.close()
        out.write(Data("\r\n--\(boundary)--\r\n".utf8))
        try out.close()

        var r = URLRequest(url: target)
        r.httpMethod = "POST"
        r.setValue(API.shared.authHeader, forHTTPHeaderField: "Authorization")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        received = Data()
        session.uploadTask(with: r, fromFile: body).resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onFinish?(.failure(error))
        } else if let code = (task.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
            onFinish?(.failure(APIError.status(code)))
        } else {
            onFinish?(.success(try? JSONDecoder().decode(ActionReply.self, from: received)))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundCompletion?()
        backgroundCompletion = nil
    }
}

/// Push (APNs) және фондағы жүктеудің оқиғалары.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { try? await API.shared.registerDevice(hex) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        Uploader.shared.backgroundCompletion = completionHandler
    }

    /// Қосымша ашық тұрғанда да push көрінсін, тізім жаңарсын
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in Assistant.shared.pushArrived(notification.request.content.userInfo, opened: false) }
        completionHandler([.banner, .sound, .list])
    }

    /// Push басылды: ask болса тапсырма, done болса басты бет
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        Task { @MainActor in Assistant.shared.pushArrived(info, opened: true) }
        completionHandler()
    }

    static func registerForPush() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return }
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }
}
