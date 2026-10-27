---
title: 'Storia 8.1 — Le Frasi spurie non arrivano all''Agente'
type: 'feature'
created: '2026-10-27'
status: 'in-review'
baseline_commit: '088e7bbdf47f640173845dfc8acb68377db4a12f'
route: 'dispatch'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** In ascolto a mani libere, o con la Finestra di conversazione aperta, una frase sentita male («Spegni invia», «Statico», «Selling counseling gesta») arriva all'Agente e occupa Claude per 4–20 s (Banco, ricerca §13–§17) senza che Nico abbia chiesto niente.

**Approach:** Nel Router, dopo i Comandi rapidi e la Corsia locale e prima dell'Agente, una frase senza Parola di attivazione decide `.askIntent` in due casi: ha al massimo tre parole e nessun bersaglio noto, oppure è fatta in maggioranza di parole che non sono italiane. L'HUD chiede «Vuoi che faccia qualcosa?» per 8 s, senza armare la conversazione né aprire la Finestra. La frase successiva viene valutata come se la domanda non ci fosse. Lo stesso vale quando il Classificatore on-device supera il tempo massimo su una frase senza Parola di attivazione.

## Boundaries & Constraints

**Always:** Parola di attivazione o push-to-talk: percorso invariato. In un campo di testo con Parola di attivazione resta `.askToType` (AD-2). Il bersaglio noto è lo stesso di `RouteHeuristics.hasKnownTarget` (Storia 7.3). Ogni regola nuova aggiunge righe al Corpus.

**Never:** nessun Motore avviato per una `.askIntent`; nessun cambiamento ai Comandi rapidi né alla Corsia locale.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Due parole sentite male | «Spegni invia», sessione, nessun bersaglio | `.askIntent` | — |
| Parole straniere | «Selling counseling gesta», finestra aperta | `.askIntent` | — |
| Comando | «apri Safari», «clicca Salva» | Comando rapido | — |
| Con parola di attivazione | «computer, statico» | percorso di oggi | — |
| Classificatore oltre il tempo | frase lunga in sessione, timeout | `.askIntent` | — |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/IntentRouter.swift` -- `RouteDecision.askIntent`, `commandRoute` (regola prima dell'Agente), rami «sessione» e «finestra» di `decide` (timeout del classificatore).
- `Sources/MacTalkAct/IntentClassifier.swift` -- `RouteHeuristics.isSpurious` (tre parole senza bersaglio, maggioranza di parole non italiane con `NSSpellChecker`).
- `Sources/MacTalkAct/Coordinator.swift` -- HUD «Vuoi che faccia qualcosa?», 8 s, senza armare né aprire la finestra; `knownTarget` sempre disponibile al Router.
- `Sources/MacTalkAct/DebugCLI.swift` -- route-test con `knownTarget`; Banco: le Frasi spurie ora decise dal Router.
- `Tests/corpus/instradamento.tsv` -- almeno 15 Frasi spurie con esito «chiedi» o «ignora».

## Tasks & Acceptance

**Execution:**
- [x] `IntentRouter.swift`, `IntentClassifier.swift` -- decisione e regola.
- [x] `Coordinator.swift` -- HUD e bersaglio noto.
- [x] `DebugCLI.swift`, `Tests/corpus/instradamento.tsv` -- Corpus e Banco.

**Acceptance Criteria:**
- Given `--route-test`, when gira, then passa con almeno 15 Frasi spurie e zero frasi valide decise `.askIntent`.
- Given il Banco, when lo eseguo, then le 5 Frasi spurie non avviano l'Agente.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest`, `--route-test` -- expected: nessun FAIL

## Implementation Notes

- Spec approvata in autonomia (Nico: «committa e procedi»). Branch `epic-8-precisione` da `epic-7-velocita`.
- La lingua si giudica con `NLLanguageRecognizer` sull'intera frase (italiano sotto il 20% → non italiana): il dizionario italiano di `NSSpellChecker` accetta «the», «end», «story».
- In un campo di testo il campo è il bersaglio: «Modifica la domanda» resta all'Agente.
- Banco: 5 Frasi spurie da 4,8 s di mediana con Claude a 1,6 s col solo Router; Corpus 160/160.

## Spec Change Log

## Review Triage Log
