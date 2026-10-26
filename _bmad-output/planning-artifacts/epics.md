---
status: final
stepsCompleted: [1, 2, 3, 4]
inputDocuments:
  - _bmad-output/planning-artifacts/prds/prd-mactalkact-2026-10-26/prd.md
  - _bmad-output/planning-artifacts/prds/prd-mactalkact-2026-10-26/addendum.md
  - _bmad-output/planning-artifacts/architecture/architecture-mactalkact-2026-10-26/ARCHITECTURE-SPINE.md
  - _bmad-output/planning-artifacts/research/analisi-limiti-mactalkact-2026-10-26.md
  - _bmad-output/planning-artifacts/research/valutazione-motori-agente-2026-10-27.md
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
FR-25: Nico sceglie il Motore (Claude, Codex, Locale) dal menu e dalle impostazioni; predefinito Claude.
FR-26: Con Codex l'Agente usa la CLI `codex` con login ChatGPT, solo gli strumenti di MacTalkAct, due livelli.
FR-27: Catena di riserva: Motore scelto → altro Motore cloud → Motore locale, con avviso a ogni Passaggio di Motore e ritorno al Motore scelto.
FR-28: Dopo un limite a metà richiesta si ripete sul Motore successivo solo se nessuna Azione con effetti è stata eseguita.
FR-29: Ogni Motore ha il proprio stato; il messaggio di limite di Codex viene letto (ora, durata, giorno).
FR-30: Il Motore locale esegue richieste a più passi (massimo 8) e si ferma con onestà quando non ce la fa.
FR-31: Il Motore locale può usare un Modello locale esteso da un server compatibile OpenAI sul Mac, con elenco modelli e «Prova».
FR-32: Banco di prova dell'Agente (≥ 20 compiti) e comando `--agent-bench` per ogni Motore.
FR-33: Ripulitura della dettatura e passi liberi delle macro funzionano anche senza Motori cloud.
FR-34: Sezione «Motori» nelle impostazioni.

### NonFunctional Requirements

NFR-1: Decisione del Router ≤ 0,8 s, azione della Corsia locale ≤ 1,5 s, primo strumento dell'Agente semplice ≤ 3 s (90° percentile).
NFR-2: Classificazione, Memoria di conversazione e Corpus restano sul Mac; la Chiacchiera non va nel log; la Memoria di conversazione non va su disco.
NFR-3: Senza Classificatore on-device l'app funziona con regole deterministiche e non scrive Frasi ambigue.
NFR-4: Accuratezza sul Corpus ≥ 95%, zero comandi o Chiacchiera decisi *Scrivi*.
NFR-5: Le conferme esistenti per azioni rischiose restano obbligatorie in tutte le corsie.
NFR-6: Con i valori predefiniti l'app si comporta come prima; ogni sezione ha «Ripristina predefiniti».
NFR-7: Ogni modifica vale dall'azione successiva, senza riavvio.
NFR-8: Ogni Motore agisce solo tramite gli strumenti di MacTalkAct.
NFR-9: Scelta del Motore ≤ 50 ms; primo strumento: Codex rapido ≤ 4 s, modello Apple ≤ 2 s, Modello locale esteso ≤ 5 s su M1 16 GB.
NFR-10: Con il Motore locale nessun dato lascia il Mac; server esteso senza avvisi solo su localhost.

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
- AD-13: protocollo `AgentEngine` (`ClaudeEngine`, `CodexEngine`, `LocalEngine`); `AgentRunner` resta proprietario di strumenti, server MCP, messaggio e lucchetto.
- AD-14: `EngineSelector.select(...)` funzione pura; ordine scelto → altro cloud → locale; `EngineSwitch` mostrato una volta.
- AD-15: `AgentTools.effectfulCalls`; ripetizione solo con zero Azioni con effetti, un tentativo per Motore.
- AD-16: Claude e Codex vedono solo il server MCP interno; il Motore locale usa adattatori `Tool` su `AgentTools.call`.
- AD-17: `LocalEngine` su `LanguageModelSession` con `any LanguageModel`: modello Apple o `OpenAICompatibleModel`; prompt corto, strumenti ridotti.
- AD-18: `Tests/bench/agente.tsv`, pagine in `Tests/bench/pages/`, `--agent-bench`.
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
FR-25: Epic 4 — Scelta del Motore (Storie 4.5, 4.7)
FR-26: Epic 4 — Codex come Motore (Storie 4.1, 4.3)
FR-27: Epic 4 — Catena di riserva (Storia 4.5)
FR-28: Epic 4 — Limite a metà richiesta (Storia 4.6)
FR-29: Epic 4 — Disponibilità di ogni Motore (Storie 4.3, 4.7)
FR-30: Epic 4 — Agente locale di base (Storia 4.4), migliorato in Epic 5 (Storia 5.4)
FR-31: Epic 5 — Modello locale esteso (Storie 5.2, 5.3)
FR-32: Epic 5 — Banco di prova dell'Agente (Storia 5.1)
FR-33: Epic 5 — Niente cloud dove non serve (Storia 5.5)
FR-34: Epic 4 — Motori nelle impostazioni (Storia 4.7), server esteso in Epic 5 (Storia 5.3)

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

### Epic 4: Mai senza Agente

Nico sceglie se far lavorare l'Agente con Claude, con Codex o con il modello sul Mac. Quando il Motore scelto esaurisce la quota l'app passa da sola all'altro Motore cloud e, se anche quello manca, al modello locale con un avviso; quando il Motore scelto torna, l'app torna a usarlo. Nessuna azione viene fatta due volte per colpa di un passaggio.
**FRs covered:** FR-25, FR-26, FR-27, FR-28, FR-29, FR-30 (base), FR-34 (Motori cloud)

### Epic 5: Bravo anche da solo

Senza Claude e senza Codex l'app resta utile davvero: il Motore locale porta a termine i compiti brevi tipici, misurati con un Banco di prova; se Nico vuole di più collega un modello più capace servito da Ollama o MLX sul Mac. Nessuna funzione dell'app, oltre all'Agente, ha più bisogno del cloud.
**FRs covered:** FR-30 (ottimizzato), FR-31, FR-32, FR-33, FR-34 (server esteso)

**Perché due epic e non uno (Epic 4 e 5).** L'Epic 4 rende l'Agente sempre raggiungibile ed è soprattutto lavoro di integrazione con rischio contenuto: Codex usa lo stesso server MCP di Claude. L'Epic 5 è lavoro di qualità, con esito incerto: dipende dal modello e dalla memoria del Mac e va guidato da misure. L'Epic 4 contiene già un Motore locale di base (Storia 4.4) perché la Catena di riserva deve finire da qualche parte; l'Epic 5 lo rende buono. L'Epic 5 si appoggia all'Epic 4 (protocollo `AgentEngine`), mai il contrario.

**Perché due epic e non uno (Epic 1 e 2).** I due epic toccano in parte gli stessi file (`Coordinator.swift`, `AgentRunner.swift`), ma il confine è un confine di rischio: l'Epic 1 elimina il danno e si misura subito con SM-1; solo dopo una settimana d'uso con il nuovo Router ha senso tarare la Corsia locale e i modelli dell'Epic 2. L'Epic 2 si appoggia all'Epic 1 (Router e Classificatore on-device), mai il contrario.

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

## Epic 4: Mai senza Agente

L'Agente diventa indipendente dal fornitore: un protocollo comune per i Motori (AD-13), Codex accanto a Claude, un Motore locale di base con il modello Apple e una Catena di riserva decisa in un solo punto (AD-14). Strumenti, prompt, memoria e conferme restano quelli di oggi (AD-16).

### Story 4.1: Spike — Codex senza interfaccia con gli strumenti di MacTalkAct

As a Nico,
I want sapere con certezza come far lavorare Codex con gli strumenti dell'app prima di scrivere il codice,
So that l'integrazione non scopre a metà strada che Codex ha strumenti nascosti o è troppo lento.

**Acceptance Criteria:**

**Given** il server MCP interno avviato da `--selftest` o da un piccolo eseguibile di prova, e la bozza di opzioni nell'addendum del PRD
**When** lancio `codex exec` con quelle opzioni e una richiesta di prova («osserva lo schermo e dimmi l'app in primo piano»)
**Then** il JSONL mostra che Codex ha chiamato solo strumenti `mactalk` e l'elenco degli strumenti disponibili non contiene shell, exec, computer use, browser, ricerca web o generazione di immagini
**And** annoto per ogni `--disable` se è necessario, inutile o sconosciuto in questa versione

**Given** un processo `codex exec -` avviato e in attesa su stdin
**When** misuro il tempo tra l'invio della richiesta e il primo strumento, a freddo e con processo pronto (5 prove ciascuno)
**Then** so se il processo pronto in anticipo fa risparmiare tempo come con `claude`; se no, provo `codex app-server` con le stesse misure

**Given** l'output reale di Codex
**When** raccolgo esempi di risposta finale, errore di rete, login scaduto e (se capita, o dalle fonti) limite d'uso
**Then** li salvo anonimizzati in `Tests/fixtures/codex/` per i test di lettura della Storia 4.3

**Given** 10 richieste tipiche (aprire, cliccare, modificare, cercare)
**When** le eseguo con due configurazioni candidate (rapida: sforzo basso; profonda: sforzo medio o alto)
**Then** registro esito, passi e tempi e scelgo i modelli predefiniti dei due livelli
**And** il risultato è una sezione «Esito dello spike» in `research/valutazione-motori-agente-2026-10-27.md`; nessun codice dell'app viene modificato

### Story 4.2: Motori dietro un solo protocollo

As a Nico,
I want che l'Agente sia pronto ad avere più Motori senza cambiare nulla di quello che fa oggi,
So that aggiungere Codex e il modello locale non rompe Claude.

**Acceptance Criteria:**

**Given** `AgentRunner` che oggi possiede due `ClaudeCLI`
**When** la storia è completa
**Then** esistono `AgentEngine.swift` (protocollo `AgentEngine`, `EngineID`, `AgentLevel`, `AgentRequest`) e `ClaudeEngine.swift` con la logica attuale di processo pronto, livelli, limite e ripresa (AD-13)
**And** `AgentRunner` compone il messaggio (schermo, memoria, `<recent>`), possiede `AgentTools`, `MCPServer` e il lucchetto, e delega l'esecuzione al Motore

**Given** i valori predefiniti
**When** uso l'app come prima (richieste semplici e profonde, limite della subscription, «stop»)
**Then** il comportamento, i messaggi dell'HUD e le righe di log sono identici, salvo il prefisso `Agente (claude/<modello>)` (NFR-6)
**And** `--selftest` e `--route-test` passano

### Story 4.3: Codex come Motore

As a Nico,
I want poter far lavorare l'Agente con Codex,
So that uso anche il mio abbonamento ChatGPT e non resto bloccato quando finisce Claude.

**Acceptance Criteria:**

**Given** l'esito dello spike 4.1
**When** la storia è completa
**Then** esistono `CodexCLI.swift` (ricerca del binario, avvio con le opzioni di AD-16, processo pronto o app-server secondo lo spike, lettura del JSONL) e `CodexEngine.swift` (FR-26)
**And** la ricerca del binario prova `~/.local/bin/codex`, `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex`, Homebrew e la shell di login, saltando gli shim di altre app

**Given** il Motore Codex scelto con le impostazioni nascoste di debug
**When** chiedo «modifica la domanda in che cos'è Internet» sulla pagina di prova del notebook
**Then** Codex usa gli strumenti di MacTalkAct, la conferma per le azioni rischiose compare come con Claude e la risposta finale appare nell'HUD
**And** il token del server MCP non compare negli argomenti del processo (`ps`) ma solo nel suo ambiente

**Given** i messaggi raccolti in `Tests/fixtures/codex/`
**When** `--selftest` li legge
**Then** «try again at 5:40 PM» → pausa fino alle 17:40; «try again in 2 hours 10 minutes» → pausa di 2 h 10 min; una data con giorno diverso → pausa fino a quel giorno; messaggio illeggibile → 30 minuti (FR-29)
**And** `codex login status` diverso da «Logged in» porta lo stato «accesso da fare»

### Story 4.4: Motore locale di base con il modello Apple

As a Nico,
I want che il modello Apple sul Mac sappia fare da Agente per le richieste brevi,
So that quando Claude e Codex non ci sono l'app non si ferma.

**Acceptance Criteria:**

**Given** `LocalEngine.swift`
**When** riceve una richiesta
**Then** usa un `LanguageModelSession` con `SystemLanguageModel.default`, istruzioni corte in italiano e adattatori `Tool` che chiamano `AgentTools.call` per il sottoinsieme di strumenti di AD-17 (FR-30)
**And** smette dopo 8 passi o al tempo massimo e risponde «Col modello locale non ci riesco: …» invece di dichiarare riuscito il compito

**Given** il modello Apple non disponibile (Apple Intelligence spenta)
**When** l'app controlla i Motori
**Then** il Motore locale è «non disponibile» con il motivo, e la Catena di riserva lo salta

**Given** una conferma richiesta dallo strumento `confirm`
**When** arriva dal Motore locale
**Then** compare la stessa conferma dei Motori cloud (NFR-5)

**Given** 5 compiti brevi su pagine di prova (aprire un sito, cliccare un link per nome, scrivere in un campo, sostituire una riga, scorrere)
**When** li eseguo con il Motore locale
**Then** registro esito e tempi nel log: è la misura di partenza per l'Epic 5

### Story 4.5: Scelta del Motore e Catena di riserva

As a Nico,
I want scegliere il Motore e lasciare che l'app passi da sola agli altri quando serve,
So that l'Agente risponde sempre e so sempre chi sta lavorando.

**Acceptance Criteria:**

**Given** il menu della barra
**When** lo apro
**Then** vedo «Motore: Claude / Codex / Locale» con la spunta su quello scelto, e scegliendone un altro la richiesta successiva lo usa (FR-25)

**Given** `EngineSelector.select` (AD-14)
**When** `--selftest` lo prova con tutte le combinazioni di Motore scelto e stati (disponibile, in pausa, non trovato, accesso da fare) con e senza Catena di riserva
**Then** l'ordine è sempre scelto → altro cloud → locale, e senza Catena di riserva il risultato è solo il Motore scelto o nessuno

**Given** Codex scelto e in pausa fino alle 17:40, Claude disponibile
**When** faccio una richiesta
**Then** la esegue Claude e l'HUD mostra una volta «Codex in pausa fino alle 17:40 · uso Claude»; le richieste successive non ripetono l'avviso (FR-27)
**And** alle 17:40 l'HUD dice «Codex è tornato» e la richiesta successiva usa Codex

**Given** Claude e Codex entrambi non disponibili
**When** faccio una richiesta
**Then** l'HUD avvisa «Claude e Codex non disponibili · passo al modello locale» e la richiesta va al Motore locale
**And** se anche il Motore locale non è disponibile l'app entra in Modalità ridotta come oggi (FR-14)

**Given** la Catena di riserva disattivata e il Motore scelto in pausa
**When** faccio una richiesta
**Then** l'app si comporta come la Modalità ridotta di oggi e non avvia nessun altro Motore

### Story 4.6: Limite a metà richiesta senza azioni doppie

As a Nico,
I want che un limite arrivato durante una richiesta non mi costringa a ripeterla, ma senza rischi,
So that l'app recupera da sola quando può e non invia mai due volte la stessa mail.

**Acceptance Criteria:**

**Given** `AgentTools` con il contatore `effectfulCalls` per richiesta (AD-15)
**When** l'Agente chiama `observe` o `screenshot`
**Then** il contatore non cambia; quando chiama `click`, `type_text`, `replace_text`, `press_keys`, `open_app`, `open_url` o `click_many` aumenta

**Given** Claude si ferma per limite dopo due `observe` e nessuna Azione con effetti
**When** `AgentRunner` riceve l'errore
**Then** ripete la richiesta con il Motore successivo della catena, una sola volta, e l'HUD mostra il Passaggio di Motore (FR-28)

**Given** Claude si ferma per limite dopo un clic
**When** `AgentRunner` riceve l'errore
**Then** non ripete la richiesta; l'HUD dice «Claude ha esaurito la quota a metà: ho fatto 1 passo, controlla. La prossima richiesta userà Codex»
**And** la Memoria di conversazione registra l'esito parziale con i passi fatti

**Given** una prova simulata (errore di limite iniettato dal comando di debug dopo N strumenti)
**When** la eseguo con N = 0 e N = 1
**Then** nel primo caso la richiesta è completata dal secondo Motore, nel secondo nessuna azione è ripetuta (SM-C3)

### Story 4.7: Motori nelle impostazioni, nel menu e nello stato

As a Nico,
I want vedere e regolare tutti i Motori da un unico posto,
So that capisco subito chi è disponibile e perché.

**Acceptance Criteria:**

**Given** la finestra delle impostazioni
**When** apro la nuova sezione «Motori» (al posto di «Agente», che vi confluisce)
**Then** vedo Motore scelto, interruttore «Passa agli altri Motori quando serve» (acceso), e per Claude e Codex: percorso del comando, stato (disponibile, in pausa fino alle…, non trovato, accesso da fare), modelli rapido e profondo con il loro sforzo; per il Locale: stato del modello Apple e passi massimi (FR-34)
**And** passi massimi, turni, tempo massimo e validità delle conferme restano comuni a tutti i Motori

**Given** il menu della barra
**When** lo apro
**Then** la riga di stato dice quale Motore è in uso e, se diverso da quello scelto, perché («Codex in pausa fino alle 17:40 · uso Claude»)

**Given** la sezione Stato e diagnostica
**When** la apro
**Then** vedo una riga per Motore con stato e ultimo errore, e un pulsante «Ricontrolla» che riesegue la ricerca dei comandi e dell'accesso senza toccare le pause in corso (FR-29)

**Given** i valori predefiniti
**When** non tocco nulla
**Then** l'app usa Claude come prima; l'unica differenza visibile è che, al limite di Claude, passa a Codex o al locale invece di fermarsi (nuova funzione, documentata nel README)

## Epic 5: Bravo anche da solo

Il Motore locale diventa buono abbastanza da usare l'app senza abbonamenti, e la qualità si misura (AD-18). Il modello Apple resta il predefinito; un Modello locale esteso servito sul Mac è un'opzione per chi vuole di più (AD-17).

### Story 5.1: Banco di prova dell'Agente

As a Nico,
I want misurare quanto è bravo ogni Motore sugli stessi compiti,
So that scelgo modelli e prompt con i numeri e non a sensazione.

**Acceptance Criteria:**

**Given** `Tests/bench/agente.tsv` con almeno 20 compiti e le pagine in `Tests/bench/pages/` (posta finta, tabella con caselle, notebook finto con una cella, modulo, elenco lungo, pagina con link per nome)
**When** li leggo
**Then** ogni compito ha partenza, richiesta come la direi a voce, verifica attesa leggibile con l'Accessibilità e livello (breve: 1–3 passi; medio: 4–8) (FR-32)
**And** nessuna pagina contiene dati privati

**Given** `MacTalkAct --agent-bench --engine local`
**When** lo eseguo
**Then** apre ogni pagina, esegue la richiesta con il Motore indicato, verifica l'esito e stampa compiti riusciti per livello, passi medi, tempo al primo strumento (mediana e 90° percentile) e tempo totale
**And** scrive la tabella in `~/Library/Logs/MacTalkAct-bench-<data>.tsv`

**Given** il Banco completo
**When** lo eseguo con Claude, Codex e modello Apple
**Then** la tabella dei tre risultati è aggiunta alla ricerca dei motori come punto di partenza

### Story 5.2: Spike — quale modello locale su questo Mac

As a Nico,
I want sapere quale modello più capace di quello Apple funziona bene sul mio M1 con 16 GB,
So that non installo e configuro modelli che poi sono troppo lenti o occupano tutta la memoria.

**Acceptance Criteria:**

**Given** Ollama 0.40.11 e LM Studio già installati
**When** provo i candidati Qwen 3.5 4B e 9B e Gemma 4 E4B in 4 bit, ciascuno con Ollama e con LM Studio (motore MLX)
**Then** per ognuno misuro con il Banco di prova (solo compiti brevi e medi): compiti riusciti, tempo al primo strumento, memoria occupata con Edge aperto, correttezza delle chiamate di strumento
**And** verifico se Ollama usa davvero MLX per quel modello

**Given** il prompt e gli strumenti del Motore locale di base
**When** misuro quanti token legge il modello al primo passo
**Then** annoto il costo in secondi per ogni modello, per guidare la Storia 5.4

**Given** il pacchetto `mlx-swift-lm` con `MLXLanguageModel`
**When** provo a caricarlo in un eseguibile di prova con il modello migliore
**Then** confronto tempi e memoria con il server e decido se MLX dentro l'app merita una storia futura
**And** il risultato è una sezione «Esito dello spike sui modelli locali» nella ricerca, con il modello e il server predefiniti consigliati

### Story 5.3: Modello locale esteso tramite server sul Mac

As a Nico,
I want collegare il Motore locale a un modello più capace servito da Ollama o MLX,
So that senza cloud l'app riesce anche nei compiti medi.

**Acceptance Criteria:**

**Given** `OpenAICompatibleModel.swift`, provider `LanguageModel` di FoundationModels verso `/v1/chat/completions` con `tools` e streaming (AD-17)
**When** il Motore locale lo usa
**Then** la stessa `LanguageModelSession` di `LocalEngine` funziona con il modello del server senza altre modifiche al ciclo (FR-31)

**Given** la sezione Motori › Locale
**When** scelgo «Server sul Mac»
**Then** vedo indirizzo (predefinito `http://127.0.0.1:11434/v1`), elenco dei modelli letto dal server, tempo di permanenza in memoria (10 minuti) e un pulsante «Prova» che mostra esito e tempo al primo strumento
**And** un indirizzo diverso da `localhost`/`127.0.0.1` richiede una conferma esplicita con l'avviso che i dati lasciano il Mac (NFR-10)

**Given** il server spento o il modello non caricabile
**When** arriva una richiesta per il Motore locale
**Then** la esegue il modello Apple e l'HUD lo dice una volta («Server locale non raggiungibile · uso il modello Apple»)

**Given** il Banco di prova
**When** lo eseguo con il modello consigliato dallo spike 5.2
**Then** almeno l'85% dei compiti riesce e il primo strumento arriva entro 5 s al 90° percentile (SM-6, NFR-9) [ASSUMPTION: soglie da confermare dopo lo spike]

### Story 5.4: Motore locale ottimizzato

As a Nico,
I want che il Motore locale riesca nei compiti che faccio più spesso,
So that posso usare l'app per una serata intera senza cloud.

**Acceptance Criteria:**

**Given** i risultati del Banco con il Motore locale di base
**When** applico le ottimizzazioni una alla volta, misurando il Banco prima e dopo ciascuna
**Then** il registro delle prove (ottimizzazione, compiti riusciti, tempo) è aggiunto alla ricerca e restano solo le ottimizzazioni che migliorano i numeri

**Given** le ottimizzazioni candidate
**When** le provo
**Then** includono almeno: `observe` che restituisce i 15 elementi più pertinenti alla richiesta; descrizioni degli strumenti abbreviate; Memoria permanente filtrata sui fatti che contengono parole della richiesta; un primo passo che propone l'intero piano con generazione vincolata (struct `@Generable`) e lo esegue un passo alla volta verificando; riscaldamento della sessione all'avvio e dopo ogni risposta; riuso della sessione tra i passi

**Given** il Banco di prova con il modello Apple
**When** eseguo i compiti brevi
**Then** almeno il 70% riesce e il primo strumento arriva entro 2 s al 90° percentile (SM-6, NFR-9)

**Given** una richiesta che il Router giudica complessa e solo il Motore locale disponibile
**When** viene eseguita
**Then** l'HUD avvisa «Col modello locale potrebbe non riuscire» prima di iniziare, e la Memoria di conversazione registra l'esito

### Story 5.5: Niente cloud dove non serve

As a Nico,
I want che dettatura pulita e macro funzionino anche senza Claude e Codex,
So that senza abbonamento perdo solo l'Agente più potente, non pezzi dell'app.

**Acceptance Criteria:**

**Given** «Ripulisci la dettatura» acceso e nessun Motore cloud disponibile
**When** detto una frase
**Then** la ripulitura usa il modello Apple con istruzioni corte e, se supera 1,5 s o fallisce, scrive il testo originale (FR-33)

**Given** una macro con un passo che la grammatica non conosce («apri la posta e cerca Marco»)
**When** la eseguo senza Motori cloud
**Then** il passo va al Motore in uso secondo la Catena di riserva invece di fallire con «Non so eseguire … senza Claude»

**Given** tutto il codice dell'app
**When** cerco gli usi diretti di `ClaudeCLI` e `LLMPlanner` fuori dai Motori
**Then** non ne restano, salvo l'accesso con chiave API che resta una variante del Motore Claude
**And** il README spiega come usare l'app senza abbonamenti e come collegare Ollama o LM Studio
