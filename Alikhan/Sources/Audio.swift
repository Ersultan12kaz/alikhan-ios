import AudioToolbox
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

/// mp3 ағынын бөлшектеп декодтайды: алғашқы бөліктер келгенде ойнай бастайды (AudioFileStream + AVAudioConverter).
final class MP3Stream {
    private var streamID: AudioFileStreamID?
    private var srcFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private(set) var outFormat: AVAudioFormat?
    var onReady: ((AVAudioFormat) -> Void)?
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    init() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        AudioFileStreamOpen(ctx, { client, stream, prop, _ in
            let me = Unmanaged<MP3Stream>.fromOpaque(client).takeUnretainedValue()
            if prop == kAudioFileStreamProperty_ReadyToProducePackets { me.prepare(stream) }
        }, { client, numBytes, numPackets, data, descs in
            let me = Unmanaged<MP3Stream>.fromOpaque(client).takeUnretainedValue()
            me.packets(numBytes, numPackets, data, descs)
        }, kAudioFileMP3Type, &streamID)
    }

    deinit {
        if let streamID { AudioFileStreamClose(streamID) }
    }

    func feed(_ data: Data) {
        guard let streamID, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            _ = AudioFileStreamParseBytes(streamID, UInt32(raw.count), raw.baseAddress!, [])
        }
    }

    private func prepare(_ stream: AudioFileStreamID) {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &asbd) == noErr,
              let src = AVAudioFormat(streamDescription: &asbd),
              let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate,
                                      channels: max(1, asbd.mChannelsPerFrame), interleaved: false) else { return }
        srcFormat = src
        outFormat = out
        converter = AVAudioConverter(from: src, to: out)
        onReady?(out)
    }

    private func packets(_ numBytes: UInt32, _ numPackets: UInt32, _ data: UnsafeRawPointer,
                         _ descs: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard let src = srcFormat, let out = outFormat, let conv = converter, let descs, numPackets > 0 else { return }
        var maxSize = 0
        for i in 0..<Int(numPackets) { maxSize = max(maxSize, Int(descs[i].mDataByteSize)) }
        let comp = AVAudioCompressedBuffer(format: src, packetCapacity: AVAudioPacketCount(numPackets), maximumPacketSize: maxSize)
        memcpy(comp.data, data, Int(numBytes))
        comp.byteLength = numBytes
        comp.packetCount = numPackets
        if let pd = comp.packetDescriptions {
            for i in 0..<Int(numPackets) { pd[i] = descs[i] }
        }
        let perPacket = max(AVAudioFrameCount(src.streamDescription.pointee.mFramesPerPacket), 1152)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: perPacket * numPackets + 4096) else { return }
        var fed = false
        var error: NSError?
        conv.convert(to: pcm, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return comp
        }
        if error == nil, pcm.frameLength > 0 { onBuffer?(pcm) }
    }

    /// Ағын бітті: декодерде қалған кадрлар
    func finish() {
        guard let out = outFormat, let conv = converter,
              let pcm = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: 8192) else { return }
        var error: NSError?
        conv.convert(to: pcm, error: &error) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        if error == nil, pcm.frameLength > 0 { onBuffer?(pcm) }
    }
}

/// Микрофон мен динамик. Барлық сыртқы шақыру мен `onEvent` негізгі ағында.
/// Ойнату да осы AVAudioEngine арқылы жүреді: сонда Voice Processing Алиханның өз дауысын микрофоннан алып тастайды.
final class AudioIO: NSObject, AVSpeechSynthesizerDelegate, URLSessionDataDelegate {
    let vad = VAD()
    var onEvent: ((VAD.Event) -> Void)?
    var onFirstAudio: (() -> Void)?      // Алғашқы дыбыс шыққан сәт: «сөйлеу» күйі
    var onInterrupted: (() -> Void)?
    var onResume: (() -> Void)?

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var playerFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "kz.ersultan.alikhan.audio")
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VAD.rate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var pending: [Float] = []
    private let synth = AVSpeechSynthesizer()
    private var headsetMic = false
    private(set) var voiceProcessing = false

    // Ойнату күйі
    private var finishPlayback: (() -> Void)?
    private var scheduled = 0
    private var inputDone = true
    private var playToken = 0
    private var stream: MP3Stream?
    private var download: URLSessionDataTask?
    private lazy var streamSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    // Ойнату кезінде және одан кейін 0,25 с кіріс еленбейді (Voice Processing жоқ болса). queue ағынында оқылады.
    private let lock = NSLock()
    private var _muteUntil: TimeInterval = 0
    private var muteUntil: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _muteUntil }
        set { lock.lock(); _muteUntil = newValue; lock.unlock() }
    }
    private var _normalMax = 15.0

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

    func start(headsetMic: Bool, voiceProcessing wantVP: Bool) throws {
        if engine.isRunning { return }
        try configureSession(headsetMic: headsetMic)
        do {
            try startEngine(voiceProcessing: wantVP)
        } catch {
            // Voice Processing қосылмаса, онсыз жұмыс істей берсін
            guard wantVP else { throw error }
            reset()
            try startEngine(voiceProcessing: false)
        }
    }

    private func startEngine(voiceProcessing wantVP: Bool) throws {
        let input = engine.inputNode
        voiceProcessing = false
        if wantVP {
            // Шуды басады, деңгейді теңестіреді, жаңғырықты (Алиханның өз дауысын) алып тастайды
            try input.setVoiceProcessingEnabled(true)
            voiceProcessing = true
            // Яндекс Музыка бәсеңдемесін
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        if player.engine == nil { engine.attach(player) }
        _ = engine.mainMixerNode   // Шығыс тізбегі бар болсын
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

    /// Қозғалтқышты жаңадан құрады (қате не формат өзгерсе)
    private func reset() {
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        playerFormat = nil
    }

    func stop() {
        stopPlayback()
        reset()
        queue.async { self.pending.removeAll(); self.vad.reset() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func configure(ratio: Float, maxLength: Double, minSpeech: Double, endSilence: Double) {
        queue.async {
            self.vad.ratio = ratio
            self.vad.minSpeech = minSpeech
            self.vad.endSilence = endSilence
            self._normalMax = maxLength
            let want = self.isPlaying && !self.isPaused && self.voiceProcessing ? 2.8 : maxLength
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
                vad.reset()   // Өз дауысын сөз деп қабылдамайды
                continue
            }
            if let event = vad.push(frame) {
                DispatchQueue.main.async { self.onEvent?(event) }
            }
        }
    }

    // MARK: Ойнату (бәрі AVAudioPlayerNode арқылы)

    private func ensureEngineForPlayback() {
        if engine.isRunning { return }
        try? start(headsetMic: headsetMic, voiceProcessing: true)
    }

    private func connect(_ format: AVAudioFormat) {
        if let f = playerFormat, f == format { return }
        player.stop()
        engine.connect(player, to: engine.mainMixerNode, format: format)
        playerFormat = format
    }

    private func beginPlayback(_ completion: @escaping () -> Void) -> Int {
        stopPlayback()
        ensureEngineForPlayback()
        playToken += 1
        isPlaying = true
        isPaused = false
        scheduled = 0
        inputDone = false
        finishPlayback = completion
        let barge = voiceProcessing
        queue.async {
            if barge {
                // Voice Processing бар: ойнату кезінде де тыңдаймыз, тек «Алихан»-ды тану үшін (2,8 с бөліктер)
                self.vad.maxLength = 2.8
                self.vad.reset()
            }
        }
        if !barge { muteUntil = .infinity }
        return playToken
    }

    /// Барлық кадр ойнап болса: бітті
    private func checkDone(_ token: Int) {
        guard token == playToken, isPlaying, inputDone, scheduled == 0 else { return }
        done()
    }

    private func schedule(_ buf: AVAudioPCMBuffer, token: Int) {
        DispatchQueue.main.async {
            guard token == self.playToken, self.isPlaying else { return }
            self.connect(buf.format)
            self.scheduled += 1
            if let first = self.onFirstAudio {
                self.onFirstAudio = nil
                first()
            }
            self.player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, token == self.playToken else { return }
                    self.scheduled -= 1
                    self.checkDone(token)
                }
            }
            if !self.isPaused && !self.player.isPlaying { self.player.play() }
        }
    }

    /// Толық mp3 (base64 `audio`)
    func play(_ data: Data) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let token = beginPlayback { c.resume() }
            let s = MP3Stream()
            s.onBuffer = { [weak self] b in self?.schedule(b, token: token) }
            stream = s
            s.feed(data)
            s.finish()
            DispatchQueue.main.async {
                self.inputDone = true
                self.checkDone(token)
            }
        }
    }

    /// Ағынмен ойнату (`audio_url`): алғашқы бөліктер келгенде басталады
    func play(url: URL) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let token = beginPlayback { c.resume() }
            let s = MP3Stream()
            s.onBuffer = { [weak self] b in self?.schedule(b, token: token) }
            stream = s
            let task = streamSession.dataTask(with: url)
            task.taskDescription = String(token)
            download = task
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask.taskDescription == String(playToken) else { return }
        stream?.feed(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let token = Int(task.taskDescription ?? "") else { return }
        if error == nil { stream?.finish() }
        DispatchQueue.main.async {
            guard token == self.playToken else { return }
            self.inputDone = true
            self.checkDone(token)
        }
    }

    func beep() {
        guard let url = Bundle.main.url(forResource: "beep", withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil else { return }
        let token = beginPlayback {}
        schedule(buf, token: token)
        DispatchQueue.main.async { self.inputDone = true }
    }

    /// Сервер дауысы жоқ кезде (желі әлсіз): телефонның өз дауысы, сол қозғалтқыш арқылы
    func speakLocally(_ text: String) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let token = beginPlayback { c.resume() }
            let u = AVSpeechUtterance(string: text)
            u.voice = AVSpeechSynthesisVoice(language: "kk-KZ") ?? AVSpeechSynthesisVoice(language: "ru-RU")
            synth.write(u) { [weak self] buffer in
                guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    DispatchQueue.main.async {
                        self.inputDone = true
                        self.checkDone(token)
                    }
                } else {
                    self.schedule(pcm, token: token)
                }
            }
        }
    }

    /// «Алихан» деп бөлді: кідірту (тоқтатпау)
    func pausePlayback() {
        guard isPlaying, !isPaused else { return }
        isPaused = true
        player.pause()
        let normal = _normalMax
        queue.async { self.vad.maxLength = normal; self.vad.reset() }   // 4 с тыңдау: толық сөйлем
    }

    func resumePlayback() {
        guard isPlaying, isPaused else { return }
        isPaused = false
        player.play()
        let barge = voiceProcessing
        queue.async { if barge { self.vad.maxLength = 2.8 }; self.vad.reset() }
    }

    func stopPlayback() {
        download?.cancel()
        download = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        if isPlaying { done() }
        player.stop()
    }

    private func done() {
        playToken += 1
        isPlaying = false
        isPaused = false
        stream = nil
        muteUntil = ProcessInfo.processInfo.systemUptime + 0.25
        let normal = _normalMax
        queue.async {
            self.vad.maxLength = normal
            self.vad.reset()
        }
        let f = finishPlayback
        finishPlayback = nil
        f?()
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
            self.reset()
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
