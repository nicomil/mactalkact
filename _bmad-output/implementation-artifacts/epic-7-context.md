# Epic 7 Context: Veloce dove conta

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Le risposte dell'Agente devono arrivare in circa metà del tempo di oggi senza perdere precisione. L'epic parte da una riga di base misurata (il Banco di prova che scompone ogni compito in fasi e copre anche app native, una webmail, una pagina con canvas e le Frasi spurie), poi interviene sui colli di bottiglia: una Sessione lunga di Claude riusata tra le richieste, un Livello istantaneo per i comandi a un passo, un'osservazione dello schermo a costo fisso e CLI tenute sotto controllo per versione e login. Ogni intervento si giudica con la tabella prima/dopo sugli stessi compiti.

## Stories

- Story 7.1: Riga di base — il Banco misura fase per fase, anche fuori dal browser
- Story 7.2: Sessione lunga sorvegliata e CLI sotto controllo
- Story 7.3: Livello istantaneo per i comandi a un passo
- Story 7.4: Osservazione a costo fisso
- Story 7.5: Misura finale della velocità

## Requirements & Constraints

- Il Banco riporta per ogni compito le fasi (scansione iniziale, avvio o riuso della sessione, connessione MCP, primo token, ogni azione con assestamento, classificatore di sicurezza, turno finale, chiusura); la somma delle fasi coincide con il totale entro 0,2 s. Per compito riporta anche turni, conferme chieste e azioni bloccate.
- Il Banco copre: almeno 5 compiti su Mail, Calendario e Finder con dati creati e rimossi dal Banco stesso; almeno 2 compiti su una webmail aperta su un account di prova (sull'account personale solo osservazione, log ridotto ai tempi); 1 compito su una pagina con canvas; almeno 5 Frasi spurie con esito atteso «nessuna azione».
- Obiettivi di velocità (criteri di `--agent-bench`, esito dichiarato anche se non superato): primo strumento ≤ 1,5 s, compito ≤ 4,5 s, livello istantaneo ≤ 2,5 s (mediane).
- Nessuna storia 7.2–7.5 è fatta senza la tabella prima/dopo; la riga di base va scritta nella ricerca `technical-agente-precisione-velocita-e-strumenti-2026-10-27`.
- Reversibilità: ogni funzione nuova ha un interruttore in `AppSettings` con ripiego al comportamento precedente (Sessione lunga → processo pronto).
- Le richieste in modalità privata o su app riservate non raggiungono i Motori cloud e non entrano in alcuna Sessione lunga.
- Le versioni delle CLI (Claude ≥ 2.1.299 per la Sessione lunga, ≥ 2.1.293 per Haiku 5.5; Codex ≥ 0.131.0) vanno rilette entro il 1° novembre 2026.

## Technical Decisions

- **Fasi e orologio:** solo `AgentRunner` marca le fasi (`BenchPhase`), con un solo orologio monotonico. I Motori segnalano gli eventi che servono tramite `AgentEngine.onPhase` (sessione avviata o riusata, server connesso, primo token, turno finito); `act` marca una fase per passo. I Motori non chiamano mai HUD, Coordinator o Executor.
- **Banco:** `Tests/bench/agente.tsv` (id, pagina o app di partenza, richiesta, verifica attesa), pagine statiche in `Tests/bench/pages/` aperte con `file://`; `MacTalkAct --agent-bench [--engine …] [--model …]` verifica l'esito leggendo lo stato con l'Accessibilità e scrive `~/Library/Logs/MacTalkAct-bench-<data>.tsv`.
- **Livelli:** `AgentLevel` ha `.instant`, `.fast`, `.deep`. `.instant` (Haiku 5.5, effort basso) esiste solo per Claude, per comandi a un passo con bersaglio noto (`RouteHeuristics.hasKnownTarget`, condivisa con il filtro delle Frasi spurie dell'Epic 8); scala a `.fast` con `cancel()` senza `tools.reset()` al primo esito negativo o alla seconda chiamata di strumento. Su Codex o locale si usa `.fast`.
- **Sessione lunga:** al massimo una per livello del Motore Claude (`claude -p --input-format stream-json`), avviata alla prima richiesta, mai riscaldata in anticipo, `--no-session-persistence`, nessun ping. Si riavvia dopo `sessionMaxRequests`, 10 minuti di inattività, scadenza del `TurnClock`, cambio di modello o effort, «dimentica la conversazione», modalità privata. `ConversationLog` tiene un cursore per sessione. Una richiesta interrotta dal riavvio si ripete solo se non ha eseguito Azioni con effetti.
- **Orologio del turno:** `AgentRunner` possiede il `TurnClock`; le CLI non hanno timeout propri sul compito (`agentTimeout` resta il valore).
- **CLIStatus:** `.verified`, `.unverified`, `.belowMinimum`, separato da `availability`; `EngineSelector` non lo legge. `ClaudeCLI` rimuove dall'ambiente del figlio `CLAUDE_CODE_SIMPLE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDECODE`, `ANTHROPIC_API_KEY`; un avvio senza login dell'abbonamento porta a `.unverified`.
- **Osservazione:** `AgentTools.scan` usa figli visibili (`AXVisibleChildren`/`AXVisibleRows`), tetto per contenitore, filtro per ruolo, budget di tempo; per Electron/Chromium imposta `AXManualAccessibility` e attende che l'albero si popoli.
- **Log:** formato `Agente (<motore>/<modello>): …`; per ogni turno token letti dalla cache e ogni riavvio con motivo.

## Cross-Story Dependencies

- 7.1 precede tutte le altre: fornisce fasi e riga di base su cui si misurano 7.2–7.5.
- 7.2 introduce il `TurnClock` (la pausa durante le domande arriva con la Storia 9.2).
- 7.3 introduce `RouteHeuristics.hasKnownTarget`, riusata dalla Storia 8.1.
- 7.5 richiede 7.2–7.4 fatte.
- `AgentTools.swift` è toccato anche dagli Epic 8 e 9 in zone diverse.
