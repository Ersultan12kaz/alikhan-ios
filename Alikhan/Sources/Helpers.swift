import ActivityKit
import Contacts
import CryptoKit
import EventKit
import UIKit

/// «Алихан» сөзі: ноутбуктағы wake_tail-дің көшірмесі.
/// Дауыс тануы «алихан», «али хан», «әлихан» деп жазуы мүмкін.
enum Wake {
    static func words(_ text: String) -> [String] {
        let cleaned = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? String($0) : " " }.joined()
        return cleaned.split(separator: " ").map(String.init)
    }

    static func soundsLikeWake(_ word: String) -> Bool {
        if word.hasPrefix("alikhan") || word.hasPrefix("alihan") { return true }
        let plain = word.replacingOccurrences(of: "ә", with: "а").replacingOccurrences(of: "і", with: "и")
            .replacingOccurrences(of: "қ", with: "х").replacingOccurrences(of: "һ", with: "х")
        guard plain.contains("лих") || plain.hasPrefix("алхан") else { return false }
        return ratio(String(plain.prefix(7)), "алихан") >= 0.72
    }

    /// Шақыру сөзінен кейінгі сөздер. Шақыру сөзі жоқ болса, nil.
    static func tail(_ text: String) -> String? {
        let w = words(text)
        for i in w.indices {
            if soundsLikeWake(w[i]) { return w[(i + 1)...].joined(separator: " ") }
            if i + 1 < w.count, soundsLikeWake(w[i] + w[i + 1]) { return w[(i + 2)...].joined(separator: " ") }
        }
        return nil
    }

    /// difflib.SequenceMatcher.ratio()-ға жақын: 2·ортақ / ұзындықтар
    static func ratio(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        var dp = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0..<x.count {
            for j in 0..<y.count {
                dp[i + 1][j + 1] = x[i] == y[j] ? dp[i][j] + 1 : max(dp[i][j + 1], dp[i + 1][j])
            }
        }
        return 2 * Double(dp[x.count][y.count]) / Double(x.count + y.count)
    }
}

/// Жиі айтылатын сөйлемдер: серверден бір рет алынып, телефонда сақталады.
final class Voice {
    static let shared = Voice()
    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("phrases")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func file(_ text: String) -> URL {
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return dir.appendingPathComponent("\(hash).mp3")
    }

    func cached(_ text: String) -> Data? { try? Data(contentsOf: file(text)) }

    func audio(_ text: String, keep: Bool = false) async -> Data? {
        if let data = cached(text) { return data }
        guard let data = try? await API.shared.speak(text), !data.isEmpty else { return nil }
        if keep { try? data.write(to: file(text)) }
        return data
    }

    func prefetch(_ phrases: [String]) {
        Task.detached {
            for p in phrases where self.cached(p) == nil { _ = await self.audio(p, keep: true) }
        }
    }
}

/// Apple «Напоминания»: «Алихан» тізіміне, қайталамай.
final class Reminders {
    static let shared = Reminders()
    private let store = EKEventStore()
    private let doneKey = "addedReminders"

    var authorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    func requestAccess() async {
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
            _ = try? await store.requestFullAccessToReminders()
        }
    }

    private func calendar() -> EKCalendar? {
        if let c = store.calendars(for: .reminder).first(where: { $0.title == "Алихан" }) { return c }
        let c = EKCalendar(for: .reminder, eventStore: store)
        c.title = "Алихан"
        guard let source = store.defaultCalendarForNewReminders()?.source
                ?? store.sources.first(where: { $0.sourceType == .local }) else { return nil }
        c.source = source
        do { try store.saveCalendar(c, commit: true) } catch { return nil }
        return c
    }

    static func parse(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
                       "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    private func key(_ title: String, _ date: Date) -> String {
        "\(title.lowercased())|\(Int(date.timeIntervalSince1970 / 60))"
    }

    private func existing(in cal: EKCalendar) async -> Set<String> {
        await withCheckedContinuation { (c: CheckedContinuation<Set<String>, Never>) in
            store.fetchReminders(matching: store.predicateForReminders(in: [cal])) { list in
                var keys = Set<String>()
                for r in list ?? [] {
                    if let date = r.alarms?.first?.absoluteDate ?? r.dueDateComponents?.date {
                        keys.insert(self.key(r.title ?? "", date))
                    }
                }
                c.resume(returning: keys)
            }
        }
    }

    func add(_ items: [ReminderItem]) async {
        guard !items.isEmpty, authorized, let cal = calendar() else { return }
        var seen = await existing(in: cal).union(UserDefaults.standard.stringArray(forKey: doneKey) ?? [])
        for item in items {
            guard let date = Reminders.parse(item.at) else { continue }
            let k = key(item.title, date)
            if seen.contains(k) { continue }
            let r = EKReminder(eventStore: store)
            r.title = item.title
            r.calendar = cal
            var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            comps.timeZone = TimeZone.current
            r.dueDateComponents = comps
            r.addAlarm(EKAlarm(absoluteDate: date))
            switch item.repeat ?? "" {
            case "daily": r.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))
            case "weekly": r.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil))
            default: break
            }
            do {
                try store.save(r, commit: true)
                seen.insert(k)
            } catch {}
        }
        UserDefaults.standard.set(Array(seen.suffix(500)), forKey: doneKey)
    }
}

/// Телефон әрекеттері: қоңырау, сілтеме, «Алихан басқару» Shortcut-ы.
enum Phone {
    static func requestContacts() async {
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        }
    }

    static func number(for name: String) async -> String? {
        let query = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        return await Task.detached { () -> String? in
            let store = CNContactStore()
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
                        CNContactOrganizationNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
            if let found = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys),
               let c = found.first(where: { !$0.phoneNumbers.isEmpty }) {
                return c.phoneNumbers.first?.value.stringValue
            }
            // «анам» → «Анам ❤️», «Анама» сияқты: толық атпен немесе басымен салыстыру
            var best: (score: Int, number: String)?
            let request = CNContactFetchRequest(keysToFetch: keys)
            try? store.enumerateContacts(with: request) { c, _ in
                guard let num = c.phoneNumbers.first?.value.stringValue else { return }
                let names = [c.nickname, "\(c.givenName) \(c.familyName)", c.givenName, c.familyName, c.organizationName]
                    .map { Wake.words($0).joined(separator: " ") }.filter { !$0.isEmpty }
                for n in names {
                    let score = n == query ? 3 : (n.hasPrefix(query) || (query.hasPrefix(n) && n.count >= 3)) ? 2 : n.contains(query) ? 1 : 0
                    if score > (best?.score ?? 0) { best = (score, num) }
                }
            }
            return best?.number
        }.value
    }

    @MainActor
    static func call(_ name: String) async -> Bool {
        guard let raw = await number(for: name) else { return false }
        let digits = raw.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty, let url = URL(string: "tel://\(digits)") else { return false }
        return await UIApplication.shared.open(url)
    }

    @MainActor
    static func open(_ string: String) async {
        guard let url = URL(string: string) else { return }
        _ = await UIApplication.shared.open(url)
    }

    /// iOS басқа қосымшаның ойнатуын басқаруға рұқсат бермейді: Shortcut арқылы.
    @MainActor
    static func runShortcut(_ command: String) async {
        var c = URLComponents()
        c.scheme = "shortcuts"
        c.host = "x-callback-url"
        c.path = "/run-shortcut"
        c.queryItems = [URLQueryItem(name: "name", value: "Алихан басқару"),
                        URLQueryItem(name: "input", value: "text"),
                        URLQueryItem(name: "text", value: command),
                        URLQueryItem(name: "x-success", value: "alikhan://")]
        guard let url = c.url else { return }
        _ = await UIApplication.shared.open(url)
    }

    static func links(in text: String) -> [URL] {
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return det.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { $0.url }
            .filter { $0.scheme == "https" || $0.scheme == "http" }
    }
}

/// Dynamic Island мен құлып экраны.
@MainActor
final class Island {
    static let shared = Island()
    private var activity: Activity<AlikhanAttributes>?
    private var last: AlikhanAttributes.ContentState?

    private func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }

    private func content(_ s: AlikhanAttributes.ContentState) -> ActivityContent<AlikhanAttributes.ContentState> {
        var c = s
        c.heard = clip(c.heard, 120)
        c.said = clip(c.said, 160)
        // 25 минут жаңартылмаса, қосымша жабық деп есептеледі (виджет сұр болады)
        return ActivityContent(state: c, staleDate: Date().addingTimeInterval(25 * 60))
    }

    /// Тек қосымша алдыңғы жоспарда тұрғанда басталады (iOS шарты).
    func start(_ s: AlikhanAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if activity == nil { activity = Activity<AlikhanAttributes>.activities.first(where: { $0.activityState == .active }) }
        if activity != nil { update(s); return }
        activity = try? Activity<AlikhanAttributes>.request(attributes: AlikhanAttributes(), content: content(s), pushType: nil)
        last = s
    }

    var isRunning: Bool { activity != nil }

    /// Қосымша тірі: 10 минут сайын жаңартады, сонда айдаһар сұр болмайды
    func heartbeat() {
        guard let a = activity, let s = last else { return }
        let c = content(s)
        Task { await a.update(c) }
    }

    /// Қосымша толық жабылғанда: айдаһар Dynamic Island-тан бірден кетеді
    nonisolated static func endAllNow() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for a in Activity<AlikhanAttributes>.activities {
                await a.end(nil, dismissalPolicy: .immediate)
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    func update(_ s: AlikhanAttributes.ContentState, alert: String? = nil) {
        guard let a = activity, s != last || alert != nil else { return }
        last = s
        let c = content(s)
        Task {
            if let alert {
                // Ескерту: Dynamic Island кеңейтілген күйге өтеді
                await a.update(c, alertConfiguration: AlertConfiguration(title: "Алихан", body: LocalizedStringResource(stringLiteral: alert), sound: .named("silence.wav")))
            } else {
                await a.update(c)
            }
        }
    }

    func end() {
        activity = nil
        last = nil
        for a in Activity<AlikhanAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
