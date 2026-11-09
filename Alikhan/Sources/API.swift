import Foundation
import Network

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
    var audio_url: String?     // stream=true: дауыс синтезі бөлек сілтемеде, бірден ашамыз

    enum CodingKeys: String, CodingKey { case text, heard, audio, action, arg, url, end, reminders, audio_url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        heard = try? c.decodeIfPresent(String.self, forKey: .heard)
        audio = try? c.decodeIfPresent(String.self, forKey: .audio)
        action = try? c.decodeIfPresent(String.self, forKey: .action)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        end = try? c.decodeIfPresent(Bool.self, forKey: .end)
        reminders = try? c.decodeIfPresent([ReminderItem].self, forKey: .reminders)
        audio_url = try? c.decodeIfPresent(String.self, forKey: .audio_url)
        // arg кейде сан болып келеді (volume: 40)
        if let s = try? c.decodeIfPresent(String.self, forKey: .arg) {
            arg = s
        } else if let n = try? c.decodeIfPresent(Double.self, forKey: .arg) {
            arg = String(Int(n.rounded()))
        }
    }
}

struct CaptureInfo: Decodable, Hashable {
    var arg: String?
    var url: String?
}

/// /notifications элементі. Өрістердің бәрі бола бермейді.
struct Notice: Decodable {
    var id: String?
    var voice_text: String?
    var kind: String?          // ask, question, done, message
    var ask_id: String?
    var title: String?
    var question: String?
    var url: String?
    var remote_browser_url: String?
    var capture: CaptureInfo?
    var task_id: String?

    enum CodingKeys: String, CodingKey { case id, voice_text, kind, ask_id, title, question, url, remote_browser_url, capture, task_id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexibleString(.id)
        voice_text = try? c.decodeIfPresent(String.self, forKey: .voice_text)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        ask_id = c.flexibleString(.ask_id)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        question = try? c.decodeIfPresent(String.self, forKey: .question)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        remote_browser_url = try? c.decodeIfPresent(String.self, forKey: .remote_browser_url)
        capture = try? c.decodeIfPresent(CaptureInfo.self, forKey: .capture)
        task_id = c.flexibleString(.task_id)
    }

    private init(text: String) { voice_text = text; kind = "message" }

    /// Қосымшаның өз хабары (мысалы «Сервер қатесі»)
    static func local(_ text: String) -> Notice { Notice(text: text) }
}

/// Қолданушы өз қолымен істейтін тапсырма (GET /asks)
struct Ask: Decodable, Identifiable, Hashable {
    var ask_id: String
    var title: String?
    var question: String?
    var status: String?
    var created_at: String?
    var url: String?
    var remote_browser_url: String?
    var capture: CaptureInfo?

    var id: String { ask_id }
    var heading: String { title ?? question ?? "Тапсырма" }
    var created: Date? { created_at.flatMap(Reminders.parse) }

    enum CodingKeys: String, CodingKey { case ask_id, title, question, status, created_at, url, remote_browser_url, capture }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ask_id = c.flexibleString(.ask_id) ?? UUID().uuidString
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        question = try? c.decodeIfPresent(String.self, forKey: .question)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        created_at = try? c.decodeIfPresent(String.self, forKey: .created_at)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        remote_browser_url = try? c.decodeIfPresent(String.self, forKey: .remote_browser_url)
        capture = try? c.decodeIfPresent(CaptureInfo.self, forKey: .capture)
    }
}

/// /ask/{id}/done, /cancel, /upload жауабы
struct ActionReply: Decodable {
    var ok: Bool?
    var text: String?
    var audio: String?
    var task_id: String?

    enum CodingKeys: String, CodingKey { case ok, text, audio, task_id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try? c.decodeIfPresent(Bool.self, forKey: .ok)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        audio = try? c.decodeIfPresent(String.self, forKey: .audio)
        task_id = c.flexibleString(.task_id)
    }
}

extension KeyedDecodingContainer {
    /// id сан не мәтін болуы мүмкін
    func flexibleString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let n = try? decodeIfPresent(Int.self, forKey: key) { return String(n) }
        return nil
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
        // Желі не VPN (Tailscale) дайын ба
        monitor.pathUpdateHandler = { [weak self] path in self?.pathReady = path.status == .satisfied }
        monitor.start(queue: DispatchQueue(label: "kz.ersultan.alikhan.net"))
    }

    private let monitor = NWPathMonitor()
    private var pathReady = true

    /// Siri-ден ашқанда VPN әлі қосылмаған болуы мүмкін: 5 секундқа дейін күтеміз
    private func waitForNetwork() async {
        var waited = 0.0
        while !pathReady && waited < 5 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 0.2
        }
    }

    /// Серверге жетпеген қате: қайталауға болады
    private static func retryable(_ error: Error, after seconds: Double) -> Bool {
        guard let e = error as? URLError else { return false }
        switch e.code {
        case .notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed:
            return true
        case .timedOut:
            return seconds < 3   // Қосыла алмай тез үзілді. Ұзақ күтіп барып үзілсе, қайталамаймыз.
        default:
            return false
        }
    }

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        guard let base = Settings.shared.baseURL, let url = URL(string: base.absoluteString + path) else { throw APIError.noServer }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(Settings.shared.token)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// Бірінші сұрау сәтсіз болса, бірден қате айтпаймыз: 0,3, 0,6, 1, 1,5, 2 с сайын қайталаймыз (барлығы 5 с шамасы)
    private func send(_ r: URLRequest, long useLong: Bool = false) async throws -> Data {
        await waitForNetwork()
        let delays: [Double] = [0.3, 0.6, 1, 1.5, 2]
        var attempt = 0
        while true {
            let started = Date()
            do {
                return try await sendOnce(r, long: useLong)
            } catch {
                guard attempt < delays.count, !Task.isCancelled,
                      API.retryable(error, after: Date().timeIntervalSince(started)) else { throw error }
                try await Task.sleep(nanoseconds: UInt64(delays[attempt] * 1_000_000_000))
                attempt += 1
            }
        }
    }

    private func sendOnce(_ r: URLRequest, long useLong: Bool) async throws -> Data {
        let (data, resp) = try await (useLong ? long : quick).data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(code) else { throw APIError.status(code) }
        return data
    }

    func phone(audio: Encoded? = nil, text: String? = nil, earlyId: String? = nil) async throws -> PhoneReply {
        var form = Multipart()
        if let audio { form.file("file", audio) }
        if let text { form.field("text", text) }
        var path = "/phone?stream=true"
        if let earlyId { path += "&early_id=\(earlyId)" }
        var r = try request(path, method: "POST")
        r.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        r.httpBody = form.finish()
        return try JSONDecoder().decode(PhoneReply.self, from: try await send(r))
    }

    /// 0,2 с үнсіздік: сервер сөзді алдын ала таниды, модель ойлана бастайды
    func sttEarly(id: String, audio: Encoded) async throws {
        var form = Multipart()
        form.file("file", audio)
        var r = try request("/stt/early?id=\(id)&device=phone", method: "POST")
        r.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        r.httpBody = form.finish()
        _ = try await send(r)
    }

    struct Expect {
        var expect = false     // Сервер жауап күтіп тұр
        var running = 0        // Жүріп жатқан тапсырма саны
        var said = ""          // Алиханның соңғы айтқаны
    }

    func expect() async throws -> Expect {
        let json = try JSONSerialization.jsonObject(with: try await send(try request("/expect"))) as? [String: Any] ?? [:]
        return Expect(expect: json["expect"] as? Bool ?? false,
                      running: (json["running"] as? Int) ?? Int(json["running"] as? Double ?? 0),
                      said: json["said"] as? String ?? "")
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

    func asks() async throws -> [Ask] {
        let data = try await send(try request("/asks?status=pending"))
        if let list = try? JSONDecoder().decode([Ask].self, from: data) { return list }
        struct Wrapped: Decodable { var asks: [Ask]? }
        return (try? JSONDecoder().decode(Wrapped.self, from: data))?.asks ?? []
    }

    private func askAction(_ id: String, _ verb: String) async throws -> ActionReply {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var r = try request("/ask/\(safe)/\(verb)", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data("{}".utf8)
        return try JSONDecoder().decode(ActionReply.self, from: try await send(r))
    }

    func askDone(_ id: String) async throws -> ActionReply { try await askAction(id, "done") }
    func askCancel(_ id: String) async throws -> ActionReply { try await askAction(id, "cancel") }

    func browserLink() async throws -> URL {
        let json = try JSONSerialization.jsonObject(with: try await send(try request("/browser/link"))) as? [String: Any]
        guard let s = json?["remote_browser_url"] as? String, let url = URL(string: s) else { throw APIError.status(-2) }
        return url
    }

    func registerDevice(_ token: String) async throws {
        var r = try request("/device", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["apns_token": token, "platform": "ios", "bundle_id": "kz.ersultan.alikhan"])
        _ = try await send(r)
    }

    /// Жүктеу тек өз серверімізге: токен басқа хостқа кетпесін.
    func isOwnServer(_ url: URL) -> Bool {
        guard let base = Settings.shared.baseURL else { return false }
        return url.absoluteString.hasPrefix(base.absoluteString + "/")
    }

    var authHeader: String { "Bearer \(Settings.shared.token)" }
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
