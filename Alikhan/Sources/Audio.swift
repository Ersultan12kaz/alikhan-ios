import AudioToolbox
import AVFoundation
import SoundAnalysis

/// Сөз анықтау (ноутбуктағы сандармен).
/// Сөз = Apple SoundAnalysis «speech» ≥ 0,5 ЖӘНЕ дыбыс бөлме шуынан ≥ 1,65 есе қатты. Абсолютті қаттылық шегі жоқ:
/// ақырын әрі анық сөз де ұсталады, ал теледидар мен шу (танығыш «сөз емес» десе) оятпайды.
/// 0,2 с үнсіздікте алдын ала тану, 0,8 с үнсіздікте сөйлем бітті.
final class VAD {
    static let rate = 16000.0
    static let frame = 480                 // 30 мс
    private let frameS = 0.03
    var ratio: Float = 1.65
    var maxLength = 15.0                   // ояту күйінде 4,5 с, ойнату кезінде 2,8 с
    var minSpeech = 0.4                    // жауаптан кейін 0,15 с: қысқа «иә», «жоқ»
    var endSilence = 0.8
    let earlyPause = 0.2
    let preRoll = 0.6                      // Танығыш 0,25–0,5 с кешігеді: сөз басы кесілмесін

    private(set) var noise: Float = 0.001  // Бөлме шуы: сөз жоқ кезде үнемі жаңарады
    private var smooth: Float = 0
    private(set) var level: Float = 0      // Соңғы кадр деңгейі (экранда көрсету үшін)
    // SoundAnalysis: «бұл адам сөзі ме?» (ноутбуктағы Silero VAD орнына)
    var useClassifier = false
    private(set) var speechProb: Float = 0
    private var speechAt: TimeInterval = 0
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

    /// Танығыштың соңғы нәтижесі (0,25 с сайын келеді)
    func setSpeech(_ p: Float) {
        speechProb = p
        speechAt = ProcessInfo.processInfo.systemUptime
    }

    /// Бөлме шуы сөз жоқ кезде: көтерілсе баяу (×0,05), түссе тез (×0,2). Тұрақты шек жоқ.
    private func updateNoise(_ rms: Float) {
        noise += (rms - noise) * (rms > noise ? 0.05 : 0.2)
        noise = max(noise, 1e-6)
    }

    func push(_ f: [Float]) -> Event? {
        var sum: Float = 0
        for x in f { sum += x * x }
        let rms = (sum / Float(f.count)).squareRoot()
        smooth = smooth * 0.5 + rms * 0.5      // Бір кадрлық тықыр сөз болып саналмасын
        level = smooth
        // Сөз = (танығыш «сөз» ≥ 0,5) ЖӘНЕ (бөлме шуынан ≥ 1,65 есе қатты). Ақырын әрі анық сөз де өтеді.
        let isSpeech = !useClassifier || (ProcessInfo.processInfo.systemUptime - speechAt < 0.8 && speechProb >= 0.5)
        let loud = smooth > noise * ratio && isSpeech
        if !inSpeech && !loud { updateNoise(rms) }

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

/// Серверге жіберу. Сөйлем (/phone, /stt/early) ноутбуктағыдай сығусыз WAV 16 кГц/16 бит:
/// AAC 24 кбит/с «с», «ш», «қ» сияқты дыбыстарды бұзып, тану нашарлайтын.
/// «Алихан» растауы (қысқа бөлік) AAC 48 кбит/с: батарея мен трафик үшін.
enum Encoder {
    /// Сөйлем: деңгейі теңестірілген WAV
    static func speech(_ samples: [Float]) -> Encoded {
        Encoded(data: wav(normalize(samples)), filename: "speech.wav", mime: "audio/wav")
    }

    /// «Алихан» растауы: AAC, болмаса WAV
    static func compress(_ samples: [Float]) -> Encoded {
        let x = normalize(samples)
        for bitrate in [48000, 32000, 0] {
            if let data = aac(x, bitrate: bitrate) { return Encoded(data: data, filename: "speech.m4a", mime: "audio/mp4") }
        }
        return Encoded(data: wav(x), filename: "speech.wav", mime: "audio/wav")
    }

    /// Ақырын жазбаны көтереміз: ең қатты нүкте ≈ −3 dBFS, бірақ 8 еседен аспайды (шу да көтеріліп кетпесін)
    static func normalize(_ samples: [Float]) -> [Float] {
        var peak: Float = 0
        for x in samples { peak = max(peak, abs(x)) }
        guard peak > 1e-4 else { return samples }
        let gain = min(0.7 / peak, 8)
        guard gain > 1.05 else { return samples }
        return samples.map { max(-1, min(1, $0 * gain)) }
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


/// SoundAnalysis нәтижесі: `speech` класының сенімділігі
final class SpeechObserver: NSObject, SNResultsObserving {
    var onSpeech: ((Float) -> Void)?
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        onSpeech?(Float(r.classification(forIdentifier: "speech")?.confidence ?? 0))
    }
}

/// Микрофон мен динамик. Жауап микрофонмен бір AVAudioEngine арқылы ойнайды (AVAudioPlayerNode):
/// Voice Processing оны бәсеңдетпейді әрі микрофоннан Алиханның өз дауысын алып тастайды.
/// Декодтау сәтсіз болса, жиналған файл AVAudioPlayer-мен ойнайды. Барлық сыртқы шақыру негізгі ағында.
final class AudioIO: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate, URLSessionDataDelegate {
    let vad = VAD()
    var onEvent: ((VAD.Event) -> Void)?
    var onInterrupted: (() -> Void)?
    var onResume: (() -> Void)?
    var onFirstAudio: (() -> Void)?      // Алғашқы дыбыс шыққан сәт: «сөйлеу» күйі
    var onLevel: ((Float, Float) -> Void)?   // Микрофон деңгейі (dB) және «сөз» сенімділігі: баптау бетінде

    private var analyzer: SNAudioStreamAnalyzer?
    private let speechObserver = SpeechObserver()
    private let analysisQueue = DispatchQueue(label: "kz.ersultan.alikhan.analysis")
    private var analysisPos: AVAudioFramePosition = 0
    private var levelFrames = 0

    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "kz.ersultan.alikhan.audio")
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VAD.rate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var pending: [Float] = []
    private var player: AVAudioPlayer?          // Қосалқы жол: декодтау сәтсіз болса
    // Негізгі жол: жауап микрофонмен бір қозғалтқыш арқылы ойнайды.
    // Сонда Voice Processing оны «бөтен дыбыс» деп бәсеңдетпейді және микрофоннан өз дауысын алып тастайды.
    private var node = AVAudioPlayerNode()
    private var nodeFormat: AVAudioFormat?
    private var scheduled = 0
    private var inputDone = true
    private var playToken = 0
    private var stream: MP3Stream?
    private var collected = Data()             // Ағын бұзылса, жиналған файл AVAudioPlayer-мен ойнайды
    private var produced = false
    private var download: URLSessionDataTask?
    private lazy var streamSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
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
        // .voiceChat: дыбыс деңгейін өзі көтереді, шуды басады, жаңғырықты кетіреді (.measurement-ті қолданбаймыз)
        if s.category != .playAndRecord || s.mode != .voiceChat || s.categoryOptions != options {
            try s.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        }
        try s.setActive(true)
        if s.isInputGainSettable { try? s.setInputGain(1.0) }
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
            node = AVAudioPlayerNode()
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
        if node.engine == nil { engine.attach(node) }
        _ = engine.mainMixerNode   // Шығыс тізбегі бар болсын
        nodeFormat = nil
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw APIError.status(-1) }
        converter = AVAudioConverter(from: format, to: target)
        // 48 → 16 кГц: ең жоғары сапамен (сөз танудың дәлдігі үшін)
        converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        setupAnalyzer()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            guard let self else { return }
            let samples = self.convert(buf)    // Буфер қайта қолданылады: бірден көшіреміз
            self.queue.async { self.process(samples) }
            self.analyze(samples)
        }
        engine.prepare()
        try engine.start()
        startedAt = Date()
        forceSpeakerIfNeeded()
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .AVAudioEngineConfigurationChange, object: engine)
    }

    /// Apple SoundAnalysis: құрылғының өзінде, интернетсіз. 0,5 с терезе, 0,25 с сайын нәтиже.
    private func setupAnalyzer() {
        let a = SNAudioStreamAnalyzer(format: target)
        do {
            let req = try SNClassifySoundRequest(classifierIdentifier: .version1)
            let want = CMTime(seconds: 0.5, preferredTimescale: 16000)
            let c = req.windowDurationConstraint
            if c.type == .enumerated {
                let list = c.enumeratedDurations.map(\.timeValue)
                if let best = list.min(by: { abs($0.seconds - 0.5) < abs($1.seconds - 0.5) }) { req.windowDuration = best }
            } else if c.type == .range, c.durationRange.containsTime(want) {
                req.windowDuration = want
            }
            req.overlapFactor = 0.5
            speechObserver.onSpeech = { [weak self] p in
                guard let self else { return }
                self.queue.async { self.vad.setSpeech(p) }
            }
            try a.add(req, withObserver: speechObserver)
            analyzer = a
            analysisPos = 0
            queue.async { self.vad.useClassifier = true }
        } catch {
            analyzer = nil
            queue.async { self.vad.useClassifier = false }   // Танығыш жоқ болса: тек энергия
        }
    }

    private func analyze(_ samples: [Float]) {
        guard !samples.isEmpty, let a = analyzer else { return }
        analysisQueue.async {
            guard let buf = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: AVAudioFrameCount(samples.count)),
                  let ch = buf.floatChannelData else { return }
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: samples.count) }
            a.analyze(buf, atAudioFramePosition: self.analysisPos)
            self.analysisPos += AVAudioFramePosition(samples.count)
        }
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
            levelFrames += 1
            if levelFrames % 4 == 0 {   // ~8 рет/с: баптау бетіндегі деңгей
                let db = 20 * log10(max(vad.level, 1e-6))
                let p = vad.useClassifier ? vad.speechProb : 1
                DispatchQueue.main.async { self.onLevel?(db, p) }
            }
        }
    }

    // MARK: Ойнату

    private func beginPlayback(_ completion: @escaping () -> Void) -> Int {
        stopPlayback()
        if !engine.isRunning { try? start(headsetMic: headsetMic, voiceProcessing: wantVoiceProcessing) }
        forceSpeakerIfNeeded()
        playToken += 1
        isPlaying = true
        isPaused = false
        scheduled = 0
        inputDone = false
        produced = false
        collected = Data()
        finishPlayback = completion
        // Ойнату кезінде тек «Алихан» деп бөлу үшін тыңдаймыз: қысқа 2,8 с бөліктер
        queue.async { self.vad.maxLength = 2.8; self.vad.reset() }
        return playToken
    }

    private func firstAudio() {
        let f = onFirstAudio
        onFirstAudio = nil
        f?()
    }

    private func schedule(_ buf: AVAudioPCMBuffer, token: Int) {
        DispatchQueue.main.async {
            guard token == self.playToken, self.isPlaying, self.engine.isRunning else { return }
            if self.nodeFormat != buf.format {
                self.node.stop()
                self.engine.connect(self.node, to: self.engine.mainMixerNode, format: buf.format)
                self.nodeFormat = buf.format
            }
            self.produced = true
            self.scheduled += 1
            self.firstAudio()
            self.node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, token == self.playToken else { return }
                    self.scheduled -= 1
                    self.checkDone(token)
                }
            }
            if !self.isPaused && !self.node.isPlaying { self.node.play() }
        }
    }

    /// Барлық кадр ойнап болса: бітті. Декодтау ештеңе бермесе: жиналған файл AVAudioPlayer-мен.
    private func checkDone(_ token: Int) {
        guard token == playToken, isPlaying, inputDone, scheduled == 0, player == nil else { return }
        if !produced, collected.count > 200, let p = try? AVAudioPlayer(data: collected) {
            player = p
            p.delegate = self
            if p.play() { firstAudio(); return }
            player = nil
        }
        done()
    }

    /// Толық mp3 (base64 `audio`)
    func play(_ data: Data, completion: @escaping () -> Void) {
        let token = beginPlayback(completion)
        collected = data
        let s = MP3Stream()
        s.onBuffer = { [weak self] b in self?.schedule(b, token: token) }
        stream = s
        s.feed(data)
        s.finish()
        DispatchQueue.main.async {
            guard token == self.playToken else { return }
            self.inputDone = true
            self.checkDone(token)
        }
    }

    func play(_ data: Data) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            play(data) { c.resume() }
        }
    }

    /// `audio_url` ағыны: бір ғана сұраныс (сілтеме бір рет жарамды), келген бөліктер бірден ойнайды.
    func play(url: URL) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let token = beginPlayback { c.resume() }
            let s = MP3Stream()
            s.onBuffer = { [weak self] b in self?.schedule(b, token: token) }
            stream = s
            var r = URLRequest(url: url)
            r.timeoutInterval = 15
            let task = streamSession.dataTask(with: r)
            task.taskDescription = String(token)
            download = task
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        DispatchQueue.main.async {
            guard dataTask.taskDescription == String(self.playToken) else { return }
            self.collected.append(data)
            self.stream?.feed(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            guard let token = Int(task.taskDescription ?? ""), token == self.playToken else { return }
            if error == nil { self.stream?.finish() }
            // finish() кадрлары schedule арқылы негізгі кезекке түседі: солардан кейін тексереміз
            DispatchQueue.main.async {
                guard token == self.playToken else { return }
                self.inputDone = true
                self.checkDone(token)
            }
        }
    }

    /// Сервер дауысы жоқ кезде (желі әлсіз): телефонның өз дауысы.
    func speakLocally(_ text: String) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            _ = beginPlayback { c.resume() }
            inputDone = true
            produced = true
            let u = AVSpeechUtterance(string: text)
            u.voice = AVSpeechSynthesisVoice(language: "kk-KZ") ?? AVSpeechSynthesisVoice(language: "ru-RU")
            synth.speak(u)
            firstAudio()
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

    /// «Алихан» деп бөлді: кідірту (тоқтатпау)
    func pausePlayback() {
        guard isPlaying, !isPaused else { return }
        isPaused = true
        node.pause()
        player?.pause()
        if synth.isSpeaking { synth.pauseSpeaking(at: .immediate) }
        let normal = normalMax
        queue.async { self.vad.maxLength = normal; self.vad.reset() }   // 4 с тыңдау: толық сөйлем
    }

    func resumePlayback() {
        guard isPlaying, isPaused else { return }
        isPaused = false
        if scheduled > 0 { node.play() }
        player?.play()
        if synth.isPaused { synth.continueSpeaking() }
        queue.async { self.vad.maxLength = 2.8; self.vad.reset() }
    }

    func stopPlayback() {
        download?.cancel()
        download = nil
        player?.stop()
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        if isPlaying { done() }
        node.stop()
    }

    private func done() {
        playToken += 1
        player = nil
        stream = nil
        scheduled = 0
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
        DispatchQueue.main.async { if self.isPlaying && self.player == nil && self.scheduled == 0 { self.done() } }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { if self.isPlaying && self.player == nil && self.scheduled == 0 { self.done() } }
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
            self.node = AVAudioPlayerNode()
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
