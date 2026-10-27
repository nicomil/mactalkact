# Riconciliazione PRD (27/10 sera) → ARCHITECTURE-SPINE

**Input:** `prd.md` (§0 nota di aggiornamento, UJ-8…UJ-10, Glossario, §4.9–§4.11, estensioni NFR-2/NFR-5, SM-8…SM-10, SM-C4…SM-C7, Domande 7–11, §10) e `addendum.md` (ultime cinque sezioni).
**Target:** `ARCHITECTURE-SPINE.md` (AD-6, AD-14, AD-16, AD-18, AD-19, AD-20 emendate; AD-21…AD-23; Consistency Conventions; Stack; Structural Seed; Capability map; Deferred).
**Data:** 2026-10-27.

Legenda copertura: **completa** (la spina lega il requisito e tutte le conseguenze verificabili), **parziale** (manca almeno una conseguenza o una qualità implicita), **assente** (nessuna AD lo lega), **contraddetta** (la spina dice una cosa diversa dal PRD, o il PRD si contraddice e la spina sceglie senza dirlo).

## 1. Tabella FR/NFR → AD → copertura

| Requisito | AD / sezione | Copertura | Nota |
| --- | --- | --- | --- |
| FR-41 Banco con tempi scomposti e compiti fuori dal browser | AD-18 (em.), mappa ✓ | parziale | Fasi, app native con dati creati e rimossi, canvas, Frasi spurie e suite di sicurezza ci sono. Mancano: (a) la regola per la webmail sull'**account personale** (solo compiti di osservazione, log ridotto ai tempi); (b) la **riga di base prima di ogni intervento** di §4.9 (disciplina «misura prima»), che AD-18 chiede solo per il Motore locale. |
| FR-42 Sessione lunga per livello | AD-6 (em.), AD-14, Seed, mappa ✓ | parziale | Riavvii (N richieste, 10 min, timeout, «dimentica», modalità privata), processo dedicato per richieste private, delta della Memoria, versione verificata, interruttore: tutto legato. Mancano: (a) **«nessuna sessione scritta su disco»** (`--no-session-persistence`, NFR-2); (b) **riavvio a metà richiesta → ripetizione solo se `effectfulCalls == 0`** (AD-15 copre solo il Passaggio di Motore, non il riavvio della stessa sessione); (c) **cane da guardia**: HUD «Riavvio l'Agente» una sola volta, log di ogni riavvio e compattazione con il motivo; (d) dopo un riavvio la sessione riceve il **blocco `<recent>` intero**; (e) log dei **token letti dalla cache** (conseguenza verificabile della cache calda); (f) **cambio di modello o effort di un livello invalida la cache** (addendum) → deve riavviare quella sessione, altrimenti AD-11 («letto al momento dell'uso») produce una sessione con cache fredda senza che nessuno lo veda; (g) l'addendum scarta il **ping periodico** per tenere calda la cache: la spina non lo vieta. |
| FR-43 Livello istantaneo | AD-6 (em.), Stack, Conventions «Motori», mappa ✓ | parziale | Modello, effort, scelta del Router, regola dell'esecutore, scalata con passaggio di consegne senza ripetere Azioni con effetti: legati. Mancano: (a) la seconda condizione di scalata, **«alla seconda chiamata di strumento»**; (b) la riga di log «istantaneo → rapido · motivo»; (c) la convenzione `RouteDecision` elenca ancora `agent(text, complexity)` senza dire che `complexity` è `AgentLevel` a tre valori; (d) chi decide «bersaglio nominato» non è detto: AD-23 introduce `RouteHeuristics.hasKnownTarget`, AD-6 dovrebbe usare la stessa funzione, altrimenti nascono due euristiche del bersaglio. |
| FR-44 Osservazione a costo fisso | AD-19 (em.), mappa ✓ | completa | Figli visibili, tetto per contenitore, filtro per ruolo, budget di tempo, `AXManualAccessibility` per Electron/Chromium. La soglia «< 1 s su webmail» è misurata dal Banco (FR-41). |
| FR-45 CLI sorvegliate | AD-14 (em.), AD-6, Stack, mappa ✓ | parziale | `minimumVersion`/`verifiedVersions`, stato `.unverified`, modalità non «bare» esplicita: legati. Il PRD chiede di rilevare il cambio di comportamento **in Stato e diagnostica prima che l'Agente fallisca**; la spina lo rileva «come errore di avvio», cioè alla prima richiesta. Serve un controllo in `refreshAvailability` (avvio di prova senza richiesta) oltre alla classificazione dell'errore. La scadenza del 1° novembre per rileggere la base non compare nella spina. |
| NFR-12 Tempi del ciclo | nessuna AD la lega; AD-18 la misura | assente (nei Binds) | Le soglie (primo strumento ≤ 1,5 s, compito ≤ 4,5 s, istantaneo ≤ 2,5 s) non sono citate né in AD-18 né nella riga «Tempi» delle convenzioni. Il Banco deve conoscerle per segnalare la regressione. |
| FR-46 Evidenza prima del «fatto» | AD-19 (em.), AD-4, mappa ✓ | parziale | Prompt che cita `RESULT`, Memoria con esito e testo cambiato: legati. Manca il tetto **`<recent>` ≤ 300 parole per interazione** (AD-4 fissa 5 voci ma nessuna dimensione). Il requisito riguarda l'**Agente cloud**: AD-19 dice «il Motore» senza distinguere; AD-17 (prompt corto locale) lo escluderebbe di fatto, ma va detto. |
| FR-47 Lettura locale del testo nelle immagini | AD-19 (em.), AD-20 (em.), Seed, Deferred, mappa (manca AD-17) | parziale | `read_text(region)` con Vision, accurata→veloce, 10 s, riscaldamento in background, screenshot con testo che sostituisce l'immagine: legati. Mancano: (a) **il Motore locale può usare `read_text`** — il sottoinsieme di strumenti di AD-17 non lo contiene e la mappa non cita AD-17; (b) lettura chiesta **prima della fine del riscaldamento** → modalità veloce o «testo non leggibile ora» entro il tempo massimo; (c) riscaldamento «**senza ritardare l'ascolto**» (priorità del task rispetto a `SpeechEngine`); (d) criterio di «quando il testo basta» per sostituire l'immagine: vago nel PRD e nella spina, va fissato come regola (è la promessa di privacy di UJ-9). Il Seed indica `LocalText.swift / OCR.swift`: due nomi per un file, sceglierne uno. |
| FR-48 Frasi spurie | AD-23, mappa ✓ | completa | Filtro dopo Comandi rapidi e Corsia locale, `hasKnownTarget`, ≤ 3 parole o solo parole estranee, timeout del classificatore senza Parola di attivazione, 8 s, eccezioni per Parola di attivazione e push-to-talk, Corpus che conta i falsi «chiedi». Manca solo l'aggiunta di `.askIntent` alla riga `RouteDecision` e di «8 s» alla riga «Tempi» delle convenzioni; «almeno 15 Frasi spurie nel Corpus» resta un contenuto di test, non di architettura. |
| FR-49 Spike azioni dirette | AD-20 (em.), Deferred, mappa ✓ | completa | Comando di debug, nessuno strumento dell'Agente, niente `do shell script`/JavaScript. |
| NFR-13 Precisione fuori dal Banco | nessuna AD; AD-9 rende contabile il log | assente (nei Binds) | «Zero Frasi spurie affidate all'Agente nel log di una settimana» è contabile grazie al formato di AD-9 (`Instradamento: <decisione>`), ma nessuna AD lo dichiara come misura. |
| FR-50 Server degli strumenti chiuso | AD-16 (em.), Seed, mappa ✓ | completa | Token via stdin/ambiente, mai negli argomenti; 403 su `Origin`/`Host`; log della revisione; suite con `~/.codex/AGENTS.md` di prova. I rimedi dell'addendum (`CODEX_HOME` dedicato o directory vuota) sono materia di storia. |
| FR-51 Conferma legata alla singola azione | AD-21, Conventions «Sicurezza», mappa ✓ | parziale | Grant per bersaglio, stessa richiesta e finestra, decadenza all'esito, consumo, nessuna finestra temporale, sospensione del timeout, «senza tornare al Motore», domanda in linguaggio naturale non vale: legati. Mancano: (a) **come il «sì» a voce raggiunge il grant**: `RouterState` ha «domanda dell'Agente in attesa» (FR-9) ma non «conferma dell'esecutore in attesa»; senza un caso di `RouteDecision` o un campo di `RouterState`, un «sì» può finire in Dettatura o all'Agente; (b) **cosa succede alla chiamata bloccata**: il PRD (UJ-8, UJ-10) descrive l'esecutore che sospende, chiede e sul «sì» esegue, sul «no» restituisce al Motore un esito «bloccato dall'utente» — la spina dice «richiede un grant emesso da `confirm(target:)`» e si può leggere come «la chiamata fallisce e il Motore deve chiamare `confirm`» (un giro di modello in più, contro SM-C5); (c) tono: la seconda conferma è **formulata con il bersaglio** («Elimino anche “Newsletter ottobre”?»). |
| FR-52 Campi sicuri | AD-22, Seed, mappa ✓ | completa | Ruolo o sottoruolo, ripiego «riga singola = sicuro», nessun valore né lunghezza, errore su `get_text`/`type_text`, inserimento sicuro della tastiera segnalato con l'app. Il marcatore «(password field: content never read)» resta un dettaglio di storia. |
| FR-53 Gate dell'esecutore | AD-21, AD-18 (suite), mappa ✓ | parziale | Elenco canonico, riconoscimento per costruzione e per riconoscimento, HUD con «che tu non hai chiesto», log del blocco, suite ≥ 10 scenari a errore: legati. Mancano: (a) la **misura di copertura del riconoscimento** (quota di pulsanti di invio/eliminazione riconosciuti, ≥ 90%) come uscita del Banco; (b) NFR-14 «ogni azione bloccata nell'uso reale diventa uno scenario»: perché sia possibile, la **riga di log del blocco** deve contenere app, etichetta/`AXIdentifier`/azione e tipo di effetto esterno, cioè i campi di `sicurezza.tsv`. Nessuna convenzione lo fissa. |
| FR-54 Livelli di accesso per app | AD-22, mappa ✓ | parziale / contraddetta in un punto | Quattro livelli, elenco in `AppSettings`, Terminal/iTerm `.clickOnly` esclusi dagli screenshot al cloud, Corsia locale sì e Dettatura no: legati. Mancano: (a) **livello in vigore visibile nell'HUD** mentre l'Agente lavora; (b) il PRD distingue **Finder = conferma per ogni Azione con effetti *esterni*** (Cestino, spostamenti fuori dalla finestra) da **Impostazioni di Sistema = conferma per ogni Azione con *effetti*** (più ampio): la spina li mette entrambi in `.fullWithConfirm`, quindi uno dei due è legato in modo diverso dal PRD; (c) «spostamenti fuori dalla finestra» del Finder come effetto esterno non compare nel riconoscimento per costruzione di AD-21 (che cita solo i trascinamenti verso il Cestino). |
| FR-55 Classificatore come secondo strato | AD-21, AD-18 (fase), mappa ✓ | completa | Valuta solo le azioni non già bloccate, in parallelo a `settle()`, può solo aggiungere conferme; latenza come `BenchPhase`; la suite passa anche a classificatore spento (interruttore ammesso). |
| NFR-14 Suite di sicurezza | AD-18 (em.), AD-21, Conventions «Test» | completa | Fa parte del Banco, errore alla prima Azione con effetti esterni senza conferma, gira prima di ogni build distribuita. Vedi FR-53(b) per la retroazione dall'uso reale. |
| NFR-15 Reversibilità | Conventions «Reversibilità» | contraddetta (PRD interno) | Il PRD dice «ogni funzionalità di §4.9–§4.11 ha un interruttore» e, in NFR-5, «nessun Motore, classificatore o impostazione può aggirare la conferma». La spina sceglie NFR-5 («nessun interruttore può disattivare AD-21 o AD-22») senza dichiarare che sta risolvendo una contraddizione del PRD. Va detto nella spina e corretto nel PRD (NFR-15 esclude FR-51…FR-53; FR-52 e FR-54 restano regolabili tramite l'elenco, FR-55 tramite l'interruttore del classificatore). |
| NFR-2 (estensione) | AD-6, AD-4, AD-22 | parziale | Richieste private fuori dalla sessione e azzeramento con «dimentica»: legati. «Mai su disco» per la Sessione lunga non è scritto (vedi FR-42a). «Consenso all'addestramento disattivato negli account» è operativo, non architetturale: basta una riga in Deferred o nelle assunzioni. |
| NFR-5 (estensione) | AD-21, Conventions «Sicurezza» | completa | Vocabolario unico, gate nell'esecutore, modelli che aggiungono soltanto. |
| SM-8, SM-C4, SM-C6 | AD-18 | parziale | Il Banco misura le fasi ma non elenca come colonne **turni per compito** (SM-C6) né confronta con la riga di base (SM-C4). |
| SM-9, SM-C7 | AD-23, AD-9 | parziale | Il Corpus conta i falsi «chiedi» (zero). «Non più di 3 azioni legittime bloccate o messe in dubbio a settimana nel log» richiede che blocchi e `askIntent` siano righe di log contabili: AD-9 copre `askIntent` (è una decisione), non i blocchi del gate (vedi FR-53b). |
| SM-10, SM-C5 | AD-18, AD-21 | parziale | SM-10 è la suite. SM-C5 (**conferme per compito non aumentano** sui compiti positivi) richiede una colonna «conferme» nel Banco sui compiti positivi; AD-18 misura solo gli scenari negativi. |
| Domande 7–11 | AD-6, AD-14, AD-16, Deferred | n/a | Q7 (prova di 8 ore col cane da guardia) e Q11 (clausola legale) non hanno traccia; Q10 è coperta dal log di AD-16 e dalla riga Deferred sulla revisione MCP. Vedi §2 per una riga di Deferred. |
| Glossario: Gate dell'esecutore, Livello di accesso, Sessione lunga, Livello istantaneo, Azione con effetti esterni | Conventions «Nomi», «Sicurezza», «Motori» | parziale | «Azione con effetti esterni» → `Safety.externalEffect`, «Livello istantaneo» → `.instant`, «Livello di accesso» → `AccessLevel`: legati. «Gate dell'esecutore» non ha un nome di tipo; la riga «Nomi» elenca solo i tipi del primo ciclo (manca `AgentLevel`, `ConfirmationGrant`, `AccessLevel`, `PrivacyGuard`, `BenchPhase`, `RouteHeuristics`, `ClaudeSession`). |

Mappa Capability → Architecture: FR-41…FR-55 sono tutte presenti. Correzioni: FR-47 deve citare anche AD-17 (Motore locale); NFR-12, NFR-13, NFR-15 e le metriche SM-8…SM-10 / SM-C4…SM-C7 non compaiono in alcun `Binds` (AD-18 è il posto naturale).

## 2. Lacune con testo proposto

### G1 — Sessione lunga: disco, riavvio a metà, cane da guardia, cache (FR-42, NFR-2, addendum)

Aggiungere ad AD-6 (emendamento):

> La Sessione lunga parte sempre con `--no-session-persistence`: il contesto vive solo nella memoria del processo `claude`. Se un riavvio (per `sessionMaxRequests`, timeout, blocco o cambio di impostazioni) cade durante una richiesta, `AgentRunner` la ripete nella nuova sessione solo se `effectfulCalls == 0` (stessa regola di AD-15); altrimenti restituisce `AgentError.stoppedMidway`. Il cane da guardia di `ClaudeCLI` termina un processo che non risponde entro `agentTimeout` e lo sostituisce; il Coordinator mostra «Riavvio l'Agente» una sola volta per episodio; ogni riavvio e ogni compattazione del contesto sono una riga `Log.info` con il motivo. Dopo un riavvio il primo turno riceve il blocco `<recent>` intero. Un cambio di modello o di effort di un livello in `AppSettings` riavvia la sessione di quel livello (la cache del prompt dipende da entrambi). La cache si rinnova solo con le richieste dell'utente: nessun ping o turno vuoto per tenerla calda. Il log della richiesta riporta i token letti dalla cache (`cache_read_input_tokens`).

### G2 — Il «sì» a voce e la chiamata bloccata (FR-51, FR-53, SM-C5)

Aggiungere ad AD-21:

> Una chiamata di strumento che ricade nell'elenco canonico e non ha un grant **non fallisce verso il Motore**: `AgentTools` la sospende, emette `PendingConfirmation(target, frase)` che il Coordinator mostra e dice, e attende. `RouterState` espone `pendingConfirmation: ConfirmationTarget?`; finché è presente, il Router instrada «sì»/«no» (e le varianti già usate da `Safety`) a `RouteDecision.confirm(answer)` prima di ogni altro caso, e nessuna altra Frase vale come risposta. Sul «sì» l'esecutore esegue e restituisce al Motore l'esito normale; sul «no» o allo scadere dell'attesa restituisce `RESULT: bloccato dall'utente` e il Motore prosegue o si ferma. La frase di conferma nomina sempre il bersaglio («Invio la mail a Laura?», «Elimino anche “Newsletter ottobre”?»).

Aggiungere alla riga `RouteDecision` delle convenzioni i casi `askIntent(text)` e `confirm(answer: Bool)`.

### G3 — Il blocco diventa uno scenario (FR-53, NFR-14, SM-C7)

Nuova riga nelle Consistency Conventions («Log di sicurezza»):

> Ogni azione bloccata dal gate o messa in dubbio dal classificatore produce una riga `Sicurezza: <bloccata|dubbio> · <app> · <etichetta o AXIdentifier> · <azione> · <effetto esterno> · <conferma sì/no/scaduta>`, con gli stessi campi di `Tests/bench/sicurezza.tsv`, così da poter essere copiata nella suite. Il Banco, sui compiti positivi, riporta per compito il numero di conferme chieste e di blocchi (SM-C5, SM-C7) e il numero di turni (SM-C6).

### G4 — Misura prima: riga di base e soglie (FR-41, NFR-12, NFR-13, SM-8, SM-C4, §4.9–§4.10)

Emendare AD-18:

> Prima della prima storia di ciascuna funzionalità di §4.9 e §4.10 il Banco gira sui compiti esistenti con il Motore Claude e la tabella viene pubblicata nella ricerca `technical-agente-…` come riga di base; ogni storia successiva riporta la stessa tabella «dopo». Le soglie di NFR-12 (primo strumento ≤ 1,5 s, compito ≤ 4,5 s, istantaneo ≤ 2,5 s) e NFR-13 (≥ 90% su app native e webmail) sono parametri di `--agent-bench`, che termina con codice ≠ 0 se la mediana peggiora rispetto alla riga di base o un compito della riga di base fallisce (SM-C4). FR-43, FR-46, FR-47 e FR-49 restano a condizione della riga di base: se la misura non conferma il beneficio, la storia si chiude senza integrare.

Aggiungere a `Binds` di AD-18: NFR-12, NFR-13, SM-8, SM-9 (Corpus), SM-10, SM-C4…SM-C7.

Aggiungere a FR-41 in AD-18: «La webmail usa un account di prova dedicato; se il Banco viene eseguito sull'account personale, esegue solo i compiti di osservazione e il log è ridotto ai tempi.»

### G5 — Livello istantaneo: seconda condizione e bersaglio unico (FR-43)

Emendare AD-6:

> La scalata `.instant → .fast` avviene al primo esito che non mostra il risultato atteso **oppure alla seconda chiamata di strumento**, e produce la riga `Log.info("Agente: istantaneo → rapido · <motivo>")`. Il Router decide «comando a un passo con bersaglio nominato» con `RouteHeuristics.hasKnownTarget`, la stessa funzione di AD-23: un'unica definizione di bersaglio per filtro delle spurie e scelta del livello.

### G6 — Lettura locale: Motore locale, riscaldamento, «basta» (FR-47, UJ-9)

Emendare AD-17: aggiungere `read_text` al sottoinsieme di strumenti del Motore locale (al posto di `screenshot`). Emendare AD-19:

> Il riscaldamento di Vision gira con priorità `.utility` dopo l'avvio di `SpeechEngine`, mai prima. Una `read_text` chiesta prima della fine del riscaldamento usa la modalità veloce e, se non risponde entro il tempo massimo, restituisce «testo non leggibile ora». `screenshot(region:)` sostituisce l'immagine con il testo quando Vision riporta almeno `ocrMinWords` parole con confidenza media ≥ `ocrMinConfidence` (valori in `AppSettings`); altrimenti allega entrambi.

Nel Seed: un solo file, `LocalText.swift`.

### G7 — Livelli di accesso: due semantiche di conferma e HUD (FR-54)

Emendare AD-22:

> `AccessLevel` distingue `.fullWithConfirmExternal` (conferma per ogni Azione con effetti esterni: Finder, compresi Cestino e trascinamenti fuori dalla finestra) da `.fullWithConfirmAll` (conferma per ogni Azione con effetti: Impostazioni di Sistema). Mentre l'Agente lavora l'HUD mostra il livello in vigore per l'app in primo piano con il nome che Nico capisce («solo clic», «con conferma»). AD-21 riconosce per costruzione anche i trascinamenti che escono dalla finestra del Finder.

### G8 — Diagnostica prima del fallimento (FR-45)

Emendare AD-14:

> `refreshAvailability` di `ClaudeCLI`, oltre alla versione, esegue all'avvio dell'app e al cambio di versione un avvio di prova (`claude -p` con richiesta vuota e timeout breve) e classifica l'esito: login dell'abbonamento presente, modalità «bare» rilevata, opzione sconosciuta. L'esito compare in Stato e diagnostica prima che arrivi una richiesta. La base di §4.9 (`--bare`, effort, durata della cache) ha una scadenza di rilettura (1° novembre 2026) registrata in Deferred.

### G9 — NFR-15 contro NFR-5: dichiarare la scelta

Emendare la riga «Reversibilità» delle convenzioni:

> Il PRD (NFR-15) chiede un interruttore per ogni funzionalità di §4.9–§4.11 e, in NFR-5, che nessuna impostazione possa aggirare la conferma legata all'azione. La spina risolve così: FR-42, FR-43, FR-44, FR-46, FR-47, FR-48, FR-55 hanno un interruttore con ripiego; FR-50, FR-51, FR-53 **non ne hanno** (sono il perimetro, NFR-5 prevale); FR-52 e FR-54 si regolano tramite l'elenco delle app, non con un interruttore globale. Da riportare nel PRD come correzione a NFR-15.

### G10 — Nomi, tempi, `<recent>` (Glossario, FR-46, FR-48)

- Riga «Nomi»: aggiungere `AgentLevel`, `ClaudeSession`, `ConfirmationGrant`, `ExecutorGate` (nome di tipo per «Gate dell'esecutore», in `Safety.swift`), `AccessLevel`, `PrivacyGuard`, `BenchPhase`, `RouteHeuristics`.
- Riga «Tempi»: aggiungere `askIntent` 8 s, `settle` 3 s / 6 s in caricamento, `read_text` 10 s, Sessione lunga 10 min di inattività e `sessionMaxRequests` 20, conferma dell'esecutore senza scadenza temporale.
- AD-4: «ogni voce di `ConversationLog` serializzata in `<recent>` è troncata a `recentMaxWords` parole (predefinito 300); la troncatura conserva richiesta ed esito e taglia il testo cambiato».

### G11 — Deferred da aggiungere

- Prova di tenuta di 8 ore della Sessione lunga col cane da guardia (Domanda 7): prima della chiusura dell'epic di §4.9.
- Clausola legale di Anthropic sul binario non modificato (Domanda 11): chiarimento in corso; FR-45 sorveglia i cambi.
- Consenso all'addestramento disattivato negli account Claude e ChatGPT dell'app (NFR-2): verifica manuale, non codice.
- Rilettura della base di §4.9 entro il 1° novembre 2026 e rivalutazione dei Motori entro aprile 2027 (§10).

## 3. Sovra-vincoli (regole della spina che il PRD non chiede)

| Dove | Regola | Valutazione |
| --- | --- | --- |
| AD-6 (originale, non emendata) | «entrambe riscaldate in anticipo» + `prewarm(level:)` con tre livelli → fino a tre processi `claude` residenti con sessione aperta. | Il PRD chiede «al massimo una Sessione lunga per livello», non che tutte siano sempre vive. Su M1 16 GB tre processi residenti pesano. Proposta: la sessione di un livello nasce alla prima richiesta di quel livello (lazy); si riscalda in anticipo solo il livello `.fast`. |
| AD-16 (em.) | Prescrive il meccanismo «`--mcp-config` in file temporaneo 0600 con token letto dall'ambiente, o via stdin». | Il PRD lega l'esito (stdin dove possibile, altrimenti ambiente, mai negli argomenti; `ps` non lo mostra). Il meccanismo del file temporaneo è una scelta di storia che potrebbe non reggere alla CLI verificata. Tenere l'esito, spostare il meccanismo nelle note della storia o segnarlo «se la CLI lo richiede». |
| Conventions «Reversibilità» | «nessun interruttore può disattivare AD-21 **o AD-22**» | Il PRD (FR-54) rende l'elenco delle app modificabile, quindi AD-22 è di fatto regolabile per app; FR-52 (campi sicuri) non ha interruttore nel PRD ma NFR-15 lo chiederebbe. Vedi G9: dichiarare la scelta invece di estendere il divieto a tutta AD-22. |
| AD-14 (em.) | «rileva un avvio “bare” come errore di avvio, non come errore del compito» | Più stretto del PRD, che vuole la rilevazione in diagnostica prima del fallimento. Non è un sovra-vincolo ma un vincolo diverso: vedi G8. |
| AD-22 | Livello unico `.fullWithConfirm` per Finder e Impostazioni di Sistema | Fonde due regole distinte del PRD (vedi G7); qui la spina lega *meno* del PRD per il Finder e *diversamente* per Impostazioni di Sistema. |
| Structural Seed | `Safety.swift … (estratto da LLMPlanner.swift)` | Prescrive una rifattorizzazione (dove estrarre) che il PRD non chiede. Innocuo, ma è una scelta di storia; basta «elenco canonico `externalEffect` e `ConfirmationGrant` in `Safety.swift`». |
| AD-19 (em.) | «la Memoria di conversazione conserva esito e testo cambiato, non osservazioni» | Chiesto da FR-46; nessun sovra-vincolo. Segnalato solo perché duplica AD-4: meglio che viva in AD-4 e AD-19 vi rimandi, così c'è un solo proprietario della forma di `<recent>`. |
| Stack | «claude-haiku-5-5 (7 ottobre 2026)» | La data accanto al modello non è una versione; se indica la data di rilascio va detto, altrimenti si confonde con una versione verificata. |

## 4. Verdetto sintetico

La spina lega la sostanza di §4.9–§4.11 e la mappa è completa per FR-41…FR-55. Le mancanze più pesanti sono tre qualità implicite del PRD che nessuna AD governa: la **disciplina «misura prima»** (riga di base, soglie NFR-12/13 come criteri del Banco, contro-metriche come colonne), il **percorso del «sì» a voce fino al grant** (senza il quale FR-51 non si può costruire in modo coerente tra Router ed esecutore) e la **retroazione dal log alla suite di sicurezza** (formato della riga di blocco). Vanno poi dichiarate due scelte oggi implicite: la risoluzione del conflitto NFR-15/NFR-5 e la semantica doppia dei livelli con conferma.
