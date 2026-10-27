---
review: avversario
target: ARCHITECTURE-SPINE.md (aggiornamento del 27/10 sera: AD-6, AD-14, AD-16, AD-18, AD-19, AD-21, AD-22, AD-23)
livello sotto: epic e storie di FR-41…FR-55 (PRD §4.9–§4.11)
data: 2026-10-27
verdetto: NON PRONTA — 1 coppia critica, 7 alte, 6 medie, 1 bassa
---

# Revisione avversaria della spina dorsale

**Metodo.** Per ogni AD modificata oggi ho costruito due unità del livello sotto (storie o componenti) che rispettano alla lettera il testo dell'AD e verificato se, costruite separatamente, si incastrano. Dove non si incastrano c'è un buco da chiudere con un'AD nuova o più stretta. Il codice in `Sources/MacTalkAct/` è usato per radicare l'attacco: dove una storia «vince» per inerzia perché il codice già fa così, lo dico.

**Verdetto.** La spina dorsale va emendata prima di scrivere le storie di §4.9–§4.11. Le tre aree più fragili sono: (1) le app riservate hanno tre comportamenti diversi in tre AD; (2) la conferma ha oggi tre proprietari del tempo e tre stati «in attesa», e il nuovo `ConfirmationGrant` ne aggiunge un quarto senza eliminare gli altri; (3) la scalata istantaneo→rapido e la Sessione lunga sono descritte come se il turno fosse interrompibile dal di dentro, ma `engine.run` è atomico e `AgentTools` non ha un canale verso `AgentRunner`.

Conteggio: **15 coppie** — 1 critica, 7 alte, 6 medie, 1 bassa.

---

## Coppia 1 — App riservata: processo dedicato, `.none` o solo Motore locale? [CRITICA]

**Unità A — Storia «Sessione lunga» (AD-6, FR-42).** Legge: «una richiesta privata o su app riservata usa un processo dedicato chiuso alla fine». Implementa in `ClaudeEngine` un ramo che, quando `PrivacyGuard` segnala app riservata o modalità privata, spawna un processo `claude` dedicato, lo usa per la richiesta e lo chiude. Claude lavora sull'app riservata, fuori dalla Sessione lunga. Obbedisce all'AD-6 alla lettera.

**Unità B — Storia «Livelli di accesso» (AD-22, FR-54).** Legge: `AccessLevel.none` «per app e siti riservati» e «ogni esecuzione che passa dall'esecutore rispetta il livello». Implementa in `AgentTools.perform` e `Executor` un rifiuto di ogni strumento (osservare incluso, perché `.none` è «niente») quando il livello è `.none`. Nessun Motore, nemmeno quello locale, tocca l'app riservata. Obbedisce all'AD-22 alla lettera.

**Unità C — Il codice di oggi.** `AgentRunner.run` forza `chosenEngine = .local` e `fallbackOn = false` quando `PrivacyGuard.cloudBlockReason() != nil`; `AgentTools.call` blocca ogni strumento al Motore cloud con `privateWindowError`. L'app riservata è lavorabile dal solo Motore locale.

**Dove si scontrano.** Tre comportamenti incompatibili per lo stesso evento: Claude in processo dedicato (A), nessuno (B), solo locale (C). La storia A manderebbe al cloud lo schermo di 1Password; la storia B toglierebbe al modello locale un'app che oggi può usare (e il PRD §4.11 non chiede di toglierla: la tabella di FR-54 dice «niente» ma la riga nasce dall'«elenco esistente», che oggi è un blocco del *cloud*). Inoltre `.none` rende inutile il processo dedicato per app riservata di AD-6: resta valido solo per la modalità privata, che però oggi forza `.local` (riga 272 di `AgentRunner`): anche lì il processo Claude dedicato non verrebbe mai usato. L'AD-6 descrive un ramo morto.

**AD che chiude (AD-22 riscritta, AD-6 corretta).**
> `AccessLevel` ha un asse in più: *chi* può agire. `.none` significa «nessun Motore cloud vede né tocca la finestra; il Motore locale lavora con il livello `.fullWithConfirm`». La fonte è una sola, `PrivacyGuard.accessLevel(for pid:, engine: EngineID) -> AccessLevel`, e `cloudBlockReason()` ne diventa una vista derivata (`accessLevel(…, engine: .claude) == .none`). AD-6: il «processo dedicato» esiste **solo per la modalità privata quando l'utente ha scelto esplicitamente di tenere il cloud in modalità privata** (impostazione `privateModeKeepsCloud`, predefinita *off*); con l'impostazione predefinita una richiesta privata o riservata va al Motore locale, come oggi. Il testo «una richiesta privata o su app riservata usa un processo dedicato» viene rimosso.

---

## Coppia 2 — Chi possiede il tempo del turno mentre si aspetta una conferma [ALTA]

**Unità A — Storia «Sessione lunga con cane da guardia» (AD-6, FR-42).** Implementa in `ClaudeCLI` un turno con tempo massimo `agentTimeout` (oggi 240 s: `withThrowingTaskGroup` + `Task.sleep`), e il cane da guardia che, scaduto il tempo, termina il processo, riavvia la sessione e mostra «Riavvio l'Agente». `ClaudeCLI` non sa nulla di conferme: è sotto `AgentEngine`, che per AD-13 «non chiama mai HUD, Coordinator o Executor».

**Unità B — Storia «ConfirmationGrant» (AD-21, FR-51).** Legge: «l'attesa sospende il tempo massimo del turno». Implementa in `AgentTools.confirm` una chiamata a `askUser` che attende `agentQuestionSeconds` (25 s) la voce dell'utente; per «sospendere il turno» espone un `onWaitingForUser(Bool)`.

**Dove si scontrano.** Nessuno dei due possiede il contatore dell'altro. Il tempo del turno vive in `ClaudeCLI` (strato Motore), l'attesa in `AgentTools`/`Coordinator` (strato strumenti). Perché B sospenda il contatore di A serve un canale `AgentTools → AgentRunner → ClaudeEngine → ClaudeCLI` che nessuna AD nomina, e che AD-13 di fatto vieta nella direzione opposta. Costruite separatamente: il cane da guardia uccide la sessione nel mezzo di una conferma lunga (utente che ha il bambino in braccio e risponde tardi), l'HUD dice «Riavvio l'Agente» mentre mostra ancora «Di' sì», e la risposta «sì» arriva a un `agentQuestion` la cui richiesta è morta. Inoltre oggi esistono già **tre** stati «in attesa di conferma» con tre durate: `Coordinator.pending` (`PendingPlan`, 20 s, usato da pianificatore API e Corsia locale `.keys(confirm:)`), `Coordinator.agentQuestion` (25 s, strumenti `confirm`/`ask_user`) e `AgentTools.confirmedUntil` (45 s, da rimuovere). Il Router vede solo il primo (`RouterState.pendingConfirmation`). Il grant ne aggiunge un quarto se la storia B non li unifica.

**AD che chiude (AD-21 stretta + nuova AD-24).**
> **AD-24 — Un solo orologio del turno, pausabile.** `AgentRunner` possiede `TurnClock` (avvio, pausa, ripresa, scadenza), unico contatore del tempo massimo di un turno. I Motori ricevono la scadenza come `Deadline` nel `AgentRequest` e la rispettano senza tenerne uno proprio; il cane da guardia di `ClaudeCLI` scatta solo su `Deadline` superata **e** processo senza output da `watchdogGrace` secondi. `AgentTools.confirm` e `ask_user` chiamano `TurnClock.pause()` prima di `askUser` e `resume()` dopo. L'attesa stessa ha il proprio limite (`agentQuestionSeconds`) e, scaduto, vale «negato».
> **AD-21 stretta:** esiste un solo stato «domanda in attesa» nel Coordinator, `PendingQuestion` (`enum`: `.grant(ConfirmationGrant)`, `.openQuestion`, `.intent` di AD-23, `.proposedText`); `RouterState.pendingQuestion` lo riporta e il Router produce `.answer(text)`; il Coordinator lo consegna al proprietario. `Coordinator.pending`/`PendingPlan`, `confirmationSeconds` e `confirmedUntil` vengono rimossi; la Corsia locale `.keys(confirm:)` passa dal grant.

---

## Coppia 3 — Il gate dell'esecutore contro il Comando rapido «invio» e la Dettatura [ALTA]

**Unità A — Storia «Gate dell'esecutore» (AD-21, FR-53).** Legge: «l'esecutore (`AgentTools.perform` **e** `Executor`) riconosce per costruzione l'Invio in un campo di composizione, le scorciatoie che inviano o eliminano». Implementa il riconoscimento in `Executor.press`/`pressSequence`: se il tasto è Return e il focus è in un campo di composizione (chat, mail, modulo), serve un grant. È il punto più basso, dunque il più sicuro: lo attraversano Agente, Corsia locale, pianificatore API.

**Unità B — Comandi rapidi e Dettatura (AD-1, grammatica fissa, invariati).** «Computer, invio» è un Comando rapido della grammatica (`Grammar.parse` → `.fast`) che chiama `Executor.press("return")`; la Dettatura chiude con «a capo»/«invio» nello stesso modo. L'utente lo dice apposta per mandare il messaggio in chat. Nessuna storia prevede una conferma: è la volontà esplicita dell'utente.

**Dove si scontrano.** Con A nell'`Executor`, ogni «invio» detto a voce in una chat chiede «Confermi?», rompendo il comportamento di prima (NFR-6) e raddoppiando i turni del caso d'uso principale. Con A solo in `AgentTools.perform`, il gate lascia scoperti la Corsia locale (che chiama `executor.press` direttamente in `Coordinator.runLocal`) e il pianificatore API (`Coordinator.execute` → `executor.run(step)`), contraddicendo «indipendentemente dal Motore». L'AD non dice da **chi** proviene l'azione.

**AD che chiude (AD-21 stretta).**
> Ogni chiamata all'`Executor` porta un `ActionOrigin` (`.user` per Comandi rapidi della grammatica fissa, Dettatura e numeri sullo schermo; `.model(EngineID)` per Agente, Corsia locale e pianificatore). Il gate di AD-21 si applica a `.model`; `.user` non chiede mai conferma perché la Frase stessa è la conferma. Il livello di accesso di AD-22 si applica a `.model` e alla Corsia locale, non a `.user` quando l'azione è Dettatura (coerente con «la Dettatura no»). `Executor` rifiuta chiamate senza origine (nessun predefinito).

---

## Coppia 4 — `ConfirmationGrant` contro `act` e `click_many` [ALTA]

**Unità A — Storia «ConfirmationGrant» (AD-21).** Legge: `target` è «l'id dell'elemento con l'azione oppure l'indice del passo della serie»; «una serie con due Azioni con effetti esterni ne chiede due». Implementa: il Motore chiama `confirm(target: .step(3))` e `confirm(target: .step(5))` **prima** di `act`, poi `act` consuma i due grant ai passi 3 e 5.

**Unità B — Storia «`act` serie» (AD-20) e «esecutore esegue dopo il sì» (AD-21).** Legge: `act` «esegue una serie chiamando `dispatch` per ogni passo, si ferma al primo errore e calcola l'esito una volta sola alla fine»; e «dopo il “sì” l'azione la esegue l'esecutore, senza tornare al Motore». Implementa: `act` arriva al passo 3, riconosce l'effetto esterno, **si ferma e chiede** «Elimino anche “Newsletter ottobre”?» (il PRD vuole la domanda formulata con il bersaglio, che al momento del `confirm` anticipato il Motore non conosce ancora), poi prosegue da sé.

**Dove si scontrano.**
1. *Indice del passo.* In A il grant nasce prima della serie e punta a un indice futuro: se il Motore riordina o il passo 2 fallisce (la serie «si ferma al primo errore»), l'indice 3 non corrisponde più a nulla o a un'azione diversa. In B l'indice è certo perché la domanda nasce durante l'esecuzione.
2. *`click_many` dentro `act`.* `actSteps` include `click_many`; un passo `click_many(ids: [4,5,6])` con `[5]` = «Elimina»: il target è il passo (A) o l'elemento 5 (B)? Le due storie leggono l'AD in modo opposto e il grant di una non viene riconosciuto dall'altra.
3. *«Decade quando l'esito segnala che l'elemento è cambiato».* Dentro `act` non c'è esito tra i passi (AD-20: uno solo alla fine), quindi un grant su `.step(5)` non può decadere anche se il passo 2 ha cambiato pagina.
4. *«Senza tornare al Motore».* Oggi `confirm` è uno strumento: la risposta «approved» torna al Motore che poi chiama `click`. Se l'esecutore esegue da sé dopo il «sì», il risultato di `confirm` deve contenere l'esito dell'azione e il Motore non deve richiamare `click`, altrimenti doppio invio. Nessuna AD lo dice.

**AD che chiude (AD-21 stretta).**
> Il grant ha come bersaglio **solo** un elemento (`id` con generazione) o una scorciatoia (`keys` + `pid` + identità del campo focalizzato); il passo di una serie non è un bersaglio. `act` e `click_many` non ricevono grant anticipati: quando un passo ricade in un'Azione con effetti esterni e non ha grant, l'esecutore sospende la serie, chiede con il bersaglio («Elimino “X”?»), e su «sì» **esegue quel passo e prosegue**; su «no» la serie si ferma lì e il risultato elenca i passi non eseguiti. `confirm(target:)` chiamato dal Motore esegue a sua volta l'azione dentro l'esecutore e restituisce `RESULT` dell'azione: il Motore non la ripete; il prompt lo dice. Un grant decade al cambio di generazione dell'elemento, oltre che a fine richiesta.

---

## Coppia 5 — `.unverified(version)` come stato di disponibilità [ALTA]

**Unità A — Storia «CLI sorvegliate» (AD-14 emendata, FR-45).** Legge: «`refreshAvailability` … produce lo stato `.unverified(version)`». Aggiunge il caso `unverified(String)` a `AgentAvailability`, perché è lì che `refreshAvailability` scrive.

**Unità B — `EngineSelector` (AD-14, funzione pura, già in codice).** `select` accetta un Motore solo se `engines[id] == .available`; tutto il resto è scartato e produce `.reduced` nel Router (AD-7: «`.reduced` solo quando nessun Motore è utilizzabile»).

**Dove si scontrano.** Con A, una versione non verificata di `claude` rende Claude **non selezionabile**: il selettore passa a Codex o al locale, il Router può andare in Modalità ridotta. Il PRD e l'AD dicono il contrario: «l'Agente funziona con un processo per richiesta e lo dice». La storia B non ha nulla da cambiare e vince per inerzia: il Motore sparisce.

**AD che chiude (AD-14 stretta).**
> La verifica della versione **non è** un caso di `AgentAvailability`. Ogni Motore CLI espone `cliStatus: CLIStatus` (`.verified(version)`, `.unverified(version)`, `.belowMinimum(version)`), separato da `availability`. `.belowMinimum` pone `availability = .unavailable("versione X troppo vecchia")`; `.unverified` lascia `availability` intatta e forza `sessionMode = .perRequest`. Stato e diagnostica mostra entrambi. `EngineSelector` non legge `cliStatus`.

---

## Coppia 6 — `.askIntent` arma la conversazione e riapre la porta alle Frasi spurie [ALTA]

**Unità A — Storia «Frasi spurie» (AD-23, FR-48).** Implementa `.askIntent` come fa oggi ogni domanda dell'app: `hud.show(.confirm, "Vuoi che faccia qualcosa?")` e `conversation.arm(seconds: 8)`, com'è in `askByVoice` (`conversation.arm(seconds: wait)`) e nel «clarify» del pianificatore (`conversation.arm(seconds: 15)`). È il pattern del codice: una domanda arma, così la risposta non ha bisogno della Parola di attivazione.

**Unità B — Il Router (AD-23, stesso testo).** «Le Frasi con Parola di attivazione o in push-to-talk non cambiano percorso». In `decide`, `explicit = pushToTalk || wakeRest != nil || state.armed || session`. Una Frase **armata** è esplicita e salta il filtro.

**Dove si scontrano.** La seconda Frase spuria, arrivata negli 8 s dopo la domanda («statico», rumore del riconoscimento), è armata → esplicita → salta il filtro → va all'Agente. Il filtro ha trasformato una Frase spuria in due, la seconda delle quali occupa il Motore cloud: esattamente ciò che AD-23 vuole impedire. Entrambe le storie obbediscono al testo.

**AD che chiude (AD-23 stretta).**
> `.askIntent` **non arma** la conversazione: registra `PendingQuestion.intent(original:)` (vedi Coppia 2) e il Router, finché è pendente, tratta la Frase successiva così: se è un «sì»/«no» o un'altra Frase che il filtro giudica spuria, produce `.ignore` e chiude la domanda; se ha un bersaglio noto o più di tre parole, è la richiesta vera e viene instradata come se avesse la Parola di attivazione. La domanda non estende la Finestra di conversazione. Nel Corpus: dopo `askIntent`, «statico» → `ignore`; «apri la mail di Laura» → `agent`.

---

## Coppia 7 — Dove si applica `AccessLevel`: `AgentTools`, `Executor` o entrambi; e cosa vede il cloud di un terminale [ALTA]

**Unità A — Storia «Livelli di accesso» (AD-22).** Mette il controllo in `AgentTools.perform`, come oggi `cloudBlockReason`: è dove passano gli strumenti di tutti i Motori. «Ogni esecuzione che passa dall'esecutore (Agente, Corsia locale)» → la Corsia locale passa dall'esecutore… ma `Coordinator.runLocal` chiama `executor.press`/`openApp` **senza** `AgentTools`. Il livello non la tocca.

**Unità B — Stessa storia, altra lettura.** Mette il controllo in `Executor` (press, typeText, click, paste): vale per tutti. Ma `Executor.insertDictation` e `paste` sono anche la Dettatura, che l'AD esclude: la storia aggiunge una variabile `isDictating` nell'`Executor`, cioè uno stato nascosto che un'altra storia non conosce.

**Unità C — «Terminal `.clickOnly`, escluso dagli screenshot ai Motori cloud».** La storia esclude `screenshot`. Ma `AgentRunner.run` manda al cloud `tools.initialObservation()` (gli elementi della finestra con il loro testo: in Terminal è il contenuto del terminale), `observe` lo rimanda, `get_text` legge l'output, e il nuovo `read_text(region)` (AD-19) lo legge con Vision. Lo screenshot era il canale meno informativo: quello escluso. Il motivo dell'AD («screenshot di un terminale inviati al cloud») è protetto solo a parole.

**Dove si scontrano.** A e B pongono il gate a due livelli diversi, con due elenchi di eccezioni diversi; chi implementa la Corsia locale non sa quale vale. C mostra che `.clickOnly` ha due letture: «niente input» (A, B) o «niente lettura verso il cloud» (il motivo dell'AD).

**AD che chiude (AD-22 stretta).**
> Il controllo vive in un solo punto, `AccessGate.check(action: ActionKind, origin: ActionOrigin, pid:) throws`, chiamato da `AgentTools.perform` **e** da `Coordinator.runLocal` prima di toccare l'`Executor`; l'`Executor` resta cieco e la Dettatura (`origin: .user`) non lo chiama. `AccessLevel` ha due assi: *input* (`.none`, `.clickOnly`, `.fullWithConfirm`, `.full`) e *lettura verso il cloud* (`.visible`, `.structureOnly`, `.hidden`). Terminal e iTerm: input `.clickOnly`, lettura `.structureOnly` (ruoli e etichette senza il valore dei testi: `observe`, `initialObservation`, `get_text`, `read_text` e `screenshot` restituiscono al Motore cloud «(terminal content hidden)»); il Motore locale li legge. Il livello è calcolato **per chiamata** sull'app in primo piano (come `cloudBlockReason`), non per richiesta: l'Agente che apre Terminal a metà compito cambia livello alla chiamata successiva.

---

## Coppia 8 — La scalata istantaneo→rapido non ha un meccanismo di interruzione [ALTA]

**Unità A — Storia «Livello istantaneo» (AD-6, FR-43).** Legge: «l'esecutore giudica l'esito con una regola … e `AgentRunner` sale a `.fast` passando richiesta, azioni eseguite con esito ed elementi attuali». Implementa: `AgentTools.outcome()` riconosce `nothing changed`/bersaglio non cambiato, imposta `escalationRequested = true`, e `AgentRunner`, finito `engine.run`, se il flag è alzato rilancia su `.fast`. Semplice: nessun canale nuovo.

**Unità B — Storia «Sessione lunga» (AD-6, FR-42).** `engine.run(req)` è **un turno atomico** del processo `claude`: ritorna solo quando il modello risponde. Se il flag di A viene letto solo alla fine, il modello istantaneo intanto ha ricevuto «nothing changed … try another way» e **continua da sé** (il prompt glielo dice: «Never repeat the same failing action… try another way») chiamando altri strumenti, forse con effetti, prima di rispondere. La «scalata» arriva dopo che Haiku ha già fatto il lavoro del rapido, male. Se invece A interrompe il turno (cancel del processo), nella Sessione lunga istantanea il turno troncato lascia la sessione in uno stato indefinito: per la regola «un turno supera `agentTimeout` → riavvio» la storia B lo tratta come turno da riavviare (costo: la cache del prompt istantaneo si perde a ogni scalata), oppure no, e la sessione contiene mezzo turno.

**Altri incastri mancanti nella stessa coppia.**
- PRD FR-43 dice anche «**o alla seconda chiamata di strumento**»; AD-6 lo omette. Una storia conta le chiamate, l'altra no.
- `AgentRunner.run` fa `tools.reset()` all'inizio: la scalata è una seconda `run` o la stessa? Se seconda, `effectfulCalls`, registro degli elementi e grant si azzerano e il rapido può ripetere l'Azione con effetti (contro AD-15 e AD-6); se la stessa, serve `reset(keepElements:)` più un trasferimento di `effectfulCalls`, `changes` e grant. AD-21 dice che il grant «vale nella stessa richiesta»: la scalata è la stessa richiesta?
- Il Router sceglie `.instant`; con Claude in pausa `EngineSelector` passa a Codex, che «non ha livello `.instant`»: `CodexEngine.model(for: .instant)` è indefinito. Una storia lo fa fallire, l'altra lo mappa su `.fast`.

**AD che chiude (AD-6 stretta).**
> La scalata è un'operazione di `AgentRunner`, non dell'esecutore: `AgentTools` non decide, segnala. Dopo ogni strumento `AgentTools` emette `ToolEvent(name, effectful, outcomeKind: .changed | .nothingChanged | .targetUnchanged(id) | .blocked)`. `AgentRunner`, al livello `.instant`, sale a `.fast` quando riceve il **primo** `nothingChanged`/`targetUnchanged` o il **secondo** `ToolEvent` di qualsiasi tipo: chiama `engine.cancel()` sul turno in corso e, per la Sessione lunga, `ClaudeCLI` tratta un turno annullato dall'app come «turno chiuso senza risposta» (la sessione resta valida; `--input-format stream-json` consente il turno successivo) senza riavvio. La scalata è **la stessa richiesta**: `tools.reset` non viene chiamato; `effectfulCalls`, registro, generazione, `changes` e grant pendenti passano intatti; il messaggio del rapido contiene `<handoff>` con le azioni eseguite e il loro `RESULT`. `AgentLevel.instant` è valido solo per `EngineID.claude`: `EngineSelector.select(level:)` riceve il livello e per ogni altro Motore lo rimappa a `.fast`, scrivendo il motivo nell'`EngineChoice.reason`.

---

## Coppia 9 — Il classificatore «in parallelo a `settle()`» non può bloccare nulla [MEDIA]

**Unità A — Storia «Classificatore come secondo strato» (AD-21, FR-55).** Legge: «valuta le Azioni con effetti non già bloccate, **in parallelo a `settle()`**». `settle()` gira **dopo** che l'azione è stata eseguita (`AgentTools.call`: `perform` → `settle` → `outcome`). La storia implementa il classificatore lì: valuta l'azione appena fatta e, se la giudica con effetti esterni, scrive nel log e… l'azione è già partita. Al massimo «impone una conferma» alla **successiva** azione dello stesso tipo, cosa che l'AD non dice.

**Unità B — Stessa storia, lettura «deve bloccare».** «Se le giudica con effetti esterni impone una conferma»: per imporla deve valutare **prima** di `perform`. La storia mette la chiamata al modello Apple prima dell'azione: ~0,3–1 s in serie su ogni Azione con effetti (il classificatore ha timeout 1,0 s per AD-2), contro NFR-12 e contro la lettura «in parallelo» di A.

**Dove si scontrano.** Due posizioni nel ciclo, due semantiche (post-azione = solo log; pre-azione = gate con latenza). E per AD-18 la fase «classificatore di sicurezza» va nel Banco con «la somma delle fasi coincide con il totale entro 0,2 s»: una fase parallela non si somma, una seriale sì. Il Banco della storia A e quello della storia B producono colonne diverse.

**AD che chiude (AD-21 stretta).**
> Il classificatore valuta **prima** dell'azione e solo per gli strumenti con effetti che il gate per costruzione/riconoscimento non ha già fermato; gira in parallelo non a `settle()` dell'azione corrente ma al **recupero degli argomenti** (risoluzione dell'id, frame, label) e ha tempo massimo 300 ms, poi «nessun parere». La sua latenza è una fase seriale del Banco. Il parallelismo con `settle()` è rimosso dal testo.

---

## Coppia 10 — Le fasi del Banco: chi marca cosa, e `act` [MEDIA]

**Unità A — Storia «Banco con fasi» (AD-18, FR-41).** Legge: «`AgentTools` e `AgentRunner` emettono marche temporali per fase». Implementa `BenchPhase` in questi due. Le fasi «avvio o riuso della sessione», «connessione MCP», «primo token» sono però visibili solo in `ClaudeCLI`/`CodexCLI` (l'evento `system/init` con `mcp_servers`, il primo `assistant` dello stream): la storia le stima da fuori (inizio di `engine.run` → prima chiamata di strumento), sommandole in una fase sola.

**Unità B — Storia «Sessione lunga» (AD-6).** Vuole distinguere «riuso» da «avvio» e misurare la cache del prompt (FR-42: «token letti dalla cache maggiore di zero»). Solo `ClaudeCLI` lo sa; per AD-13 i Motori «non chiamano mai HUD, Coordinator o Executor» e nulla dice che possano emettere eventi verso `AgentRunner`. La storia aggiunge un `onPhase` al protocollo `AgentEngine` che A non si aspetta.

**Dove si scontrano.** Due fonti di fasi con nomi e confini diversi; la somma «entro 0,2 s» fallisce se A stima e B misura. In più: (i) `act` esegue N passi con **un** `settle` alla fine (AD-20) mentre FR-41 vuole «ogni azione con la sua attesa di assestamento»: la storia fasi registra 1 azione o N? (ii) `click_many` idem. (iii) Nessuna AD fissa l'orologio: `Date()` (già usato in `AgentTools.firstCallAt`) o monotono (`ContinuousClock`); con regolazione dell'ora o sospensione la somma non torna.

**AD che chiude (AD-18 stretta + AD-13 ampliata).**
> `AgentEngine` espone `onPhase: ((BenchPhase, ContinuousClock.Instant) -> Void)?`; i Motori emettono `.sessionStart`/`.sessionReuse`, `.mcpConnected`, `.firstToken` e `.cacheReadTokens(n)`; `AgentTools` emette `.toolStart(name)`, `.settled`, `.classifier`; `AgentRunner` `.requestStart`, `.finalTurn`, `.closed`. Unico orologio `ContinuousClock`. Dentro `act` e `click_many` ogni passo emette `.toolStart` e l'unico `settle` finale è attribuito all'ultimo passo. Il Banco somma per fase e verifica la differenza dal totale entro 0,2 s.

---

## Coppia 11 — La Memoria di conversazione «a differenza» per sessione contro cap, scadenza e modalità privata [MEDIA]

**Unità A — Storia «Sessione lunga» (AD-6).** «A ogni turno la sessione riceve solo le voci della Memoria aggiunte dopo il suo turno precedente». Implementa un cursore per livello: `lastDeliveredIndex` o `lastDeliveredTime` sulle `entries` di `ConversationLog`.

**Unità B — `ConversationLog` (AD-4, già in codice).** `maxEntries` = 5 (`removeFirst` quando si supera), `expire()` cancella **tutto** se l'ultima voce è più vecchia di 10 min, `clear()` su «dimentica», `add` è un no-op in modalità privata, e `Coordinator.setPrivateMode(false)`/fine timer chiama `clear()` (righe 981, 997).

**Dove si scontrano.**
- Indice: `removeFirst` sposta gli indici → il cursore punta alla voce sbagliata. Tempo: due voci nello stesso secondo (Corsia locale + Agente) e la seconda si perde o si duplica.
- Cap: se tra due turni della sessione profonda sono entrate 7 voci (rapide, locali), la sessione ne riceve 5: la differenza promessa non esiste più.
- Scadenza: il log svuota dopo 10 min dall'ultima voce; la sessione si riavvia dopo 10 min di **inattività propria**. Una sessione rapida usata ogni 9 min non si riavvia mai e accumula ore di contesto; il log intanto ha cancellato tutto. «Dopo un riavvio riceve il blocco intero» non basta: senza riavvio la sessione conosce cose che il log ha dimenticato, e «dimentica la conversazione» riavvia le sessioni ma l'**uscita** dalla modalità privata (che pure fa `clear()`) non è elencata in AD-6: le sessioni restano con il contesto di prima della modalità privata mentre il log è vuoto.

**AD che chiude (AD-4 e AD-6 strette).**
> Ogni `Entry` di `ConversationLog` ha un `id: UInt64` monotono mai riusato; il cursore della sessione è l'`id` dell'ultima voce consegnata. `ConversationLog` tiene, oltre alle `maxEntries` visibili, le voci non ancora consegnate ad almeno una sessione viva (al massimo `maxEntries × livelli`). Ogni `clear()` del log (dimentica, ingresso **e uscita** dalla modalità privata, scadenza dei 10 min) emette `onCleared` e `AgentRunner` riavvia tutte le Sessioni lunghe: il contesto di una sessione non sopravvive mai al log. Una sessione si riavvia anche dopo `sessionMaxAge` (predefinito 30 min dall'avvio), non solo per inattività.

---

## Coppia 12 — Campi sicuri contro Dettatura, `InsertionJournal` ed Electron [MEDIA]

**Unità A — Storia «Campi sicuri» (AD-22, FR-52).** «`type_text` restituisce un errore» su un campo sicuro. Implementa il blocco in `Executor.typeText`/`paste`, perché è lì che il testo viene scritto, da chiunque. Risultato: la Dettatura in un campo password fallisce («la Dettatura no» riguarda i *livelli*, non i campi sicuri: la storia lo legge così). Chi ha le mani occupate e vuole dettare una password resta bloccato; e se invece la storia lascia passare la Dettatura, `InsertionJournal.record` (AD-5) salva **la password in chiaro** in `last.text` e `textAfter` per 10 min, e «cancella quello che hai scritto» la ricompone.

**Unità B — Storia «Osservazione a costo fisso» (AD-19, FR-44).** Per Electron/Chromium imposta `AXManualAccessibility` e **attende** che l'albero si popoli. Nel frattempo sottoruoli e valori non sono ancora disponibili: «se la lettura del sottoruolo fallisce, un campo di testo a riga singola è trattato come sicuro» (AD-22) → tutti i campi del modulo diventano sicuri → `type_text` rifiuta tutto → l'Agente non compila nessun modulo in Slack/VS Code finché l'albero non è pieno. Due regole prudenti si sommano in un'app che non lavora.

**AD che chiude (AD-22 e AD-5 strette).**
> Il blocco dei campi sicuri vive in `AccessGate` (Coppia 7) per `origin: .model`; la Dettatura (`origin: .user`) può scrivere in un campo sicuro ma `InsertionJournal` **non registra** l'inserimento (`record` salta se `context.isSecure`) e `undoLastInsertion` risponde «non registro ciò che scrivo nei campi password». Il ripiego «sottoruolo illeggibile → sicuro» si applica solo quando `AXSubrole` restituisce errore **dopo** che `scan` ha dichiarato l'albero popolato (`treeReady`), mai durante l'attesa di `AXManualAccessibility`; durante l'attesa `type_text` risponde «albero non pronto, riprova» (errore recuperabile, non «campo sicuro»).

---

## Coppia 13 — Timeout del classificatore: `askToType` o `askIntent`? [MEDIA]

**Unità A — AD-2 (già in codice).** Timeout del classificatore → `.uncertain`; in un campo editabile il Router produce `.askToType(text, "incerto")` → HUD «Di' “scrivilo”», `proposedText` 8 s.

**Unità B — AD-23.** «Lo stesso [`.askIntent`] quando `OnDeviceClassifier` supera il tempo massimo su una Frase senza Parola di attivazione» → HUD «Vuoi che faccia qualcosa?», 8 s.

**Dove si scontrano.** Stessa Frase, stesso timeout, campo editabile e Finestra aperta: due domande diverse con due stati pendenti diversi (`proposedText` e il nuovo pendente di AD-23). La storia AD-23 aggiunge il ramo prima o dopo quello di AD-2? Il Corpus non può dare un esito atteso.

**AD che chiude (AD-23 stretta).**
> In un campo editabile il timeout del classificatore resta `.askToType` (AD-2 ha la precedenza: scrivere è reversibile per AD-5). Fuori da un campo editabile, timeout senza Parola di attivazione → `.askIntent`. Il Corpus ha una riga per ciascun caso.

---

## Coppia 14 — L'oracolo della suite di sicurezza è il gate stesso [MEDIA]

**Unità A — Storia «Suite di sicurezza» (AD-18, NFR-14).** «Termina con errore alla prima Azione con effetti esterni eseguita senza conferma». Implementa l'oracolo leggendo il log del gate (AD-21: «ogni blocco va nel log») e `effectfulCalls`: se il gate ha registrato il blocco, lo scenario passa.

**Unità B — Storia «Gate dell'esecutore» (AD-21).** È il componente sotto prova. Se ha un buco (pulsante con sola icona non riconosciuto), **non** registra nulla: il log è pulito, `effectfulCalls` cresce di 1 come per un clic innocuo, e la suite di A dice «passato» proprio nel caso che doveva scoprire.

**AD che chiude (AD-18 stretta).**
> L'oracolo della suite è lo **stato della pagina o dell'app**, mai il log del gate: ogni pagina di `Tests/bench/pages/` per la suite espone un contatore `data-external-effects` incrementato dal gestore dell'evento (submit, delete, pay); le app native usano i dati di prova (la mail di prova è ancora in Bozze; l'evento di prova esiste). Lo scenario fallisce se il contatore cambia senza un grant consumato per quel bersaglio; il log del gate è evidenza aggiuntiva, non verdetto.

---

## Coppia 15 — Token e file di configurazione MCP contro la vita lunga dei processi [BASSA]

**Unità A — Storia «Server chiuso» (AD-16, FR-50).** Scrive `--mcp-config` in un file temporaneo 0600 con il token letto dall'ambiente, e lo **cancella** subito dopo l'avvio del processo (il file è un segreto da non lasciare in giro).

**Unità B — Storia «Sessione lunga» (AD-6).** Il processo vive 10 min e oltre, si riavvia da solo (cane da guardia), e l'`AgentRunner.start()` ricrea `MCPServer` solo se `server == nil`: un server che cade e riparte cambia porta ma non token (`let token`), mentre le sessioni tengono l'URL vecchio nel file che A ha già cancellato o nel processo in memoria.

**Dove si scontrano.** Il riavvio della sessione da parte di B rilegge un file che A ha cancellato → avvio fallito «bare»/senza strumenti, che per AD-14 è «errore di avvio». E un riavvio del server lascia tutte le sessioni collegate a una porta morta senza che nessuna AD dica chi le invalida.

**AD che chiude (AD-16 stretta).**
> Il file di configurazione è generato **a ogni spawn** da `ClaudeCLI.spawn` e cancellato dopo l'evento `system/init` (connessione MCP riuscita) o dopo 10 s; il token è letto da `MCPServer.token` al momento dello spawn. `MCPServer` è l'unico a sapere di essere ripartito: emette `onRestart` e `AgentRunner` chiude tutte le Sessioni lunghe (ripartiranno al prossimo turno, col nuovo URL e un nuovo token: il token è ruotato a ogni avvio del server).

---

## Riepilogo per gravità

| # | Coppia | Gravità | AD toccate |
|---|---|---|---|
| 1 | App riservata: processo dedicato / `.none` / solo locale | **Critica** | AD-6, AD-22 |
| 2 | Orologio del turno contro attesa di conferma; quattro stati «in attesa» | Alta | AD-6, AD-21, nuova AD-24 |
| 3 | Gate nell'`Executor` contro Comando rapido «invio» e Dettatura | Alta | AD-21 |
| 4 | `ConfirmationGrant` contro `act` e `click_many` | Alta | AD-20, AD-21 |
| 5 | `.unverified` come `AgentAvailability` esclude il Motore | Alta | AD-14, AD-7 |
| 6 | `.askIntent` arma e riapre la porta alle Frasi spurie | Alta | AD-23 |
| 7 | Punto di applicazione di `AccessLevel`; terminale letto dal cloud | Alta | AD-22, AD-19 |
| 8 | Scalata istantaneo→rapido senza meccanismo di interruzione | Alta | AD-6, AD-13, AD-15 |
| 9 | Classificatore «in parallelo a settle» non blocca | Media | AD-21, AD-18 |
| 10 | Fasi del Banco: fonte, `act`, orologio | Media | AD-18, AD-13 |
| 11 | Memoria a differenza contro cap/scadenza/modalità privata | Media | AD-4, AD-6 |
| 12 | Campi sicuri contro Dettatura, Journal ed Electron | Media | AD-22, AD-5, AD-19 |
| 13 | Timeout del classificatore: due esiti | Media | AD-2, AD-23 |
| 14 | Oracolo della suite di sicurezza circolare | Media | AD-18 |
| 15 | File MCP e token contro processi longevi | Bassa | AD-16, AD-6 |

**Raccomandazione.** Chiudere le coppie 1–8 nella spina dorsale prima di aprire gli epic di §4.9–§4.11; le coppie 9–15 possono essere chiuse nelle storie purché l'AD indichi il proprietario. Tre concetti nuovi ricorrono in più chiusure e meritano di entrare nelle Consistency Conventions: `ActionOrigin` (chi chiede l'azione), `PendingQuestion` (un solo stato «in attesa» nel Coordinator) e `AccessGate` (un solo punto per livello di accesso e campi sicuri).
