---
status: final
stepsCompleted: [1, 2, 3, 4]
inputDocuments:
  - _bmad-output/planning-artifacts/prds/prd-mactalkact-2026-10-26/prd.md
  - _bmad-output/planning-artifacts/prds/prd-mactalkact-2026-10-26/addendum.md
  - _bmad-output/planning-artifacts/architecture/architecture-mactalkact-2026-10-26/ARCHITECTURE-SPINE.md
  - _bmad-output/planning-artifacts/research/analisi-limiti-mactalkact-2026-10-26.md
---

# mactalkact - Epic Breakdown

## Overview

Questo documento scompone in epic e storie i requisiti del PRD del 26/10/2026 e le decisioni dell'architettura. Le storie sono pensate per essere realizzate una alla volta, in ordine, da un agente di sviluppo. Non c'è un documento UX separato: l'interfaccia è l'HUD esistente e le indicazioni necessarie sono nei criteri di accettazione.

## Requirements Inventory

### Functional Requirements

FR-1: Il Router assegna a ogni Frase esattamente una Decisione di instradamento e la registra nel log con motivo e tempo.
FR-2: Una Frase composta solo dalla Parola di attivazione non viene mai scritta, in nessuno stato.
FR-3: Nei campi di testo, il Classificatore on-device distingue comando, Dettatura e Chiacchiera.
FR-4: Nel dubbio il Router non scrive: mostra il testo e lo inserisce solo se l'utente dice «scrivilo» entro 8 s.
FR-5: La Dettatura esplicita («scrivi …», modalità dettatura) ha sempre la precedenza.
FR-6: Esiste un Corpus di almeno 80 Frasi e un comando che verifica il Router e fallisce su ogni comando o Chiacchiera decisi *Scrivi*.
FR-7: Dopo ogni risposta si apre una Finestra di conversazione di 20 s in cui i comandi non richiedono la Parola di attivazione.
FR-8: L'Agente riceve la Memoria di conversazione (al massimo 5 interazioni degli ultimi 10 minuti), solo in RAM.
FR-9: Una risposta senza contenuto a una domanda aperta dell'Agente fa ripetere la domanda una volta.
FR-10: «Cancella quello che hai scritto» rimuove l'ultimo Inserimento se il campo non è cambiato, altrimenti usa Cmd+Z e lo dice.
FR-11: I comandi a un passo vengono eseguiti dalla Corsia locale quando la proposta supera il Validatore.
FR-12: Il Validatore approva solo tasti consentiti, app installate e URL validi; il resto va all'Agente.
FR-13: Le richieste semplici usano un modello rapido con effort basso, quelle complesse il modello configurato; «pensaci bene» forza il secondo.
FR-14: Al limite della subscription l'app entra in Modalità ridotta fino all'ora di ripresa, poi riprova e avvisa.
FR-15: L'Agente può eseguire la stessa azione su più elementi numerati in una chiamata, con lo stato di ciascuno dopo l'azione.
FR-16: L'Agente può sostituire testo in campi che non espongono il testo all'Accessibilità e verificare il risultato.
FR-17: La finestra delle impostazioni si apre con il contenuto visibile, a sezioni con barra laterale, e ricorda l'ultima sezione.
FR-18: Tempi e soglie dell'ascolto visibili e modificabili; parola di attivazione scelta dall'utente, con varianti generate da sole.
FR-19: Tempi della conversazione e dimensione della Memoria di conversazione visibili e modificabili.
FR-20: Comprensione e Agente (interruttori, modelli, effort, limiti, accesso a Claude) visibili e modificabili.
FR-21: Voce, suoni e durata dei messaggi visibili e modificabili.
FR-22: Numeri sullo schermo, fatti e macro (elenco, eliminazione, file) e svuotamento della Memoria di conversazione.
FR-23: Stato dei permessi, del modello Apple, del comando claude, dell'Agente e del log.
FR-24: Menu della barra con stato, impostazioni rapide e collegamenti alle sezioni.

### NonFunctional Requirements

NFR-1: Decisione del Router ≤ 0,8 s, azione della Corsia locale ≤ 1,5 s, primo strumento dell'Agente semplice ≤ 3 s (90° percentile).
NFR-2: Classificazione, Memoria di conversazione e Corpus restano sul Mac; la Chiacchiera non va nel log; la Memoria di conversazione non va su disco.
NFR-3: Senza Classificatore on-device l'app funziona con regole deterministiche e non scrive Frasi ambigue.
NFR-4: Accuratezza sul Corpus ≥ 95%, zero comandi o Chiacchiera decisi *Scrivi*.
NFR-5: Le conferme esistenti per azioni rischiose restano obbligatorie in tutte le corsie.
NFR-6: Con i valori predefiniti l'app si comporta come prima; ogni sezione ha «Ripristina predefiniti».
NFR-7: Ogni modifica vale dall'azione successiva, senza riavvio.

### Additional Requirements

- AD-1: tutta la logica di instradamento in `IntentRouter.decide(...) -> RouteDecision`, senza effetti; il Coordinator esegue la decisione.
- AD-2: protocollo `IntentClassifier` con `OnDeviceClassifier` (FoundationModels) e `RuleClassifier`; timeout 1,0 s; il classificatore non esegue mai.
- AD-3: ogni `LocalAction` passa da `LocalActionValidator` prima di `Executor`.
- AD-4: `ConversationState` e `ConversationLog` solo in RAM, posseduti dal Coordinator su `@MainActor`; all'Agente come blocco `<recent>`.
- AD-5: ogni testo scritto dall'app registrato in `InsertionJournal`.
- AD-6: due configurazioni CLI (rapida e profonda) in `AgentRunner`, una sola esecuzione alla volta.
- AD-7: `AgentRunner.availability` unica fonte della disponibilità; il Router produce `.reduced` quando l'Agente non è disponibile.
- AD-8: id degli elementi con numero di generazione; id scaduti rifiutati.
- AD-9: log `Instradamento: <decisione> · <motivo> · <ms>` senza testo per *Ignora*.
- AD-10: convenzioni esistenti ratificate (MainActor, CLI con subscription, server MCP interno, `Safety`, build e firma attuali).
- AD-11: `AppSettings` unica fonte dei comportamenti regolabili, letti al momento dell'uso.
- AD-12: predefiniti in `AppSettings.Defaults`, uguali alle costanti precedenti; ripristino per sezione.
- Nessun template di partenza: progetto esistente (brownfield).

### UX Design Requirements

Nessun documento UX. I requisiti di interfaccia (indicatore della Finestra di conversazione, messaggi della Modalità ridotta, proposta «scrivilo») sono nei criteri di accettazione delle storie.

### FR Coverage Map

FR-1: Epic 1 — Router unico con log delle decisioni (Storia 1.1)
FR-2: Epic 1 — Parola di attivazione mai scritta (Storia 1.1)
FR-3: Epic 1 — Classificatore on-device (Storia 1.2)
FR-4: Epic 1 — Nel dubbio non scrivere (Storia 1.1)
FR-5: Epic 1 — Precedenza della Dettatura esplicita (Storia 1.1)
FR-6: Epic 1 — Corpus e `--route-test` (Storia 1.1, esteso in 1.2)
FR-7: Epic 1 — Finestra di conversazione (Storia 1.3)
FR-8: Epic 1 — Memoria di conversazione (Storia 1.4)
FR-9: Epic 1 — Risposte coerenti all'Agente (Storia 1.4)
FR-10: Epic 1 — Annulla l'ultimo Inserimento (Storia 1.5)
FR-11: Epic 2 — Corsia locale (Storia 2.1)
FR-12: Epic 2 — Validatore (Storia 2.1)
FR-13: Epic 2 — Modello proporzionato (Storia 2.2)
FR-14: Epic 2 — Modalità ridotta (Storia 2.3)
FR-15: Epic 2 — Azioni in blocco verificate (Storia 2.4)
FR-16: Epic 2 — Modifica negli editor web (Storia 2.5)
FR-17: Epic 3 — Finestra a sezioni (Storia 3.1)
FR-18: Epic 3 — Ascolto (Storia 3.2)
FR-19: Epic 3 — Conversazione (Storia 3.2)
FR-20: Epic 3 — Comprensione e Agente (Storia 3.3)
FR-21: Epic 3 — Voce e suoni (Storia 3.4)
FR-22: Epic 3 — Numeri, memoria e macro (Storia 3.5)
FR-23: Epic 3 — Permessi e stato (Storia 3.5)
FR-24: Epic 3 — Menu della barra (Storia 3.6)

## Epic List

### Epic 1: Mi capisce al primo colpo

Nico parla in modo naturale, anche con il bambino o con altre persone nella stanza, e l'app non scrive più frasi che non sono dettatura: decide in meno di un secondo se scrivere, eseguire o ignorare, tiene aperta la conversazione dopo ogni risposta, ricorda le ultime cose fatte e permette di annullare a voce quello che ha scritto.
**FRs covered:** FR-1, FR-2, FR-3, FR-4, FR-5, FR-6, FR-7, FR-8, FR-9, FR-10

### Epic 2: Veloce e sempre disponibile

I comandi a un passo vengono eseguiti in circa un secondo senza Claude, l'Agente usa il modello giusto per la difficoltà, lavora con precisione su liste ed editor web, e quando la subscription è esaurita l'app continua a funzionare in Modalità ridotta.
**FRs covered:** FR-11, FR-12, FR-13, FR-14, FR-15, FR-16

### Epic 3: Tutto sotto controllo dalle impostazioni

Nico apre le impostazioni e trova, ordinato per sezioni, tutto ciò che l'app fa: può vederlo, cambiarlo e tornare ai valori di fabbrica, senza riavviare e senza che l'app cambi comportamento finché non tocca nulla. Dalla barra dei menu raggiunge in un clic gli interruttori più usati.
**FRs covered:** FR-17, FR-18, FR-19, FR-20, FR-21, FR-22, FR-23, FR-24
**Vincolo:** nessuna funzionalità nuova (NFR-6).

**Perché due epic e non uno.** I due epic toccano in parte gli stessi file (`Coordinator.swift`, `AgentRunner.swift`), ma il confine è un confine di rischio: l'Epic 1 elimina il danno e si misura subito con SM-1; solo dopo una settimana d'uso con il nuovo Router ha senso tarare la Corsia locale e i modelli dell'Epic 2. L'Epic 2 si appoggia all'Epic 1 (Router e Classificatore on-device), mai il contrario.

## Epic 1: Mi capisce al primo colpo

Ogni Frase riceve una sola Decisione di instradamento, presa da un Router testabile; il Classificatore on-device separa comandi, Dettatura e Chiacchiera; la conversazione resta aperta e ha memoria; ogni Inserimento si può annullare.

### Story 1.1: Router unico che non scrive mai per errore

As a Nico, con il cursore in un documento e le mani occupate,
I want che ogni frase passi da un'unica decisione prudente e verificabile,
So that nessun comando, saluto o «computer» finisca scritto nel mio lavoro.

**Acceptance Criteria:**

**Given** il codice attuale, dove `Coordinator.handle` e `runSmart` decidono con euristiche diverse
**When** la storia è completa
**Then** esistono `IntentRouter.swift` con `RouterState`, `RouteDecision` e `IntentRouter.decide(...)`, e `IntentClassifier.swift` con il protocollo e `RuleClassifier`
**And** il Coordinator esegue la `RouteDecision` senza altre condizioni sul testo (AD-1)

**Given** il cursore in un campo di testo e l'app armata
**When** dico solo «Computer», «Computer.» o «ehi computer»
**Then** nessun testo viene inserito e l'HUD mostra «Dimmi pure…» (FR-2)

**Given** il cursore in un campo di testo
**When** dico «Rimetti la domanda di prima» e il `RuleClassifier` risponde «incerto»
**Then** nulla viene scritto e l'HUD mostra il testo con «Di' "scrivilo" per inserirlo»
**And** se entro 8 s dico «scrivilo» il testo viene inserito, altrimenti la proposta scade (FR-4)

**Given** il cursore in un campo di testo
**When** dico «computer, scrivi ciao a tutti» oppure detto in modalità dettatura
**Then** il testo viene scritto senza domande (FR-5)

**Given** qualunque Frase che arriva al Router
**When** il Router decide
**Then** il log contiene `Instradamento: <decisione> · <motivo> · <ms>` e, per *Ignora*, solo la lunghezza della Frase (FR-1, AD-9)

**Given** il file `Tests/corpus/instradamento.tsv` con almeno 80 Frasi (incluse le 11 della sessione del 26/10, riscritte senza dati privati)
**When** eseguo `MacTalkAct --route-test`
**Then** il comando stampa accuratezza ed errori per tipo e termina con codice diverso da zero se un comando o una Chiacchiera vengono decisi *Scrivi* (FR-6)
**And** `--selftest` continua a passare

### Story 1.2: Classificatore on-device nei campi di testo

As a Nico,
I want che l'app capisca da sola se una frase è un comando, una dettatura o chiacchiera,
So that posso dettare in modo naturale senza dire «scrivilo» e senza che i comandi finiscano nel testo.

**Acceptance Criteria:**

**Given** Apple Intelligence attiva e il cursore in un campo di testo
**When** arriva una Frase che non è Dettatura esplicita né Comando rapido
**Then** `OnDeviceClassifier` la classifica con generazione vincolata (struct `@Generable` con `@Guide(.anyOf(["comando","dettatura","chiacchiera"]))`)
**And** comando → *Agente*, dettatura → *Scrivi*, chiacchiera → *Ignora* (FR-3)

**Given** il modello caldo
**When** misuro 20 decisioni consecutive
**Then** il 90° percentile resta sotto 0,8 s (NFR-1)
**And** il modello viene riscaldato all'avvio e dopo ogni risposta

**Given** il modello non disponibile o più lento di 1,0 s
**When** arriva una Frase ambigua
**Then** il Router usa `RuleClassifier` e applica il comportamento prudente della Storia 1.1 (NFR-3)

**Given** il Corpus esteso con almeno 20 frasi di Chiacchiera domestica e 20 di dettatura naturale
**When** eseguo `--route-test` con il Classificatore on-device
**Then** l'accuratezza è almeno 95% e nessun comando o Chiacchiera è deciso *Scrivi* (NFR-4)

### Story 1.3: Finestra di conversazione

As a Nico,
I want poter continuare a dare comandi per qualche secondo dopo una risposta senza ripetere «computer»,
So that una richiesta in più passaggi non diventa una lotta con la parola di attivazione.

**Acceptance Criteria:**

**Given** l'app ha appena risposto (riuscita, errore o domanda dell'Agente)
**When** entro 20 s dico «cambia anche la seconda» senza «computer»
**Then** la Frase viene classificata ed eseguita come comando (FR-7)
**And** la finestra riparte da 20 s

**Given** la Finestra di conversazione aperta
**When** dico «ciao amore, arrivo»
**Then** la Frase è *Ignora* e la finestra non si prolunga

**Given** la Finestra di conversazione aperta
**When** dico «basta così», «grazie» o «a posto»
**Then** la finestra si chiude subito e l'HUD lo conferma brevemente

**Given** la Finestra di conversazione aperta
**When** guardo lo schermo
**Then** l'HUD mostra un indicatore discreto «conversazione aperta», che sparisce alla chiusura
**And** `armedUntil` e `followUpUntil` sono sostituiti da `ConversationState` (AD-4), senza regressioni su «computer» da solo e sui Comandi rapidi

### Story 1.4: L'Agente ricorda le ultime cose fatte

As a Nico,
I want che l'Agente sappia che cosa gli ho chiesto e che cosa ha fatto pochi minuti fa,
So that posso dire «rimetti com'era prima» o «fai lo stesso con l'altra» come farei con una persona.

**Acceptance Criteria:**

**Given** l'Agente ha appena sostituito «Che cos'è il cloud computing?» con «Che cos'è Internet?»
**When** dico «rimetti la domanda di prima»
**Then** il messaggio all'Agente contiene un blocco `<recent>` con richiesta, esito, app e testo prima/dopo dell'interazione precedente
**And** l'Agente ripristina il testo originale (FR-8)

**Given** la Memoria di conversazione
**When** passano 10 minuti senza interazioni, chiudo l'app o dico «dimentica la conversazione»
**Then** la memoria è vuota e nessun suo contenuto è mai stato scritto su disco (NFR-2)
**And** contiene al massimo 5 interazioni

**Given** l'Agente chiede «Con quale testo sostituisco la domanda?»
**When** rispondo solo «sì» (o una risposta senza contenuto)
**Then** l'app ripete la domanda una volta invece di inoltrare la risposta (FR-9)
**And** se anche la seconda risposta è vuota, l'Agente riceve «nessuna risposta» e si ferma senza agire

### Story 1.5: Annulla quello che hai scritto

As a Nico,
I want poter dire «cancella quello che hai scritto» quando l'app ha scritto qualcosa che non volevo,
So that posso rimediare senza mettere giù il bambino.

**Acceptance Criteria:**

**Given** l'app ha appena inserito «Bellissimo, ok, stop» in una cella
**When** dico «cancella quello che hai scritto» (o «non era da scrivere»)
**Then** solo quei caratteri vengono rimossi e il testo precedente resta intatto (FR-10)

**Given** ogni scrittura dell'app (dettatura, `type_text` dell'Agente, Corsia locale)
**When** avviene
**Then** viene registrata in `InsertionJournal` con app, elemento, testo e testo prima del cursore (AD-5)

**Given** ho modificato il campo dopo l'Inserimento o ho cambiato finestra
**When** dico «cancella quello che hai scritto»
**Then** l'app usa Cmd+Z e mostra «Ho usato Annulla: controlla il risultato»

## Epic 2: Veloce e sempre disponibile

I comandi semplici diventano istantanei e locali, l'Agente costa meno quota e sbaglia meno, e la fine della quota non spegne l'app.

### Story 2.1: Corsia locale per i comandi a un passo

As a Nico,
I want che comandi come «apri nuova tab» o «metti a schermo intero» vengano eseguiti subito,
So that non aspetto 4 secondi l'Agente per una scorciatoia.

**Acceptance Criteria:**

**Given** una Frase classificata comando che la grammatica fissa non conosce
**When** il Classificatore on-device propone una `LocalAction` (tasti, app, URL, scorrimento)
**Then** `LocalActionValidator` la approva solo se i tasti sono nell'elenco consentito, l'app è trovata da `Executor.findApp` e l'URL ha schema o dominio noto (FR-12, AD-3)
**And** l'azione approvata viene eseguita senza avviare l'Agente (FR-11)

**Given** le proposte errate del test del 26/10 («tasti: ingrandisci», «tasti: [», «apri_app: youtube»)
**When** passano dal Validatore
**Then** vengono respinte o corrette e la Frase va all'Agente

**Given** una combinazione segnalata da `Safety.isRiskyKeys`
**When** arriva dalla Corsia locale
**Then** non viene mai eseguita senza la conferma esistente (NFR-5)

**Given** «apri nuova tab», «chiudi questa scheda», «metti a schermo intero», «apri Spotify»
**When** li dico con Edge in primo piano
**Then** il 90° percentile dalla fine della Frase all'azione è sotto 1,5 s (NFR-1)
**And** il Corpus ha almeno 15 righe per la Corsia locale con la decisione attesa

### Story 2.2: Modello proporzionato alla difficoltà

As a Nico,
I want che le richieste semplici usino un modello più rapido,
So that rispondono prima e consumano meno subscription, lasciando Opus ai compiti lunghi.

**Acceptance Criteria:**

**Given** `AgentRunner` con due configurazioni riscaldate, rapida (`claude-sonnet-5-5`, effort `low`) e profonda (modello configurato, effort `medium`) (AD-6)
**When** il Router decide *Agente* con complessità semplice
**Then** la richiesta usa la configurazione rapida e il log riporta il modello usato (FR-13)

**Given** una richiesta che contiene «pensaci bene» o che il Router giudica complessa
**When** viene eseguita
**Then** usa la configurazione profonda

**Given** le impostazioni
**When** le apro
**Then** posso scegliere il modello rapido e quello profondo

**Given** 10 richieste tipiche (aprire, cliccare, modificare, cercare)
**When** le eseguo con la configurazione rapida
**Then** registro nel log esito e durata, per rispondere alla domanda aperta 2 del PRD
**And** mai due esecuzioni dell'Agente sono attive insieme

### Story 2.3: Modalità ridotta al limite della subscription

As a Nico,
I want che l'app continui a funzionare quando finisco la quota della subscription,
So that dettatura e comandi non si fermano e so quando torna l'Agente.

**Acceptance Criteria:**

**Given** la CLI risponde «You've hit your session limit · resets 7pm»
**When** `AgentRunner` riceve l'errore
**Then** `availability` diventa `paused(until: 19:00)` (o 30 minuti se l'ora non è leggibile) (FR-14, AD-7)

**Given** l'Agente in pausa
**When** faccio una richiesta che richiederebbe l'Agente
**Then** il Router produce `.reduced` e l'HUD risponde in meno di 0,5 s «Agente in pausa fino alle 19:00 · dettatura e comandi funzionano»
**And** nessun processo `claude` viene avviato

**Given** l'Agente in pausa
**When** uso dettatura, Comandi rapidi, Corsia locale o «mostra numeri»
**Then** funzionano normalmente

**Given** l'ora di ripresa
**When** arriva
**Then** l'app riscalda la CLI, torna `available` se riesce e l'HUD avvisa «L'Agente è tornato»
**And** il menu mostra lo stato «Agente in pausa fino alle …» finché dura la pausa

### Story 2.4: Azioni in blocco verificate

As a Nico,
I want che l'Agente spunti molte caselle in una volta e controlli che siano davvero spuntate,
So that i compiti ripetitivi sono rapidi e non sbagliano riga.

**Acceptance Criteria:**

**Given** il registro degli elementi di `AgentTools`
**When** avvengono `observe`, `screenshot` o `scroll`
**Then** la generazione aumenta e gli id restituiti la portano (AD-8)
**And** uno strumento che riceve un id di una generazione precedente risponde con errore e invita a osservare di nuovo

**Given** uno strumento `click_many(ids, method)`
**When** l'Agente lo usa su 12 caselle
**Then** riceve per ogni id etichetta, esito e stato dopo l'azione (per esempio spuntata sì/no) (FR-15)

**Given** il compito di UJ-4 su una pagina di prova locale con 30 righe e caselle
**When** lo chiedo a voce
**Then** l'Agente lo completa con meno di 10 chiamate di strumento e tutte le caselle attese risultano spuntate
**And** il prompt dell'Agente indica di preferire gli id e di verificare dopo ogni clic per coordinate

### Story 2.5: Modifica affidabile negli editor web

As a Nico,
I want che l'Agente sappia cambiare una riga in un notebook o in un editor di codice nel browser,
So that «modifica la domanda» riesce al primo tentativo.

**Acceptance Criteria:**

**Given** una cella Jupyter in Edge che contiene `domanda = "Che cos'è il cloud computing?"`
**When** chiedo «modifica la domanda in che cos'è Internet»
**Then** l'Agente usa uno strumento di sostituzione che funziona anche senza testo esposto all'Accessibilità
**And** il testo finale è `domanda = "Che cos'è Internet?"` al primo tentativo (FR-16)

**Given** la sostituzione eseguita
**When** lo strumento termina
**Then** verifica il risultato (lettura del testo della pagina o screenshot) e riporta all'Agente se il testo atteso è presente
**And** il testo sostituito viene registrato in `InsertionJournal` e nella Memoria di conversazione con il valore precedente

**Given** un campo dove lo strumento non riesce
**When** la verifica fallisce
**Then** l'Agente lo dice chiaramente invece di dichiarare il compito riuscito

## Epic 3: Tutto sotto controllo dalle impostazioni

Ogni comportamento regolabile vive in `AppSettings` (AD-11) con predefiniti uguali a prima (AD-12); la finestra lo mostra per sezioni e il menu della barra offre le scorciatoie.

### Story 3.1: Finestra delle impostazioni a sezioni

As a Nico,
I want che le impostazioni si aprano davvero, ordinate in sezioni con una barra laterale,
So that trovo subito quello che cerco invece di una finestra vuota.

**Acceptance Criteria:**

**Given** il menu della barra
**When** scelgo «Impostazioni…»
**Then** si apre una finestra ridimensionabile (almeno 760×520) con barra laterale e contenuto visibile (FR-17)
**And** le sezioni sono Ascolto, Conversazione, Comprensione, Agente, Voce e suoni, Numeri, Memoria e macro, Permessi, Stato e diagnostica

**Given** ho chiuso la finestra sulla sezione Agente
**When** la riapro
**Then** si apre sulla sezione Agente

**Given** le impostazioni già esistenti (tasto, frasi di attivazione, modelli, accesso a Claude, chiave API…)
**When** apro la finestra
**Then** le trovo nella sezione giusta e funzionano come prima

### Story 3.2: Ascolto e conversazione regolabili

As a Nico,
I want vedere e cambiare i tempi dell'ascolto e della conversazione,
So that posso adattare l'app a come parlo e a chi c'è nella stanza.

**Acceptance Criteria:**

**Given** la sezione Ascolto
**When** la apro
**Then** vedo silenzio di fine frase (0,8 s), sensibilità (0,006), rapporto sul rumore (4), durata massima di una frase (60 s), silenzio di fine dettatura lunga (4 s) e pausa della dettatura (1,6 s), chiusura della sessione a mani libere (60 s) (FR-18)
**And** le soglie del rilevatore stanno in un gruppo «Avanzate» con una spiegazione

**Given** cambio il silenzio di fine frase
**When** pronuncio la frase successiva
**Then** il rilevatore usa il nuovo valore senza riavvio (NFR-7, AD-11)

**Given** la sezione Conversazione
**When** la apro
**Then** vedo finestra di conversazione (20 s), ascolto dopo «computer» (8 s), proposta «scrivilo» (8 s), attesa risposta all'Agente (25 s), attesa di una conferma (20 s), voci (5) e durata (10 min) della Memoria di conversazione (FR-19)

**Given** una qualsiasi delle due sezioni
**When** premo «Ripristina predefiniti»
**Then** tornano i valori di prima solo per quella sezione (NFR-6, AD-12)

### Story 3.3: Comprensione e Agente regolabili

As a Nico,
I want vedere come l'app capisce le frasi e come lavora l'Agente, e cambiarlo,
So that decido io tra velocità, consumo della subscription e prudenza.

**Acceptance Criteria:**

**Given** la sezione Comprensione
**When** la apro
**Then** vedo i due interruttori (modello Apple, corsia locale), il tempo massimo del classificatore (1,5 s) e la lunghezza massima per la corsia locale (6 parole), con l'indicazione se il modello Apple è disponibile (FR-20)

**Given** la sezione Agente
**When** la apro
**Then** vedo uso di Claude, accesso (abbonamento o chiave), percorso di `claude`, modelli rapido e profondo con il loro effort (basso, medio), passi massimi (60), turni massimi (40), tempo massimo di un compito (240 s), validità di una conferma (45 s), ripulitura della dettatura

**Given** cambio l'effort del modello profondo
**When** faccio la richiesta successiva
**Then** il processo `claude` pronto viene sostituito con uno che usa il nuovo valore

### Story 3.4: Voce, suoni e messaggi regolabili

As a Nico,
I want regolare voce, suoni e quanto restano visibili i messaggi,
So that l'app non sveglia il bambino e i messaggi restano il tempo giusto.

**Acceptance Criteria:**

**Given** la sezione Voce e suoni
**When** la apro
**Then** vedo risposte a voce, volume (0,45) e velocità (1,05) della voce, suoni sì/no e volume (0,2), durata dei messaggi di riuscita (1,3 s), delle risposte dell'Agente (5 s) e degli errori (4 s) (FR-21)

**Given** spengo i suoni
**When** l'app conferma o segnala un errore
**Then** non si sente nulla

### Story 3.5: Numeri, memoria, permessi e stato

As a Nico,
I want vedere ciò che l'app ricorda, i permessi e lo stato di ogni componente,
So that capisco perché qualcosa non funziona e tengo in ordine la memoria.

**Acceptance Criteria:**

**Given** la sezione Numeri
**When** la apro
**Then** vedo durata (30 s) e numero massimo (180) dei numeri sullo schermo (FR-22)

**Given** la sezione Memoria e macro
**When** la apro
**Then** vedo l'elenco dei fatti e delle macro con un pulsante per eliminare ciascuno, «Apri il file» e «Svuota la memoria di conversazione»

**Given** la sezione Permessi
**When** la apro
**Then** vedo lo stato aggiornato di Accessibilità, Microfono e Registrazione schermo e un pulsante per concederli (FR-23)

**Given** la sezione Stato e diagnostica
**When** la apro
**Then** vedo modello Apple disponibile sì/no, comando `claude` trovato e percorso, stato dell'Agente (disponibile, in pausa fino alle…, non trovato), classificatore in uso, versione dell'app, e posso aprire il log e la guida

### Story 3.6: Menu della barra ricco

As a Nico,
I want un menu nella barra con lo stato e gli interruttori più usati,
So that cambio le cose al volo senza aprire la finestra.

**Acceptance Criteria:**

**Given** il menu della barra
**When** lo apro
**Then** vedo lo stato dell'Agente e del classificatore, le modalità di ascolto, un sottomenu «Impostazioni rapide» (modello Apple, corsia locale, modello rapido, risposte a voce, suoni, durata della conversazione) e un sottomenu «Impostazioni» con una voce per sezione (FR-24)

**Given** spunto o tolgo un interruttore dal sottomenu
**When** riapro le impostazioni
**Then** la finestra mostra lo stesso valore (AD-11)

### Story 3.7: Parola di attivazione a scelta

As a Nico,
I want scegliere io la parola che attiva l'app al posto di «computer»,
So that uso una parola che mi viene naturale e che in casa non si dice per caso.

**Acceptance Criteria:**

**Given** la sezione Ascolto
**When** scrivo «Jarvis» nel campo «Parola di attivazione»
**Then** l'app risponde a «Jarvis», «ok Jarvis», «ehi Jarvis», «hey Jarvis» e alle storpiature «i Jarvis», «e Jarvis», e non più a «computer» (FR-18)
**And** sotto il campo vedo l'elenco completo delle frasi a cui risponde

**Given** non voglio le varianti
**When** spengo «Accetta anche le varianti»
**Then** l'app risponde solo alla parola e alle eventuali «Altre parole» che aggiungo a mano

**Given** il campo vuoto o una parola molto corta o comune
**When** la scrivo
**Then** vedo un avviso (vuoto → resta «computer»; corta o comune → rischio di attivazioni per sbaglio)

**Given** i valori predefiniti
**When** non cambio nulla
**Then** l'app risponde esattamente a «computer, ok computer, ehi computer, hey computer, i computer, e computer» come prima (NFR-6)
**And** chi aveva già personalizzato l'elenco ritrova le sue parole

**Given** suggerimenti, guida e messaggi dell'HUD
**When** cambio parola
**Then** mostrano la nuova parola invece di «computer»
