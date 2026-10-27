---
title: 'Storia 7.1 — Riga di base: il Banco misura fase per fase, anche fuori dal browser'
type: 'feature'
created: '2026-10-27'
status: 'in-progress'
baseline_commit: '2fe1b7b5e9d579e3dc13f16e72b1a6eeb36ccc9e'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-7-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Il Banco (`--agent-bench`) dà solo «primo strumento» e «totale» e lavora solo su pagine HTML in Safari: non dice dove si perdono i secondi e non copre app native, webmail, canvas né Frasi sentite male. Senza questa riga di base nessun intervento dell'Epic 7 si può misurare prima/dopo.

**Approach:** `AgentRunner` misura ogni richiesta con un solo orologio monotonico, divisa in fasi contigue (la somma coincide col totale per costruzione); i Motori segnalano gli eventi che vedono tramite `onPhase`. Il Banco riceve nuovi tipi di compito (Finder, Calendario, Mail, webmail, canvas, Frasi spurie) con preparazione, verifica e pulizia proprie, e scrive le fasi in colonne più turni, conferme chieste e azioni bloccate.

## Boundaries & Constraints

**Always:**
- Solo `AgentRunner` possiede l'orologio delle fasi (`ContinuousClock`); i Motori emettono eventi `EnginePhase`, mai durate.
- Fasi contigue: ogni istante della richiesta appartiene a una sola fase; tabella con verifica |somma − totale| ≤ 0,2 s per compito.
- Nei compiti su app vere (Mail, Calendario, Finder, webmail) il Banco risponde «no» a ogni conferma e la conta; i destinatari sono indirizzi `@example.invalid`.
- Ogni dato creato dal Banco (cartella `~/Desktop/Banco MacTalkAct`, eventi col titolo che inizia con «Banco», finestre di composizione) viene rimosso a fine compito anche se il compito fallisce.
- Compiti webmail attivi solo con la variabile `MACTALK_BENCH_WEBMAIL` (URL della webmail di prova già aperta e con login fatto in Safari); senza, risultano «saltato». Con `MACTALK_BENCH_WEBMAIL_PERSONAL=1` girano solo i compiti di osservazione e la colonna `risposta` resta vuota.
- Il formato attuale di `agente.tsv` resta valido: le righe esistenti funzionano senza modifiche.

**Never:**
- Nessun invio di posta, nessuna eliminazione fuori dalla cartella e dagli eventi del Banco.
- Nessun cambiamento al comportamento dell'app fuori dal Banco (le fasi si misurano sempre ma vanno solo nel log a livello debug).
- Nessuna ottimizzazione di velocità in questa storia (Storie 7.2–7.4).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Compito pagina | riga `posta-apri` esistente | come oggi, più colonne fasi/turni/conferme/bloccate | — |
| Compito Finder | `app:Finder`, check `+file:finale.txt;-file:bozza.txt` | preparazione crea cartella e file, verifica sul disco, pulizia la cancella | cartella non creata → «preparazione fallita», niente Agente |
| Compito Calendario | `app:Calendar`, check `+evento:Banco riunione` | verifica con EventKit, pulizia elimina gli eventi «Banco…» | accesso al calendario negato → compito «saltato» con motivo |
| Compito Mail | `app:Mail`, bozza a `prova@example.invalid` | verifica sul titolo della finestra di composizione; chiusura senza salvare | conferma d'invio → risposta «no», contata |
| Webmail | `webmail:` senza variabile | «saltato (MACTALK_BENCH_WEBMAIL non impostata)» | — |
| Frase spuria | `frase:` «ehm sì va be'» | passa dal Router; ok se nessuna Azione con effetti | Router → `.agent` → l'Agente gira; ok solo con `effectfulCalls == 0` |
| Errore del Motore | timeout a metà | fasi chiuse fino all'errore, fase «chiusura» fino al ritorno | somma resta = totale |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/AgentEngine.swift:101-120` -- protocollo `AgentEngine`: aggiungere `var onPhase: ((EnginePhase) -> Void)? { get set }`; qui anche `enum EnginePhase` (`.sessionStarted`, `.sessionReused`, `.serverConnected`, `.firstToken`, `.modelTurn`, `.turnFinished`).
- `Sources/MacTalkAct/AgentRunner.swift:263-330` -- `run`: aprire il `PhaseTimer` prima di `tools.initialObservation()`, collegare `engine.onPhase`, chiudere in ogni ramo (successo, errore, ripetizione su altro Motore). Esporre `lastPhases` per il Banco. Il log `Agente (…)` aggiunge le fasi solo con `Log.debug`.
- `Sources/MacTalkAct/ClaudeCLI.swift:116-140,226-249` -- `run`: spare preso → `.sessionReused`, spawn → `.sessionStarted`; `readResult`: evento `system/init` con server `connected` → `.serverConnected`; primo evento `assistant` → `.firstToken`; ogni evento `assistant` → `.modelTurn`. Passare la callback come parametro di `run` (la classe è usata fuori dal main actor).
- `Sources/MacTalkAct/ClaudeEngine.swift`, `CodexEngine.swift`, `LocalEngine.swift` -- proprietà `onPhase`; Claude inoltra gli eventi di `ClaudeCLI`; Codex segnala almeno `.firstToken`/`.turnFinished` dagli eventi JSON che già legge; locale solo `.turnFinished`.
- `Sources/MacTalkAct/AgentTools.swift:35-60,234-300` -- `call` già conta `callCount`/`effectfulCalls`: aggiungere `onCall: ((String, Duration) -> Void)?` (inizio/fine di ogni strumento, `settle` compreso) e contatori `confirmationsAsked`, `blockedCalls` (conferma negata o assente sulle righe `Safety.isRisky…` ~408, 993, 1148, 1161, 1193 e in `confirm` ~533). Azzerati da `reset`.
- `Sources/MacTalkAct/DebugCLI.swift:788-1058` -- `BenchTask`, `loadBench`, `agentBench`: tipi di compito, preparazione/verifica/pulizia, colonne nuove, mediane per fase. Riusare `closeBenchPages`, l'apertura in Safari e le funzioni `median`/`p90`.
- `Sources/MacTalkAct/IntentRouter.swift:134` -- `decide(_:editable:state:)` per le Frasi spurie (costruire il Router come fa il Coordinator, con `RouterState()` vuoto).
- `Tests/bench/agente.tsv`, `Tests/bench/pages/` -- nuovi compiti e `lavagna.html` (canvas).
- Non toccare: `EngineSelector`, la logica di ripetizione di AD-15, `Safety` (solo lettura degli esiti).

## Tasks & Acceptance

**Execution:**
- [ ] `Sources/MacTalkAct/AgentEngine.swift` -- `EnginePhase`, `BenchPhase` (`scan`, `session`, `mcp`, `firstToken`, `actions`, `reasoning`, `classifier`, `finalTurn`, `close`) e `PhaseTimer` (struct con `mark(_ phase:)` che chiude la fase corrente sull'orologio continuo, `finish() -> [BenchPhase: Duration]`); `onPhase` nel protocollo -- fasi contigue per costruzione.
- [ ] `Sources/MacTalkAct/AgentRunner.swift` -- usa `PhaseTimer`: `scan` fino a fine `initialObservation`, poi `session`; eventi del Motore: `.sessionStarted/.sessionReused` → `mcp`, `.serverConnected` → `reasoning` in attesa del primo token (marcata `firstToken`), strumento in corso → `actions`, tra strumenti → `reasoning`, ultimo strumento finito e turno in corso → `finalTurn`, ritorno del Motore → `close`. `classifier` resta a zero finché il classificatore di sicurezza non esiste (Storia 9.5). Salva `lastPhases`, `lastTurns`.
- [ ] `Sources/MacTalkAct/ClaudeCLI.swift`, `ClaudeEngine.swift`, `CodexEngine.swift`, `LocalEngine.swift` -- emissione degli eventi come nel Code Map.
- [ ] `Sources/MacTalkAct/AgentTools.swift` -- `onCall`, `confirmationsAsked`, `blockedCalls`.
- [ ] `Sources/MacTalkAct/DebugCLI.swift` -- colonna `pagina` estesa: nome file (come oggi), `app:Finder|Calendar|Mail`, `webmail:<percorso>`, `frase:`; check estesi `+file:`/`-file:` (relativi alla cartella del Banco), `+evento:` (EventKit, oggi ±7 giorni), `+url:` (URL del documento di Safari via AX), `+titolo` come oggi sulla finestra in primo piano. Preparazione Finder (cartella con `bozza.txt`, `nota.txt`), pulizia sempre in `defer`. Conferme: «sì» sulle pagine HTML, «no» sulle app vere. Tabella a schermo e TSV con colonne per fase, `turni`, `conferme`, `bloccate`, `somma_ok`; riga finale con le mediane per fase.
- [ ] `Tests/bench/pages/lavagna.html` -- canvas con tre forme disegnate; un clic dentro una forma mette il suo nome nel titolo (`Banco lavagna · cliccato=cerchio rosso`).
- [ ] `Tests/bench/agente.tsv` -- 3 Finder (apri la cartella, rinomina `bozza.txt` in `finale.txt`, crea cartella `Archivio`), 1 Calendario (evento «Banco riunione» domani alle 15), 1 Mail (bozza a `prova@example.invalid` oggetto «Banco prova», non inviare), 2 webmail (cerca, apri cartella inviata), 1 canvas, 5 Frasi spurie.
- [ ] `Sources/MacTalkAct/DebugCLI.swift` (`--selftest`) -- test di `PhaseTimer` (somma = totale, fase errore) e di `loadBench` sui nuovi tipi.
- [ ] `_bmad-output/planning-artifacts/research/technical-agente-precisione-velocita-e-strumenti-2026-10-27/research.md` -- sezione «Riga di base» con mediane di primo strumento, compito e fasi dalla corsa con Claude.

**Acceptance Criteria:**
- Given `--agent-bench` con Claude, when finisce, then la tabella ha una colonna per fase e `somma_ok` vero su ogni compito, più turni, conferme e bloccate.
- Given `agente.tsv`, when lo leggo, then ha ≥ 5 compiti su Mail/Calendario/Finder, ≥ 2 webmail, 1 canvas, ≥ 5 Frasi spurie, e le righe di prima invariate.
- Given la corsa con Claude, when finisce, then la ricerca riporta la riga di base e il TSV è in `~/Library/Logs/`.

## Design Notes

La fase `reasoning` (il modello che pensa tra uno strumento e l'altro) non è nell'elenco della storia ma serve perché la somma coincida col totale: senza, quel tempo non avrebbe colonna. `classifier` esiste già come colonna (zero) per non cambiare il formato quando arriva la Storia 9.5.

Il Banco risponde «no» alle conferme sulle app vere perché oggi risponde «sì» a tutto: su Mail un «sì» invierebbe davvero.

La webmail di prova dipende da un account che solo Nico può aprire: la variabile d'ambiente evita di scrivere credenziali o indirizzi nel repository.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest` -- expected: nessun FAIL
- `.build/debug/MacTalkAct --agent-bench --engine claude` -- expected: tabella con fasi, `somma_ok` sempre vero (agisce sullo schermo: Mac libero; consuma quota dell'abbonamento)

## Implementation Notes

- Approvazione: Nico ha chiesto di procedere da solo («committa e procedi»); spec approvata senza checkpoint interattivo, scope tenuto intero (un solo obiettivo: la riga di base) pur sopra i 1600 token.
- Lavoro sul branch `epic-7-velocita`, creato da `privacy-log`.

## Spec Change Log

## Review Triage Log
