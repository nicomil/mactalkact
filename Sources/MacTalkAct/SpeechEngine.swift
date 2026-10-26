import AVFoundation
import Speech

enum SpeechError: LocalizedError {
    case localeUnsupported
    case noAudioFormat
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .localeUnsupported: return "L'italiano non è supportato dal riconoscimento vocale di questo Mac"
        case .noAudioFormat: return "Formato audio non disponibile"
        case .microphoneDenied: return "Accesso al microfono negato (Impostazioni › Privacy › Microfono)"
        }
    }
}

/// Small reference box so values can cross into escaping/async closures.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Audio router (audio thread)

/// Splits the microphone stream into sentences ("segments").
///
/// The recogniser transcribes best when each sentence has a clean start and end:
/// with one endless stream it keeps revising earlier words and finalises late.
/// So, like push-to-talk, every sentence gets its own recognition session:
/// - push-to-talk: the segment lasts while the key is held (`beginForced`/`endForced`);
/// - continuous listening: a voice-activity detector on the audio level opens a
///   segment when speech starts (including ~0.4 s of audio before, so the first
///   syllable is not lost) and closes it after a short silence.
///
/// Runs on the real-time audio thread; state is guarded by a lock.
final class AudioRouter: @unchecked Sendable {
    struct Config {
        var minStartRMS: Float = 0.006       // absolute floor for "speech" (a low voice is ~0.01)
        var noiseFactor: Float = 4.0         // speech = this many times the background noise
        var minSpeech: TimeInterval = 0.12   // speech needed to open a segment
        var endSilence: TimeInterval = 0.8   // silence that closes a segment
        var maxSegment: TimeInterval = 60    // hard limit for one sentence
        var prerollChunks = 16               // ~0.4 s kept before speech starts
    }

    var config = Config()
    /// Both callbacks are invoked on the audio thread.
    var onSegmentStart: ((AsyncStream<AnalyzerInput>, Bool) -> Void)?
    var onSegmentEnd: ((Bool) -> Void)?

    private let lock = NSLock()
    private var preroll: [AnalyzerInput] = []
    private var active: AsyncStream<AnalyzerInput>.Continuation?
    private var forced = false
    private var vadEnabled = false
    private var speechTime: TimeInterval = 0
    private var silenceTime: TimeInterval = 0
    private var segmentTime: TimeInterval = 0
    private var noiseFloor: Float = 0.004
    private var peakRMS: Float = 0

    func setVAD(_ on: Bool) {
        lock.withLock {
            vadEnabled = on
            speechTime = 0
        }
    }

    /// Longer pauses are allowed while dictating, so thinking pauses don't split the text.
    func setEndSilence(_ seconds: TimeInterval) {
        lock.withLock { config.endSilence = seconds }
    }

    /// Opens a segment that only ends with `endForced` (or takes over the one in progress).
    func beginForced() {
        let stream: AsyncStream<AnalyzerInput>? = lock.withLock {
            forced = true
            return active == nil ? openLocked() : nil
        }
        if let stream { onSegmentStart?(stream, true) }
    }

    /// Closes the forced segment. Returns false if there was none.
    @discardableResult
    func endForced() -> Bool {
        let ended: Bool = lock.withLock {
            guard forced else { return false }
            forced = false
            guard active != nil else { return false }
            closeLocked()
            return true
        }
        if ended { onSegmentEnd?(true) }
        return ended
    }

    /// Closes whatever segment is open (used when stopping the microphone).
    func closeAny() {
        let wasForced: Bool? = lock.withLock {
            guard active != nil else { forced = false; return nil }
            let f = forced
            forced = false
            closeLocked()
            return f
        }
        if let wasForced { onSegmentEnd?(wasForced) }
    }

    private func openLocked() -> AsyncStream<AnalyzerInput> {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        for input in preroll { continuation.yield(input) }
        preroll.removeAll()
        active = continuation
        segmentTime = 0
        silenceTime = 0
        peakRMS = 0
        return stream
    }

    private func closeLocked() {
        active?.finish()
        active = nil
        speechTime = 0
        silenceTime = 0
    }

    /// Called from the tap for every audio buffer.
    func process(_ inputs: [AnalyzerInput], rms: Float, duration: TimeInterval) {
        var started: AsyncStream<AnalyzerInput>?
        var ended = false

        lock.lock()
        if let active {
            for input in inputs { active.yield(input) }
        } else {
            preroll.append(contentsOf: inputs)
            if preroll.count > config.prerollChunks { preroll.removeFirst(preroll.count - config.prerollChunks) }
        }

        // Background noise follows quiet moments quickly and loud ones slowly,
        // and is frozen while a sentence is open (the voice itself is not "noise").
        if active == nil {
            if rms < noiseFloor {
                noiseFloor = noiseFloor * 0.8 + rms * 0.2
            } else {
                noiseFloor += (rms - noiseFloor) * 0.002
            }
        }
        let threshold = max(config.minStartRMS, noiseFloor * config.noiseFactor)

        if active == nil {
            if vadEnabled && rms > threshold {
                speechTime += duration
                if speechTime >= config.minSpeech { started = openLocked() }
            } else {
                speechTime = 0
            }
        } else if !forced {
            segmentTime += duration
            peakRMS = max(peakRMS, rms)
            // Hysteresis: once a sentence is open, even a soft last word counts as speech.
            let keepGoing = max(config.minStartRMS * 0.4, noiseFloor * 2)
            silenceTime = rms > keepGoing ? 0 : silenceTime + duration
            if silenceTime >= config.endSilence || segmentTime >= config.maxSegment {
                Log.debug(String(format: "VAD: frase %.2fs, picco %.4f, fondo %.4f, soglia %.4f, continua %.4f",
                                 segmentTime, peakRMS, noiseFloor, threshold, keepGoing))
                closeLocked()
                ended = true
            }
        }
        lock.unlock()

        if let started { onSegmentStart?(started, false) }
        if ended { onSegmentEnd?(false) }
    }
}

// MARK: - One sentence

/// Recognition of a single sentence: its own analyzer, closed cleanly at the end.
@MainActor
final class TranscriptionSession {
    var forced: Bool
    var onLive: ((String) -> Void)?

    private var finals: [String] = []
    private var volatileText = ""
    private var analyzer: SpeechAnalyzer?
    private var startTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    init(forced: Bool) {
        self.forced = forced
    }

    private var text: String {
        (finals + [volatileText]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    func start(stream: AsyncStream<AnalyzerInput>, locale: Locale, format: AVAudioFormat) {
        let transcriber = SpeechEngine.makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let t = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        if !t.isEmpty { self.finals.append(t) }
                        self.volatileText = ""
                    } else {
                        self.volatileText = t
                    }
                    self.onLive?(self.text)
                }
            } catch {
                Log.error("Trascrizione interrotta: \(error.localizedDescription)")
            }
        }
        startTask = Task { @MainActor in
            do {
                try await analyzer.prepareToAnalyze(in: format)
                try await analyzer.start(inputSequence: stream)
            } catch {
                Log.error("Avvio analisi: \(error.localizedDescription)")
            }
        }
    }

    /// Waits for the final transcription of the whole sentence.
    func finish() async -> String {
        await startTask?.value
        if let analyzer {
            await withTimeout(seconds: 4) { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        }
        if let resultsTask {
            await withTimeout(seconds: 1.5) { await resultsTask.value }
        }
        resultsTask?.cancel()
        analyzer = nil
        return text
    }
}

@MainActor
func withTimeout(seconds: Double, _ op: @escaping @MainActor () async -> Void) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask { @MainActor in await op() }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
        await group.next()
        group.cancelAll()
    }
}

// MARK: - Engine

/// On-device speech recognition with Apple's SpeechAnalyzer + DictationTranscriber.
///
/// microphone tap → AnalyzerInputConverter → AudioRouter → one TranscriptionSession per sentence.
@MainActor
final class SpeechEngine {
    /// Live text of the sentence being spoken (for the HUD).
    var onLive: ((String) -> Void)?
    /// Microphone level 0...1 for the HUD meter.
    var onLevel: ((Float) -> Void)?
    /// A complete sentence detected by voice activity (continuous listening).
    var onUtterance: ((String) -> Void)?
    /// The user started speaking (voice activity detected).
    var onSpeechStart: (() -> Void)?

    private(set) var isRunning = false
    private var locale: Locale?
    private var analyzerFormat: AVAudioFormat?
    private var audioEngine: AVAudioEngine?
    private let router = AudioRouter()
    private var session: TranscriptionSession?
    private var pttWaiter: CheckedContinuation<String, Never>?

    init() {
        router.onSegmentStart = { [weak self] stream, forced in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.segmentStarted(stream, forced: forced) } }
        }
        router.onSegmentEnd = { [weak self] forced in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.segmentEnded(forced: forced) } }
        }
    }

    static func makeTranscriber(locale: Locale) -> DictationTranscriber {
        DictationTranscriber(
            locale: locale,
            contentHints: [.shortForm],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    static func italianLocale() async throws -> Locale {
        guard let l = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "it-IT")) else {
            throw SpeechError.localeUnsupported
        }
        return l
    }

    /// Makes sure the Italian model is installed. `onDownload` fires only if a download is needed.
    static func ensureModel(locale: Locale, onDownload: (() -> Void)? = nil) async throws {
        let transcriber = makeTranscriber(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onDownload?()
            try await request.downloadAndInstall()
        }
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    func prepare(onDownload: (() -> Void)? = nil) async throws {
        let loc = try await Self.italianLocale()
        try await Self.ensureModel(locale: loc, onDownload: onDownload)
        let transcriber = Self.makeTranscriber(locale: loc)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechError.noAudioFormat
        }
        locale = loc
        analyzerFormat = format
        Log.info("Riconoscimento pronto: \(loc.identifier), \(format)")
    }

    // MARK: Microphone

    /// Starts the microphone. With `vad` on, sentences are detected automatically.
    func startAudio(vad: Bool) async throws {
        router.setVAD(vad)
        guard !isRunning else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw SpeechError.microphoneDenied }
        }
        if analyzerFormat == nil { try await prepare() }
        guard let format = analyzerFormat else { throw SpeechError.noAudioFormat }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let converter = AnalyzerInputConverter(analyzerFormat: format)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0),
                         block: Self.makeTap(converter: converter, router: router, level: onLevel))
        engine.prepare()
        try engine.start()
        audioEngine = engine
        isRunning = true
        Log.info("Microfono acceso (rilevamento voce: \(vad ? "sì" : "no"))")
    }

    func setVAD(_ on: Bool) {
        router.setVAD(on)
    }

    func setEndSilence(_ seconds: TimeInterval) {
        router.setEndSilence(seconds)
    }

    func stopAudio() async {
        router.setVAD(false)
        guard isRunning else { return }
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        isRunning = false
        router.closeAny()
        onLevel?(0)
        Log.info("Microfono spento")
    }

    // MARK: Push-to-talk

    func beginPushToTalk(continuous: Bool) async throws {
        try await startAudio(vad: continuous)
        router.beginForced()
        session?.forced = true
    }

    /// Ends the push-to-talk sentence and returns its transcription.
    func endPushToTalk() async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            pttWaiter = c
            if !router.endForced() { resumePTT("") }
        }
    }

    func cancelPushToTalk() {
        router.endForced()
    }

    private func resumePTT(_ text: String) {
        pttWaiter?.resume(returning: text)
        pttWaiter = nil
    }

    // MARK: Segments

    private func segmentStarted(_ stream: AsyncStream<AnalyzerInput>, forced: Bool) {
        guard let locale, let format = analyzerFormat else { return }
        let s = TranscriptionSession(forced: forced)
        s.onLive = { [weak self] text in self?.onLive?(text) }
        s.start(stream: stream, locale: locale, format: format)
        session = s
        Log.debug("Inizio frase (\(forced ? "tasto" : "voce"))")
        if !forced { onSpeechStart?() }
    }

    private func segmentEnded(forced: Bool) {
        guard let s = session else {
            if forced { resumePTT("") }
            return
        }
        session = nil
        let wasForced = forced || s.forced
        Task { @MainActor in
            let text = await s.finish()
            Log.debug("Fine frase (\(wasForced ? "tasto" : "voce")): «\(text)»")
            if wasForced {
                self.resumePTT(text)
            } else {
                self.onUtterance?(text)
            }
        }
    }

    /// Built outside the main actor: the audio tap runs on a real-time audio thread.
    nonisolated private static func makeTap(
        converter: AnalyzerInputConverter,
        router: AudioRouter,
        level: ((Float) -> Void)?
    ) -> AVAudioNodeTapBlock {
        let levelBox = Box(level)
        let lastLevel = Box(Date.distantPast)
        return { buffer, _ in
            let inputs = (try? converter.convert(buffer, at: nil)) ?? []
            var rms: Float = 0
            let n = Int(buffer.frameLength)
            if let channel = buffer.floatChannelData?[0], n > 0 {
                var sum: Float = 0
                for i in 0..<n { sum += channel[i] * channel[i] }
                rms = (sum / Float(n)).squareRoot()
            }
            let duration = Double(n) / buffer.format.sampleRate
            router.process(inputs, rms: rms, duration: duration)

            if let handler = levelBox.value, Date().timeIntervalSince(lastLevel.value) > 0.05 {
                lastLevel.value = Date()
                let value = min(1, rms * 14)
                DispatchQueue.main.async { handler(value) }
            }
        }
    }
}
