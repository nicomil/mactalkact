# Epic 11 Context: Risposta in un attimo

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Togliere dal ciclo dell'Agente con Claude i secondi che non dipendono dal ragionamento del modello: l'avvio della sessione e la connessione agli strumenti, la scalata dal Livello istantaneo al rapido e il turno finale in cui il modello scrive solo «fatto». Alla fine dell'Epic 7 il compito aveva una mediana di 6,0 s e il primo strumento di 2,7 s; su Gmail il primo token arrivava a 12,7 s, di cui 6,1 s di scalata e 3,5 s di avvio del server MCP. L'epic porta l'utente a vedere una prima reazione nell'HUD entro mezzo secondo e a chiudere il compito entro le soglie riviste. Chiude anche uno spike di sola misura sulla ricerca in Mail e la misura finale del ciclo 3, con l'aggiornamento della pagina «Come funziona».

## Stories

- Story 11.1: Riga di base del ciclo 3 e CLI riverificate
- Story 11.2: Sessione pronta quando inizio a parlare
- Story 11.3: Scalata sotto il secondo
- Story 11.4: Risposta scritta dall'app
- Story 11.5: Spike — ricerca in Mail sotto il secondo
- Story 11.6: Misura finale del ciclo 3

## Requirements & Constraints

- **Soglie di velocità riviste** (mediane sul Banco con Claude), che sono anche i criteri di `--agent-bench`: primo strumento ≤ 2,0 s (il primo token da solo costa circa 1,6 s), compito ≤ 4,5 s, Livello istantaneo ≤ 2,5 s per compito, prima risposta visibile nell'HUD ≤ 0,5 s dalla fine della Frase, primo token sulla webmail ≤ 4 s. Il report dichiara l'esito di ogni soglia, superata o no.
- **Sessione pronta all'ascolto:** quando la Parola di attivazione compare nel testo parziale, o quando l'utente preme il tasto per parlare, l'app avvia le Sessioni lunghe di Claude che mancano (quella rapida e, se il Livello istantaneo è attivo, quella istantanea) fino alla connessione agli strumenti. Nessun contenuto parte prima della fine della Frase. Non succede in modalità privata, su app riservate, con un Motore diverso da Claude o con l'Agente non disponibile, e la Chiacchiera senza Parola di attivazione non avvia nulla. Obiettivo: avvio della sessione più connessione MCP sotto 0,2 s di mediana, anche sul primo compito dopo una pausa.
- **Scalata ≤ 1 s di mediana** (oggi 2,4 s, su Gmail 6,1 s; la soglia è un'ipotesi da verificare): la sessione rapida si prepara mentre lavora l'istantaneo, ma riceve la richiesta solo al passaggio di consegne. Agisce sempre un solo processo, nessuna Azione con effetti viene ripetuta (`effectfulCalls` e grant restano invariati) e nessun compito istantaneo in più fallisce. La regola della resa legge tutta la risposta, escluse le domande di cortesia (caso `menu-accessori`: la resa stava nella seconda frase).
- **Risposta composta dall'app:** quando l'ultima azione termina con un esito che prova il risultato (elemento cambiato, testo comparso, finestra aperta), l'app chiude il turno e compone lei la frase. Il modello risponde ancora per domande, errori, esiti non verificati e richieste informative. Non ci deve essere nessun «fatto» senza esito. La mediana deve scendere almeno quanto vale la fase «turno finale» (circa 1,5 s).
- **Reversibilità:** la sessione pronta all'ascolto e le «Risposte rapide» hanno ciascuna un interruttore in `AppSettings`, con ripiego al comportamento di oggi.
- **Spike sulla ricerca in Mail:** l'obiettivo è ≤ 1 s su una casella da 45.915 messaggi. Si misurano due strade (Apple Events su un perimetro ridotto, indice di Spotlight); il comando non porta nessuna integrazione, la casella resta invariata e nessuna finestra resta aperta.
- **Nessuna regressione di sicurezza:** dopo ogni storia restano verdi la suite di sicurezza (Claude 10/10 e 8/8 blocchi, Codex 8/8), `--security-coverage`, `--route-test` e `--hands-test`. Nessun guadagno di tempo può passare dal togliere conferme.

## Technical Decisions

- **Sessioni di `ClaudeCLI`:** c'è al massimo una Sessione lunga per livello (`.instant`, `.fast`, `.deep`), su `claude -p --input-format stream-json` con `--no-session-persistence`. Si riavvia dopo `sessionMaxRequests` richieste, dopo 10 minuti di inattività, alla scadenza del `TurnClock`, al cambio di modello o di effort, con «dimentica» e con la modalità privata. Non c'è nessun ping di mantenimento. `ConversationLog` tiene un cursore per sessione, e `clear`/`expire` azzerano i cursori e impongono il riavvio. La Sessione lunga esiste solo con `CLIStatus.verified`; altrimenti si usa un processo per richiesta.
- **Avvio anticipato (emendamento del 28/10):** «mai riscaldato in anticipo» non vale più. Il pre-avvio si ferma all'evento `init` con i server MCP connessi, quindi non consuma token. Vale al massimo un avvio ogni 5 s, come `wakeModels()`; le sessioni mai usate si chiudono con le regole di inattività attuali. Resta un solo `run` che agisce alla volta.
- **Livello istantaneo:** usa Haiku 5.5 con effort `low`, solo con Claude, per i comandi a un passo con bersaglio noto (`RouteHeuristics.hasKnownTarget`). In Catena di riserva la richiesta usa `.fast`. Il tetto è una chiamata con effetti.
- **Escalation:** i segnali sono un esito negativo, una seconda chiamata, una resa nella risposta o un errore del modello. Al primo segnale `cancel()` interrompe subito il turno istantaneo, senza `tools.reset()`. Il rapido riceve la richiesta, le azioni eseguite con il loro esito e gli elementi attuali. Se dopo l'ultima osservazione non ci sono state Azioni con effetti, quell'osservazione si riusa invece di rifarla. `AgentEngine.cancel()` non deve perdere lo stato di `AgentTools`.
- **Esito e turno finale:** gli strumenti che agiscono (`act`, `click`, `type_text`, `press_keys`…) accettano il parametro `final: true` sull'ultima azione; al Livello istantaneo l'unica chiamata vale sempre come finale. Con esito verificato `AgentRunner` interrompe il turno del Motore e la frase la compone l'app. La Memoria di conversazione registra richiesta ed esito. La richiesta successiva nella stessa Sessione lunga non deve vedere una risposta a metà: si verifica con `--session-test`.
- **CLI:** `CLIStatus` (`.verified`, `.unverified`, `.belowMinimum`) è separato da `availability` e `EngineSelector` non lo legge. Le versioni minime sono Claude 2.1.299 per la Sessione lunga, 2.1.293 per Haiku 5.5 e Codex ≥ 0.131.0. `ClaudeCLI` toglie `CLAUDE_CODE_SIMPLE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDECODE` e `ANTHROPIC_API_KEY` dall'ambiente del figlio; un avvio senza login dell'abbonamento porta a `.unverified`. Le versioni vanno rilette entro il 1° novembre 2026: se l'interfaccia del flusso cambia, la storia lo segnala prima di procedere.
- **Banco (`--agent-bench`):** l'unico che marca le `BenchPhase` è `AgentRunner`, con un solo orologio monotonico; i Motori segnalano gli eventi tramite `onPhase`. La somma delle colonne delle fasi deve coincidere con il totale entro 0,2 s. Questo epic aggiunge la fase «prima risposta visibile» (dalla fine della Frase al primo cambio dell'HUD) e il costo della scalata per compito. Nessuna storia di velocità è «fatta» senza la tabella prima/dopo sugli stessi compiti. Le tabelle vanno in `~/Library/Logs`, la riga di base e i risultati nella ricerca. Sulla webmail con l'account personale si fanno solo compiti di osservazione, con log ridotto ai tempi.
- **Apple Events:** nessuna azione via Apple Events come strumento dell'Agente. Lo spike vive solo in `DebugCLI` (`--apple-events-spike`); la decisione di farne uno strumento spetta a Nico, dopo aver visto i numeri.
- **File toccati:** `ClaudeCLI`, `AgentRunner`, `AgentEngine`, `AgentTools` (`final`), `Coordinator` (`wakeModels`), `AppSettings`, `DebugCLI`, `Tests/bench`.

## UX & Interaction Patterns

- La prima reazione visibile è un cambio dell'HUD entro 0,5 s dalla fine della Frase.
- Le risposte composte dall'app sono brevi e nascono dall'esito («Fatto: ho inviato…», «Ho aperto…»). Si mostrano o si pronunciano come le risposte di oggi.
- L'HUD dice «Riavvio l'Agente» una sola volta per riavvio. Un avvio anticipato non deve produrre messaggi visibili.

## Cross-Story Dependencies

- La 11.1 viene prima di tutte: riverifica le CLI e scrive la riga di base con le nuove fasi, contro cui si giudicano 11.2, 11.3 e 11.4.
- La 11.3 riusa il meccanismo di avvio fino all'`init` introdotto dalla 11.2. La 11.4 considera finale l'unica chiamata dell'istantaneo, quindi va coordinata con la logica di scalata della 11.3.
- La 11.2 chiude due debiti aperti: un test di `ConversationLog.expire()` con un orologio iniettabile (la generazione cresce e la sessione riparte) e un test del Coordinator per `.askIntent`.
- La 11.6 richiede Epic 10 e le storie 11.1–11.5 completate. Confronta tutte le soglie riviste e quella del secondo strato sotto carico (zero timeout, al massimo 0,3 s in più al 90° percentile) e aggiorna `docs/come-funziona.html` (limiti noti, grafici dei tempi, tabella del secondo strato, versione e data).
- Con l'Epic 10, il cancello unico e il giudizio anticipato del secondo strato condividono `AgentTools.perform` e il percorso del clic: le misure di tempo di questo epic includono il costo del gate.
