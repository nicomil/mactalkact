---
title: 'Storia 11.2 — Sessione pronta quando inizio a parlare'
type: 'feature'
created: '2026-10-28'
status: 'done'
baseline_commit: 'eb7b2c7ba8745d5a2ba073ef0c0730e5ec3dc530'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** La prima richiesta dopo una pausa paga l'avvio della Sessione lunga e la connessione agli strumenti (sulla webmail 3,5 s di avvio del server nella prova del 28/10), perché la sessione parte solo alla prima richiesta.

**Approach:** Quando la Parola di attivazione compare nel testo parziale, o con il tasto per parlare premuto, `ClaudeCLI` avvia le Sessioni lunghe mancanti del livello rapido e, con il Livello istantaneo attivo, di quello istantaneo, e si ferma all'evento `init` con i server MCP connessi, senza inviare alcun messaggio prima della fine della Frase (AD-6 emendata, FR-59). Interruttore «Sessione pronta all'ascolto» con ripiego al comportamento di oggi (NFR-15). Si chiudono due debiti: test di `ConversationLog.expire()` e test di `.askIntent` nel Coordinator.

## Boundaries & Constraints

**Always:** solo con Motore scelto Claude, Agente disponibile, `CLIStatus` verificato e Sessione lunga attiva, modalità non privata e app in primo piano non riservata (`PrivacyGuard.cloudBlockReason()` nullo); al massimo un avvio ogni 5 s; nessun messaggio e quindi nessun token prima della fine della Frase; le sessioni avviate e mai usate seguono le regole di oggi (chiusura dopo 10 minuti di inattività, riavvio per memoria cambiata, configurazione cambiata); una richiesta che arriva mentre la sessione si sta preparando la aspetta e la usa, mai due processi per lo stesso livello.

**Never:** nessun avvio in ascolto continuo senza Parola di attivazione (Chiacchiera, finestra di conversazione aperta senza «Computer»); nessun ping di mantenimento; nessun cambiamento a Codex o al Motore locale.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Parola nel parziale | «Computer apri…» mentre parlo, Claude, sessione assente | avvio di rapido (e istantaneo) fino a `init`; la richiesta trova la sessione pronta (`sessionReused` o «pronta») | `init` non arriva entro 10 s: il processo resta e la richiesta lo usa come oggi |
| Tasto per parlare | `pttDown` | come sopra | — |
| Ascolto continuo senza Parola | testo parziale senza «Computer» | nessun avvio | — |
| Throttle | due Parole in 3 s | un solo avvio | — |
| Privato o app riservata | modalità privata o app riservata | nessun avvio | — |
| Interruttore spento | «Sessione pronta all'ascolto» spento | comportamento di oggi | — |
| Richiesta durante la preparazione | Frase finita prima di `init` | la richiesta attende la preparazione e usa quel processo | preparazione fallita: avvio normale |
| Memoria cambiata | «dimentica» dopo la preparazione | alla richiesta la sessione si riavvia col motivo di oggi | — |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/ClaudeCLI.swift` -- `Session`, `runInSession` (~259), `scheduleIdleEnd`, `spawn`, `phase(of:)` (riconosce `init` con `mcp_servers` connessi), `readResult`: aggiungere la preparazione (avvio + lettura fino a `init`) senza scrivere su stdin; `runInSession` deve accettare una sessione preparata (ancora senza richieste) come sessione viva, e attendere una preparazione in corso. Verificare prima con la CLI vera se `claude -p --input-format stream-json` emette `init` prima del primo messaggio: se non lo fa, la preparazione si limita ad avviare il processo e lo dichiara nelle note.
- `Sources/MacTalkAct/ClaudeEngine.swift` -- `config(_:)`, `cli(_:)`, `usesSession`, `effective(_:)`: nuovo metodo che prepara i livelli rapido e (se attivo) istantaneo.
- `Sources/MacTalkAct/AgentRunner.swift` -- punto d'ingresso unico per la preparazione: controlla Motore scelto (`EngineSelector`), disponibilità, `PrivacyGuard.cloudBlockReason()`, interruttore, throttle di 5 s.
- `Sources/MacTalkAct/Coordinator.swift` -- `handleLive` (~427): chiamare la preparazione quando `wake != nil`; `pttDown` (~381): chiamarla; `wakeModels()` (~152) è il modello per il throttle.
- `Sources/MacTalkAct/Settings.swift`, `SettingsWindow.swift` -- interruttore `prepareSessionOnWake` (predefinito acceso) nella sezione dell'Agente, accanto a «Sessione lunga».
- `Sources/MacTalkAct/Conversation.swift` -- `ConversationLog.expire()` (~69), `generation`: rendere l'orologio iniettabile per il test.
- `Sources/MacTalkAct/DebugCLI.swift` -- `--fallback-test` usa `Tests/fixtures/claude/finto-claude` (claude finto): test di preparazione, attesa e riuso; selftest per `expire()`; test di `.askIntent` estraendo in una funzione pura ciò che il Coordinator fa (HUD sì, finestra no, sessione non riavviata); `agentBench`: opzione `--cold` (chiude le sessioni prima di ogni compito, come dopo una pausa) e `--prepare` (prepara la sessione 1,5 s prima della richiesta, come la Parola detta a inizio Frase).

## Tasks & Acceptance

**Execution:**
- [x] `Sources/MacTalkAct/ClaudeCLI.swift` -- preparazione fino a `init`, attesa di una preparazione in corso, nessuna scrittura prima della richiesta.
- [x] `Sources/MacTalkAct/ClaudeEngine.swift`, `AgentRunner.swift` -- preparazione con tutti i controlli della sezione Always.
- [x] `Sources/MacTalkAct/Coordinator.swift` -- aggancio a Parola nel parziale e tasto per parlare.
- [x] `Sources/MacTalkAct/Settings.swift`, `SettingsWindow.swift` -- interruttore.
- [x] `Sources/MacTalkAct/Conversation.swift` -- orologio iniettabile.
- [x] `Sources/MacTalkAct/DebugCLI.swift` -- test di ogni riga della matrice (claude finto e funzioni pure), `expire()`, `.askIntent`; `--cold` e `--prepare` nel Banco.
- [x] ricerca -- §29 con il confronto `--cold` contro `--cold --prepare` sulle fasi «sessione» e «mcp». (§29 scritta con la verifica della CLI e la misura `init` a freddo/pronta; tabella del Banco da riempire dopo il «via» di Nico)
- [x] `README.md` -- interruttore e comportamento.

**Acceptance Criteria:**
- Given il Banco con `--cold --prepare` contro `--cold`, when confronto le fasi, then «sessione» + «mcp» hanno mediana sotto 0,2 s con `--prepare`.
- Given `--session-test` e `--fallback-test`, when finiscono, then sono verdi e la seconda richiesta riusa la sessione preparata.
- Given il log, when una sessione preparata viene chiusa senza uso, then il motivo è quello di oggi («inattiva da 10 minuti»).

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest` -- expected: Tutto ok.
- `.build/debug/MacTalkAct --fallback-test` -- expected: Tutto ok.
- `.build/debug/MacTalkAct --session-test` -- expected: Tutto ok.
- `.build/debug/MacTalkAct --agent-bench Tests/bench/agente.tsv --engine claude --only <una decina di compiti brevi di pagina> --cold` e lo stesso con `--prepare` -- expected: fasi «sessione»+«mcp» sotto 0,2 s di mediana con `--prepare`

## Implementation Notes

- Spec approvata in autonomia (Nico, 28/10: «builda tutto fin quando non finiscono»).
- Nico sta usando il Mac: nessun comando che muove mouse o tastiera (Banco, `--hands-test`, `--security-suite`, `--agent-test`) finché non dice «via»; quelle verifiche si annotano come da fare.
- Verifica della CLI (claude 2.1.312): senza messaggi su stdin non scrive niente, `init` compreso, ma si collega ai server MCP appena parte (~1,2 s). La preparazione quindi si limita ad avviare il processo, senza scrivere su stdin; `init` arriva ~0,03 s dopo il messaggio della richiesta (0,44–0,51 s a freddo). Dettagli nella ricerca, §29.

- 28/10: verdi senza schermo build, `--selftest`, `--security-coverage`, `--session-test`; `--fallback-test` verde in 7 corse su 8 con il Mac carico (load 8–13): una FAIL non riprodotta, probabilmente un tempo stretto. `--route-test` 164/164 (una corsa 163/164 sotto carico). Da fare dopo il «via»: Banco `--cold` contro `--cold --prepare`.

- 28/10 sera, Mac libero: Banco `--cold` contro `--cold --prepare` sui 10 compiti brevi: sessione + mcp 0,45 → 0,07 s (obiettivo < 0,2 s rispettato), compito 4,8 → 3,5 s. Ricerca §29.

## Spec Change Log

## Review Triage Log

| # | Fonte | Rilievo | Verdetto | Evidenza / esito |
|---|---|---|---|---|
| 1 | blind, edge | attesa della preparazione senza limite e senza annullamento: «stop» non ferma l'invio | medium | → patch |
| 2 | edge | prima richiesta su sessione preparata conta come «riusata»: ritentativo inutile | medium | → patch |
| 3 | edge | sessione preparata uccisa se la memoria cambia generazione | medium | annulla il guadagno → patch |
| 4 | blind, edge | throttle avanzato anche quando la privacy blocca; motivi del blocco non registrati | low | → patch |
| 5 | edge | la voce dell'app con la Parola può avviare la preparazione | low | → patch |
| 6 | edge | cambio di Motore o interruttore spento: processi preparati restano fino a 10 minuti | low | → patch |
| 7 | verifica, blind | `handling(of:mode:)` con rami irraggiungibili; ramo vivo non provato con `.off`/`.wakeWord` | medium | → patch |
| 8 | blind | letture fuori dal lock (`prepared`, `maxIdle`) | low | → patch |
| 9 | verifica | throttle e «Sessione lunga spenta» senza test veri; `shutdown` mancante; test a pause fisse | medium | → patch |
| 10 | blind, edge | Banco `--prepare`: livelli preparati non controllati, fasi mancanti = 0 s, compiti profondi nella mediana | low | → patch |
| 11 | blind | README senza condizioni e costi | low | → patch |
| 12 | verifica | punti di chiamata nel Coordinator senza test | medium (non verificato) | serve un banco di prova del Coordinator → defer |
| 13 | blind | Parola riconosciuta in qualunque punto del parziale | low | stesso criterio del riconoscimento della Parola nell'app → rifiutato |
| 14 | blind | sessioni da riavviare alla richiesta non sostituite; livello profondo mai preparato | low | profondo escluso dalla spec; previsione dei riavvii → defer |
| 15 | blind | i test scrivono le impostazioni vere | medium (non verificato) | schema già usato dai test esistenti → defer |
| 16 | edge | la preparazione non aspetta `init` | false | la CLI non emette `init` senza messaggio; caso previsto dalla spec e annotato |
