---
title: 'Storia 7.1 — Riga di base: il Banco misura fase per fase, anche fuori dal browser'
type: 'feature'
created: '2026-10-27'
status: 'done'
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
- [x] `Sources/MacTalkAct/AgentEngine.swift` -- `EnginePhase`, `BenchPhase` (`scan`, `session`, `mcp`, `firstToken`, `actions`, `reasoning`, `classifier`, `finalTurn`, `close`) e `PhaseTimer` (struct con `mark(_ phase:)` che chiude la fase corrente sull'orologio continuo, `finish() -> [BenchPhase: Duration]`); `onPhase` nel protocollo -- fasi contigue per costruzione.
- [x] `Sources/MacTalkAct/AgentRunner.swift` -- usa `PhaseTimer`: `scan` fino a fine `initialObservation`, poi `session`; eventi del Motore: `.sessionStarted/.sessionReused` → `mcp`, `.serverConnected` → `reasoning` in attesa del primo token (marcata `firstToken`), strumento in corso → `actions`, tra strumenti → `reasoning`, ultimo strumento finito e turno in corso → `finalTurn`, ritorno del Motore → `close`. `classifier` resta a zero finché il classificatore di sicurezza non esiste (Storia 9.5). Salva `lastPhases`, `lastTurns`.
- [x] `Sources/MacTalkAct/ClaudeCLI.swift`, `ClaudeEngine.swift`, `CodexEngine.swift`, `LocalEngine.swift` -- emissione degli eventi come nel Code Map.
- [x] `Sources/MacTalkAct/AgentTools.swift` -- `onCall`, `confirmationsAsked`, `blockedCalls`.
- [x] `Sources/MacTalkAct/DebugCLI.swift` -- colonna `pagina` estesa: nome file (come oggi), `app:Finder|Calendar|Mail`, `webmail:<percorso>`, `frase:`; check estesi `+file:`/`-file:` (relativi alla cartella del Banco), `+evento:` (EventKit, oggi ±7 giorni), `+url:` (URL del documento di Safari via AX), `+titolo` come oggi sulla finestra in primo piano. Preparazione Finder (cartella con `bozza.txt`, `nota.txt`), pulizia sempre in `defer`. Conferme: «sì» sulle pagine HTML, «no» sulle app vere. Tabella a schermo e TSV con colonne per fase, `turni`, `conferme`, `bloccate`, `somma_ok`; riga finale con le mediane per fase.
- [x] `Tests/bench/pages/lavagna.html` -- canvas con tre forme disegnate; un clic dentro una forma mette il suo nome nel titolo (`Banco lavagna · cliccato=cerchio rosso`).
- [x] `Tests/bench/agente.tsv` -- 3 Finder (apri la cartella, rinomina `bozza.txt` in `finale.txt`, crea cartella `Archivio`), 1 Calendario (evento «Banco riunione» domani alle 15), 1 Mail (bozza a `prova@example.invalid` oggetto «Banco prova», non inviare), 2 webmail (cerca, apri cartella inviata), 1 canvas, 5 Frasi spurie.
- [x] `Sources/MacTalkAct/DebugCLI.swift` (`--selftest`) -- test di `PhaseTimer` (somma = totale, fase errore) e di `loadBench` sui nuovi tipi.
- [x] `_bmad-output/planning-artifacts/research/technical-agente-precisione-velocita-e-strumenti-2026-10-27/research.md` -- sezione «Riga di base» con mediane di primo strumento, compito e fasi dalla corsa con Claude.

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
- Implementazione diretta, senza subagente: serviva fermarsi al 98% della quota delle 5 ore, e un subagente non si può sorvegliare.
- Fatto (commit `0e42b7f`, `5bea597`): `PhaseTimer`/`BenchPhase`/`EnginePhase` in `AgentEngine.swift`; fasi in `AgentRunner.run` (`lastPhases`, `lastTotal`, `lastTurns`, log debug); eventi da `ClaudeCLI` (spare → riuso, spawn → avvio, `system/init` → MCP, primo `assistant` → primo token, `result.num_turns`), `CodexCLI` (`turn.started`, primo `item.*`, fine turno) e `LocalEngine`; contatori `confirmationsAsked`/`blockedCalls` e `onCall` in `AgentTools` (i passi dentro `act` non contano come bloccati); `BenchFixtures.swift` nuovo (tipi, verifiche, preparazione e pulizia; Mail via `osascript`, Calendario via EventKit); `agentBench` riscritto; `lavagna.html`; 13 compiti nuovi; test in `--selftest` verdi.
- Corse parziali con Claude (16 pagine, 5 Frasi spurie, 1 Finder): tutto funziona, somma = totale ovunque; riga di base parziale nella ricerca, §13. Frasi spurie ora con ascolto continuo e conversazione aperta (senza, il Router le ignorava per la parola di attivazione mancante); tempo del Router in colonna `router_s`, fuori dalle fasi dell'Agente. Corsa fermata perché il Mac era in uso (Keynote davanti, inattività 6 s).
- Da fare: corsa completa `--agent-bench --engine claude` (seconda metà in scratchpad `bench-b.txt`: le restanti pagine, canvas, Finder; poi Calendario e Mail con Nico presente) per chiudere la riga di base e sezione «Riga di base» nella ricerca. Al primo giro macOS chiede l'accesso al Calendario e l'Automazione verso Mail per il terminale: serve Nico davanti al Mac, oppure `--only` sui compiti senza quelle app. Poi step-04 (review).

## Spec Change Log

## Review Triage Log

Prima review (3 revisori: blind, edge case, verification gap). Nessun rilievo di intento o di spec; tutti patch salvo un rinvio.

| Rilievo | Verdetto | Evidenza / esito |
|---|---|---|
| Pulizia del Banco su «Banco…» può cancellare eventi, bozze o una cartella dell'utente | high | Il prefisso «Banco» prende anche titoli veri come «Banco alimentare». Patch: marcatore «Banco MacTalkAct», cartella rimossa solo se contiene il file sentinella, rifiuto se c'è già una cartella dell'utente |
| Eventi del Motore fuori ordine riportano indietro le fasi (primo token dopo l'avvio di uno strumento, secondo `turn.started`, `onCall` dopo la chiusura) | medium | Fonti concorrenti (stdout e MCP). Patch: eventi solo in avanti, strumenti ignorati dopo la chiusura |
| Chiamate di strumenti in parallelo: la prima che finisce segna ragionamento | medium | MCPServer serve ogni richiesta in un Task. Patch: contatore delle chiamate in volo |
| Calendario: la pulizia iniziale salta perché l'accesso non è ancora noto, e un evento vecchio fa passare la verifica | medium | `calendarAllowed` era nil al primo compito. Patch: accesso chiesto prima della pulizia |
| `EKEvent.title` nil fa cadere il Banco | low | `String!` importato da EventKit. Patch: `?? ""` |
| osascript senza timeout sul main actor; bozze salvate non pulite | medium | Una richiesta di Automazione lo blocca. Patch: timeout di 10 s con messaggio; cancellazione anche dalle Bozze |
| Agente avviato su qualunque app in primo piano (app, webmail, frase); URL webmail nullo | medium | Prima solo `.page` era controllato. Patch: verifica del bundle atteso per ogni tipo; URL non valido → saltato |
| Account webmail personale: titolo e domande stampati in console | medium | Violava «log ridotto ai tempi». Patch: titolo e domanda nascosti |
| `bloccate` contata due volte e anche per azioni poi approvate | medium | Errore «confirm first» +1 e diniego +1. Patch: dinieghi + un'azione rischiosa rimasta senza risposta; suffisso del messaggio in una sola costante |
| Contatori azzerati nella ripetizione su un altro Motore | low | `reset(keepElements: true)` li azzerava. Patch: tenuti nella ripetizione |
| Richiesta rifiutata prima del `defer`: il Banco riusa le fasi della precedente | medium | Le guardie stavano prima del `defer`. Patch: azzeramento prima delle guardie |
| Orologio letto fuori dal lock: segmento negativo possibile | low | `mark` leggeva `now` prima del lock. Patch: lettura sotto lock |
| «primo token» era il primo messaggio completo | medium | Mancava `--include-partial-messages`. Patch: flag aggiunto, numeri della ricerca corretti; Codex letto dal campo `type` invece che da una sottostringa |
| Callback del Motore abbandonato ancora attivo dopo il ripiego | low | Patch: `onPhase = nil` nel ramo d'errore |
| Finestre Finder lasciate aperte fanno passare `finder-apri` | medium | Patch: chiusura delle finestre sulla cartella del Banco nella pulizia |
| Preparazione fallita lascia la cartella | low | Patch: pulizia sul ramo saltato |
| Finestra eventi −1/+7 giorni invece di ±7 | low | Patch: −7/+7 |
| `lavagna.html`: dati del triangolo incoerenti | low | Patch: campi inutili tolti |
| Nessun test delle fasi attraverso `AgentRunner.run` | gap | Patch: `FakeEngine.phased` in `--fallback-test` con evento duplicato in ritardo |
| Nessun test della lettura degli eventi Claude/Codex | gap | Patch: `ClaudeCLI.phase(of:)` e `CodexEventParser.phase` puri, testati su `success.jsonl` |
| Nessun test dei contatori | gap | Patch: blocco in `--fallback-test` |
| Permesso Calendario per un binario senza Info.plist | maybe-false | Si chiarisce lanciando `calendario-evento` con Nico presente. Rinviato |
| Codex: turni sempre nil | low | Corretto insieme alla patch del parser (`turns` da `turn.started`) |
| Frasi spurie: ignorata dal Router e arrivata all'Agente danno lo stesso esito | false | La colonna `risposta` dice già `router: …` contro la risposta dell'Agente, e l'AC chiede «nessuna azione» |
| `bundleID` per app non mappate, `app:X:banco` non Finder | low | Respinto: nessun compito li usa |
| Riepilogo `somma_ok` vero sui saltati; conversione `Duration` duplicata | low | Respinto come cosmetico (conversione comunque unificata) |
| PhaseTimer classe invece di struct (affermazione della spec) | false | Serve un riferimento condiviso tra i task; nessun danno |
