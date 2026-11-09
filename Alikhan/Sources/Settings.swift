import Foundation
import Security

/// Токен тек Keychain-да: кодта, журналда, UserDefaults-та жоқ.
enum Keychain {
    private static let service = "kz.ersultan.alikhan"

    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    static func get(_ key: String) -> String? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        SecItemDelete(base(key) as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base(key)
        add[kSecValueData as String] = Data(value.utf8)
        // Телефон құлыпталса да фонда оқылады
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    static let defaultServer = "http://100.78.149.53:8000"
    private let d = UserDefaults.standard

    @Published var server: String { didSet { d.set(server, forKey: "server") } }
    @Published var token: String { didSet { Keychain.set("token", token) } }
    @Published var alwaysListen: Bool { didSet { d.set(alwaysListen, forKey: "alwaysListen") } }
    @Published var headsetMic: Bool { didSet { d.set(headsetMic, forKey: "headsetMic") } }
    @Published var nearRatio: Double { didSet { d.set(nearRatio, forKey: "nearRatio") } }
    @Published var pip: Bool { didSet { d.set(pip, forKey: "pip") } }
    @Published var endSilence: Double { didSet { d.set(endSilence, forKey: "endSilence") } }       // Сөздің соңы: 0,8 с
    @Published var voiceProcessing: Bool { didSet { d.set(voiceProcessing, forKey: "voiceProcessing3") } }
    @Published var configured: Bool { didSet { d.set(configured, forKey: "configured") } }

    private init() {
        d.register(defaults: ["server": Settings.defaultServer, "alwaysListen": true, "headsetMic": false,
                              "nearRatio": 1.65, "pip": false, "configured": false,
                              "endSilence": 0.8, "voiceProcessing3": true])
        server = d.string(forKey: "server") ?? Settings.defaultServer
        token = Keychain.get("token") ?? ""
        alwaysListen = d.bool(forKey: "alwaysListen")
        headsetMic = d.bool(forKey: "headsetMic")
        nearRatio = d.double(forKey: "nearRatio")
        pip = d.bool(forKey: "pip")
        endSilence = d.double(forKey: "endSilence")
        voiceProcessing = d.bool(forKey: "voiceProcessing3")   // Промт бойынша әдепкіде қосулы
        configured = d.bool(forKey: "configured")
    }

    var baseURL: URL? {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }
}

/// /wake/confirm-ға соңғы сағатта неше рет жіберілгені (батарея үшін).
enum WakeCounter {
    private static let key = "wakeSends"

    static func add() {
        var list = recent()
        list.append(Date().timeIntervalSince1970)
        UserDefaults.standard.set(list, forKey: key)
    }

    static func recent() -> [Double] {
        let hourAgo = Date().timeIntervalSince1970 - 3600
        return (UserDefaults.standard.array(forKey: key) as? [Double] ?? []).filter { $0 > hourAgo }
    }

    static var lastHour: Int { recent().count }
}
