import Foundation

/// «Calibrazione completa» (Impostazioni › Ascolto): the protocol of `--gesture-spike`, guided by
/// voice, to choose personal thresholds. Look at the screen, turn to the room, come back, 5 sì and
/// 5 no at each number said, then a check with 3 sì and 3 no. Only angles are recorded, in memory;
/// `HeadProfileFit` chooses the thresholds. «stop» or closing the settings cancels: nothing saved.
@MainActor
final class HeadCalibrationGuide {
    static let gestureCount = 5
    static let checkCount = 3
    static let secondsPerGesture = 3.0
    static let screenSeconds = 5.0
    static let roomSeconds = 6.0
    static let backSeconds = 3.0

    enum Outcome: Equatable {
        case done(HeadProfileFit.Result)
        case cancelled
        case failed(String)
        /// Another calibration is already recording.
        case busy
    }

    private(set) var isRunning = false
    private var cancelled = false
    private let speaker: Speaker

    init(speaker: Speaker) { self.speaker = speaker }

    func cancel() {
        guard isRunning else { return }
        cancelled = true
        speaker.stop()
    }

    /// `progress`: a short line for the settings card at each phase.
    func run(watcher: HeadWatcher, progress: @escaping (String) -> Void) async -> Outcome {
        guard !isRunning else { return .busy }
        isRunning = true
        cancelled = false
        defer { isRunning = false }
        if let failure = watcher.beginRecording() {
            return failure == .busy ? .busy : .failed("La fotocamera non funziona: \(failure.label).")
        }
        var phases: [GesturePhase] = []
        let total = 7

        func say(_ text: String) async { if !cancelled { await speaker.say(text) } }
        /// Waits in small steps, so «stop» is felt at once. False when cancelled.
        func wait(_ seconds: Double) async -> Bool {
            var left = seconds
            while left > 0, !cancelled {
                try? await Task.sleep(for: .milliseconds(100))
                left -= 0.1
            }
            return !cancelled
        }
        /// One phase: instruction, then recording for `seconds` or the numbers.
        func phase(_ index: Int, _ name: String, instruction: String, seconds: Double = 0, numbers: Int = 0,
                   expectYes: Bool = false) async -> Bool {
            progress("Fase \(index) di \(total): \(instruction)")
            await say(instruction)
            guard !cancelled else { return false }
            var p = GesturePhase(name: name, expectAttention: name != "stanza")
            p.start = HeadCamera.hostNow()
            if numbers > 0 {
                if expectYes { p.expectedYes = numbers } else { p.expectedNo = numbers }
                for i in 1...numbers {
                    p.cues.append(HeadCamera.hostNow())
                    await say("\(i)")
                    guard await wait(Self.secondsPerGesture) else { return false }
                }
            } else {
                guard await wait(seconds) else { return false }
            }
            p.end = HeadCamera.hostNow()
            phases.append(p)
            return true
        }

        await say("Calibrazione dei gesti con la testa. Non salvo nessuna immagine, solo gli angoli. Di' stop per interrompere.")
        var ok = await phase(1, "schermo", instruction: "Guarda lo schermo e resta fermo.", seconds: Self.screenSeconds)
        if ok, HeadCalibration.reference(watcher.recordedSamples()) == nil {
            // The message is said once, by whoever shows the outcome.
            let (_, failure) = watcher.endRecording()
            if let failure { return .failed("La fotocamera non funziona: \(failure.label).") }
            return .failed("Non vedo il tuo volto: mettiti davanti alla fotocamera e riprova.")
        }
        if ok { ok = await phase(2, "stanza", instruction: "Ora girati verso la stanza, come se parlassi con qualcuno, e resta così.", seconds: Self.roomSeconds) }
        if ok { ok = await phase(3, "ritorno", instruction: "Torna a guardare lo schermo.", seconds: Self.backSeconds) }
        if ok { ok = await phase(4, "sì", instruction: "Guardando lo schermo, fai sì con la testa a ogni numero.", numbers: Self.gestureCount, expectYes: true) }
        if ok { ok = await phase(5, "no", instruction: "Ora fai no con la testa a ogni numero.", numbers: Self.gestureCount) }
        if ok { ok = await phase(6, HeadProfileFit.checkPrefix + "sì", instruction: "Verifica: fai sì a ogni numero.", numbers: Self.checkCount, expectYes: true) }
        if ok { ok = await phase(7, HeadProfileFit.checkPrefix + "no", instruction: "E ora no a ogni numero.", numbers: Self.checkCount) }
        let (samples, failure) = watcher.endRecording()
        guard ok, !cancelled else { return .cancelled }
        if let failure { return .failed("La fotocamera non funziona: \(failure.label).") }
        progress("Scelgo le soglie…")
        // The grid runs off the main actor: a few hundred replays of about a minute of angles.
        let fitted = phases
        let result = await Task.detached(priority: .userInitiated) { HeadProfileFit.fit(samples, phases: fitted) }.value
        // «stop» or the settings closed while the thresholds were chosen: still nothing saved.
        return cancelled ? .cancelled : .done(result)
    }

    /// What to save and what to say after a run. Pure, tested by `--selftest`.
    nonisolated static func conclusion(_ outcome: Outcome) -> (profile: HeadProfile?, reference: HeadPose?, message: String) {
        switch outcome {
        case .cancelled:
            return (nil, nil, "Calibrazione interrotta: non ho cambiato niente.")
        case .failed(let why):
            return (nil, nil, why)
        case .busy:
            return (nil, nil, "Calibrazione già in corso.")
        case .done(let r):
            switch r.failure {
            case .noFace:
                return (nil, nil, "Non vedo il tuo volto: mettiti davanti alla fotocamera e riprova.")
            case .noThresholds:
                return (nil, nil, "Non sono riuscito a tarare senza gesti falsi: resto come prima.")
            case .falseInCheck:
                return (nil, nil, "Nella verifica ho visto un gesto falso: resto come prima. Riprova con gesti netti.")
            case .tooFewNo:
                return (nil, nil, "Ho riconosciuto pochi no: resto come prima. Riprova facendo no ben deciso.")
            case .roomUnclear:
                return (nil, nil, "Non ti ho visto girarti abbastanza verso la stanza: resto come prima. Riprova girandoti di più.")
            case .screenUnsteady:
                return (nil, nil, "Mentre guardavi lo schermo ti sei mosso troppo: resto come prima. Riprova restando fermo.")
            case nil:
                guard let p = r.profile else { return (nil, nil, "Non sono riuscito a tarare: resto come prima.") }
                let yes = p.yesVerified ? " Puoi attivare la conferma con un sì della testa." : " Il sì non è ancora affidabile: per confermare usa la voce."
                return (p, r.reference, "Fatto: \(p.summary).\(yes)")
            }
        }
    }
}
