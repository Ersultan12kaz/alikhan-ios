import AVFoundation
import SwiftUI

/// Сервердегі агент сізден күтетін іс: кіру, растау, түсіру т.б.
struct UserTask: Identifiable, Codable, Equatable {
    var id: String
    var text: String
    var links: [URL]
    var created: Date
    var done: Bool = false
}

struct CaptureRequest: Identifiable {
    let id = UUID()
    let video: Bool
    let upload: URL
}

/// Алиханның «құлағы, аузы, пульті». Ойламайды: дыбысты серверге жібереді, жауапты ойнатады, әрекетті орындайды.
@MainActor
final class Assistant: ObservableObject {
    static let shared = Assistant()

    enum Mode { case off, wake, talk }

    @Published private(set) var mode: Mode = .off
    @Published private(set) var orb: OrbState = .sleep
    @Published private(set) var heard = ""
    @Published private(set) var said = ""
    @Published private(set) var banner = ""
    @Published private(set) var tasks: [UserTask] = Assistant.loadTasks()
    @Published var showTasks = false          // «Тапсырмаларым» беті
    @Published var webTask: UserTask?         // Қосымша ішіндегі кіру беті
    @Published var capture: CaptureRequest?
    @Published var status = ""
    @Published private(set) var wakeSendsLastHour = 0

    let settings = Settings.shared
    let audio = AudioIO()

    static let listening = "Тыңдап тұрмын, сэр"
    static let weakNet = "Интернет әлсіз"

    private var gen = 0                      // Жаңа сөз айтылса, ескі жауап тасталады
    private var talkTask: Task<Void, Never>?
    private var idleDeadline = Date()
    private var booted = false
    private var notices: [Notice] = []
    private var noticesTask: Task<Void, Never>?
    private var remindersCheckedAt = Date.distantPast
    private var remindersMissing = false
    private var interrupted = false

    private init() {}

    // MARK: Іске қосу

    func boot() {
        guard !booted else { return }
        booted = true
        audio.onEvent = { [weak self] e in self?.handle(e) }
        audio.onInterrupted = { [weak self] in self?.interrupted = true }
        audio.onResume = { [weak self] in self?.resumeAudio() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdog() }
        }
        if settings.pip { DragonPiP.shared.enable() }
        guard settings.configured else { return }
        afterSetup()
        startTalk()
    }

    /// Баптау сақталғанда да шақырылады.
    func afterSetup() {
        Voice.shared.prefetch([Assistant.listening, Assistant.weakNet])
        startNotices()
    }

    func requestPermissions() async {
        _ = await AVAudioApplication.requestRecordPermission()
        await Phone.requestContacts()
        await Reminders.shared.requestAccess()
    }

    // MARK: Режимдер

    private func ensureAudio(maxLength: Double) -> Bool {
        audio.configure(ratio: Float(settings.nearRatio), maxLength: maxLength)
        if audio.isRunning { return true }
        do {
            try audio.start(headsetMic: settings.headsetMic)
            interrupted = false
            return true
        } catch {
            status = "Микрофон ашылмады: \(error.localizedDescription)"
            setOrb(.error)
            return false
        }
    }

    /// Сөйлесу: батырмасыз, 0,9 с үнсіздік — сөйлем кетеді.
    func startTalk() {
        guard ensureAudio(maxLength: 15) else { return }
        mode = .talk
        idleDeadline = Date().addingTimeInterval(10)
        banner = ""
        setOrb(.listen)
        Island.shared.start(content)
    }

    func endTalk() {
        gen += 1
        talkTask?.cancel()
        if settings.alwaysListen { goWake() } else { stopAll() }
        drainNotices()
    }

    /// Фонда «Алихан» сөзін күтеді.
    func goWake() {
        guard ensureAudio(maxLength: 4.5) else { return }
        mode = .wake
        banner = ""
        setOrb(.sleep)
        Island.shared.start(content)
    }

    /// Микрофон жабылады, Live Activity жабылады.
    func stopAll() {
        gen += 1
        talkTask?.cancel()
        audio.stopPlayback()
        audio.stop()
        mode = .off
        banner = ""
        setOrb(.sleep)
        Island.shared.end()
    }

    func toggleTalk() {
        if mode == .talk { endTalk() } else { startTalk() }
    }

    func settingsChanged() {
        audio.configure(ratio: Float(settings.nearRatio), maxLength: mode == .wake ? 4.5 : 15)
        if settings.pip { DragonPiP.shared.enable() } else { DragonPiP.shared.disable() }
        if mode == .off && settings.alwaysListen && settings.configured { goWake() }
        if mode == .wake && !settings.alwaysListen { stopAll() }
    }

    func headsetChanged() {
        guard mode != .off else { return }
        audio.stop()
        _ = ensureAudio(maxLength: mode == .wake ? 4.5 : 15)
    }

    private var content: AlikhanAttributes.ContentState {
        AlikhanAttributes.ContentState(state: orb.rawValue, heard: heard, said: said, banner: banner)
    }

    private func setOrb(_ s: OrbState, alert: String? = nil) {
        orb = s
        DragonPiP.shared.state = s
        Island.shared.update(content, alert: alert)
    }

    // MARK: Микрофон оқиғалары

    private func handle(_ e: VAD.Event) {
        switch (mode, e) {
        case (.talk, .started):
            idleDeadline = Date().addingTimeInterval(10)
        case (.talk, .utterance(let samples)):
            ask(samples: samples)
        case (.wake, .utterance(let samples)):
            confirmWake(samples)
        default:
            break
        }
    }

    private func tick() {
        wakeSendsLastHour = WakeCounter.lastHour
        // 10 секунд ештеңе айтылмаса, сөйлесу бітеді
        if mode == .talk, orb == .listen, !audio.isPlaying, !audio.vad.speaking, Date() > idleDeadline {
            endTalk()
        }
    }

    /// Қоңырау, Siri не басқа қосымша микрофонды алса: біткен соң өзі қайта қосылады.
    private func resumeAudio() {
        guard mode != .off else { return }
        audio.stop()
        if ensureAudio(maxLength: mode == .wake ? 4.5 : 15), orb == .error { setOrb(mode == .wake ? .sleep : .listen) }
    }

    private func watchdog() {
        if mode != .off && !audio.isRunning { resumeAudio() }
    }

    // MARK: «Алихан»

    private func confirmWake(_ samples: [Float]) {
        WakeCounter.add()
        wakeSendsLastHour = WakeCounter.lastHour
        Task {
            let encoded = await Task.detached { Encoder.compress(samples) }.value
            guard let text = try? await API.shared.wakeConfirm(encoded), mode == .wake, let tail = Wake.tail(text) else { return }
            wakeConfirmed(tail: tail)
        }
    }

    private func wakeConfirmed(tail: String) {
        audio.beep()
        guard ensureAudio(maxLength: 15) else { return }
        mode = .talk
        idleDeadline = Date().addingTimeInterval(10)
        let words = tail.split(separator: " ").count
        // «Алихан, анама қоңырау шал»: сұрақ айтылып қойған, қайта сұрамаймыз.
        // Тапсырма күтіп тұрса, «Алихан, жасадым» да бірден кетеді.
        if words >= 2 || (hasPendingTasks && tail.contains("жасад")) {
            banner = ""
            ask(text: tail)
            return
        }
        banner = Assistant.listening
        said = Assistant.listening
        setOrb(.speak, alert: Assistant.listening)
        let my = gen
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)   // Қысқа дыбыс бітсін
            await say(Assistant.listening)
            guard my == gen, mode == .talk else { return }
            idleDeadline = Date().addingTimeInterval(10)
            setOrb(.listen)
        }
    }

    // MARK: Сөйлесу

    func ask(samples: [Float]? = nil, text: String? = nil) {
        gen += 1
        let my = gen
        talkTask?.cancel()   // Ойнату басталмай тұрып жаңа сөз айтылды: ескі жауап тасталады
        if mode != .talk { startTalk() }
        if let text { heard = text }
        setOrb(.think)
        talkTask = Task {
            do {
                let reply: PhoneReply
                if let samples {
                    let encoded = await Task.detached { Encoder.compress(samples) }.value
                    reply = try await API.shared.phone(audio: encoded)
                } else {
                    reply = try await API.shared.phone(text: text ?? "")
                }
                guard my == gen, mode == .talk else { return }
                await apply(reply, my)
            } catch {
                guard my == gen, mode == .talk, !Task.isCancelled else { return }
                await fail(error, my)
            }
        }
    }

    private func apply(_ r: PhoneReply, _ my: Int) async {
        if let h = r.heard, !h.isEmpty { heard = h }
        if let t = r.text, !t.isEmpty { said = t }
        banner = ""
        if heard.lowercased().contains("жасад"), let last = tasks.last(where: { !$0.done }) { setDone(last) }
        if let items = r.reminders, !items.isEmpty { Task { await Reminders.shared.add(items) } }
        if let b64 = r.audio, !b64.isEmpty, let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
            setOrb(.speak)
            await audio.play(data)
            guard my == gen else { return }
        }
        await perform(action: r.action ?? "none", arg: r.arg ?? "", url: r.url ?? "")
        guard my == gen else { return }
        if r.end == true {
            endTalk()
        } else {
            idleDeadline = Date().addingTimeInterval(10)
            setOrb(.listen)
        }
    }

    private func fail(_ error: Error, _ my: Int) async {
        let text: String
        if let e = error as? APIError, case .unauthorized = e { text = "Токен қате, баптауды тексеріңіз" } else { text = Assistant.weakNet }
        status = error.localizedDescription
        said = text
        setOrb(.error)
        await say(text)
        guard my == gen, mode == .talk else { return }
        idleDeadline = Date().addingTimeInterval(10)
        setOrb(.listen)
    }

    /// Мәтінді айту: сақталған дауыс → сервер → телефонның өз дауысы.
    func say(_ text: String) async {
        if let data = await Voice.shared.audio(text) {
            await audio.play(data)
        } else {
            await audio.speakLocally(text)
        }
    }

    private func perform(action: String, arg: String, url: String) async {
        switch action {
        case "call":
            if !(await Phone.call(arg)) {
                said = "«\(arg)» контактілерден табылмады"
                setOrb(.speak)
                await say(said)
            }
        case "music", "open_url":
            await Phone.open(url.isEmpty ? arg : url)
        case "next", "previous", "pause", "play", "volume":
            await Phone.runShortcut("\(action):\(arg)")
        case "capture":
            // Серверде әлі жоқ: келсе, камера ашылады
            if let target = URL(string: url) { capture = CaptureRequest(video: arg != "photo", upload: target) }
        default:
            break
        }
    }

    // MARK: Тапсырмаларым

    var hasPendingTasks: Bool { tasks.contains { !$0.done } }

    private static func loadTasks() -> [UserTask] {
        guard let data = UserDefaults.standard.data(forKey: "userTasks"),
              let list = try? JSONDecoder().decode([UserTask].self, from: data) else { return [] }
        return list
    }

    private func saveTasks() {
        tasks = Array(tasks.suffix(50))
        if let data = try? JSONEncoder().encode(tasks) { UserDefaults.standard.set(data, forKey: "userTasks") }
    }

    private func addTask(id: String?, text: String) {
        let key = id ?? text
        guard !tasks.contains(where: { $0.id == key }) else { return }
        tasks.append(UserTask(id: key, text: text, links: Phone.links(in: text), created: Date()))
        saveTasks()
        showTasks = true   // Жаңа тапсырма: бет өзі ашылады
    }

    private func setDone(_ task: UserTask) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[i].done = true
        saveTasks()
    }

    /// «Орындадым»: серверге хабар кетеді (сервер «жасадым» сөзін күтіп тұр)
    func taskDone(_ task: UserTask) {
        setDone(task)
        webTask = nil
        ask(text: "жасадым")
    }

    func removeTask(_ task: UserTask) {
        tasks.removeAll { $0.id == task.id }
        saveTasks()
    }

    func handle(url: URL) {
        // alikhan://open (Dynamic Island) не alikhan:// (Shortcut біткен соң): тек қосымшаға оралу
        if url.host == "talk" { startTalk() }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard phase == .active, booted, settings.configured else { return }
        if mode == .off { startTalk() }
        // Фонда басталмаған Live Activity-ді енді бастаймыз
        if settings.alwaysListen, !Island.shared.isRunning { Island.shared.start(content) }
    }

    // MARK: Хабарландыру

    private func startNotices() {
        guard noticesTask == nil else { return }
        noticesTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard self.settings.configured, !self.settings.token.isEmpty else {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }
                do {
                    let peek = try await API.shared.notifications(ack: false, wait: 20)
                    if !peek.isEmpty {
                        let items = try await API.shared.notifications(ack: true, wait: 0)
                        self.notices += items.filter { !($0.voice_text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        self.drainNotices()
                    }
                    await self.syncReminders()
                } catch {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }

    private var speakingNotice = false

    /// Сөйлесу жүріп жатса, біткенін күтеді.
    func drainNotices() {
        guard !speakingNotice, !notices.isEmpty, mode != .talk, !audio.isPlaying else { return }
        speakingNotice = true
        let notice = notices.removeFirst()
        let text = (notice.voice_text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Агент сізді күтіп тұр: «Тапсырмаларым» бетіне түседі
        if text.contains("күтіп тұр") || text.lowercased().contains("жасадым") { addTask(id: notice.id, text: text) }
        Task {
            let before = orb
            said = text
            setOrb(.speak)
            await say(text)
            if mode != .talk { setOrb(mode == .off ? .sleep : before == .error ? .sleep : before) }
            speakingNotice = false
            drainNotices()
        }
    }

    /// Серверде әлі жоқ (GET /reminders/pending): 404 болса, 10 минутта бір тексереді.
    private func syncReminders() async {
        let gap: TimeInterval = remindersMissing ? 600 : 60
        guard Date().timeIntervalSince(remindersCheckedAt) > gap, Reminders.shared.authorized else { return }
        remindersCheckedAt = Date()
        do {
            let items = try await API.shared.pendingReminders()
            remindersMissing = false
            await Reminders.shared.add(items)
        } catch {
            remindersMissing = true
        }
    }

    // MARK: Камера

    func captureFinished(file: URL?, mime: String, request: CaptureRequest) {
        capture = nil
        resumeAudio()
        guard let file else { return }
        Task {
            do {
                try await API.shared.upload(file: file, mime: mime, to: request.upload)
                said = "Жүктелді"
            } catch {
                said = "Жүктелмеді: \(error.localizedDescription)"
            }
            setOrb(.speak)
            await say(said)
            if mode == .talk { setOrb(.listen) }
        }
    }

    func captureStarted() {
        audio.stop()   // Камера микрофонды алады
    }
}
