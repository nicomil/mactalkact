---
title: 'Storia 8.1 — Le Frasi spurie non arrivano all''Agente'
type: 'feature'
created: '2026-10-27'
status: 'done'
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

- **Confermato da Nico il 28/10/2026:** a mani libere i comandi brevi senza bersaglio chiaro fanno una domanda invece di agire.

## Spec Change Log

## Review Triage Log

Prima review (3 revisori). Nessun rilievo di intento o di spec; patch salvo due rinvii e un compromesso dichiarato.

| Rilievo | Verdetto | Evidenza / esito |
|---|---|---|
| La Corsia locale viene prima del filtro: una frase sentita male può fare un clic senza chiedere | high | Il controllo stava dopo il `return .local`. Patch: filtro prima della Corsia locale |
| `--route-test` passa anche se una Frase spuria arriva all'Agente, o se una richiesta valida viene solo chiesta | high | Contava solo le scritture indebite. Patch: entrambi i casi sono errori critici |
| Campo di testo in sessione a mani libere: il ramo `.command` salta il filtro | medium | Patch: filtro anche lì (il campo conta come bersaglio, resta la regola della lingua) |
| Seguiti nella finestra senza alcun filtro | medium | Un seguito può essere breve per natura. Patch: solo la regola della lingua |
| Lingua giudicata su frasi brevi, su testo senza accenti, anche con un bersaglio noto | medium | Patch: solo da 3 parole in su, senza bersaglio noto, sul testo originale |
| Avviso che suona a ogni frase e tiene viva la sessione a mani libere; frase nel log | medium | Patch: un solo suono finché la domanda è su, nessun riavvio del timer della sessione, `logsText` falso come per `.ignore` |
| Parola di attivazione scritta a mano, durata letterale | low | Patch: prima frase configurata, costante `askIntentSeconds` |
| Schermo letto due volte per frase; `editable()` rivalutato | low | Patch: etichette lette una volta per frase, `editable()` una volta |
| Banco: lettura delle etichette dentro il tempo misurato | low | Patch: prima dell'orologio |
| Frase vuota dopo la normalizzazione | low | Patch: considerata spuria |
| Timeout del classificatore senza test | gap | Patch: classificatore finto in `--fallback-test` (sessione, finestra, campo con parola di attivazione) |
| Bersaglio noto non provato in sessione | gap | Patch: stato «sessione-schermo» nel Corpus |
| `import AppKit` inutile | low | Patch: tolto |
| Comandi brevi validi senza bersaglio («fai uno screenshot») a mani libere chiedono | maybe-false | Non è un difetto: è la regola di AD-23 per le frasi senza parola di attivazione. Registrato come compromesso nel Corpus e nella ricerca |
| Domanda sì/no a cui un «sì» non risponde | false | Il testo è quello della storia; il dettaglio dice di usare la parola di attivazione |
| Errore del modello segnalato come «timeout» | low | Respinto: l'esito (chiedere) è quello prudente |
| Collegamento del Coordinator non provato | gap | Rinviato: nessuna impalcatura per il Coordinator |
| Parole con apostrofo che gonfiano il conteggio | low | Rinviato: raro, la regola della lingua copre il resto |
