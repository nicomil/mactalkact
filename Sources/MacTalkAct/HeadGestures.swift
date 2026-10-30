import Foundation

// Pure logic of the head gestures: calibration, attention gate, judgment of a Frase, yes/no with
// the head, and the report of the spike (`--gesture-spike`). The app uses the gate and the «no»
// (`HeadWatcher`). No camera here: everything works on angles and times, so `--selftest` proves
// it with synthetic samples.

/// One camera frame reduced to the head angles (degrees) and the face size. Nothing else is kept:
/// no image, no landmarks. `yaw`/`pitch` are nil when no face was found.
struct HeadSample: Equatable {
    var t: Double
    var yaw: Double?
    var pitch: Double?
    var roll: Double?
    /// Width of the face box, as a fraction of the frame width.
    var size: Double?

    var hasFace: Bool { yaw != nil && pitch != nil }

    static func absent(_ t: Double) -> HeadSample { HeadSample(t: t, yaw: nil, pitch: nil, roll: nil, size: nil) }
}

/// Where the head points when Nico looks at the screen. The camera sits above the screen, so
/// this is not yaw = pitch = 0.
struct HeadPose: Equatable {
    var yaw: Double
    var pitch: Double
}

enum HeadCalibration {
    /// The reference pose: the median of the samples with a face. Nil when too few samples have
    /// a face (the calibration phase is then repeated once, then the spike stops).
    static func reference(_ samples: [HeadSample], minFaces: Int = 10) -> HeadPose? {
        let faces = samples.filter(\.hasFace)
        guard faces.count >= minFaces else { return nil }
        return HeadPose(yaw: median(faces.compactMap(\.yaw)), pitch: median(faces.compactMap(\.pitch)))
    }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Nearest-rank percentile (p in 0...100).
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        let rank = Int((p / 100 * Double(s.count)).rounded(.up))
        return s[min(max(rank, 1), s.count) - 1]
    }
}

/// Is Nico looking at the screen? The deviation from the reference must stay inside the limits;
/// the state changes only after the new condition has held for `hold` seconds (temporal
/// hysteresis), so a blink of the detector or a quick glance does not flip it. No face counts
/// as looking away.
struct AttentionGate {
    struct Config: Equatable, Codable {
        var yawLimit = 15.0
        var pitchLimit = 15.0
        var hold = 0.3
    }

    var config = Config()
    private(set) var isOn = false
    private var pendingSince: Double?

    /// `startOn`: the state before the first sample. The app starts «looking at the screen», so the
    /// first 300 ms of the camera never ignore a sentence.
    init(config: Config = Config(), startOn: Bool = false) {
        self.config = config
        isOn = startOn
    }

    static func inside(_ s: HeadSample, reference: HeadPose, config: Config) -> Bool {
        guard let yaw = s.yaw, let pitch = s.pitch else { return false }
        return abs(yaw - reference.yaw) <= config.yawLimit && abs(pitch - reference.pitch) <= config.pitchLimit
    }

    mutating func feed(_ s: HeadSample, reference: HeadPose) -> Bool {
        let want = Self.inside(s, reference: reference, config: config)
        if want == isOn {
            pendingSince = nil
        } else {
            let since = pendingSince ?? s.t
            pendingSince = since
            if s.t - since >= config.hold - 1e-9 {
                isOn = want
                pendingSince = nil
            }
        }
        return isOn
    }
}

extension AttentionGate.Config {
    /// The limits chosen after the spike (research §40): ±25° on yaw and pitch never took reading
    /// for looking away, and recognized the room in 75–100% of the frames.
    static let app = AttentionGate.Config(yawLimit: 25, pitchLimit: 25, hold: 0.3)
}

/// Where Nico looked while saying a Frase, from the gate state of each frame in that time.
enum PhraseAttention: Equatable {
    case screen, away, unknown

    /// One frame: whether a face was seen and the gate state after it.
    struct Mark: Equatable {
        var t: Double
        var hasFace: Bool
        var gateOn: Bool
    }

    /// «Away» only when more than half of the frames with a face have the gate off, and faces
    /// cover at least half of the frames. A missing face is not «away»: bad light or Nico standing
    /// must not make the app ignore commands. Fewer than 3 frames (camera stalled): unknown.
    static func judge(_ marks: [Mark], from: Double, to: Double) -> PhraseAttention {
        let inside = marks.filter { $0.t >= from && $0.t <= to }
        guard inside.count >= 3 else { return .unknown }
        let faces = inside.filter(\.hasFace)
        guard !faces.isEmpty, faces.count * 2 >= inside.count else { return .unknown }
        return faces.filter { !$0.gateOn }.count * 2 > faces.count ? .away : .screen
    }
}

/// The «looking at the screen» pose: the calibrated one, then following slowly the samples that
/// fall inside the limits (posture changes during the day). It never moves more than `maxDrift`
/// degrees from the calibration, so a long talk with the room cannot turn the room into the screen.
struct ReferenceTracker {
    let calibrated: HeadPose
    var limits = AttentionGate.Config.app
    /// Seconds for the reference to cover about two thirds of a steady change.
    var timeConstant = 120.0
    var maxDrift = 10.0
    private(set) var reference: HeadPose
    private var lastT: Double?

    init(calibrated: HeadPose) {
        self.calibrated = calibrated
        reference = calibrated
    }

    mutating func feed(_ s: HeadSample) {
        guard let yaw = s.yaw, let pitch = s.pitch else { return }
        defer { lastT = s.t }
        guard let last = lastT, AttentionGate.inside(s, reference: reference, config: limits) else { return }
        let k = min(max(s.t - last, 0), 1) / timeConstant
        func step(_ ref: Double, _ v: Double, _ origin: Double) -> Double {
            min(max(ref + (v - ref) * k, origin - maxDrift), origin + maxDrift)
        }
        reference = HeadPose(yaw: step(reference.yaw, yaw, calibrated.yaw), pitch: step(reference.pitch, pitch, calibrated.pitch))
    }
}

/// What the app keeps while the camera runs (`HeadWatcher`): the moving reference, the gate, the
/// last `keepSeconds` of gate marks and the «no» detector. A «no» is reported only while armed
/// (a question is waiting), and once. Pure: `--selftest` feeds it synthetic samples.
struct HeadLiveState {
    var keepSeconds = 30.0
    private(set) var tracker: ReferenceTracker?
    private var gateConfig = AttentionGate.Config.app
    private var gestures = HeadGestureDetector.Config()
    private var gate = AttentionGate(config: .app, startOn: true)
    private var detector = HeadGestureDetector()
    private(set) var noArmed = false
    private(set) var yesArmed = false
    private(set) var marks: [PhraseAttention.Mark] = []

    mutating func setReference(_ r: HeadPose) {
        if tracker?.calibrated != r {
            tracker = ReferenceTracker(calibrated: r)
            tracker?.limits = gateConfig
        }
    }

    /// The personal thresholds of the guided calibration (or the defaults).
    mutating func setProfile(gestures g: HeadGestureDetector.Config, gate c: AttentionGate.Config) {
        guard g != gestures || c != gateConfig else { return }
        gestures = g
        gateConfig = c
        gate = AttentionGate(config: c, startOn: gate.isOn)
        detector = HeadGestureDetector(config: g)
        if let calibrated = tracker?.calibrated {
            tracker = ReferenceTracker(calibrated: calibrated)
            tracker?.limits = c
        }
    }

    /// A question opens: the detector starts again, so movements before it do not count. The «no»
    /// answers every question; the «sì» only when `allowYes` (the «scrivilo» proposal, option on).
    mutating func arm(allowYes: Bool) {
        detector = HeadGestureDetector(config: gestures)
        noArmed = true
        yesArmed = allowYes
    }

    mutating func disarm() {
        noArmed = false
        yesArmed = false
    }

    /// The camera starts again: no marks, the gate «looking at the screen», the detector new.
    mutating func clearMarks() {
        marks = []
        gate = AttentionGate(config: gateConfig, startOn: true)
        detector = HeadGestureDetector(config: gestures)
        // The drift of the reference does not survive the camera going off.
        if let calibrated = tracker?.calibrated {
            tracker = ReferenceTracker(calibrated: calibrated)
            tracker?.limits = gateConfig
        }
    }

    /// The awaited gesture this sample completes, if any (then disarmed). Without a face the gate
    /// keeps its state: a missing face is judged by `PhraseAttention`, not by the gate.
    mutating func feed(_ s: HeadSample) -> HeadGestureDetector.Gesture? {
        if s.hasFace, var tr = tracker {
            tr.feed(s)
            tracker = tr
            _ = gate.feed(s, reference: tr.reference)
        }
        marks.append(PhraseAttention.Mark(t: s.t, hasFace: s.hasFace, gateOn: gate.isOn))
        if let first = marks.first, s.t - first.t > keepSeconds + 5 { marks.removeAll { s.t - $0.t > keepSeconds } }
        guard let g = detector.feed(s), noArmed, g == .no || yesArmed else { return nil }
        // A nod while turned to the room is for the room: it never writes. The «no» only cancels.
        if g == .yes && !gate.isOn { return nil }
        disarm()
        return g
    }
}

/// The result of the guided calibration, saved in the settings: personal thresholds, the limit
/// of the gate, and whether the «sì» passed the check.
struct HeadProfile: Codable, Equatable {
    var gestures: HeadGestureDetector.Config
    var limit: Double
    var yesVerified: Bool
    var date: Date
    /// What the check found, as said to Nico: «sì 3/3, no 3/3, nessun falso».
    var summary: String

    var gate: AttentionGate.Config { AttentionGate.Config(yawLimit: limit, pitchLimit: limit, hold: AttentionGate.Config.app.hold) }
}

/// Chooses the personal thresholds from a guided run: the phases without gestures (screen, room),
/// the training answers (5 sì, 5 no) and the check (3 sì, 3 no). Only thresholds with zero false
/// gestures over the whole run are kept; among them, the most right answers in training, then the
/// strictest. The check is then scored with the chosen thresholds. Pure.
enum HeadProfileFit {
    enum Failure: Equatable {
        case noFace
        /// Every threshold gives at least one false gesture in the training phases.
        case noThresholds
        /// The chosen thresholds give a false gesture in the check: not saved (zero falses overall).
        case falseInCheck
        /// Too few «no» recognized: a profile would make the head «no» worse than today.
        case tooFewNo
        /// Turned to the room not clearly beyond the limit: the gate would never close.
        case roomUnclear
        /// Looking at the screen moved more than 22°: any limit up to 25° would take the screen for the room.
        case screenUnsteady
    }

    struct Result: Equatable {
        var reference: HeadPose?
        var profile: HeadProfile?
        var failure: Failure?
        var trainingYes = GestureSpikeReport.Answers()
        var trainingNo = GestureSpikeReport.Answers()
        var checkYes = GestureSpikeReport.Answers()
        var checkNo = GestureSpikeReport.Answers()
    }

    /// Phases are told apart by name: training gestures are «sì»/«no», the check «verifica sì»/«verifica no».
    static let checkPrefix = "verifica "

    static func candidates() -> [HeadGestureDetector.Config] {
        var out: [HeadGestureDetector.Config] = []
        for pitch in [5.0, 6, 8, 10, 12] {
            for yaw in [6.0, 8, 10, 12] {
                for duration in [1.2, 1.5, 2.0] {
                    for dwell in [0.5, 0.7, 0.9] {
                        var c = HeadGestureDetector.Config()
                        c.pitchAmplitude = pitch; c.yawAmplitude = yaw; c.nodMaxDuration = duration; c.nodMaxDwell = dwell
                        out.append(c)
                    }
                }
            }
        }
        return out
    }

    /// Falses and answers of one configuration over the run.
    struct Score: Equatable {
        var falses = 0
        var answers: [String: GestureSpikeReport.Answers] = [:]
    }

    static func score(_ samples: [HeadSample], phases: [GesturePhase], config: HeadGestureDetector.Config) -> Score {
        let events = HeadGestureDetector.detect(samples, config: config)
        var s = Score()
        for p in phases {
            let found = events.filter { $0.t >= p.start && $0.t <= p.end }.map { (t: $0.t, gesture: $0.gesture) }
            if let a = GestureSpikeReport.answers(found, phase: p) {
                s.falses += a.wrong
                s.answers[p.name] = a
            } else {
                s.falses += found.count // no gesture expected here
            }
        }
        return s
    }

    /// The limit of the gate: 0.6 × the median deviation while turned to the room, between 15° and
    /// 25°, and above the 95th percentile of the deviation while looking at the screen (+3°). A
    /// failure when no such limit exists, or when the room is not clearly beyond it (5° margin).
    static func limit(_ samples: [HeadSample], screen: GesturePhase, room: GesturePhase, reference: HeadPose) -> (limit: Double, failure: Failure?) {
        func deviations(_ p: GesturePhase, grace: Double) -> [Double] {
            samples.filter { $0.hasFace && $0.t >= p.start + grace && $0.t <= p.end }
                .map { max(abs($0.yaw! - reference.yaw), abs($0.pitch! - reference.pitch)) }
        }
        let roomDev = deviations(room, grace: 1)
        let screenDev = deviations(screen, grace: 0)
        let floor = screenDev.isEmpty ? 0 : HeadCalibration.percentile(screenDev, 95) + 3
        guard floor <= 25 else { return (25, .screenUnsteady) }
        guard !roomDev.isEmpty else { return (25, .roomUnclear) }
        let roomMedian = HeadCalibration.median(roomDev)
        let limit = min(max(0.6 * roomMedian, floor, 15), 25)
        return (limit, roomMedian >= limit + 5 ? nil : .roomUnclear)
    }

    /// `phases`: «schermo» first (the reference), then «stanza», the others in any order.
    static func fit(_ samples: [HeadSample], phases: [GesturePhase], date: Date = Date()) -> Result {
        var r = Result()
        guard let screen = phases.first(where: { $0.name == "schermo" }),
              let reference = HeadCalibration.reference(samples.filter { $0.t >= screen.start && $0.t <= screen.end }) else {
            r.failure = .noFace
            return r
        }
        r.reference = reference
        let room = phases.first { $0.name == "stanza" } ?? screen
        let gate = limit(samples, screen: screen, room: room, reference: reference)
        if let failure = gate.failure {
            r.failure = failure
            return r
        }
        // The thresholds are chosen on the training phases only: the check stays new data.
        let training = phases.filter { !$0.name.hasPrefix(checkPrefix) }
        let check = phases.filter { $0.name.hasPrefix(checkPrefix) }
        var best: (config: HeadGestureDetector.Config, key: [Double], score: Score)?
        for c in candidates() {
            let s = score(samples, phases: training, config: c)
            guard s.falses == 0 else { continue }
            let right = training.compactMap { s.answers[$0.name]?.right }.reduce(0, +)
            // Most right answers, then the strictest: bigger amplitudes, shorter nods and dwell.
            let key = [Double(right), c.pitchAmplitude + c.yawAmplitude, -c.nodMaxDuration, -c.nodMaxDwell]
            if best.map({ $0.key.lexicographicallyPrecedes(key) }) ?? true { best = (c, key, s) }
        }
        guard let best else {
            r.failure = .noThresholds
            return r
        }
        let a = best.score.answers
        r.trainingYes = a["sì"] ?? .init()
        r.trainingNo = a["no"] ?? .init()
        let checked = score(samples, phases: check, config: best.config)
        r.checkYes = checked.answers[checkPrefix + "sì"] ?? .init()
        r.checkNo = checked.answers[checkPrefix + "no"] ?? .init()
        guard checked.falses == 0 else {
            r.failure = .falseInCheck
            return r
        }
        guard r.trainingNo.right * 2 > r.trainingNo.cues, r.checkNo.right * 2 > r.checkNo.cues else {
            r.failure = .tooFewNo
            return r
        }
        let yesOK = r.checkYes.cues > 0 && r.checkYes.right == r.checkYes.cues
        r.profile = HeadProfile(gestures: best.config, limit: gate.limit, yesVerified: yesOK, date: date,
                                summary: "sì \(r.checkYes.right)/\(r.checkYes.cues), no \(r.checkNo.right)/\(r.checkNo.cues), nessun falso")
        return r
    }
}

/// One axis of the zigzag: a swing counts when the angle reverses direction after travelling at
/// least `amplitude` degrees, and the travel took at most `maxLeg` seconds. A reversal is
/// confirmed only when the angle has come back by `margin` degrees from the extreme, so tremor
/// smaller than the margin never reverses anything.
struct SwingTracker {
    let amplitude: Double
    let maxLeg: Double
    let margin: Double
    /// A leg also ends when the angle stops for this long at its extreme (run of 29/10: after a
    /// shake the head comes back slowly and rests, and without this the slow return merged with
    /// the next shake into one leg seconds long).
    let settle = 0.3

    private var anchor: (t: Double, v: Double)?
    private var extreme: (t: Double, v: Double) = (0, 0)
    private var direction = 0
    /// The last time the angle was still within `margin` of the anchor: where the leg really started.
    private var legStart = 0.0
    private var previousT = 0.0

    init(amplitude: Double, maxLeg: Double) {
        self.amplitude = amplitude
        self.maxLeg = maxLeg
        margin = max(5, amplitude / 2)
    }

    mutating func reset() { anchor = nil; direction = 0 }

    /// Returns the time of the swing's extreme when a fast enough swing has just been confirmed.
    mutating func feed(t: Double, v: Double) -> Double? {
        defer { previousT = t }
        guard let a = anchor else {
            anchor = (t, v); extreme = (t, v); legStart = t; direction = 0
            return nil
        }
        if direction == 0 {
            if abs(v - a.v) >= margin {
                direction = v > a.v ? 1 : -1
                extreme = (t, v)
            } else {
                legStart = t
            }
            return nil
        }
        let d = Double(direction)
        if d * (v - a.v) < margin { legStart = t }
        if d * (v - extreme.v) > 0 {
            extreme = (t, v)
            return nil
        }
        if d * (extreme.v - v) < margin {
            guard t - extreme.t >= settle else { return nil }
            // Still at the extreme: the leg is over, rest here until the next movement.
            let travelled = d * (extreme.v - a.v)
            let swing = travelled >= amplitude && extreme.t - legStart <= maxLeg + 1e-9 ? extreme.t : nil
            anchor = extreme
            direction = 0
            legStart = t
            return swing
        }
        // Reversal: judge the leg that ended at the extreme, then start the opposite one.
        let travelled = d * (extreme.v - a.v)
        let fast = extreme.t - legStart <= maxLeg + 1e-9
        let swing = travelled >= amplitude && fast ? extreme.t : nil
        anchor = extreme
        direction = -direction
        legStart = previousT
        extreme = (t, v)
        return swing
    }
}

/// One nod on one axis: from rest the angle moves away by at least `amplitude` degrees and comes
/// back near rest, all within `maxDuration` seconds. Rest is the median of the last `restWindow`
/// seconds before the movement starts. A natural «sì» is a single nod (down and back), so it can
/// not wait for a second reversal as the zigzag does: the run of 29/10 gave 0/5 that way.
struct ExcursionTracker {
    let amplitude: Double
    let maxDuration: Double
    let margin: Double
    let restWindow = 0.5
    /// Longest stay near the bottom of the movement (within 75% of the peak): a nod stays about
    /// 0.3 s, a look at the keyboard much longer.
    let maxDwell: Double

    private var recent: [(t: Double, v: Double)] = []
    private var start: (t: Double, rest: Double)?
    private var peak = 0.0
    private var path: [(t: Double, d: Double)] = []

    init(amplitude: Double, maxDuration: Double, maxDwell: Double = 0.5) {
        self.amplitude = amplitude
        self.maxDuration = maxDuration
        self.maxDwell = maxDwell
        margin = max(3, amplitude * 0.4)
    }

    mutating func reset() { recent = []; start = nil; peak = 0; path = [] }

    /// Returns the start time of the nod when it has just come back near rest.
    mutating func feed(t: Double, v: Double) -> Double? {
        defer {
            recent.append((t, v))
            recent.removeAll { t - $0.t > restWindow }
        }
        if let s = start {
            let d = v - s.rest
            if abs(d) > abs(peak) { peak = d }
            path.append((t, d))
            if t - s.t > maxDuration {
                start = nil
                return nil
            }
            if abs(d) <= margin {
                // Back near rest: a nod if it went far enough, otherwise just noise that ends here
                // (left open, it would swallow the real nod that follows).
                start = nil
                let deep = path.filter { abs($0.d) >= abs(peak) * 0.75 }
                let dwell = (deep.last?.t ?? 0) - (deep.first?.t ?? 0)
                return abs(peak) >= amplitude && dwell <= maxDwell ? s.t : nil
            }
            return nil
        }
        guard recent.count >= 4 else { return nil }
        let rest = HeadCalibration.median(recent.map(\.v))
        if abs(v - rest) >= margin {
            start = (t, rest)
            peak = v - rest
            path = [(t, v - rest)]
        }
        return nil
    }
}

/// Yes and no with the head. Yes = one pitch nod (`ExcursionTracker`) with the yaw almost still;
/// no = `swings` yaw swings within `window` seconds with the pitch almost still. «Almost still»
/// means the other axis moved less than half as much as the gesture axis. After a gesture,
/// `pause` seconds of rest.
struct HeadGestureDetector {
    struct Config: Equatable, Codable {
        var pitchAmplitude = 8.0
        var yawAmplitude = 10.0
        var maxLeg = 0.6
        var window = 1.5
        var swings = 2
        var pause = 1.0
        /// Longest nod, from leaving rest to coming back.
        var nodMaxDuration = 1.5
        /// Longest stay near the bottom of a nod (run of 29/10: slow nods stayed 0.47–0.53 s).
        var nodMaxDwell = 0.5
    }

    enum Gesture: String, Equatable {
        case yes = "sì"
        case no = "no"
    }

    struct Event: Equatable {
        var t: Double
        var gesture: Gesture
    }

    let config: Config
    private var nod: ExcursionTracker
    private var yaw: SwingTracker
    private var yawSwings: [Double] = []
    private var history: [HeadSample] = []
    private var pausedUntil = -Double.infinity

    init(config: Config = Config()) {
        self.config = config
        nod = ExcursionTracker(amplitude: config.pitchAmplitude, maxDuration: config.nodMaxDuration, maxDwell: config.nodMaxDwell)
        yaw = SwingTracker(amplitude: config.yawAmplitude, maxLeg: config.maxLeg)
    }

    mutating func feed(_ s: HeadSample) -> Gesture? {
        guard let y = s.yaw, let p = s.pitch else {
            // A missing face breaks the nod and the zigzag: start again.
            nod.reset(); yaw.reset(); yawSwings = []; history = []
            return nil
        }
        history.append(s)
        history.removeAll { $0.t < s.t - max(config.window + config.maxLeg, config.nodMaxDuration) - 0.5 }
        let nodStart = nod.feed(t: s.t, v: p)
        if let at = yaw.feed(t: s.t, v: y), at >= pausedUntil { yawSwings.append(at) }
        // The window runs back from now, not from the newest swing: a swing is confirmed only at the
        // next reversal, which may come seconds later (a glance and back, then another glance).
        yawSwings.removeAll { s.t - $0 > config.window }
        guard s.t >= pausedUntil else { return nil }
        var found: Gesture?
        if let nodStart, quiet(main: \.pitch, other: \.yaw, since: nodStart) {
            found = .yes
        } else if yawSwings.count >= config.swings, quiet(main: \.yaw, other: \.pitch, since: yawSwings[yawSwings.count - config.swings] - config.maxLeg),
                  crossesRest(since: yawSwings[yawSwings.count - config.swings] - config.maxLeg) {
            found = .no
        }
        if found != nil {
            pausedUntil = s.t + config.pause
            yawSwings = []
        }
        return found
    }

    /// A «no» goes to both sides of where the head rested before it, by at least half the
    /// amplitude each: a glance to one side and back does not.
    private func crossesRest(since: Double) -> Bool {
        let before = history.filter { $0.t < since }.compactMap(\.yaw)
        let during = history.filter { $0.t >= since }.compactMap(\.yaw)
        guard let high = during.max(), let low = during.min() else { return false }
        let rest = before.isEmpty ? (during.first ?? 0) : HeadCalibration.median(before)
        return high - rest >= config.yawAmplitude / 2 && rest - low >= config.yawAmplitude / 2
    }

    private func quiet(main: KeyPath<HeadSample, Double?>, other: KeyPath<HeadSample, Double?>, since: Double) -> Bool {
        let recent = history.filter { $0.t >= since }
        func range(_ k: KeyPath<HeadSample, Double?>) -> Double {
            let v = recent.compactMap { $0[keyPath: k] }
            return (v.max() ?? 0) - (v.min() ?? 0)
        }
        return range(other) < range(main) / 2
    }

    /// The same detector over recorded samples, for the threshold grid.
    static func detect(_ samples: [HeadSample], config: Config = Config()) -> [Event] {
        var d = HeadGestureDetector(config: config)
        return samples.compactMap { s in d.feed(s).map { Event(t: s.t, gesture: $0) } }
    }
}

// MARK: - Report

/// One processed frame of the run, as kept in memory and in the TSV.
struct GestureFrame {
    var sample: HeadSample
    var phase: Int
    var visionMs: Double
    /// From the frame's capture time to the gate and gesture decision.
    var latencyMs: Double
    /// Nil during calibration, when there is no reference yet.
    var attention: Bool?
    var gesture: HeadGestureDetector.Gesture?
}

/// One phase of the protocol, with what is expected in it and what it cost.
struct GesturePhase {
    var name: String
    var expectAttention: Bool
    var expectedYes = 0
    var expectedNo = 0
    var start = 0.0
    var end = 0.0
    var cpuSeconds = 0.0
    /// True when the app speaks during the phase (the yes/no counts): its CPU includes the voice.
    var voiced = false
    /// When each number started being spoken (yes/no phases). Each number is a question: what
    /// counts is the first gesture after it, as in a real «scrivilo?».
    var cues: [Double] = []
}

enum GestureSpikeReport {
    /// Frames at the start of a phase not judged for attention: Nico is still turning.
    static let grace = 1.0

    struct Setup {
        var camera = ""
        var resolution = ""
        var fps = 15
        var gate = AttentionGate.Config()
        var gestures = HeadGestureDetector.Config()
    }

    struct Tally: Equatable {
        var yes = 0
        var no = 0
        /// Gestures of the wrong kind, gestures beyond the expected count, any gesture in a phase without gestures.
        var falses = 0
    }

    static func tally(_ found: [HeadGestureDetector.Gesture], phase: GesturePhase) -> Tally {
        let yes = found.filter { $0 == .yes }.count
        let no = found.count - yes
        if !phase.cues.isEmpty {
            // With questions, repeating the right gesture («sì sì sì») is harmless: only the wrong kind is false.
            return Tally(yes: yes, no: no, falses: (phase.expectedYes > 0 ? 0 : yes) + (phase.expectedNo > 0 ? 0 : no))
        }
        return Tally(yes: yes, no: no, falses: max(0, yes - phase.expectedYes) + max(0, no - phase.expectedNo))
    }

    /// Answers to the spoken numbers: right when the first gesture after a number (and before the
    /// next one) is the expected kind; repeats of the right kind are counted apart, not as false.
    struct Answers: Equatable {
        var right = 0
        var cues = 0
        var wrong = 0
        var repeats = 0
        /// From the start of the number to the first right gesture, seconds.
        var delays: [Double] = []
    }

    static func answers(_ found: [(t: Double, gesture: HeadGestureDetector.Gesture)], phase: GesturePhase) -> Answers? {
        guard let first = phase.cues.first else { return nil }
        let expected: HeadGestureDetector.Gesture = phase.expectedYes > 0 ? .yes : .no
        var a = Answers(cues: phase.cues.count)
        let early = found.filter { $0.t < first }
        a.wrong += early.filter { $0.gesture != expected }.count
        a.repeats += early.filter { $0.gesture == expected }.count
        for (i, cue) in phase.cues.enumerated() {
            let end = i + 1 < phase.cues.count ? phase.cues[i + 1] : max(phase.end, cue)
            let window = found.filter { $0.t >= cue && ($0.t < end || (i + 1 == phase.cues.count && $0.t <= end)) }
            a.wrong += window.filter { $0.gesture != expected }.count
            let right = window.filter { $0.gesture == expected }
            a.repeats += max(0, right.count - 1)
            if let g = window.first, g.gesture == expected {
                a.right += 1
                a.delays.append(g.t - cue)
            }
        }
        return a
    }

    /// Share of the judged frames (after `grace`) whose attention matches the phase.
    static func attentionAccuracy(_ frames: [GestureFrame], phase: GesturePhase, attention: (GestureFrame) -> Bool?) -> (correct: Int, judged: Int) {
        var correct = 0, judged = 0
        for f in frames where f.sample.t >= phase.start + grace {
            guard let a = attention(f) else { continue }
            judged += 1
            if a == phase.expectAttention { correct += 1 }
        }
        return (correct, judged)
    }

    /// The gate replayed over the recorded angles with other limits (phases after calibration).
    static func replayGate(_ frames: [GestureFrame], reference: HeadPose, config: AttentionGate.Config) -> [Bool?] {
        var gate = AttentionGate(config: config)
        return frames.map { f in f.phase == 0 ? nil : gate.feed(f.sample, reference: reference) }
    }

    /// The detector replayed over the recorded angles: the gestures found in each phase.
    static func replayGestures(_ frames: [GestureFrame], config: HeadGestureDetector.Config) -> [Int: [(t: Double, gesture: HeadGestureDetector.Gesture)]] {
        var d = HeadGestureDetector(config: config)
        var out: [Int: [(t: Double, gesture: HeadGestureDetector.Gesture)]] = [:]
        for f in frames { if let g = d.feed(f.sample) { out[f.phase, default: []].append((f.sample.t, g)) } }
        return out
    }

    static func lines(frames: [GestureFrame], phases: [GesturePhase], reference: HeadPose, setup: Setup, date: Date = Date()) -> [String] {
        func pct(_ c: Int, _ n: Int) -> String { n == 0 ? "—" : String(format: "%.0f%%", Double(c) / Double(n) * 100) }
        func ms(_ v: [Double]) -> String {
            v.isEmpty ? "—" : String(format: "mediana %.1f ms · 95° percentile %.1f ms", HeadCalibration.median(v), HeadCalibration.percentile(v, 95))
        }
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy HH:mm"
        let byPhase = Dictionary(grouping: frames, by: \.phase)
        let wall = phases.reduce(0) { $0 + max(0, $1.end - $1.start) }
        var inPhases = 0
        for (i, p) in phases.enumerated() { inPhases += (byPhase[i] ?? []).filter { $0.sample.t >= p.start && $0.sample.t <= p.end }.count }
        let realFPS = wall > 0 ? Double(inPhases) / wall : 0
        var lines = ["Spike gesti con la fotocamera · \(f.string(from: date)) · \(setup.camera) · \(setup.resolution) · \(setup.fps) fps chiesti, \(String(format: "%.1f", realFPS)) reali"]
        // How scattered the calibration was: median absolute deviation from the reference.
        let still = (byPhase[0] ?? []).map(\.sample).filter(\.hasFace)
        let spread = still.isEmpty ? "—" : String(format: "±%.1f° yaw, ±%.1f° pitch",
                                                  HeadCalibration.median(still.compactMap(\.yaw).map { abs($0 - reference.yaw) }),
                                                  HeadCalibration.median(still.compactMap(\.pitch).map { abs($0 - reference.pitch) }))
        lines.append("Solo angoli e tempi: nessuna immagine salvata, inviata o mostrata. Riferimento (mediana della calibrazione): "
                     + String(format: "yaw %.1f°, pitch %.1f°", reference.yaw, reference.pitch) + " · dispersione (deviazione assoluta mediana): \(spread)")
        lines.append(String(format: "Cancello: ±%.0f° yaw, ±%.0f° pitch, tenuta %.0f ms · sì: un cenno di almeno %.0f° pitch, andata e ritorno entro %.1f s · no: %d oscillazioni di almeno %.0f° yaw in %.1f s, ciascuna ≤ %.0f ms · pausa %.1f s",
                            setup.gate.yawLimit, setup.gate.pitchLimit, setup.gate.hold * 1000, setup.gestures.pitchAmplitude, setup.gestures.nodMaxDuration,
                            setup.gestures.swings, setup.gestures.yawAmplitude, setup.gestures.window, setup.gestures.maxLeg * 1000, setup.gestures.pause))
        lines.append("")
        lines.append("Per fase (attenzione giudicata dopo \(String(format: "%.0f", grace)) s dall'inizio della fase):")
        var totalFalses = 0
        for (i, p) in phases.enumerated() {
            let fs = byPhase[i] ?? []
            let absent = fs.filter { !$0.sample.hasFace }.count
            let acc = attentionAccuracy(fs, phase: p) { $0.attention }
            let t = tally(fs.compactMap(\.gesture), phase: p)
            let answered = answers(fs.compactMap { f in f.gesture.map { (f.sample.t, $0) } }, phase: p)
            totalFalses += t.falses
            let faces = fs.filter(\.sample.hasFace)
            // Rounded first, so a tiny negative value does not print as «-0.0».
            func r(_ v: Double) -> Double { (v * 10).rounded() / 10 + 0 }
            let dev = faces.isEmpty ? "—" : String(format: "%+.1f° / %+.1f°", r(HeadCalibration.median(faces.compactMap(\.sample.yaw)) - reference.yaw),
                                                   r(HeadCalibration.median(faces.compactMap(\.sample.pitch)) - reference.pitch))
            let span = max(0, p.end - p.start)
            let cpu = span > 0 ? String(format: "%.0f%%", p.cpuSeconds / span * 100) : "—"
            var line = "  \(i + 1). \(p.name) · \(fs.count) fotogrammi, volto assente \(absent) · attenzione attesa \(p.expectAttention ? "accesa" : "spenta"): "
            line += i == 0 ? "— (calibrazione)" : "corretta \(pct(acc.correct, acc.judged)) (\(acc.correct)/\(acc.judged))"
            line += " · scarto mediano yaw/pitch \(dev)"
            line += " · sì \(t.yes)/\(p.expectedYes) · no \(t.no)/\(p.expectedNo) · falsi \(t.falses) · CPU \(cpu)\(p.voiced ? " (con la voce)" : "")"
            if let a = answered {
                line += " · risposte giuste \(a.right)/\(a.cues), sbagliate \(a.wrong), ripetute \(a.repeats)"
                if !a.delays.isEmpty {
                    line += String(format: ", dal numero al gesto mediana %.2f s, massimo %.2f s", HeadCalibration.median(a.delays), a.delays.max() ?? 0)
                }
            }
            lines.append(line)
        }
        lines.append("")
        let voiceless = phases.filter { !$0.voiced }
        let cpuWall = voiceless.reduce(0) { $0 + max(0, $1.end - $1.start) }
        let cpu = cpuWall > 0 ? voiceless.reduce(0) { $0 + $1.cpuSeconds } / cpuWall * 100 : 0
        lines.append("Tempi: Vision \(ms(frames.map(\.visionMs))) · camera→decisione \(ms(frames.map(\.latencyMs).filter { $0 >= 0 }))")
        lines.append(String(format: "fps reali %.1f · CPU media del processo %.0f%% di un core (fasi senza voce; Neural Engine e GPU esclusi) · falsi gesti in tutta la corsa %d", realFPS, cpu, totalFalses))
        lines.append(resolutionLine(frames.map(\.sample)))
        lines.append("")
        lines.append("Griglia sì/no sugli stessi angoli (ampiezza uguale per pitch e yaw):")
        let yesPhase = phases.firstIndex { $0.expectedYes > 0 }
        let noPhase = phases.firstIndex { $0.expectedNo > 0 }
        for amplitude in [6.0, 8.0, 10.0, 12.0] {
            for swings in [2, 3] {
                var c = setup.gestures
                c.pitchAmplitude = amplitude; c.yawAmplitude = amplitude; c.swings = swings
                let found = replayGestures(frames, config: c)
                var falses = 0
                for (i, p) in phases.enumerated() { falses += tally((found[i] ?? []).map(\.gesture), phase: p).falses }
                /// «giuste/numeri (ripetute n)» with questions, otherwise «trovati/attesi».
                func score(_ index: Int?, _ kind: HeadGestureDetector.Gesture) -> String {
                    guard let index else { return "—" }
                    let p = phases[index], got = found[index] ?? []
                    if let a = answers(got, phase: p) { return "\(a.right)/\(a.cues) (ripetute \(a.repeats))" }
                    return "\(got.filter { $0.gesture == kind }.count)/\(kind == .yes ? p.expectedYes : p.expectedNo)"
                }
                lines.append(String(format: "  A %2.0f° · %d oscillazioni (no) · sì %@ · no %@ · falsi %d", amplitude, swings,
                                    score(yesPhase, .yes), score(noPhase, .no), falses))
            }
        }
        lines.append("Griglia del cancello sugli stessi angoli (limite uguale per yaw e pitch, tenuta \(String(format: "%.0f", setup.gate.hold * 1000)) ms):")
        for limit in [10.0, 15.0, 20.0, 25.0] {
            var c = setup.gate
            c.yawLimit = limit; c.pitchLimit = limit
            let replay = replayGate(frames, reference: reference, config: c)
            var parts: [String] = []
            for (i, p) in phases.enumerated() where i > 0 {
                let idx = frames.indices.filter { frames[$0].phase == i }
                var correct = 0, judged = 0
                for j in idx where frames[j].sample.t >= p.start + grace {
                    guard let a = replay[j] else { continue }
                    judged += 1
                    if a == p.expectAttention { correct += 1 }
                }
                parts.append("\(p.name) \(pct(correct, judged))")
            }
            lines.append(String(format: "  ±%2.0f° · ", limit) + parts.joined(separator: " · "))
        }
        return lines
    }

    /// Detects quantized angles: how many distinct values (to 0.1°) and the smallest step between them.
    static func resolutionLine(_ samples: [HeadSample]) -> String {
        func describe(_ values: [Double], _ name: String) -> String {
            let distinct = Array(Set(values.map { ($0 * 10).rounded() / 10 })).sorted()
            let steps = zip(distinct.dropFirst(), distinct).map { $0 - $1 }.filter { $0 > 0 }
            return "\(distinct.count) valori distinti di \(name)" + (steps.isEmpty ? "" : String(format: " (passo minimo %.1f°)", steps.min()!))
        }
        let faces = samples.filter(\.hasFace)
        return "Risoluzione angoli: " + describe(faces.compactMap(\.yaw), "yaw") + ", " + describe(faces.compactMap(\.pitch), "pitch")
    }

    /// The angles of every frame, one row each, times in seconds from the start of the first phase.
    static func tsv(frames: [GestureFrame], phases: [GesturePhase]) -> String {
        let origin = phases.first?.start ?? frames.first?.sample.t ?? 0
        func n(_ v: Double?, _ digits: Int = 2) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "" }
        var rows = ["t\tfase\tvolto\tyaw\tpitch\troll\tdimensione\tvision_ms\tlatenza_ms\tattenzione\tgesto"]
        for f in frames {
            let s = f.sample
            let phase = phases.indices.contains(f.phase) ? phases[f.phase].name : "\(f.phase)"
            rows.append([n(s.t - origin, 3), phase, s.hasFace ? "1" : "0", n(s.yaw), n(s.pitch), n(s.roll), n(s.size, 3), n(f.visionMs, 1), n(f.latencyMs, 1),
                         f.attention.map { $0 ? "1" : "0" } ?? "", f.gesture?.rawValue ?? ""].joined(separator: "\t"))
        }
        return rows.joined(separator: "\n") + "\n"
    }
}
