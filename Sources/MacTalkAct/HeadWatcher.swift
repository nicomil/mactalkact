import AVFoundation
import Foundation
import Vision

/// The camera as the gesture code needs it: opening at VGA, the frame rate, and one frame reduced
/// to the head angles. Shared by the app (`HeadWatcher`) and by `--gesture-spike`.
enum HeadCamera {
    enum OpenError: Error {
        case noCamera
        /// The camera exists but does not open (busy, or refused by the system).
        case cannotOpen(String)
        case noOutput(String)
    }

    static func device() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) ?? AVCaptureDevice.default(for: .video)
    }

    /// A configured session, not started yet. The delegate receives the frames on `queue`.
    static func open(delegate: AVCaptureVideoDataOutputSampleBufferDelegate, queue: DispatchQueue) throws
        -> (session: AVCaptureSession, output: AVCaptureVideoDataOutput, device: AVCaptureDevice) {
        guard let device = device() else { throw OpenError.noCamera }
        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 } else if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            throw OpenError.cannotOpen(device.localizedName)
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw OpenError.noOutput(device.localizedName)
        }
        session.addOutput(output)
        session.commitConfiguration()
        return (session, output, device)
    }

    /// Asks the camera itself for the frame rate when it supports it; the receivers also skip
    /// frames that come too early.
    static func setFrameRate(_ device: AVCaptureDevice, fps: Int) {
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate }),
              (try? device.lockForConfiguration()) != nil else { return }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.unlockForConfiguration()
    }

    static func faceRequest() -> VNDetectFaceRectanglesRequest {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3
        return r
    }

    /// Vision on one frame: the angles of the biggest face (Nico's), or an absent sample. The pixel
    /// buffer is not kept.
    static func sample(_ pixels: CVPixelBuffer, t: Double, request: VNDetectFaceRectanglesRequest) -> HeadSample {
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
        let face = (request.results ?? []).max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
        func degrees(_ n: NSNumber?) -> Double? { n.map { $0.doubleValue * 180 / .pi } }
        guard let face, let yaw = degrees(face.yaw), let pitch = degrees(face.pitch) else { return .absent(t) }
        return HeadSample(t: t, yaw: yaw, pitch: pitch, roll: degrees(face.roll), size: Double(face.boundingBox.width))
    }

    /// Host clock time of a frame (the session clock converted), in seconds.
    static func time(of sampleBuffer: CMSampleBuffer, clock: CMClock?) -> Double {
        var pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let clock { pts = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()) }
        return pts.seconds
    }

    nonisolated static func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}

/// «Attenzione dalla fotocamera»: while continuous listening is on, the camera tells where Nico
/// looks (attention gate) and sees a «no» with the head. Only angles and times are kept, for 30 s;
/// no image is saved, sent or shown. Every failure leaves `attention` unknown, so the app decides
/// as it does without the camera.
@MainActor
final class HeadWatcher {
    enum Status: Equatable {
        case off
        case active
        /// No calibration yet: the camera is off and the gate is unknown.
        case needsCalibration
        case denied
        case noCamera
        /// The camera opened but gave no frames (busy, unplugged).
        case noFrames
        /// A calibration is already recording.
        case busy

        var isFailure: Bool { self == .denied || self == .noCamera || self == .noFrames }

        var label: String {
            switch self {
            case .off: return "fotocamera spenta"
            case .active: return "fotocamera attiva"
            case .needsCalibration: return "da calibrare"
            case .denied: return "permesso Fotocamera mancante"
            case .noCamera: return "nessuna fotocamera trovata"
            case .noFrames: return "la fotocamera non dà immagini (occupata o staccata)"
            case .busy: return "calibrazione già in corso"
            }
        }
    }

    static let fps = 15
    static let calibrationSeconds = 5.0

    private(set) var status: Status = .off { didSet { if status != oldValue { onStatusChange?(status) } } }
    var onStatusChange: ((Status) -> Void)?
    /// An awaited gesture (`arm`): the «no», or the «sì» when allowed. On the main actor.
    var onGesture: ((HeadGestureDetector.Gesture) -> Void)?

    private let sink = HeadFrameSink()
    private let queue = DispatchQueue(label: "mactalkact.head-watcher")
    private var running: (session: AVCaptureSession, output: AVCaptureVideoDataOutput)?
    private var watchdog: Task<Void, Never>?

    init() {
        sink.onGesture = { [weak self] g in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onGesture?(g) } }
        }
    }

    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    /// Asks the permission when it was never asked (only from the settings, with Nico there).
    static func requestAccess() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .video)
        }
        return authorized
    }

    /// Turns the camera on with the calibrated reference. Without a reference the camera stays off.
    func start(reference: HeadPose?, profile: HeadProfile? = nil) {
        guard let reference else { stop(); status = .needsCalibration; return }
        sink.setProfile(profile)
        sink.setReference(reference)
        if running != nil {
            // Frames came after the 3 s check: the camera works after all.
            if status == .noFrames && sink.hasFrames { status = .active }
            return
        }
        guard Self.authorized else {
            // Never asked yet: the settings ask it when the switch is turned on. Not a failure.
            status = AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined ? .off : .denied
            return
        }
        if let failure = openCamera() {
            status = failure
        } else {
            status = .active
            Log.info("Attenzione dalla fotocamera: accesa")
        }
    }

    func stop() {
        // A calibration is recording: the camera goes off when it ends, not under it.
        if recording { temporaryCamera = true; return }
        watchdog?.cancel()
        watchdog = nil
        if let r = running {
            running = nil
            r.output.setSampleBufferDelegate(nil, queue: nil)
            // stopRunning blocks: off the main thread, in order with the start.
            let box = SessionBox(r.session)
            queue.async { box.session.stopRunning() }
            Log.info("Attenzione dalla fotocamera: spenta")
        }
        sink.clear()
        status = .off
    }

    /// Where Nico looked between two host-clock times. Unknown without the camera running; with it,
    /// `PhraseAttention` needs recent frames, so a camera that stopped sending them gives unknown.
    func attention(from: Double, to: Double) -> PhraseAttention {
        guard running != nil else { return .unknown }
        return PhraseAttention.judge(sink.marks(), from: from, to: to)
    }

    /// A question is now waiting for an answer: the next «no» with the head answers it. A «no» after
    /// the question is gone finds nothing to cancel (`Coordinator.headNoTarget`).
    /// Never while a calibration records: its gestures must not answer a real question.
    func arm(allowYes: Bool) { if !recording { sink.arm(allowYes: allowYes) } }
    func disarm() { sink.disarm() }

    enum CalibrationResult: Equatable {
        case pose(HeadPose)
        case noFace
        case failed(Status)
        /// Another calibration is running.
        case busy
    }


    private var recording = false
    private var temporaryCamera = false

    /// Starts recording every sample (angles only, in memory) for a calibration. The camera is
    /// turned on just for this when it is off. The failure, or nil. One recording at a time.
    func beginRecording() -> Status? {
        guard Self.authorized else { return .denied }
        guard !recording else { return .busy }
        temporaryCamera = running == nil
        if temporaryCamera, let failure = openCamera(reportFailure: false) { return failure }
        recording = true
        sink.disarm() // gestures made for the calibration never answer a question
        sink.beginCalibration()
        return nil
    }

    /// The samples recorded so far (the guide checks the face after the first phase).
    func recordedSamples() -> [HeadSample] { sink.calibrationSoFar() }

    /// Stops recording and returns the samples, or the failure «no frames». The camera goes back
    /// to how it was.
    func endRecording() -> (samples: [HeadSample], failure: Status?) {
        guard recording else { return ([], nil) }
        recording = false
        let samples = sink.endCalibration()
        // Read before stop(), which resets the status.
        let noFrames = !sink.hasFrames || status == .noFrames
        if temporaryCamera { stop() }
        temporaryCamera = false
        return (samples, noFrames ? .noFrames : nil)
    }

    /// 5 s looking at the screen: the median pose, not enough faces, or the camera failure.
    func calibrate() async -> CalibrationResult {
        if let failure = beginRecording() { return failure == .busy ? .busy : .failed(failure) }
        try? await Task.sleep(for: .seconds(Self.calibrationSeconds))
        let (samples, failure) = endRecording()
        if let failure { return .failed(failure) }
        return HeadCalibration.reference(samples).map { .pose($0) } ?? .noFace
    }

    /// Opens and starts the camera; the failure status, or nil when it is starting. With
    /// `reportFailure: false` (calibration) the watchdog does not change the status.
    private func openCamera(reportFailure: Bool = true) -> Status? {
        let opened: (session: AVCaptureSession, output: AVCaptureVideoDataOutput, device: AVCaptureDevice)
        do {
            opened = try HeadCamera.open(delegate: sink, queue: queue)
        } catch HeadCamera.OpenError.noCamera {
            return .noCamera
        } catch {
            return .noFrames
        }
        sink.prepare(clock: opened.session.synchronizationClock, fps: Self.fps)
        running = (opened.session, opened.output)
        let box = SessionBox(opened.session)
        let device = opened.device
        queue.async {
            box.session.startRunning()
            HeadCamera.setFrameRate(device, fps: Self.fps)
        }
        // No frame within 3 s: the camera is busy or unplugged. The gate stays unknown.
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.running != nil, !self.sink.hasFrames else { return }
            Log.info("Attenzione dalla fotocamera: nessuna immagine in 3 s")
            if reportFailure { self.status = .noFrames }
        }
        return nil
    }
}

/// AVCaptureSession is thread-safe for start/stop but not marked Sendable.
private struct SessionBox: @unchecked Sendable {
    let session: AVCaptureSession
    init(_ s: AVCaptureSession) { session = s }
}

/// Receives the frames on the camera queue: Vision, the reference, the gate and the «no».
/// Everything is under the lock: the main actor reads the marks and arms the «no».
final class HeadFrameSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var clock: CMClock?
    private var minInterval = 1.0 / 15
    private var lastProcessed = -Double.infinity
    private var live = HeadLiveState()
    private var calibration: [HeadSample]?
    private(set) var frameCount = 0
    private let request = HeadCamera.faceRequest()
    var onGesture: ((HeadGestureDetector.Gesture) -> Void)?

    var hasFrames: Bool { lock.withLock { frameCount > 0 } }

    func prepare(clock: CMClock?, fps: Int) {
        lock.withLock {
            self.clock = clock
            minInterval = 1 / Double(max(1, fps))
            lastProcessed = -.infinity
            frameCount = 0
        }
    }

    func setReference(_ r: HeadPose) {
        lock.withLock { live.setReference(r) }
    }

    func setProfile(_ p: HeadProfile?) {
        lock.withLock { live.setProfile(gestures: p?.gestures ?? HeadGestureDetector.Config(), gate: p?.gate ?? .app) }
    }

    func clear() {
        lock.withLock {
            // The calibration stays; the marks, the gate and the «no» start again.
            // The profile stays too: only the marks and the armed gestures go.
            live.disarm()
            live.clearMarks()
        }
    }

    func marks() -> [PhraseAttention.Mark] { lock.withLock { live.marks } }

    func arm(allowYes: Bool) { lock.withLock { live.arm(allowYes: allowYes) } }
    func disarm() { lock.withLock { live.disarm() } }

    func beginCalibration() { lock.withLock { calibration = [] } }
    func calibrationSoFar() -> [HeadSample] { lock.withLock { calibration ?? [] } }
    func endCalibration() -> [HeadSample] { lock.withLock { defer { calibration = nil }; return calibration ?? [] } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let (clock, minInterval, last) = lock.withLock { (self.clock, self.minInterval, self.lastProcessed) }
        let t = HeadCamera.time(of: sampleBuffer, clock: clock)
        // Small tolerance: frames do not arrive exactly on time.
        guard t - last >= minInterval * 0.8, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let sample = HeadCamera.sample(pixels, t: t, request: request)
        let fire = lock.withLock { () -> HeadGestureDetector.Gesture? in
            lastProcessed = t
            frameCount += 1
            calibration?.append(sample)
            return live.feed(sample)
        }
        if let fire { onGesture?(fire) }
    }
}
