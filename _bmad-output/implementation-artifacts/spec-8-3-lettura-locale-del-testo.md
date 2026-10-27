---
title: 'Storia 8.3 — Lettura locale del testo nelle immagini'
type: 'feature'
created: '2026-10-27'
status: 'done'
baseline_commit: '62cf5ad7dc08e37ea634181b1a196fa9117e857f'
route: 'dispatch'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Per leggere il numero su un'etichetta o il testo di una foto l'Agente manda uno screenshot a Claude.

**Approach:** Strumento `read_text(region)` con Vision sul Mac: testo con le posizioni, accurato con ripiego al veloce, entro 10 s, con riscaldamento in background all'avvio. `screenshot` con `region` include il testo letto e, quando basta, lo manda al posto dell'immagine. Il prompt indica `read_text` per il testo nelle immagini. Il Banco registra la prima lettura. Una prova a parte misura che cosa fa il modello Apple con l'immagine.

## Boundaries & Constraints

**Always:** lettura prima del riscaldamento in modalità veloce, oppure «testo non leggibile ora»; posizioni nelle coordinate di `observe`; lo strumento è di sola lettura e passa da `AgentTools.call` (AD-20).

**Never:** nessun requisito nuovo dal modello Apple senza un numero.

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/TextReader.swift` -- nuovo: Vision, riscaldamento, corsa al tempo massimo, riduzione a 2.000 px.
- `Sources/MacTalkAct/AgentTools.swift` -- `read_text`, testo nello zoom, `readTextSeconds`.
- `Sources/MacTalkAct/AgentRunner.swift` -- riga «Hands» del prompt.
- `Sources/MacTalkAct/AppDelegate.swift` -- riscaldamento all'avvio.
- `Sources/MacTalkAct/DebugCLI.swift`, `main.swift` -- `--hands-test`, colonne del Banco, `--local-vision-test`.

## Tasks & Acceptance

**Execution:**
- [x] `TextReader.swift`, `AgentTools.swift`, `AgentRunner.swift`, `AppDelegate.swift` -- strumento e prompt.
- [x] `DebugCLI.swift`, `main.swift` -- prove e Banco.
- [x] ricerca -- §20.

**Acceptance Criteria:**
- Given `etichetta-ordine` con Claude, when lo eseguo, then riesce con `read_text` e senza screenshot, e il Banco registra la prima lettura.
- Given `--hands-test`, when gira, then `read_text` legge «4821-B» e lo zoom contiene il testo.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --hands-test` -- expected: nessun FAIL (agisce sullo schermo)

## Implementation Notes

- Spec approvata in autonomia (Nico: «committa e procedi»).
- Vision non si interrompe con la cancellazione: corsa con una continuation che risponde alla prima tra la lettura e il tempo massimo.
- Il riscaldamento accurato costa circa 55 s al primo avvio di un binario appena compilato (Vision compila il modello per quel binario), poi 0,2–0,35 s per lettura. Nell'app installata il costo è una tantum all'avvio, in background; `--hands-test` aspetta il riscaldamento fino a 90 s.
- Etichetta con Claude: `read_text` in 0,36 s, nessuno screenshot. Modello Apple con immagine: descrive 5/5, legge male (numero inventato), non localizza (ricerca §20).

## Spec Change Log

## Review Triage Log

Prima review (3 revisori). Nessun rilievo di intento o di spec; patch salvo due rinvii.

| Rilievo | Verdetto | Evidenza / esito |
|---|---|---|
| Letture scadute che continuano e si accumulano; `warmUp` ripetibile | medium | Patch: coda seriale per Vision (le nuove letture attendono entro il loro limite), riscaldamento una sola volta |
| Riduzione a 2.000 px che perde la stampa piccola; `makeImage` chiamato due volte | medium | Patch: riduzione solo sopra 4.096 px, una sola immagine |
| Zoom: niente modo di chiedere l'immagine, solo testo anche su icone; fino a 10 s di attesa; suggerimento sbagliato e indicazione sui click persa | medium | Patch: `image: true`, solo testo se sicuro **e** copre più del 15% della regione, limite di 2 s sullo zoom, indicazione dei click sempre presente |
| Ordine delle righe non transitivo e duplicato | low | Patch: `TextReader.ordered` (righe per sovrapposizione verticale, poi da sinistra), testato |
| Coordinate di `read_text` in punti della finestra mentre i click usano lo screenshot | low | Patch: la descrizione lo dice e indica come cliccare |
| Regione malformata letta come finestra intera | low | Patch: errore |
| Regione vuota: accurata vuota e poi veloce; errore di Vision trattato come «riprova» | low | Patch: un vuoto è una risposta, un errore vale «nessun testo» |
| Colonne del Banco: righe senza Agente, zoom contato come screenshot, tempi azzerati nel ripiego | low | Patch: solo con l'Agente, solo screenshot interi, tempi tenuti nella ripetizione |
| `firstReadSeconds` mai letto | low | Patch: tolto |
| Prompt che scoraggiava lo screenshot per le icone senza etichetta | low | Patch: riga aggiornata |
| Nessun test per regione, zoom solo testo, `image: true`, tempo massimo, soglia di 1 s a caldo | gap | Patch: tutti in `--hands-test`, con l'attesa vera del riscaldamento |
| `localVisionTest`: niente controllo del modello | low | Patch: controllo della disponibilità |
| `VNRecognizeTextRequest` invece di `RecognizeTextRequest` | low | Scelta registrata: la richiesta classica dà il controllo sincrono che serve alla corsa col tempo massimo |
| `read_text` non disponibile al Motore locale | gap | Rinviato: il Motore locale lavora in modalità piano con `observe` (AD-17); da valutare con i numeri |
| Posizioni di `read_text` non confrontate con quelle di `observe` | gap | Rinviato: confronto manuale fatto sull'etichetta (@277,278) |
