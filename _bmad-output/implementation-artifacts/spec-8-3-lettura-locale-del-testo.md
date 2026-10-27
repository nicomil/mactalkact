---
title: 'Storia 8.3 — Lettura locale del testo nelle immagini'
type: 'feature'
created: '2026-10-27'
status: 'in-review'
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
- La prima lettura accurata in assoluto è costata 57 s (il sistema compila il modello una volta sola); poi 0,2 s.
- Etichetta con Claude: `read_text` in 0,36 s, nessuno screenshot. Modello Apple con immagine: descrive 5/5, legge male (numero inventato), non localizza (ricerca §20).

## Spec Change Log

## Review Triage Log
