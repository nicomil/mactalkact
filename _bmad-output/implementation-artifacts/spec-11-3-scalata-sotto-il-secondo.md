---
title: 'Storia 11.3 — Scalata sotto il secondo'
type: 'feature'
created: '2026-10-28'
status: 'in-review'
baseline_commit: '4debdaa4b39409bc8798043748fa58bd788ffcb9'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Quando il Livello istantaneo non ce la fa, il passaggio al rapido costa 5,0 s di mediana (§28; 6,1 s su Gmail): il rapido avvia la sua sessione solo dopo, l'osservazione si rifà anche quando non è cambiato nulla e la regola della resa legge solo la prima frase della risposta.

**Approach:** Mentre il tentativo istantaneo lavora, la Sessione lunga rapida, se manca, si prepara in parallelo fino a `init` con la preparazione della Storia 11.2, senza ricevere messaggi; agisce sempre un solo processo (AD-6, FR-58). Al primo segnale di scalata l'istantaneo è interrotto subito; se dopo l'ultima osservazione non ci sono state Azioni con effetti, il passaggio di consegne riusa quell'osservazione. La regola della resa legge tutta la risposta, escluse le domande di cortesia.

## Boundaries & Constraints

**Always:** nessuna azione ripetuta dopo la scalata (`effectfulCalls`, grant e `deniedThisRequest` invariati come oggi); dopo un «no» dell'utente nessuna scalata (FR-51); il rapido riceve richiesta, azioni fatte con esito ed elementi attuali come oggi; la preparazione parallela rispetta i controlli della 11.2 (Claude, Sessione lunga attiva, non privato, non riservato) e il suo interruttore.

**Never:** il rapido non riceve la richiesta prima del passaggio di consegne; nessun cambiamento a Codex o al Motore locale; nessun cambiamento ai criteri che decidono se un compito va all'istantaneo.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Seconda chiamata | Haiku chiama un secondo strumento | turno istantaneo interrotto subito, rapido parte con la sessione già pronta | interruzione senza risposta: processo chiuso dopo 3 s come oggi |
| Osservazione ancora valida | scalata dopo `observe` senza azioni con effetti dopo | il passaggio di consegne riusa l'ultima osservazione (nessuna nuova scansione) | — |
| Osservazione scaduta | scalata dopo un'azione con effetti | nuova osservazione come oggi | — |
| Resa a metà risposta | «Ho cliccato Prodotti. Non trovo però la voce Accessori.» | scalata «risposta senza risultato» | — |
| Domanda di cortesia | «Fatto. Non c'è altro? Vuoi che lo apra?» | nessuna scalata | — |
| Sessione rapida già viva | sessione rapida esistente | nessuna preparazione | — |
| Preparazione disattivata | interruttore della 11.2 spento | comportamento di oggi | — |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/AgentRunner.swift` -- ciclo di `run` (~380–470): `instantPending`, `escalate(_:)` interno (misura `lastEscalationCost`, ricostruisce `req.message` con `tools.initialObservation()`), gestione di `tools.escalation`; qui parte la preparazione della sessione rapida quando il tentativo è `.instant`.
- `Sources/MacTalkAct/AgentTools.swift` -- `call` (~260): `instantGuard` rifiuta la seconda chiamata e chiama `escalate`; `instantFailure` (~315); `instantGaveUp(answer:effectfulCalls:)` (~831): oggi legge solo la prima frase; `escalate` privato (~842) con `onEscalate`; `initialObservation()` (~988) e `lastView`/`generation`: base per sapere se l'ultima osservazione è ancora valida (nessuna azione con effetti dopo).
- `Sources/MacTalkAct/ClaudeEngine.swift` -- `interrupt()` (~278); preparazione della 11.2 per il livello rapido.
- `Sources/MacTalkAct/ClaudeCLI.swift` -- `interruptCurrent()` (~174): `control_request` di interruzione, chiusura dopo 3 s; preparazione della 11.2.
- `Sources/MacTalkAct/DebugCLI.swift` -- selftest della scalata (~1202–1260, motori finti) e di `instantGaveUp` (~126–130); `agentBench`: costo della scalata già misurato (`escalationCost`), aggiungere il tempo del passaggio di consegne.

## Tasks & Acceptance

**Execution:**
- [x] `Sources/MacTalkAct/AgentRunner.swift` -- preparazione parallela della sessione rapida all'inizio del tentativo istantaneo; riuso dell'osservazione nel passaggio di consegne.
- [x] `Sources/MacTalkAct/AgentTools.swift` -- regola della resa su tutta la risposta con eccezione per le domande di cortesia; esposizione di «osservazione ancora valida».
- [x] `Sources/MacTalkAct/DebugCLI.swift` -- test di ogni riga della matrice (motori finti e funzioni pure); nel Banco tempo del passaggio di consegne per compito.
- [x] ricerca -- §30 con il costo della scalata prima e dopo sui compiti istantanei del Banco.

**Acceptance Criteria:**
- Given il Banco sui compiti istantanei, when misuro, then il costo della scalata ha mediana ≤ 1 s [ASSUMPTION] o il §30 dichiara il valore e quale fase lo tiene sopra; nessun compito istantaneo in più fallisce rispetto al §28; nessuna azione ripetuta dopo la scalata.
- Given `--selftest` e `--fallback-test`, when finiscono, then sono verdi.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest` e `--fallback-test` -- expected: Tutto ok.
- `.build/debug/MacTalkAct --agent-bench Tests/bench/agente.tsv --engine claude --only <compiti istantanei del §28, compresi elenco-articolo, sito-contatti, menu-accessori>` -- expected: costo della scalata riportato per compito e in mediana

## Implementation Notes

- Spec approvata in autonomia (Nico, 28/10: «builda tutto fin quando non finiscono»).
- Dipende dalla Storia 11.2 (commit 4debdaa): la preparazione è `ClaudeCLI.prepareSession`, `ClaudeEngine.prepareSessions`, `AgentRunner.prepareSession(generation:force:)`; la CLI non emette `init` senza messaggio, quindi preparare = avviare il processo (si collega da solo agli strumenti).
- Nico sta usando il Mac: nessun comando che muove mouse o tastiera (Banco, `--hands-test`, `--security-suite`, `--agent-test`) finché non dice «via»; quelle verifiche si annotano come da fare.

- La ricerca usa il §33 (il §30 è della Storia 10.1).

- 28/10: dopo la review «non ho ancora» / «non l'ho ancora» sono segni forti, così il caso `menu-accessori` del §17 (resa nella seconda frase) scala; test in `--selftest`.
- Verdi senza schermo: build, `--selftest`, `--fallback-test`, `--security-coverage`, `--session-test`, `--route-test` 164/164. Da fare dopo il «via»: Banco sui compiti istantanei e tabella del §33.

## Spec Change Log

## Review Triage Log

| # | Fonte | Rilievo | Verdetto | Evidenza / esito |
|---|---|---|---|---|
| 1 | blind, edge, verifica | la regola della resa su tutta la risposta scala risposte riuscite («Non c'è più niente dentro») | medium | scalate inutili su compiti riusciti → patch (segnali forti fuori dalla prima frase, confini di parola) |
| 2 | blind, edge | resa dopo la virgola in una domanda; «?» dentro «…»; punti in orari e URL | low | → patch |
| 3 | blind | la scansione dell'esito cancella l'osservazione invece di riusarla | medium | il riuso non scatta quasi mai → patch |
| 4 | edge | osservazione riusata dopo un cambio d'app rifiutato o troppo vecchia | medium | elementi di un'app non più davanti → patch (invalidazione, età massima 4 s, stessa app e finestra) |
| 5 | blind | nuova osservazione presa solo a turno istantaneo chiuso | low | fino a 3 s persi → patch (al segnale) |
| 6 | edge, blind | passaggio di consegne chiuso da eventi diversi o da un altro Motore | low | → patch (solo Claude, evento registrato) |
| 7 | edge, blind | passaggio mancante contato 0 s; parte «che tiene sopra» scelta sulle mediane | medium | verdetto falso possibile → patch |
| 8 | blind | etichetta «rapido» quando si prepara il profondo | low | → patch |
| 9 | blind | testo dell'interruttore non aggiornato | low | → patch |
| 10 | verifica, blind | mancano test: `wait` poi scalata, «solo clic» nel riuso, definizione del costo, Sessione lunga spenta, Codex | medium | → patch |
| 11 | blind | costo della preparazione sui turni istantanei che non scalano non misurato | low | → patch (contatore nel Banco) |
| 12 | blind, edge | criterio del Banco aperto, «§30» nella spec ma §33 nella ricerca | — | Banco sospeso fino al «via»; numero di paragrafo annotato |
