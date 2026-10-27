---
title: 'Storia 7.2 — Sessione lunga sorvegliata e CLI sotto controllo'
type: 'feature'
created: '2026-10-27'
status: 'in-progress'
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
- [ ] `Sources/MacTalkAct/AgentEngine.swift` -- `CLIStatus`, `TurnClock`, campi nuovi di `AgentRequest`, funzione pura `SessionPolicy.restartReason(...) -> String?` (richieste, inattività, config, generazione) -- regole testabili senza processi.
- [ ] `Sources/MacTalkAct/Conversation.swift` -- numerazione, `generation`, `promptBlock(after:)`.
- [ ] `Sources/MacTalkAct/ClaudeCLI.swift` -- sessione lunga, versione, ambiente, usage con cache nel log.
- [ ] `Sources/MacTalkAct/ClaudeEngine.swift` -- scelta, riavvii, avviso, ripetizione su sessione morta.
- [ ] `Sources/MacTalkAct/CodexCLI.swift`, `CodexEngine.swift` -- `CLIStatus`.
- [ ] `Sources/MacTalkAct/AgentRunner.swift`, `Coordinator.swift` -- `TurnClock`, messaggio di sessione, avviso.
- [ ] `Sources/MacTalkAct/Settings.swift`, `SettingsWindow.swift` -- interruttore, tetto, Stato e diagnostica.
- [ ] `Sources/MacTalkAct/DebugCLI.swift` -- test delle funzioni pure; `--session-test` (due richieste reali consecutive con Claude: la seconda riusa il processo e legge dalla cache).
- [ ] `README.md` -- Sessione lunga e interruttore (le CLI vanno rilette entro il 1° novembre 2026).
- [ ] `_bmad-output/planning-artifacts/research/technical-agente-precisione-velocita-e-strumenti-2026-10-27/research.md` -- tabella prima/dopo sul Banco.

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

## Spec Change Log

## Review Triage Log
