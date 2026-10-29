import AVFoundation
import Foundation
import Vision

/// `--gesture-spike [--fps N] [--secondi-fase K]`: measures on numbers whether Vision on the
/// webcam is precise, fast and light enough for two signals: where Nico looks (attention gate)
/// and yes/no with the head. A guided protocol in phases, spoken and printed. Only head angles,
/// face size and times are kept: no image is saved, sent or shown. The camera is on only while
/// the command runs. Never wired into the Router, the Coordinator or the settings.
@MainActor
enum GestureSpike {
    static let calibrationSeconds = 5.0
    static let gestureCount = 5
    static let secondsPerGesture = 3.0

    static func run(fps: Int, phaseSeconds: Double) async -> Int32 {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) ?? AVCaptureDevice.default(for: .video) else {
            print("Nessuna fotocamera trovata.")
            return 1
        }
        // The permission is asked only here, with Nico at the Mac running the command.
        var status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            status = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        }
        guard status == .authorized else {
            print("Permesso Fotocamera \(status == .restricted ? "limitato" : "negato"). Concedilo in Impostazioni di Sistema › Privacy e sicurezza › Fotocamera "
                  + "all'app da cui lanci il comando (per esempio il Terminale), poi riprova.")
            return 1
        }

        let recorder = GestureRecorder(fps: fps)
        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 } else if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            print("La fotocamera «\(device.localizedName)» non si apre.")
            return 1
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        let queue = DispatchQueue(label: "mactalkact.gesture-spike")
        output.setSampleBufferDelegate(recorder, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            print("La fotocamera «\(device.localizedName)» non dà fotogrammi.")
            return 1
        }
        session.addOutput(output)
        session.commitConfiguration()
        recorder.clock = session.synchronizationClock

        // From here on the camera may be on: every way out turns it off.
        session.startRunning()
        defer {
            session.stopRunning()
            output.setSampleBufferDelegate(nil, queue: nil)
        }
        setFrameRate(device, fps: fps)
        let speaker = Speaker()
        func say(_ text: String) async {
            print("» \(text)")
            await speaker.say(text)
        }

        var phases: [GesturePhase] = []
        var cues: [Double] = []
        /// Runs one phase: the instruction first, then `seconds` of recording (or `body`).
        func phase(_ p: GesturePhase, instruction: String, seconds: Double, body: (() async -> Void)? = nil) async {
            await say(instruction)
            var p = p
            let cpu0 = processCPUSeconds()
            p.start = hostNow()
            recorder.setPhase(phases.count)
            if let body { await body() } else { try? await Task.sleep(for: .seconds(seconds)) }
            p.end = hostNow()
            p.cues = cues
            cues = []
            p.cpuSeconds = processCPUSeconds() - cpu0
            recorder.setPhase(-1)
            phases.append(p)
        }

        await say("Prova dei gesti con la fotocamera. Non salvo nessuna immagine, solo gli angoli della testa. Segui le mie istruzioni.")
        // 1. Calibration: repeated once without a face, then stop.
        var reference: HeadPose?
        // No frame at all means the camera gave no images (busy or unplugged), not a missing face.
        var noFrames = false
        for attempt in 0..<2 {
            recorder.discard(phase: 0)
            phases = []
            let retry = noFrames ? "La fotocamera non ha dato immagini. Controlla che non sia usata da un'altra app, poi guarda lo schermo."
                                 : "Non vedo il tuo volto. Mettiti davanti alla fotocamera e guarda lo schermo."
            await phase(GesturePhase(name: "calibrazione", expectAttention: true),
                        instruction: attempt == 0 ? "Guarda lo schermo e resta fermo \(Int(calibrationSeconds)) secondi." : retry,
                        seconds: calibrationSeconds)
            let calibration = recorder.frames(phase: 0)
            noFrames = calibration.isEmpty
            reference = HeadCalibration.reference(calibration.map(\.sample))
            if reference != nil { break }
        }
        guard let reference else {
            print(noFrames ? "Calibrazione non riuscita: la fotocamera non ha dato immagini (occupata o staccata). Nessun report."
                           : "Calibrazione non riuscita: nessun volto visto per due volte. Nessun report.")
            return 1
        }
        recorder.setReference(reference)

        await phase(GesturePhase(name: "lettura", expectAttention: true),
                    instruction: "Ora leggi qualcosa sullo schermo, come fai di solito.", seconds: phaseSeconds)
        await phase(GesturePhase(name: "stanza", expectAttention: false),
                    instruction: "Ora guarda verso la stanza, come se parlassi con qualcuno, e resta così.", seconds: phaseSeconds)
        await phase(GesturePhase(name: "ritorno", expectAttention: true),
                    instruction: "Torna a guardare lo schermo.", seconds: phaseSeconds)
        for (name, word, yes) in [("sì", "sì", true), ("no", "no", false)] {
            await phase(GesturePhase(name: name, expectAttention: true, expectedYes: yes ? gestureCount : 0, expectedNo: yes ? 0 : gestureCount, voiced: true),
                        instruction: "Guardando lo schermo, fai \(word) con la testa a ogni numero che dico, \(gestureCount) volte.", seconds: 0) {
                for i in 1...gestureCount {
                    cues.append(hostNow())
                    await say("\(i)")
                    try? await Task.sleep(for: .seconds(secondsPerGesture))
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        await phase(GesturePhase(name: "basso", expectAttention: false),
                    instruction: "Ora guarda in basso, verso la scrivania o il telefono, e resta così.", seconds: phaseSeconds)

        session.stopRunning()
        let frames = recorder.allFrames()
        await say("Finito. La fotocamera è spenta.")

        var setup = GestureSpikeReport.Setup()
        setup.camera = device.localizedName
        // The size of the frames Vision really worked on.
        setup.resolution = recorder.frameSize.map { "\($0.width)×\($0.height)" } ?? "—"
        setup.fps = fps
        let report = GestureSpikeReport.lines(frames: frames, phases: phases, reference: reference, setup: setup)
        print(report.joined(separator: "\n"))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacTalkAct-gesti-\(f.string(from: Date()))")
        let txt = base.appendingPathExtension("txt"), tsv = base.appendingPathExtension("tsv")
        for (label, url, text) in [("Report", txt, report.joined(separator: "\n") + "\n"), ("Angoli", tsv, GestureSpikeReport.tsv(frames: frames, phases: phases))] {
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                print("\(label): \(url.path)")
            } catch {
                print("\(label) non scritto in \(url.path): \(error.localizedDescription)")
            }
        }
        return 0
    }

    /// Asks the camera itself for the frame rate when it supports it; the recorder also skips
    /// frames that come too early.
    private static func setFrameRate(_ device: AVCaptureDevice, fps: Int) {
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate }),
              (try? device.lockForConfiguration()) != nil else { return }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.unlockForConfiguration()
    }

    nonisolated static func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    /// CPU time of the whole process (user + system), in seconds.
    static func processCPUSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1_000_000
    }
}

/// Receives the camera frames on its own queue: Vision, then the live gate and detector. Keeps
/// only the angles; the pixel buffer is released as soon as Vision is done with it.
final class GestureRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var phase = -1
    private var reference: HeadPose?
    private var frames: [GestureFrame] = []
    private var size: (width: Int, height: Int)?
    /// Set once before the session starts.
    var clock: CMClock?
    // Touched only on the capture queue.
    private let minInterval: Double
    private var lastProcessed = -Double.infinity
    private var gate = AttentionGate()
    private var detector = HeadGestureDetector()
    private let request: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3
        return r
    }()

    init(fps: Int) { minInterval = 1 / Double(max(1, fps)) }

    func setPhase(_ p: Int) { lock.withLock { phase = p } }
    func setReference(_ r: HeadPose) { lock.withLock { reference = r } }
    func discard(phase p: Int) { lock.withLock { frames.removeAll { $0.phase == p } } }
    func frames(phase p: Int) -> [GestureFrame] { lock.withLock { frames.filter { $0.phase == p } } }
    func allFrames() -> [GestureFrame] { lock.withLock { frames } }
    /// Width and height of the first pixel buffer Vision processed.
    var frameSize: (width: Int, height: Int)? { lock.withLock { size } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let (phase, reference) = lock.withLock { (self.phase, self.reference) }
        guard phase >= 0 else { return }
        var pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let clock { pts = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()) }
        let t = pts.seconds
        // Small tolerance: frames do not arrive exactly on time.
        guard t - lastProcessed >= minInterval * 0.8, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastProcessed = t
        let pixelSize = (width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        let v0 = GestureSpike.hostNow()
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
        let visionMs = (GestureSpike.hostNow() - v0) * 1000
        // The biggest face is Nico's.
        let face = (request.results ?? []).max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
        func degrees(_ n: NSNumber?) -> Double? { n.map { $0.doubleValue * 180 / .pi } }
        var sample = HeadSample.absent(t)
        if let face, let yaw = degrees(face.yaw), let pitch = degrees(face.pitch) {
            sample = HeadSample(t: t, yaw: yaw, pitch: pitch, roll: degrees(face.roll), size: Double(face.boundingBox.width))
        }
        let attention = reference.map { gate.feed(sample, reference: $0) }
        let gesture = detector.feed(sample)
        let latencyMs = (GestureSpike.hostNow() - t) * 1000
        let frame = GestureFrame(sample: sample, phase: phase, visionMs: visionMs, latencyMs: latencyMs, attention: attention, gesture: gesture)
        // The phase may have changed (or its frames been discarded) while Vision worked: such a frame is dropped.
        let kept = lock.withLock { () -> Bool in
            guard self.phase == phase else { return false }
            frames.append(frame)
            if size == nil { size = pixelSize }
            return true
        }
        if kept, let gesture { print("  · \(gesture.rawValue)") }
    }
}
