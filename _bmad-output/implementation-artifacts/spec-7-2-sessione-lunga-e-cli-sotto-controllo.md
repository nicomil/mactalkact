---
title: 'Storia 7.2 — Sessione lunga sorvegliata e CLI sotto controllo'
type: 'feature'
created: '2026-10-27'
status: 'done'
baseline_commit: '25298a8795ea80ce2f2cc4e158d1dcd201abd200'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-7-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Ogni richiesta all'Agente Claude usa un processo nuovo (pronto in anticipo, ma usato una volta sola): il modello rilegge da capo prompt di sistema, strumenti e memoria, senza cache del prompt. La riga di base (Storia 7.1) mostra che il tempo va quasi tutto nel modello. In più l'app non sa quale versione della CLI usa, né se la CLI è partita con il login dell'abbonamento.

**Approach:** Per ogni livello del Motore Claude, un processo `claude -p --input-format stream-json` resta aperto tra una richiesta e l'altra (Sessione lunga), sorvegliato da regole di riavvio esplicite e con un solo orologio del turno in `AgentRunner`. La sessione riceve solo la parte di Memoria di conversazione che non ha ancora visto. Un `CLIStatus` per Motore CLI dice se la versione è verificata; senza verifica si torna al processo per richiesta. Un interruttore riporta al comportamento di prima.

## Boundaries & Constraints

**Always:**
- Sessione lunga solo con `CLIStatus.verified` (Claude ≥ 2.1.299) e interruttore «Sessione lunga» attivo (predefinito: attivo).
- Al massimo una sessione per livello (`.fast`, `.deep`), avviata alla prima richiesta di quel livello, mai in anticipo, `--no-session-persistence`, nessun ping di mantenimento.
- Riavvio (con motivo nel log, «Riavvio l'Agente» nell'HUD una sola volta per riavvio) quando: richieste ≥ `sessionMaxRequests` (predefinito 8), inattività ≥ 10 minuti, scadenza del `TurnClock`, cambio di modello o effort, Memoria di conversazione azzerata («dimentica la conversazione», ingresso o uscita dalla modalità privata, scadenza della memoria).
- Una richiesta interrotta da un riavvio (la sessione muore a metà) si ripete una volta su una sessione nuova solo se `effectfulCalls == 0`.
- Il log riporta per ogni turno i token letti dalla cache (`usage.cache_read_input_tokens`).
- `ClaudeCLI` rimuove dall'ambiente del figlio `CLAUDE_CODE_SIMPLE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDECODE`, `ANTHROPIC_API_KEY`.
- Un primo evento con messaggio di autenticazione (login mancante) porta il `CLIStatus` a `.unverified` e la richiesta usa il processo per richiesta; `EngineSelector` non legge mai `CLIStatus`.
- Codex: `CLIStatus` da `codex --version`, verificato come intervallo ≥ 0.131.0; resta su `exec`.
- Le richieste in modalità privata o su app riservate continuano a non usare i Motori cloud (comportamento esistente, invariato).

**Never:**
- Nessun Livello istantaneo, nessuna pausa del `TurnClock` durante le domande (Storie 7.3 e 9.2).
- Nessun cambiamento a `EngineSelector`, alla Catena di riserva o alla regola di AD-15 fuori dal caso «sessione morta a metà».
- Nessun file di sessione su disco.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Riuso | due richieste `.fast` entro 10 min | la seconda non avvia processi; log `cache letta N` con N > 0 | — |
| Memoria delta | sessione viva, 1 voce nuova nella memoria | il messaggio contiene solo la voce nuova | — |
| Dimentica | «dimentica la conversazione» poi richiesta | sessione riavviata, motivo «memoria azzerata» | — |
| Tetto richieste | 9ª richiesta con `sessionMaxRequests` = 8 | riavvio con motivo «8 richieste» | — |
| Inattività | richiesta dopo 11 min | riavvio con motivo «inattiva da 10 minuti» | — |
| Modello cambiato | impostazioni: altro modello rapido | riavvio con motivo «modello o effort cambiati» | — |
| Scadenza | il turno supera `agentTimeout` | processo chiuso, errore di timeout, la sessione successiva è nuova | — |
| Sessione morta | il processo esce a metà turno, 0 azioni | richiesta ripetuta una volta su sessione nuova | con azioni: `stoppedMidway` come oggi |
| Versione | `claude --version` = 2.1.250 | `.belowMinimum`, processo per richiesta, Stato mostra «versione 2.1.250 non verificata» | — |
| Login assente | primo evento con messaggio di login | `.unverified`, la richiesta riparte con processo per richiesta | errore di login come oggi se fallisce anche così |
| Interruttore spento | «Sessione lunga» off | processo pronto come prima | — |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/ClaudeCLI.swift` -- `Running`, `spawn`, `run`, `readResult`: aggiungere la modalità sessione (stdin resta aperto, lettura fino al `result` del messaggio, processo tenuto), `CLIStatus` e lettura della versione, ambiente pulito (aggiungere `CLAUDE_CODE_SIMPLE`). Il processo pronto attuale resta per l'interruttore spento e per `.unverified`.
- `Sources/MacTalkAct/ClaudeEngine.swift` -- sceglie sessione o processo per richiesta per livello; regole di riavvio con motivo; `onNotice` («Riavvio l'Agente») come `LocalEngine.onNotice`; ripetizione su sessione morta solo con 0 azioni (legge `AgentTools.effectfulCalls` tramite `toolAccess`).
- `Sources/MacTalkAct/CodexCLI.swift`, `CodexEngine.swift` -- `CLIStatus` dalla versione (intervallo ≥ 0.131.0), solo per Stato e diagnostica.
- `Sources/MacTalkAct/AgentEngine.swift` -- `enum CLIStatus` (`.verified(String)`, `.unverified(String?)`, `.belowMinimum(String)`), `struct TurnClock` (scadenza dal valore `agentTimeout`, `remaining`), `AgentRequest` aggiunge `deadline`, `memoryGeneration`, `sessionMessage` (messaggio con la sola memoria nuova) e `memoryCursor`.
- `Sources/MacTalkAct/AgentRunner.swift` -- crea il `TurnClock` per richiesta e lo passa nell'`AgentRequest`; compone `sessionMessage` dal cursore che il Motore riporta; inoltra `onNotice` di Claude come per il locale.
- `Sources/MacTalkAct/Conversation.swift` -- `ConversationLog`: numero progressivo per voce e `generation` che cresce a ogni `clear`/`expire` che svuota; `promptBlock(after:)`.
- `Sources/MacTalkAct/Coordinator.swift:882` -- passare anche il log (o generazione e voci) ad `agent.run`, senza cambiare il blocco completo di oggi.
- `Sources/MacTalkAct/Settings.swift`, `SettingsWindow.swift` -- `longSession` (predefinito true), `sessionMaxRequests` (8); riga di Stato e diagnostica con la versione e lo stato di `claude` e `codex`.
- `Sources/MacTalkAct/DebugCLI.swift` -- test in `--selftest` (confronto delle versioni, motivi di riavvio come funzione pura, `promptBlock(after:)`), Banco prima/dopo.
- Non toccare: `EngineSelector`, `MCPServer`, la gestione dei limiti (`pauseForLimit`).

## Tasks & Acceptance

**Execution:**
- [x] `Sources/MacTalkAct/AgentEngine.swift` -- `CLIStatus`, `TurnClock`, campi nuovi di `AgentRequest`, funzione pura `SessionPolicy.restartReason(...) -> String?` (richieste, inattività, config, generazione) -- regole testabili senza processi.
- [x] `Sources/MacTalkAct/Conversation.swift` -- numerazione, `generation`, `promptBlock(after:)`.
- [x] `Sources/MacTalkAct/ClaudeCLI.swift` -- sessione lunga, versione, ambiente, usage con cache nel log.
- [x] `Sources/MacTalkAct/ClaudeEngine.swift` -- scelta, riavvii, avviso, ripetizione su sessione morta.
- [x] `Sources/MacTalkAct/CodexCLI.swift`, `CodexEngine.swift` -- `CLIStatus`.
- [x] `Sources/MacTalkAct/AgentRunner.swift`, `Coordinator.swift` -- `TurnClock`, messaggio di sessione, avviso.
- [x] `Sources/MacTalkAct/Settings.swift`, `SettingsWindow.swift` -- interruttore, tetto, Stato e diagnostica.
- [x] `Sources/MacTalkAct/DebugCLI.swift` -- test delle funzioni pure; `--session-test` (due richieste reali consecutive con Claude: la seconda riusa il processo e legge dalla cache).
- [x] `README.md` -- Sessione lunga e interruttore (le CLI vanno rilette entro il 1° novembre 2026).
- [x] `_bmad-output/planning-artifacts/research/technical-agente-precisione-velocita-e-strumenti-2026-10-27/research.md` -- tabella prima/dopo sul Banco.

**Acceptance Criteria:**
- Given il Banco con Claude, when lo eseguo con la Sessione lunga, then la ricerca riporta prima/dopo (primo strumento, compito, fasi) e il log mostra cache letta > 0 dalla seconda richiesta dello stesso livello.
- Given `--selftest`, when gira, then le regole di riavvio, il confronto delle versioni e la memoria delta passano.

## Design Notes

Spike del 27/10 (2.1.311, Haiku): tre messaggi sullo stesso processo, stessa `session_id`, la terza risposta ricorda la prima e `cache_read_input_tokens` = 559. La CLI risponde a ogni messaggio con un evento `result` e resta in attesa: la sessione è lo stesso processo pronto di oggi, con stdin lasciato aperto.

La memoria delta evita di ripetere alla sessione ciò che ha già visto nei propri turni; le voci aggiunte da altre strade (Corsia locale, Comandi rapidi) arrivano come voci nuove. Una generazione diversa vuol dire memoria azzerata: la sessione si riavvia, così non ricorda ciò che Nico ha chiesto di dimenticare.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest` e `--fallback-test` -- expected: nessun FAIL
- `.build/debug/MacTalkAct --session-test` -- expected: seconda richiesta senza avvio, cache letta > 0
- `.build/debug/MacTalkAct --agent-bench --engine claude` -- expected: tabella prima/dopo (agisce sullo schermo)

## Implementation Notes

- Spec scritta e approvata in autonomia (Nico: «committa e procedi»); sopra i 1600 token, obiettivo unico (Sessione lunga con i suoi controlli).
- Implementazione diretta (commit `0cae5e7`): `ClaudeCLI.runInSession` con iteratore di righe per sessione (nessuna riga persa tra due messaggi), `SessionPolicy`, `CLIStatus`, `TurnClock`, `MemorySnapshot`/`promptBlock(after:)`; il cursore della sessione è `lastSeq + 1` perché la voce della richiesta viene aggiunta subito dopo. Con la Sessione lunga non si tiene alcun processo pronto.
- Banco prima/dopo nella ricerca, §14: compito 7,6 → 6,9 s, primo strumento 2,6 → 2,8 s, 42 mila token di cache per turno. Il guadagno è piccolo perché la cache del prompt lavorava già tra processi.

## Spec Change Log

## Review Triage Log

Prima review (3 revisori). Nessun rilievo di intento o di spec; patch salvo due rinvii.

| Rilievo | Verdetto | Evidenza / esito |
|---|---|---|
| Timeout del turno mai applicato: il lettore dello stdout non si ferma con la cancellazione e il gruppo lo aspetta | high | Vale anche per il processo per richiesta, che c'era già. Patch: il task del timeout chiude il processo; test con «DORMI» sul claude finto (< 3 s) |
| Login mancante: nessuna ripetizione col processo per richiesta; `markUnverified` senza effetto sul livello rapido; `status()` sincrono sul main | high | Lo stato era in cache solo su `cliDeep`. Patch: flag `loginFailed` nel Motore, stato `.unverified(v)`, la stessa richiesta riparte senza sessione se non ha fatto azioni; nessun processo lanciato sul main |
| Stato `.unverified` permanente, versione mai riletta dopo un aggiornamento | medium | Cache per percorso senza scadenza. Patch: `status(force:)` da «Ricontrolla i motori» / `refreshAvailability`, che azzera anche il flag di login |
| `claude --version` / `codex --version` senza tempo massimo; quello di Codex prima del login e senza cache | medium | Patch: `versionOutput` con limite di 5 s; Codex dopo il controllo del login |
| Closure `@MainActor` (memoria, avviso) chiamate dal task della CLI | medium | `messageSince` legge `ConversationLog` e `AgentRunner`. Patch: messaggi composti sul main actor prima della chiamata (`liveCursor`), avviso con `Task { @MainActor }` |
| Risposta senza testo trattata come processo morto | medium | `noOutput` sia per stream finito sia per risultato vuoto. Patch: `streamEnded` separato; la sessione resta col risultato vuoto |
| Ripetizione anche quando muore una sessione appena avviata | medium | Un errore di avvio si ripeterebbe uguale. Patch: ripete solo una sessione riusata (`lastAttemptReused`); regola pura testata |
| Interruttore spento lascia vivo il processo | medium | Nessun osservatore. Patch: `settings.$longSession` chiude le sessioni |
| Inattività controllata solo alla richiesta dopo | medium | Il processo restava in memoria per ore. Patch: chiusura programmata dopo 10 minuti senza uso |
| La sessione ricorda più turni della memoria di conversazione impostata | medium | Patch: tetto = min(`sessionMaxRequests`, `conversationMemoryCount`) |
| Avviso «Riavvio l'Agente» passato come cambio di Motore (🔀 fisso, detto a voce) | medium | Patch: `AgentRunner.onNotice` separato, mostrato solo mentre l'Agente lavora, mai a voce |
| Dimentica e modalità privata: motivo diverso da «memoria azzerata» | low | Patch: stesso motivo nel log |
| Codex e Motore locale con timeout proprio dopo un ripiego | medium | Patch: `request.clock.remaining` anche lì |
| SIGPIPE se il processo esce mentre gli si scrive | medium | Nessun `signal(SIGPIPE, SIG_IGN)` nell'app. Patch in `main.swift` |
| Motivo «modello o effort cambiati» anche quando cambia solo un altro argomento | low | Patch: «configurazione cambiata» |
| `TurnClock` con valore non finito o enorme | low | Patch: limiti 1 s…24 h |
| Pre-release della versione minima contata come verificata | low | Patch e test |
| Stato della sessione letto e scritto fuori dal lock | low | Patch: contatori e cursore sotto lock |
| Nessun test di ripetizione, cursore, regole al punto d'uso, timeout | gap | Patch: `Tests/fixtures/claude/finto-claude` e blocco in `--fallback-test` |
| `expire()` che fa crescere la generazione senza test | gap | Rinviato: serve un orologio iniettabile in `ConversationLog` (Storia 9.2) |
| Selftest della memoria falsato dalla modalità privata attiva | low | Patch: avviso e salto |
| Contesto della sessione senza tetto di token | low | Rinviato: il tetto di richieste lo limita già; si valuta con i numeri della ricerca (§14) |
| Cursore sbagliato se la voce della richiesta non viene aggiunta | false | La sola esclusione (modalità privata) azzera la memoria e cambia generazione |
| `.unverified(nil)` rilancia `--version` a ogni prewarm | false | Lo stato resta in cache per percorso anche quando non è leggibile |
| Documentazione: `--session-test`, `CLAUDE_CODE_SIMPLE` | low | Patch: README e commento |
