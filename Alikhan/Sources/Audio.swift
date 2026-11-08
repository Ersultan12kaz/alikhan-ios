import AVFoundation

/// Сөз анықтау. Бөлме шуын үйренеді: кадр шудан `ratio` есе қатты болса ғана сөз.
/// Қысқа «иә» де ұсталады (0,15 с), 0,9 с үнсіздік — сөйлем бітті.
final class VAD {
    static let rate = 16000.0
    static let frame = 480                 // 30 мс
    private let frameS = 0.03
    var ratio: Float = 1.65
    var maxLength = 15.0                   // ояту күйінде 4,5 с
    let minSpeech = 0.15
    let silenceEnd = 0.9
    let preRoll = 0.3
    private let floorRMS: Float = 0.0035   // Тым тыныш бөлмеде де бір шек болсын

    private(set) var noise: Float = 0.004
    private var pre: [[Float]] = []
    private var buffer: [Float] = []
    private var inSpeech = false
    private var voicedRun = 0
    private var silenceFrames = 0

    enum Event { case started, utterance([Float]) }

    var speaking: Bool { inSpeech }

    func reset() {
        pre.removeAll()
        buffer.removeAll()
        inSpeech = false
        voicedRun = 0
        silenceFrames = 0
    }

    func push(_ f: [Float]) -> Event? {
        var sum: Float = 0
        for x in f { sum += x * x }
        let rms = (sum / Float(f.count)).squareRoot()
        let loud = rms > max(noise * ratio, floorRMS)

        if !inSpeech {
            // Шу деңгейі: тыныш кадрда тез үйренеді, қатты кадрда өте баяу (бөлме біржола шулы болса да бейімделеді)
            noise += (rms - noise) * (loud ? 0.002 : (rms < noise ? 0.1 : 0.02))
            pre.append(f)
            if Double(pre.count) * frameS > preRoll + minSpeech { pre.removeFirst() }
            voicedRun = loud ? voicedRun + 1 : 0
            if Double(voicedRun) * frameS >= minSpeech {
                inSpeech = true
                buffer = pre.flatMap { $0 }
                pre.removeAll()
                silenceFrames = 0
                return .started
            }
            return nil
        }

        buffer += f
        silenceFrames = loud ? 0 : silenceFrames + 1
        let length = Double(buffer.count) / VAD.rate
        if Double(silenceFrames) * frameS >= silenceEnd || length >= maxLength {
            let out = buffer
            reset()
            return .utterance(out)
        }
        return nil
    }
}

/// Серверге жіберер алдында сығу: AAC/m4a, 16 кГц, моно. Болмаса, WAV.
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

/// Микрофон мен динамик. Барлық сыртқы шақыру мен `onEvent` негізгі ағында.
final class AudioIO: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    let vad = VAD()
    var onEvent: ((VAD.Event) -> Void)?
    var onInterrupted: (() -> Void)?
    var onResume: (() -> Void)?

    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "kz.ersultan.alikhan.audio")
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VAD.rate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var pending: [Float] = []
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var finishPlayback: (() -> Void)?
    private var headsetMic = false

    // Ойнату кезінде және одан кейін 0,3 с микрофон кірісі еленбейді (queue ағынында оқылады)
    private let lock = NSLock()
    private var _muteUntil: TimeInterval = 0
    private var muteUntil: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _muteUntil }
        set { lock.lock(); _muteUntil = newValue; lock.unlock() }
    }

    private(set) var isPlaying = false
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
        // mixWithOthers: Яндекс Музыка тоқтамайды. A2DP: наушникке жоғары сапа.
        // allowBluetooth (HFP) тек «Наушник микрофоны» қосулы болса.
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
        if headsetMic { options.insert(.allowBluetooth) }
        try s.setCategory(.playAndRecord, mode: .default, options: options)
        try s.setActive(true)
        choosePreferredInput()
    }

    private func choosePreferredInput() {
        let s = AVAudioSession.sharedInstance()
        let inputs = s.availableInputs ?? []
        if headsetMic, let bt = inputs.first(where: { $0.portType == .bluetoothHFP }) {
            try? s.setPreferredInput(bt)
        } else if let mic = inputs.first(where: { $0.portType == .builtInMic }) {
            try? s.setPreferredInput(mic)
        }
    }

    // MARK: Микрофон

    func start(headsetMic: Bool) throws {
        if engine.isRunning { return }
        try configureSession(headsetMic: headsetMic)
        let input = engine.inputNode
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
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .AVAudioEngineConfigurationChange, object: engine)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.async { self.pending.removeAll(); self.vad.reset() }
        if !isPlaying { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    func restart() {
        let hs = headsetMic
        stop()
        try? start(headsetMic: hs)
    }

    func configure(ratio: Float, maxLength: Double) {
        queue.async {
            self.vad.ratio = ratio
            if self.vad.maxLength != maxLength {
                self.vad.maxLength = maxLength
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
                vad.reset()   // Өз дауысын сөз деп қабылдамайды
                continue
            }
            if let event = vad.push(frame) {
                DispatchQueue.main.async { self.onEvent?(event) }
            }
        }
    }

    // MARK: Ойнату

    func play(_ data: Data, completion: @escaping () -> Void) {
        stopPlayback()
        guard let p = try? AVAudioPlayer(data: data) else { completion(); return }
        if !engine.isRunning { try? configureSession(headsetMic: headsetMic) }
        muteUntil = .infinity
        isPlaying = true
        finishPlayback = completion
        player = p
        p.delegate = self
        if !p.play() { done() }
    }

    func play(_ data: Data) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            play(data) { c.resume() }
        }
    }

    /// Сервер дауысы жоқ кезде (желі әлсіз): телефонның өз дауысы.
    func speakLocally(_ text: String) async {
        stopPlayback()
        if !engine.isRunning { try? configureSession(headsetMic: headsetMic) }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            muteUntil = .infinity
            isPlaying = true
            finishPlayback = { c.resume() }
            let u = AVSpeechUtterance(string: text)
            u.voice = AVSpeechSynthesisVoice(language: "kk-KZ") ?? AVSpeechSynthesisVoice(language: "ru-RU")
            synth.speak(u)
        }
    }

    func beep() {
        guard let url = Bundle.main.url(forResource: "beep", withExtension: "wav"), let data = try? Data(contentsOf: url) else { return }
        play(data) {}
    }

    func stopPlayback() {
        player?.stop()
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        if isPlaying { done() }
    }

    private func done() {
        player = nil
        isPlaying = false
        muteUntil = ProcessInfo.processInfo.systemUptime + 0.3
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
        DispatchQueue.main.async { if self.isPlaying && self.player == nil { self.done() } }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { if self.isPlaying && self.player == nil { self.done() } }
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
        // Наушник қосылды/ажыратылды: формат өзгерді, қайта бастаймыз
        DispatchQueue.main.async { self.onResume?() }
    }

    @objc private func routeChanged(_ n: Notification) {
        DispatchQueue.main.async { self.choosePreferredInput() }
    }
}
