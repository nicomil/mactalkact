# Addendum al PRD — dettagli tecnici e alternative scartate

Materiale utile all'architettura e alle storie che non appartiene ai requisiti.

## Alternative valutate per il Router

| Alternativa | Esito | Motivo |
| --- | --- | --- |
| Allungare la lista `Grammar.actionVerbs` | Scartata | La lingua parlata ha troppe forme («rimetti», «cambiala», «fai che…»); ogni aggiunta lascia scoperte altre frasi e non risolve la Chiacchiera. |
| Classificare con Claude (Haiku o Sonnet) via CLI | Scartata | Avvio e risposta della CLI richiedono circa 2 s, consumano la subscription e smettono di funzionare al limite. |
| Classificatore on-device (FoundationModels) | Scelta | Verificato il 26/10: 6/6 corrette, 0,55–0,63 s a modello caldo, offline, gratuito. |
| Chiedere sempre conferma prima di scrivere | Scartata | Rallenta la dettatura, che è l'uso più frequente; la conferma resta solo per i casi incerti (FR-4). |

## Dettagli dell'esperimento on-device

- API: `SystemLanguageModel.default`, `LanguageModelSession(instructions:)`, `respond(to:generating:)` con un tipo `@Generable` e `@Guide(.anyOf([...]))` per vincolare l'uscita.
- Un `enum` `@Generable` ha fallito con «Unexpected value " dettatura"»: usare una struct con un campo `String` vincolato da `.anyOf`.
- Prima chiamata dopo l'avvio del processo: circa 2 s; conviene chiamare `prewarm()` all'avvio e dopo ogni risposta.
- Codice di prova in `scratchpad/fm/fm.swift` e `scratchpad/fm/act.swift` (non nel progetto).

## Idee per lo strumento di modifica negli editor web (FR-16)

1. Clic nel campo, `get_text` per leggere la riga dal testo visibile (screenshot o AX della pagina), poi selezione con Home / Shift+End sulla riga giusta e digitazione del nuovo testo.
2. In alternativa, Cmd+A dentro la cella (in Jupyter seleziona solo la cella) e riscrittura dell'intero contenuto, quando la cella è corta.
3. Verifica finale con screenshot o lettura del testo della pagina.

## Strumento in blocco (FR-15)

Firma proposta: `click_many(ids: [Int], method: "auto|mouse")` → per ogni id: etichetta, esito, stato dopo l'azione (`AXValue` per caselle e interruttori). Dopo uno scorrimento gli id cambiano: lo strumento rifiuta id di un registro scaduto.
