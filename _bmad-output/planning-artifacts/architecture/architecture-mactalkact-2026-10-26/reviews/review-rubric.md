# Revisione rubric — ARCHITECTURE-SPINE (aggiornamento del 27/10 sera)

- **Oggetto:** `ARCHITECTURE-SPINE.md` (MacTalkAct, brownfield), emendamenti per PRD §4.9–§4.11 (FR-41…FR-55): AD-6, AD-14, AD-16, AD-18, AD-19, AD-20 emendate; AD-21, AD-22, AD-23 nuove; Stack, Structural Seed, Capability map, Deferred.
- **Data:** 2026-10-27
- **Metodo:** lettura integrale dello spine; PRD §3, §4.9–§4.11, §5, §9; codice in `Sources/MacTalkAct/` (AgentRunner, AgentEngine, AgentTools, ClaudeCLI, ClaudeEngine, CodexCLI, MCPServer, Privacy, Coordinator, IntentRouter, IntentClassifier, LLMPlanner, Settings, LocalText, `scripts/build-app.sh`); verifica delle versioni dello Stack sulla macchina (`claude --version`, `codex --version`, `ollama --version`, `sw_vers`, `swift --version`, `claude -p --help`).

## Verdetto del gate

**Non passa, con rinvio breve.** Lo spine è solido nell'impianto (paradigma chiaro, Deferred con punti d'ingresso espliciti, Stack verificato e attuale, copertura completa di FR-41…FR-55), ma tre regole nuove o emendate lasciano aperti punti su cui due storie divergerebbero o che contraddicono il codice committato oggi: il livello `.none` per le app riservate (AD-22) nega il comportamento appena rilasciato in `Coordinator` (riservata → Motore locale); lo stato `.unverified` (AD-14) farebbe saltare il Motore nel selettore così com'è scritto; il bersaglio del `ConfirmationGrant` (AD-21) non copre le Azioni «per costruzione» senza elemento (Invio, scorciatoie, trascinamenti) e il «secondo strato» è collocato dopo l'azione, dove non può più imporre nulla. Sistemate queste quattro voci (mezza giornata di lavoro sul documento), lo spine è pronto per le epic.

## Verdetti per voce della checklist

| # | Voce | Verdetto | Motivo in breve |
|---|---|---|---|
| 1 | Fissa i punti reali di divergenza per il livello sotto e non ne manca nessuno | **adequate** | Mancano: il bersaglio del grant per azioni senza elemento (H3), la chiusura del turno istantaneo nella scalata (M2), il percorso Plan/chiave API delle conferme (M6). |
| 2 | Ogni Rule è applicabile e previene davvero la divergenza dichiarata | **thin** | AD-21 colloca il classificatore «in parallelo a `settle()`», cioè dopo l'azione (H4); AD-14 `.unverified` dentro `availability` rompe il selettore (H2); AD-22 `.none` non è applicabile senza rompere il codice (H1). |
| 3 | Nulla nei Deferred può far divergere due unità | **strong** | Ogni voce rinviata nomina il punto d'ingresso (`any LanguageModel` di AD-17, `LocalActionValidator`+AD-21 per Apple Events, `MCPServer` per la revisione MCP). |
| 4 | Tecnologia nominata verificata e attuale | **strong** | Verificato oggi: Claude Code CLI 2.1.311 (`--bare`, `--effort`, `--mcp-config`, `--input-format stream-json` presenti; `-p` non bare per default), codex-cli 0.164.0-alpha.11.1, Ollama 0.40.11, macOS 27.0.1, Swift 6.4. |
| 5 | Ratifica il codice brownfield invece di contraddirlo | **thin** | AD-22 contraddice `Coordinator.swift:862-864` (H1); forma di `RouteDecision.agent` diversa dal codice (M3); «token via stdin» impossibile con la Sessione lunga (M1); «attende o viene rifiutata» non deciso mentre il codice rifiuta (L1). Buona la ratifica di AD-16 per Codex (`CodexCLI.swift:118-131`) e del blocco cloud per chiamata (`AgentTools.swift:240-248`). |
| 6 | Copre le capability FR-41…FR-55 del PRD | **strong** | Capability map completa; piccole omissioni di dettaglio (secondo innesco di FR-43, ripetizione dopo riavvio di FR-42, HUD del livello di FR-54: M2, L6). |
| 7 | Ogni dimensione dell'altitudine è decisa, rinviata o domanda aperta (build, firma, distribuzione, log, impostazioni) | **adequate** | Build/firma (AD-10), distribuzione (Deferred), log (AD-9), impostazioni (AD-11/12) ci sono. Manca una sezione Open Questions: le domande 7–11 del PRD non sono né decise né rinviate (M4); «la suite gira prima di ogni build distribuita» non ha un meccanismo (M5). |

## Findings

### Alta

**H1 — AD-22 contraddice il comportamento appena rilasciato per le app riservate.**
Citazione: «`AccessLevel` (`.none` per app e siti riservati, …)». Il codice committato oggi (614df3f) fa l'opposto: `Coordinator.swift:862-864` — `// Reserved: the local engine works on it, Claude and Codex never see it.` con HUD «resto sul Mac»; `AgentTools.swift:240-248` blocca per chiamata solo i Motori cloud. Il PRD FR-54 scrive «niente» per le riservate, ma lo spine deve ratificare o dichiarare la rottura, non lasciarla implicita: una storia implementerebbe `.none` come «nessun Agente», un'altra manterrebbe il Motore locale.
Fix: rinominare il livello in `.noCloud` («il Motore locale lavora, i Motori cloud non vedono né toccano»; screenshot, `<elements>`, `observe` mai al cloud) e aggiungere `.none` solo per siti bancari/trading se davvero si vuole bloccare anche il locale; dire se la Corsia locale vale sulle riservate; segnalare al PM la correzione di FR-54 e del Glossario.

**H2 — AD-14 (emendamento): `.unverified(version)` come stato di `availability` esclude il Motore dal selettore.**
Citazione: «`refreshAvailability` legge la versione e produce lo stato `.unverified(version)` (l'Agente funziona con un processo per richiesta…)». `EngineSelector.select` (`AgentEngine.swift:134`) accetta solo `engines[id] == .available`; AD-7 produce `.reduced` «solo quando nessun Motore è utilizzabile». Con lo stato nuovo un Claude non verificato verrebbe saltato o manderebbe l'app in Modalità ridotta: il contrario della regola.
Fix: separare le due cose. `availability` resta `available/paused/missing/loginNeeded/unavailable`; aggiungere a `AgentEngine` un `cliVersion: CLIVersionStatus` (`.verified(v)`, `.unverified(v)`, `.belowMinimum(v)`); `ClaudeEngine` avvia la Sessione lunga solo con `.verified`; `.belowMinimum` diventa `.unavailable("versione X troppo vecchia")`. Stato e diagnostica mostra entrambi.

**H3 — AD-21: il bersaglio del grant non copre le Azioni con effetti esterni «per costruzione».**
Citazione: «`target` è l'id dell'elemento con l'azione oppure l'indice del passo della serie». La stessa regola elenca come riconosciuti «l'Invio in un campo di composizione, le scorciatoie che inviano o eliminano, i trascinamenti verso il Cestino»: una `press_keys cmd+return`, un `type_text` che termina con «\n», un `drag` per coordinate non hanno un id dell'elemento con l'azione né un indice di serie. Oggi (`AgentTools.swift:408, 1161`) il controllo c'è ma la conferma è globale (`confirmedUntil`). Due storie divergerebbero su cosa legare (campo focalizzato? combinazione? nulla?).
Fix: definire `ConfirmationTarget` come `enum` con i casi `.element(id, action)`, `.keys(combo, focusedElementID)`, `.drop(onto: id | coordinates)`, `.step(index, within: seriesID)`, `.text(intoElementID)` per l'Invio da `type_text`; l'esecutore deriva il bersaglio dalla chiamata (mai dal Motore) e il grant corrisponde solo se il bersaglio tipizzato coincide. Aggiungere la riga «ogni nuovo strumento che può produrre un'Azione con effetti esterni dichiara il proprio `ConfirmationTarget`».

**H4 — AD-21: il «secondo strato» è collocato dopo l'azione.**
Citazione: «`OnDeviceClassifier` può solo aggiungere la richiesta di un grant (secondo strato: valuta le Azioni con effetti non già bloccate, in parallelo a `settle()`)». `settle()` gira dopo `perform` (`AgentTools.swift:244-247`): quando il classificatore risponde, l'azione è già avvenuta e nessuna conferma può essere imposta. La formula ha senso solo per i passi successivi di una serie `act`. Il PRD FR-55 contiene la stessa frase: lo spine la eredita senza risolverla, e due storie la risolverebbero in modo diverso (prima dell'azione con latenza sul percorso critico, oppure dopo e inutile).
Fix: «il classificatore gira **prima** del `dispatch` di ogni Azione con effetti non già bloccata, con budget di 300 ms [da misurare in FR-41]; allo scadere non aggiunge nulla e lo registra; in una serie `act` i passi i+1… vengono valutati durante il `settle()` del passo i». Segnalare al PM la frase di FR-55.

### Media

**M1 — AD-16 (emendamento): «token via stdin» non è possibile con la Sessione lunga di Claude.**
Citazione: «il token del server MCP passa ai processi figli tramite standard input dove la CLI lo permette … (per Claude la configurazione `--mcp-config` va scritta in un file temporaneo con permessi 0600 e il token letto dall'ambiente, o passata via stdin)». Con `claude -p --input-format stream-json` lo stdin è il canale dei messaggi (AD-6); oggi il token sta nell'argomento (`ClaudeEngine.swift:68`: `"--mcp-config", access.mcpConfigJSON`). Lasciare due vie fa divergere le storie.
Fix: una sola via per Claude: file `mcp-<pid>.json` con permessi 0600 in `~/Library/Application Support/MacTalkAct/`, intestazione `"Authorization": "Bearer ${MACTALK_MCP_TOKEN}"` espansa dall'ambiente del figlio (la CLI espande `${VAR}` nei file di configurazione MCP: la storia lo verifica sulla 2.1.311), file cancellato dopo l'evento `init`; eliminare «o passata via stdin». Per Codex ratificare quanto già fatto (`bearer_token_env_var`, `CodexCLI.swift:118-131`).

**M2 — AD-6 (emendamento): la scalata istantaneo → rapido non dice come finisce il turno istantaneo.**
Citazione: «`AgentRunner` sale a `.fast` passando richiesta, azioni eseguite con esito ed elementi attuali, senza ripetere Azioni con effetti». La Sessione istantanea è ancora dentro il turno, in attesa del risultato dello strumento: una storia la termina (perdendo la cache), un'altra le risponde con un errore e la lascia chiudere. Mancano anche due innesci del PRD: «alla seconda chiamata di strumento» (FR-43) e la ripetizione nella nuova sessione dopo un riavvio a metà richiesta «solo se non ha ancora eseguito Azioni con effetti» (FR-42).
Fix: «l'esecutore risponde allo strumento con `handed_over` e `AgentRunner` chiude il turno con la fine dello stream; la Sessione istantanea resta viva per la richiesta successiva». Aggiungere l'innesco «seconda chiamata di strumento» e, per il riavvio a metà richiesta, rimandare alla regola di AD-15 (`effectfulCalls == 0`).

**M3 — Convenzioni / AD-6: la forma di `RouteDecision.agent` non coincide col codice e non regge tre livelli.**
Citazione: «`agent(text, complexity)`» (Convenzioni) e «`RouteDecision.agent(complexity:)` sceglie il livello» (AD-6). Il codice ha `agent(String, deep: Bool, reason: String)` (`IntentRouter.swift:65`); un `Bool` non esprime `.instant`. La riga delle convenzioni elenca 7 casi, il codice ne ha 17 e manca il nuovo `.askIntent` di AD-23.
Fix: `agent(text, level: AgentLevel, reason)`; nella riga delle convenzioni rimandare all'`enum` del file e nominare solo i casi nuovi di questo ciclo (`askIntent`).

**M4 — Manca la sezione Open Questions; le domande 7–11 del PRD non hanno un posto.**
Lo spine non ha una sezione di domande aperte. Delle domande aggiunte il 27/10 nel PRD solo la revisione MCP (Q10) compare, in Deferred. Restano senza casa: tenuta della Sessione lunga su 8 ore (Q7), affidabilità di Haiku 5.5 sugli id (Q8), tempi Apple Events (Q9) e soprattutto la clausola legale di Anthropic sul «binario non modificato con il proprio abbonamento» (Q11), che è un rischio sull'intera scelta di AD-10.
Fix: aggiungere «## Open Questions» con proprietario, come si chiude e scadenza (la base di §4.9 va riletta entro il 1° novembre 2026, come dice il PRD).

**M5 — AD-18 (emendamento) e convenzione Test: «prima di ogni build distribuita» senza un meccanismo.**
Citazione: «gira prima di ogni build distribuita». `scripts/build-app.sh` compila e firma, non esegue nulla; non esiste una distinzione tra build quotidiana e distribuita. Senza un gancio la regola non è applicabile.
Fix: `scripts/build-app.sh --release` (o `scripts/preflight.sh`) che esegue `--selftest`, `--route-test` e `--agent-bench --suite sicurezza` e fallisce al primo errore; la build quotidiana resta libera. Dire anche con quale account di prova girano i compiti su Mail e Calendario (FR-41 chiede dati creati e rimossi dal Banco).

**M6 — AD-21 non copre la seconda strada delle conferme: il percorso Plan con chiave API.**
`Coordinator.handlePlan` (`Coordinator.swift:917-938`) conferma a livello di piano intero con `Safety.isRisky(plan)` e un `pending` che scade con `confirmationSeconds`; AD-10 (emendata) mantiene «l'accesso a Claude con chiave API … come variante del Motore Claude». AD-21 parla di `AgentTools.perform` ed `Executor` ma non di questo percorso: è una «seconda porta» nel senso di AD-20.
Fix: dichiarare che il percorso Plan passa dallo stesso `ConfirmationGrant` per passo (ogni passo rischioso del piano chiede il proprio grant), oppure che la variante con chiave API viene congelata e tolta dal perimetro delle conferme nuove.

**M7 — AD-22: Terminal `.clickOnly` esclude gli screenshot ma non il testo dell'Accessibilità.**
Citazione: «Terminal e iTerm `.clickOnly` ed esclusi dagli screenshot ai Motori cloud». Il prompt di `AgentRunner` (riga 33) dice che «observe give the text of terminals» e `<elements>` parte all'avvio di ogni richiesta: il contenuto del terminale raggiunge il cloud comunque. Protezione incoerente; il PRD FR-54 ha lo stesso buco.
Fix: per `.clickOnly` anche `observe`, `<elements>` e `get_text` restituiscono solo ruolo ed etichetta dei controlli, senza valori né testo; oppure dichiarare esplicitamente che il testo AX del terminale è ammesso e perché (e allora togliere l'esclusione degli screenshot, che non protegge nulla).

### Bassa

**L1 — AD-6: «la seconda richiesta attende o viene rifiutata con un messaggio»** non è una decisione. Il codice rifiuta (`AgentRunner.swift:265`, `guard !running else throw`). Fix: «viene rifiutata con il messaggio “sto già lavorando a un'altra richiesta”».

**L2 — Tempi non allineati e non ancorati ad `AppSettings`.** AD-2 e convenzione Tempi dicono «classificatore 1,0 s», il codice ha 1500 ms (`IntentClassifier.swift:75`). AD-6 introduce `sessionMaxRequests`, 10 minuti di inattività e `agentTimeout` senza dire che sono proprietà di `AppSettings` (AD-11). Fix: allineare il numero o rimandare al predefinito in `AppSettings.Defaults`; elencare `sessionMaxRequests`, `sessionIdleMinutes`, `instantLevelEnabled`, `longSessionEnabled` tra le chiavi.

**L3 — Structural Seed: «`LocalText.swift / OCR.swift`».** `LocalText.swift` esiste e fa la pulizia della Dettatura con il modello Apple; un nome doppio con barra fa scegliere due file diversi a due storie. Fix: un solo nome nuovo (`ScreenText.swift`) per `read_text` e il riscaldamento di Vision.

**L4 — AD-21 riusa `OnDeviceClassifier` (AD-2, classifica Frasi) per classificare Azioni.** Schema `@Generable` e prompt sono diversi; una storia infilerebbe la logica nel classificatore delle Frasi. Fix: `ActionClassifier` (stesso `SystemLanguageModel`, protocollo separato, stesso timeout).

**L5 — AD-22 + AD-5: Dettatura in un campo sicuro e `InsertionJournal`.** La Dettatura è esclusa dai livelli (coerente col PRD), ma AD-5 fa registrare «testo inserito e testo prima del cursore»: una password dettata finirebbe nel registro in RAM e, con il log dettagliato, potenzialmente nel log. Fix: in un campo sicuro il registro conserva solo la lunghezza e nessun testo; l'annullamento usa Cmd+Z.

**L6 — AD-22 non nomina l'HUD.** FR-54: «il livello in vigore è visibile nell'HUD quando l'Agente lavora». Fix: una riga: il Coordinator mostra il livello nel dettaglio dell'HUD `.thinking` quando è diverso da `.full`.

**L7 — Reversibilità: deviazione dal PRD non dichiarata.** La convenzione «nessun interruttore può disattivare AD-21 o AD-22» è giusta, ma contraddice NFR-15 («ogni funzionalità di §4.9–§4.11 ha un interruttore»). Fix: dichiararla come deviazione voluta e chiedere al PM di correggere NFR-15 (escludere FR-51, FR-52, FR-53).

## Punti di forza da conservare

- Il paradigma e il diagramma dei divieti (Router e Classificatore non toccano l'Executor) restano il miglior antidoto alla divergenza.
- AD-16 per Codex è già ratificato dal codice (`--ignore-user-config`, `--ignore-rules`, `--strict-config`, `--sandbox read-only`, `--disable …`, token in ambiente).
- `AgentTools.swift:240-248` applica già il blocco cloud per chiamata e dopo il `settle()`: AD-22 può poggiarsi su questo punto invece di inventarne uno.
- Stack verificato oggi, con la versione minima per Haiku 5.5 e la data del modello.
- Ogni voce dei Deferred dice da dove rientrerebbe.

## Conteggi

| Severità | Numero |
|---|---|
| Critical | 0 |
| High | 4 (H1–H4) |
| Medium | 7 (M1–M7) |
| Low | 7 (L1–L7) |
