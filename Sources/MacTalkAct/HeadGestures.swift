import Foundation

// Pure logic of the head gesture spike (`--gesture-spike`): calibration, attention gate, yes/no
// with the head, and the report. No camera here: everything works on angles and times, so
// `--selftest` proves it with synthetic samples.

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
    struct Config: Equatable {
        var yawLimit = 15.0
        var pitchLimit = 15.0
        var hold = 0.3
    }

    var config = Config()
    private(set) var isOn = false
    private var pendingSince: Double?

    init(config: Config = Config()) { self.config = config }

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

/// One axis of the zigzag: a swing counts when the angle reverses direction after travelling at
/// least `amplitude` degrees, and the travel took at most `maxLeg` seconds. A reversal is
/// confirmed only when the angle has come back by `margin` degrees from the extreme, so tremor
/// smaller than the margin never reverses anything.
struct SwingTracker {
    let amplitude: Double
    let maxLeg: Double
    let margin: Double

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
        guard d * (extreme.v - v) >= margin else { return nil }
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

/// Yes and no with the head. Yes = `swings` pitch swings within `window` seconds with the yaw
/// almost still; no = the same on yaw with the pitch almost still. «Almost still» means the other
/// axis moved less than half as much as the gesture axis. After a gesture, `pause` seconds of rest.
struct HeadGestureDetector {
    struct Config: Equatable {
        var pitchAmplitude = 8.0
        var yawAmplitude = 10.0
        var maxLeg = 0.6
        var window = 1.5
        var swings = 2
        var pause = 1.0
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
    private var pitch: SwingTracker
    private var yaw: SwingTracker
    private var pitchSwings: [Double] = []
    private var yawSwings: [Double] = []
    private var history: [HeadSample] = []
    private var pausedUntil = -Double.infinity

    init(config: Config = Config()) {
        self.config = config
        pitch = SwingTracker(amplitude: config.pitchAmplitude, maxLeg: config.maxLeg)
        yaw = SwingTracker(amplitude: config.yawAmplitude, maxLeg: config.maxLeg)
    }

    mutating func feed(_ s: HeadSample) -> Gesture? {
        guard let y = s.yaw, let p = s.pitch else {
            // A missing face breaks the zigzag: start again.
            pitch.reset(); yaw.reset(); pitchSwings = []; yawSwings = []; history = []
            return nil
        }
        history.append(s)
        history.removeAll { $0.t < s.t - (config.window + config.maxLeg + 0.5) }
        if let at = pitch.feed(t: s.t, v: p), at >= pausedUntil { pitchSwings.append(at) }
        if let at = yaw.feed(t: s.t, v: y), at >= pausedUntil { yawSwings.append(at) }
        // The window runs back from now, not from the newest swing: a swing is confirmed only at the
        // next reversal, which may come seconds later (a glance and back, then another glance).
        pitchSwings.removeAll { s.t - $0 > config.window }
        yawSwings.removeAll { s.t - $0 > config.window }
        guard s.t >= pausedUntil else { return nil }
        var found: Gesture?
        if pitchSwings.count >= config.swings, quiet(main: \.pitch, other: \.yaw, since: pitchSwings[pitchSwings.count - config.swings] - config.maxLeg) {
            found = .yes
        } else if yawSwings.count >= config.swings, quiet(main: \.yaw, other: \.pitch, since: yawSwings[yawSwings.count - config.swings] - config.maxLeg) {
            found = .no
        }
        if found != nil {
            pausedUntil = s.t + config.pause
            pitchSwings = []
            yawSwings = []
        }
        return found
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
        return Tally(yes: yes, no: no, falses: max(0, yes - phase.expectedYes) + max(0, no - phase.expectedNo))
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
    static func replayGestures(_ frames: [GestureFrame], config: HeadGestureDetector.Config) -> [Int: [HeadGestureDetector.Gesture]] {
        var d = HeadGestureDetector(config: config)
        var out: [Int: [HeadGestureDetector.Gesture]] = [:]
        for f in frames { if let g = d.feed(f.sample) { out[f.phase, default: []].append(g) } }
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
        lines.append(String(format: "Cancello: ±%.0f° yaw, ±%.0f° pitch, tenuta %.0f ms · sì/no: ampiezza %.0f° pitch / %.0f° yaw, %d oscillazioni in %.1f s, ciascuna ≤ %.0f ms, pausa %.1f s",
                            setup.gate.yawLimit, setup.gate.pitchLimit, setup.gate.hold * 1000, setup.gestures.pitchAmplitude, setup.gestures.yawAmplitude,
                            setup.gestures.swings, setup.gestures.window, setup.gestures.maxLeg * 1000, setup.gestures.pause))
        lines.append("")
        lines.append("Per fase (attenzione giudicata dopo \(String(format: "%.0f", grace)) s dall'inizio della fase):")
        var totalFalses = 0
        for (i, p) in phases.enumerated() {
            let fs = byPhase[i] ?? []
            let absent = fs.filter { !$0.sample.hasFace }.count
            let acc = attentionAccuracy(fs, phase: p) { $0.attention }
            let t = tally(fs.compactMap(\.gesture), phase: p)
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
                for (i, p) in phases.enumerated() { falses += tally(found[i] ?? [], phase: p).falses }
                let yes = yesPhase.map { tally(found[$0] ?? [], phase: phases[$0]) }
                let no = noPhase.map { tally(found[$0] ?? [], phase: phases[$0]) }
                lines.append(String(format: "  A %2.0f° · %d oscillazioni · sì %@ · no %@ · falsi %d", amplitude, swings,
                                    yes.map { "\($0.yes)/\(phases[yesPhase!].expectedYes)" } ?? "—",
                                    no.map { "\($0.no)/\(phases[noPhase!].expectedNo)" } ?? "—", falses))
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
