import AVFoundation

/// Сөз анықтау (ноутбуктағы сандармен).
/// Бөлме шуы: соңғы 5 секундтағы ең тыныш 15% кадр, алғашқы 0,3 секундта өлшеніп, үнемі жаңарады.
/// Сөз деп тек шудан `ratio` (1,65) есе қатты дауыс саналады. 0,2 с үнсіздікте алдын ала тану, 0,8 с үнсіздікте сөйлем бітті.
final class VAD {
    static let rate = 16000.0
    static let frame = 480                 // 30 мс
    private let frameS = 0.03
    var ratio: Float = 1.65
    var maxLength = 15.0                   // ояту күйінде 4,5 с, ойнату кезінде 2,8 с
    var minSpeech = 0.4                    // жауаптан кейін 0,15 с: қысқа «иә», «жоқ»
    var endSilence = 0.8
    let earlyPause = 0.2
    let preRoll = 0.3
    private let floorRMS: Float = 0.002    // Тым тыныш бөлмеде де бір шек болсын

    private(set) var noise: Float = 0.003
    private var smooth: Float = 0
    private var history: [Float] = []      // Соңғы 5 с кадр деңгейлері
    private var pre: [[Float]] = []
    private var buffer: [Float] = []
    private var inSpeech = false
    private var voicedRun = 0
    private var silenceFrames = 0
    private var earlySent = false

    enum Event {
        case started
        case early([Float])        // 0,2 с үнсіздік: /stt/early
        case resumed               // Сөз жалғасты: алдын ала тануды ұмыт
        case utterance([Float])    // 0,8 с үнсіздік не шекке жетті
    }

    var speaking: Bool { inSpeech }

    func reset() {
        pre.removeAll()
        buffer.removeAll()
        inSpeech = false
        voicedRun = 0
        silenceFrames = 0
        earlySent = false
    }

    private func updateNoise(_ rms: Float) {
        history.append(rms)
        if history.count > 167 { history.removeFirst() }
        // Алғашқы 0,3 с (10 кадр) өлшеген соң, әр 5 кадрда жаңарады
        guard history.count >= 10, history.count == 10 || history.count % 5 == 0 else { return }
        let sorted = history.sorted()
        noise = max(sorted[Int(Double(sorted.count - 1) * 0.15)], 0.0005)
    }

    func push(_ f: [Float]) -> Event? {
        var sum: Float = 0
        for x in f { sum += x * x }
        let rms = (sum / Float(f.count)).squareRoot()
        smooth = smooth * 0.5 + rms * 0.5      // Бір кадрлық тықыр сөз болып саналмасын
        updateNoise(rms)
        let loud = smooth > max(noise * ratio, floorRMS)

        if !inSpeech {
            pre.append(f)
            if Double(pre.count) * frameS > preRoll + minSpeech { pre.removeFirst() }
            voicedRun = loud ? voicedRun + 1 : 0
            if Double(voicedRun) * frameS >= minSpeech {
                inSpeech = true
                buffer = pre.flatMap { $0 }
                pre.removeAll()
                silenceFrames = 0
                earlySent = false
                return .started
            }
            return nil
        }

        buffer += f
        if loud {
            let wasPaused = earlySent
            silenceFrames = 0
            earlySent = false
            if wasPaused { return .resumed }
        } else {
            silenceFrames += 1
        }
        let silence = Double(silenceFrames) * frameS
        let length = Double(buffer.count) / VAD.rate
        if silence >= endSilence || length >= maxLength {
            let out = buffer
            reset()
            return .utterance(out)
        }
        if !earlySent, silence >= earlyPause, length >= 0.4 {
            earlySent = true
            return .early(buffer)
        }
        return nil
    }
}

/// Серверге жіберер алдында сығу: AAC/m4a, 16 кГц, моно, 24 кбит/с. Болмаса, WAV.
enum Encoder {
    static func compress(_ samples: [Float]) -> Encoded {
        for bitrate in [24000, 0] {
            if let data = aac(samples, bitrate: bitrate) { return Encoded(data: data, filename: "speech.m4a", mime: "audio/mp4") }
        }
        return Encoded(data: wav(samples), filename: "speech.wav", mime: "audio/wav")
    }

    private static func aac(_ samples: [Float], bitrate: Int) -> Data? {
        guard !samples.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        var settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: VAD.rate, AVNumberOfChannelsKey: 1]
        if bitrate > 0 { settings[AVEncoderBitRateKey] = bitrate }
        do {
            try autoreleasepool {
                // Файл осы блоктан шыққанда жабылады
                let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
                      let ch = buf.floatChannelData else { throw APIError.noServer }
                buf.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: samples.count) }
                try file.write(from: buf)
            }
            let data = try Data(contentsOf: url)
            return data.count > 100 ? data : nil
        } catch {
            return nil
        }
    }

    static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let rate = UInt32(VAD.rate)
        d.append(Data("RIFF".utf8)); u32(UInt32(36 + samples.count * 2)); d.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(UInt32(samples.count * 2))
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        return d
    }
}

/// Микрофон мен динамик (2611081845 нұсқасындағы тұрақты тәсіл: AVAudioEngine тек микрофонға,
/// жауап AVAudioPlayer не AVPlayer арқылы ойнайды). Барлық сыртқы шақыру мен оқиғалар негізгі ағында.
final class AudioIO: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    let vad = VAD()
    var onEvent: ((VAD.Event) -> Void)?
    var onInterrupted: (() -> Void)?
    var onResume: (() -> Void)?
    var onFirstAudio: (() -> Void)?      // Алғашқы дыбыс шыққан сәт: «сөйлеу» күйі

    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "kz.ersultan.alikhan.audio")
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VAD.rate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var pending: [Float] = []
    private var player: AVAudioPlayer?
    private var streamPlayer: AVPlayer?
    private var streamObservers: [NSObjectProtocol] = []
    private var streamStarted = false
    private var statusObservation: NSKeyValueObservation?
    private let synth = AVSpeechSynthesizer()
    private var finishPlayback: (() -> Void)?
    private var headsetMic = false
    private var wantVoiceProcessing = false
    private(set) var voiceProcessing = false
    private var startedAt = Date.distantPast   // Өзіміз қосқан сәт: сол кездегі «баптау өзгерді» хабарын елемейміз

    // Ойнату кезінде микрофон тек «Алихан» деп бөлу үшін тыңдайды (2,8 с бөліктер), одан кейін 0,25 с еленбейді.
    private let lock = NSLock()
    private var _muteUntil: TimeInterval = 0
    private var muteUntil: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _muteUntil }
        set { lock.lock(); _muteUntil = newValue; lock.unlock() }
    }
    private var normalMax = 15.0

    private(set) var isPlaying = false
    private(set) var isPaused = false
    var isRunning: Bool { engine.isRunning }

    override init() {
        super.init()
        synth.delegate = self
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(interruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(mediaReset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        nc.addObserver(self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
    }

    // MARK: Сессия

    func configureSession(headsetMic: Bool) throws {
        self.headsetMic = headsetMic
        let s = AVAudioSession.sharedInstance()
        // mixWithOthers: Яндекс Музыка тоқтамайды. A2DP: наушникке жоғары сапа. HFP тек «Наушник микрофоны» қосулы болса.
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
        if headsetMic { options.insert(.allowBluetooth) }
        if s.category != .playAndRecord || s.categoryOptions != options {
            try s.setCategory(.playAndRecord, mode: .default, options: options)
        }
        try s.setActive(true)
        choosePreferredInput()
    }

    /// Voice Processing iOS-ты «сөйлесу» режиміне ауыстырады: дыбыс құлақ тұсындағы динамикке кетеді.
    /// Наушник жоқ болса, үлкен динамикке бағыттаймыз.
    private func forceSpeakerIfNeeded() {
        let s = AVAudioSession.sharedInstance()
        let outs = s.currentRoute.outputs.map(\.portType)
        if outs.contains(.builtInReceiver) || (voiceProcessing && !outs.contains(where: { [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay, .carAudio].contains($0) })) {
            try? s.overrideOutputAudioPort(.speaker)
        }
    }

    private func choosePreferredInput() {
        let s = AVAudioSession.sharedInstance()
        let inputs = s.availableInputs ?? []
        let want = headsetMic ? inputs.first(where: { $0.portType == .bluetoothHFP }) ?? inputs.first(where: { $0.portType == .builtInMic })
                              : inputs.first(where: { $0.portType == .builtInMic })
        // Қазір де сол болса, қайта қоймаймыз (әр қою жаңа өзгеріс хабарын туғызады)
        guard let want, s.preferredInput?.uid != want.uid else { return }
        try? s.setPreferredInput(want)
    }

    // MARK: Микрофон

    func start(headsetMic: Bool, voiceProcessing wantVP: Bool) throws {
        if engine.isRunning { return }
        wantVoiceProcessing = wantVP
        try configureSession(headsetMic: headsetMic)
        do {
            try startEngine(voiceProcessing: wantVP)
        } catch {
            // Voice Processing қосылмаса, онсыз (бұрынғыдай) жұмыс істей берсін
            guard wantVP else { throw error }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine = AVAudioEngine()
            try startEngine(voiceProcessing: false)
        }
    }

    private func startEngine(voiceProcessing wantVP: Bool) throws {
        let input = engine.inputNode
        voiceProcessing = false
        if wantVP {
            // Шуды басады, деңгейді теңестіреді. Яндекс Музыка бәсеңдемесін.
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            voiceProcessing = true
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw APIError.status(-1) }
        converter = AVAudioConverter(from: format, to: target)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            guard let self else { return }
            let samples = self.convert(buf)    // Буфер қайта қолданылады: бірден көшіреміз
            self.queue.async { self.process(samples) }
        }
        engine.prepare()
        try engine.start()
        startedAt = Date()
        forceSpeakerIfNeeded()
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .AVAudioEngineConfigurationChange, object: engine)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.async { self.pending.removeAll(); self.vad.reset() }
        if !isPlaying { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    func configure(ratio: Float, maxLength: Double, minSpeech: Double, endSilence: Double) {
        queue.async {
            self.vad.ratio = ratio
            self.vad.minSpeech = minSpeech
            self.vad.endSilence = endSilence
            self.normalMax = maxLength
            let want = self.isPlaying && !self.isPaused ? 2.8 : maxLength
            if self.vad.maxLength != want {
                self.vad.maxLength = want
                self.vad.reset()
            }
        }
    }

    private func convert(_ buf: AVAudioPCMBuffer) -> [Float] {
        guard let conv = converter else { return [] }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return [] }
        var fed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard error == nil, let ch = out.floatChannelData, out.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    private func process(_ samples: [Float]) {
        pending += samples
        while pending.count >= VAD.frame {
            let frame = Array(pending[0..<VAD.frame])
            pending.removeFirst(VAD.frame)
            if ProcessInfo.processInfo.systemUptime < muteUntil {
                vad.reset()   // Ойнау біткен соң 0,25 с: жаңғырық сөз болып саналмасын
                continue
            }
            if let event = vad.push(frame) {
                DispatchQueue.main.async { self.onEvent?(event) }
            }
        }
    }

    // MARK: Ойнату

    private func beginPlayback(_ completion: @escaping () -> Void) {
        stopPlayback()
        if !engine.isRunning { try? configureSession(headsetMic: headsetMic) }
        isPlaying = true
        isPaused = false
        finishPlayback = completion
        // Ойнату кезінде тек «Алихан» деп бөлу үшін тыңдаймыз: қысқа 2,8 с бөліктер
        queue.async { self.vad.maxLength = 2.8; self.vad.reset() }
    }

    private func firstAudio() {
        let f = onFirstAudio
        onFirstAudio = nil
        f?()
    }

    /// Толық mp3 (base64 `audio`) не wav
    func play(_ data: Data, completion: @escaping () -> Void) {
        beginPlayback(completion)
        forceSpeakerIfNeeded()
        guard let p = try? AVAudioPlayer(data: data) else { done(); return }
        player = p
        p.delegate = self
        if p.play() { firstAudio() } else { done() }
    }

    func play(_ data: Data) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            play(data) { c.resume() }
        }
    }

    /// `audio_url`: сілтеме бір рет жарамды, сондықтан бір сұраныспен толық жүктеп, AVAudioPlayer-мен ойнатамыз.
    /// (AVPlayer сілтемені бірнеше рет сұрайды: екіншісінде сервер бермей, дыбыс мүлде шықпай қалуы мүмкін.)
    func play(url: URL) async {
        var r = URLRequest(url: url)
        r.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              ((resp as? HTTPURLResponse)?.statusCode ?? 200) < 300, data.count > 200, !Task.isCancelled else { return }
        await play(data)
    }

    private func streamEnded(_ p: AVPlayer) {
        guard p === streamPlayer else { return }
        done()
    }

    /// Сервер дауысы жоқ кезде (желі әлсіз): телефонның өз дауысы.
    func speakLocally(_ text: String) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            beginPlayback { c.resume() }
            let u = AVSpeechUtterance(string: text)
            u.voice = AVSpeechSynthesisVoice(language: "kk-KZ") ?? AVSpeechSynthesisVoice(language: "ru-RU")
            synth.speak(u)
            firstAudio()
        }
    }

    func beep() {
        guard let url = Bundle.main.url(forResource: "beep", withExtension: "wav"), let data = try? Data(contentsOf: url) else { return }
        play(data) {}
    }

    /// «Алихан» деп бөлді: кідірту (тоқтатпау)
    func pausePlayback() {
        guard isPlaying, !isPaused else { return }
        isPaused = true
        player?.pause()
        streamPlayer?.pause()
        if synth.isSpeaking { synth.pauseSpeaking(at: .immediate) }
        let normal = normalMax
        queue.async { self.vad.maxLength = normal; self.vad.reset() }   // 4 с тыңдау: толық сөйлем
    }

    func resumePlayback() {
        guard isPlaying, isPaused else { return }
        isPaused = false
        player?.play()
        streamPlayer?.play()
        if synth.isPaused { synth.continueSpeaking() }
        queue.async { self.vad.maxLength = 2.8; self.vad.reset() }
    }

    func stopPlayback() {
        player?.stop()
        streamPlayer?.pause()
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        if isPlaying { done() }
    }

    private func done() {
        player = nil
        streamPlayer?.pause()
        streamPlayer = nil
        streamObservers.forEach { NotificationCenter.default.removeObserver($0) }
        streamObservers.removeAll()
        statusObservation = nil
        isPlaying = false
        isPaused = false
        muteUntil = ProcessInfo.processInfo.systemUptime + 0.25
        let normal = normalMax
        queue.async { self.vad.maxLength = normal; self.vad.reset() }
        let f = finishPlayback
        finishPlayback = nil
        f?()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { if player === self.player { self.done() } }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { if player === self.player { self.done() } }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { if self.isPlaying && self.player == nil && self.streamPlayer == nil { self.done() } }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { if self.isPlaying && self.player == nil && self.streamPlayer == nil { self.done() } }
    }

    // MARK: Үзілістер: қоңырау, Siri, басқа қосымша

    @objc private func interruption(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            if type == .began {
                self.stopPlayback()
                self.onInterrupted?()
            } else {
                self.onResume?()
            }
        }
    }

    @objc private func mediaReset() {
        DispatchQueue.main.async {
            self.engine = AVAudioEngine()
            self.onResume?()
        }
    }

    @objc private func configChanged() {
        // Наушник қосылды/ажыратылды. Бірақ өзіміз қосқан сәттегі хабарды елемейміз,
        // әйтпесе шексіз қайта қосылып, микрофон өшіп-жанады, дыбыс бірде азайып, бірде қосылады.
        DispatchQueue.main.async {
            guard Date().timeIntervalSince(self.startedAt) > 2, !self.engine.isRunning else { return }
            self.onResume?()
        }
    }

    @objc private func routeChanged(_ n: Notification) {
        // Тек құрылғы шынымен қосылғанда не ажыратылғанда
        guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { self.choosePreferredInput() }
    }
}
