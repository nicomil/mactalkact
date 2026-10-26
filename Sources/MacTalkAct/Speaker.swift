import AVFoundation

/// Optional spoken replies, at low volume (a baby may be sleeping).
/// While it speaks, the app stops listening so it does not hear itself.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Void, Never>?
    private(set) var isSpeaking = false
    /// Called when speech starts (true) and ends (false).
    var onSpeakingChange: ((Bool) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    private lazy var voice: AVSpeechSynthesisVoice? = {
        let italian = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("it") }
        // Best available quality first.
        return italian.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "it-IT")
    }()

    /// Speaks and returns when done.
    func say(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        stop()
        let u = AVSpeechUtterance(string: t)
        u.voice = voice
        u.volume = Float(AppSettings.shared.speechVolume)
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(AppSettings.shared.speechRate))
        isSpeaking = true
        onSpeakingChange?(true)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finished = c
            synth.speak(u)
        }
        // Let the room echo die out before listening again.
        try? await Task.sleep(for: .milliseconds(300))
        isSpeaking = false
        onSpeakingChange?(false)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        resume()
    }

    private func resume() {
        finished?.resume()
        finished = nil
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.resume() } }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.resume() } }
    }
}
