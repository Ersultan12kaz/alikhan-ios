import AVFoundation
import SwiftUI

/// Қосымша ішіндегі «Сервер экраны» (noVNC)
struct ServerScreen: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let askId: String?
}

struct CaptureRequest: Identifiable {
    let id = UUID()
    let video: Bool
    let upload: URL
    var askId: String? = nil
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
    @Published private(set) var asks: [Ask] = []    // «Тапсырмаларым»: негізгі көзі GET /asks
    @Published var showTasks = false                 // «Тапсырмаларым» беті
    @Published var serverScreen: ServerScreen?       // Қосымша ішіндегі сервер экраны
    @Published private(set) var uploadProgress: Double?
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
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            MainActor.assumeIsolated { Island.shared.heartbeat() }
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
        Task {
            await refreshAsks()
            await AppDelegate.registerForPush()   // Токен әр ашылғанда қайта жіберіледі
        }
    }

    func requestPermissions() async {
        _ = await AVAudioApplication.requestRecordPermission()
        await Phone.requestContacts()
        await Reminders.shared.requestAccess()
        await AppDelegate.registerForPush()
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
    func startTalk(idle: TimeInterval = 10) {
        guard ensureAudio(maxLength: 15) else { return }
        mode = .talk
        idleDeadline = Date().addingTimeInterval(idle)
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
        if words >= 2 || (!asks.isEmpty && tail.contains("жасад")) {
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
        if heard.lowercased().contains("жасад") { Task { await refreshAsks() } }
        if let items = r.reminders, !items.isEmpty { Task { await Reminders.shared.add(items) } }
        if let b64 = r.audio, !b64.isEmpty, let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
            setOrb(.speak)
            await audio.play(data)
            guard my == gen else { return }
        }
        // Ойнату бітті: әрекетті күтпей, бірден «тыңдау»
        if r.end != true {
            idleDeadline = Date().addingTimeInterval(10)
            setOrb(.listen)
        }
        await perform(action: r.action ?? "none", arg: r.arg ?? "", url: r.url ?? "")
        guard my == gen else { return }
        if r.end == true {
            endTalk()   // «Рахмет, бара бер», «болды», «сау бол»
        } else if orb == .speak {
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
            if !(await Phone.open(url.isEmpty ? arg : url)) {
                said = "Бұл қосымша телефонда жоқ не ашылмады"
                setOrb(.speak)
                await say(said)
            }
        case "next", "previous", "pause", "play", "volume", "open_app":
            // Контактілер, Баптаулар, Камера сияқты қосымшалардың ашық схемасы жоқ: «Алихан басқару» Shortcut-ы ашады
            await Phone.runShortcut("\(action):\(arg)")
        case "capture":
            // Серверде әлі жоқ: келсе, камера ашылады
            if let target = URL(string: url), API.shared.isOwnServer(target) { capture = CaptureRequest(video: arg != "photo", upload: target) }
        default:
            break
        }
    }

    // MARK: Тапсырмаларым (ask)

    func refreshAsks() async {
        guard settings.configured, !settings.token.isEmpty, let list = try? await API.shared.asks() else { return }
        // Ең ескісі жоғарыда
        asks = list.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
    }

    /// «Орындадым» / «Бас тарту»: серверге кетеді, жауабы ойнатылады
    func finishAsk(_ id: String, cancel: Bool = false) {
        asks.removeAll { $0.ask_id == id }
        if serverScreen?.askId == id { serverScreen = nil }
        Task {
            do {
                let r = cancel ? try await API.shared.askCancel(id) : try await API.shared.askDone(id)
                await playReply(text: r.text, audio: r.audio)
            } catch {
                said = "Серверге жетпеді: \(error.localizedDescription)"
            }
            await refreshAsks()
        }
    }

    private func playReply(text: String?, audio b64: String?) async {
        if let t = text, !t.isEmpty { said = t }
        guard let b64, !b64.isEmpty, let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return }
        let before = orb
        setOrb(.speak)
        await audio.play(data)
        if orb == .speak { setOrb(mode == .talk ? .listen : (before == .error ? .sleep : before)) }
    }

    func openServerScreen(for ask: Ask) {
        guard let s = ask.remote_browser_url, let url = URL(string: s) else { return }
        serverScreen = ServerScreen(url: url, title: ask.heading, askId: ask.ask_id)
    }

    /// Кез келген уақытта сервер экранын ашу (аккаунттарға алдын ала кіріп қою)
    func openServerScreen() {
        Task {
            do {
                serverScreen = ServerScreen(url: try await API.shared.browserLink(), title: "Сервер экраны", askId: nil)
            } catch {
                status = "Сервер экраны ашылмады: \(error.localizedDescription)"
                said = status
            }
        }
    }

    func startCapture(for ask: Ask) {
        guard let c = ask.capture, let s = c.url, let url = URL(string: s), API.shared.isOwnServer(url) else { return }
        capture = CaptureRequest(video: c.arg != "photo", upload: url, askId: ask.ask_id)
    }

    /// Push келді не басылды
    func pushArrived(_ info: [AnyHashable: Any], opened: Bool) {
        Task { await refreshAsks(); await syncReminders(force: true) }
        guard opened else { return }
        let kind = info["kind"] as? String
        if kind == "ask" {
            let id = info["ask_id"] as? String ?? (info["ask_id"] as? Int).map(String.init)
            Task {
                await refreshAsks()
                if let id, let a = asks.first(where: { $0.ask_id == id }), a.remote_browser_url != nil {
                    openServerScreen(for: a)
                } else {
                    showTasks = true
                }
            }
        } else {
            showTasks = false
            serverScreen = nil
        }
    }

    func handle(url: URL) {
        // alikhan://open (Dynamic Island) не alikhan:// (Shortcut біткен соң): тек қосымшаға оралу
        if url.host == "talk" { startTalk() }
        if url.host == "shortcut-error" {
            said = "Бұл үшін «Алихан басқару» Shortcut-ы керек"
            Task {
                setOrb(.speak)
                await say(said)
                setOrb(mode == .talk ? .listen : .sleep)
            }
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard phase == .active, booted, settings.configured else { return }
        Task { await refreshAsks() }
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
                        self.notices += items
                        if items.contains(where: { $0.kind == "ask" }) { await self.refreshAsks() }
                        self.drainNotices()
                    }
                    await self.syncReminders()
                    if Date().timeIntervalSince(self.asksCheckedAt) > 15 {   // Тізім 15 секунд сайын жаңарады
                        self.asksCheckedAt = Date()
                        await self.refreshAsks()
                    }
                } catch {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }

    private var speakingNotice = false
    private var asksCheckedAt = Date.distantPast

    /// Сөйлесу жүріп жатса, біткенін күтеді.
    func drainNotices() {
        guard !speakingNotice, !notices.isEmpty, mode != .talk, !audio.isPlaying else { return }
        speakingNotice = true
        let notice = notices.removeFirst()
        let text = (notice.voice_text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // ask: «Тапсырмаларым» бетіне түседі (әрі дауыспен айтылады)
        if notice.kind == "ask" { showTasks = true }
        guard !text.isEmpty else { speakingNotice = false; drainNotices(); return }
        Task {
            let before = orb
            said = text
            setOrb(.speak)
            await say(text)
            speakingNotice = false
            if notice.kind == "question" {
                // Сұрақ тек дауыспен: жауабын 8 секунд тыңдаймыз, ол /phone-ға кетеді
                startTalk(idle: 8)
                return
            }
            if mode != .talk { setOrb(mode == .off ? .sleep : before == .error ? .sleep : before) }
            drainNotices()
        }
    }

    /// GET /reminders/pending: минутына бір рет және push келгенде. 404 болса, 10 минутта бір.
    private func syncReminders(force: Bool = false) async {
        let gap: TimeInterval = remindersMissing ? 600 : 60
        guard force || Date().timeIntervalSince(remindersCheckedAt) > gap, Reminders.shared.authorized else { return }
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
        uploadProgress = 0
        Uploader.shared.onProgress = { [weak self] p in self?.uploadProgress = p }
        Uploader.shared.onFinish = { [weak self] result in
            guard let self else { return }
            self.uploadProgress = nil
            Task {
                switch result {
                case .success(let reply):
                    if let reply { await self.playReply(text: reply.text ?? "Жүктелді", audio: reply.audio) } else { self.said = "Жүктелді" }
                case .failure(let error):
                    self.said = "Жүктелмеді: \(error.localizedDescription)"
                    self.setOrb(.speak)
                    await self.say(self.said)
                    if self.mode == .talk { self.setOrb(.listen) }
                }
                await self.refreshAsks()
            }
        }
        do {
            try Uploader.shared.upload(file: file, mime: mime, to: request.upload)
        } catch {
            uploadProgress = nil
            said = "Жүктелмеді: \(error.localizedDescription)"
        }
    }

    func captureStarted() {
        audio.stop()   // Камера микрофонды алады
    }
}
