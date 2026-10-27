import Foundation
import FoundationModels

/// Dictation cleanup with Apple's model (FR-33): no cloud, no subscription.
@Generable
struct CleanedDictation {
    @Guide(description: "il testo dettato con punteggiatura corretta e senza intercalari")
    var testo: String
}

@MainActor
enum LocalText {
    static let instructions = """
    Ripulisci un testo dettato a voce in italiano. Metti la maiuscola all'inizio delle frasi e la \
    punteggiatura giusta (virgole, punto finale, punto di domanda). Togli gli intercalari («ehm», «cioè», \
    «allora» a inizio frase) e le parole ripetute per errore. Non cambiare il significato, non aggiungere \
    né togliere contenuti, non rispondere al testo.
    Esempio: «ehm ciao Luca cioè ci vediamo domani domani alle tre» → «Ciao Luca, ci vediamo domani alle tre.»
    """

    private static var ready: LanguageModelSession?

    /// Loads the model so the next cleanup answers in about a second.
    static func prewarm() {
        guard LocalEngine.appleModelAvailable, ready == nil else { return }
        let s = LanguageModelSession(instructions: instructions)
        s.prewarm()
        ready = s
    }

    /// The cleaned text, or nil when the model is not available, too slow or changed too much.
    static func cleanDictation(_ text: String, timeout: Duration = .milliseconds(2500)) async -> String? {
        guard LocalEngine.appleModelAvailable else { return nil }
        let session = ready ?? LanguageModelSession(instructions: instructions)
        ready = nil
        defer { prewarm() }
        let result: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor in
                (try? await session.respond(to: text, generating: CleanedDictation.self,
                                            options: GenerationOptions(samplingMode: .greedy)))?.content.testo
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let cleaned = result?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else { return nil }
        // A cleanup never changes the length much: otherwise the model rewrote or answered.
        let ratio = Double(cleaned.count) / Double(max(1, text.count))
        return ratio > 0.6 && ratio < 1.3 ? cleaned : nil
    }
}
