import Foundation

struct ReminderItem: Decodable, Hashable {
    var title: String
    var at: String
    var `repeat`: String?
}

struct PhoneReply: Decodable {
    var text: String?
    var heard: String?
    var audio: String?
    var action: String?
    var arg: String?
    var url: String?
    var end: Bool?
    var reminders: [ReminderItem]?

    enum CodingKeys: String, CodingKey { case text, heard, audio, action, arg, url, end, reminders }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        heard = try? c.decodeIfPresent(String.self, forKey: .heard)
        audio = try? c.decodeIfPresent(String.self, forKey: .audio)
        action = try? c.decodeIfPresent(String.self, forKey: .action)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        end = try? c.decodeIfPresent(Bool.self, forKey: .end)
        reminders = try? c.decodeIfPresent([ReminderItem].self, forKey: .reminders)
        // arg кейде сан болып келеді (volume: 40)
        if let s = try? c.decodeIfPresent(String.self, forKey: .arg) {
            arg = s
        } else if let n = try? c.decodeIfPresent(Double.self, forKey: .arg) {
            arg = String(Int(n.rounded()))
        }
    }
}

struct Notice: Decodable {
    var id: String?
    var voice_text: String?

    enum CodingKeys: String, CodingKey { case id, voice_text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        voice_text = try? c.decodeIfPresent(String.self, forKey: .voice_text)
        // id сан не мәтін болуы мүмкін
        if let s = try? c.decodeIfPresent(String.self, forKey: .id) { id = s }
        else if let n = try? c.decodeIfPresent(Int.self, forKey: .id) { id = String(n) }
    }
}

struct Encoded {
    var data: Data
    var filename: String
    var mime: String
}

enum APIError: LocalizedError {
    case noServer, unauthorized, status(Int)

    var errorDescription: String? {
        switch self {
        case .noServer: return "Сервер мекенжайы қате"
        case .unauthorized: return "Токен қате (401)"
        case .status(let code): return "Сервер қатесі: \(code)"
        }
    }
}

/// Сервермен байланыс. Барлық сұраныс 15 секундта бітеді, тек /notifications ұзақ күтеді.
final class API {
    static let shared = API()
    private let quick: URLSession
    private let long: URLSession

    private init() {
        let q = URLSessionConfiguration.default
        q.timeoutIntervalForRequest = 15
        q.timeoutIntervalForResource = 15
        q.waitsForConnectivity = false
        quick = URLSession(configuration: q)
        let l = URLSessionConfiguration.default
        l.timeoutIntervalForRequest = 35   // wait=20 + желі
        l.timeoutIntervalForResource = 35
        long = URLSession(configuration: l)
    }

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        guard let base = Settings.shared.baseURL, let url = URL(string: base.absoluteString + path) else { throw APIError.noServer }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(Settings.shared.token)", forHTTPHeaderField: "Authorization")
        return r
    }

    private func send(_ r: URLRequest, long useLong: Bool = false) async throws -> Data {
        let (data, resp) = try await (useLong ? long : quick).data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(code) else { throw APIError.status(code) }
        return data
    }

    func phone(audio: Encoded? = nil, text: String? = nil) async throws -> PhoneReply {
        var form = Multipart()
        if let audio { form.file("file", audio) }
        if let text { form.field("text", text) }
        var r = try request("/phone", method: "POST")
        r.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        r.httpBody = form.finish()
        return try JSONDecoder().decode(PhoneReply.self, from: try await send(r))
    }

    func wakeConfirm(_ audio: Encoded) async throws -> String {
        var form = Multipart()
        form.file("file", audio)
        var r = try request("/wake/confirm", method: "POST")
        r.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        r.httpBody = form.finish()
        let json = try JSONSerialization.jsonObject(with: try await send(r)) as? [String: Any]
        return json?["text"] as? String ?? ""
    }

    func speak(_ text: String) async throws -> Data {
        var r = try request("/speak", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "public": false])
        return try await send(r)
    }

    func notifications(ack: Bool, wait: Int) async throws -> [Notice] {
        var path = "/notifications?ack=\(ack ? "true" : "false")"
        if wait > 0 { path += "&wait=\(wait)" }
        let data = try await send(try request(path), long: wait > 0)
        if let list = try? JSONDecoder().decode([Notice].self, from: data) { return list }
        struct Wrapped: Decodable { var notifications: [Notice]? }
        return (try? JSONDecoder().decode(Wrapped.self, from: data))?.notifications ?? []
    }

    /// Серверде әлі жоқ: болмаса 404 келеді, оны қате деп санамаймыз.
    func pendingReminders() async throws -> [ReminderItem] {
        let data = try await send(try request("/reminders/pending"))
        if let list = try? JSONDecoder().decode([ReminderItem].self, from: data) { return list }
        struct Wrapped: Decodable { var reminders: [ReminderItem]? }
        return (try? JSONDecoder().decode(Wrapped.self, from: data))?.reminders ?? []
    }

    /// Түсірілген видео/фото: тек өз серверімізге (токен басқа жерге кетпесін).
    func upload(file: URL, mime: String, to target: URL) async throws {
        guard let base = Settings.shared.baseURL, target.host == base.host, target.port == base.port else { throw APIError.noServer }
        var form = Multipart()
        form.file("file", Encoded(data: try Data(contentsOf: file), filename: file.lastPathComponent, mime: mime))
        var r = URLRequest(url: target)
        r.httpMethod = "POST"
        r.timeoutInterval = 120
        r.setValue("Bearer \(Settings.shared.token)", forHTTPHeaderField: "Authorization")
        r.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await URLSession.shared.upload(for: r, from: form.finish())
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.status(code) }
    }
}

struct Multipart {
    private let boundary = "alikhan-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    mutating func file(_ name: String, _ file: Encoded) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(file.filename)\"\r\nContent-Type: \(file.mime)\r\n\r\n".utf8))
        body.append(file.data)
        body.append(Data("\r\n".utf8))
    }

    mutating func finish() -> Data {
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}
