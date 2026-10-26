---
title: MacTalkAct — Mi capisce al primo colpo, veloce e sempre disponibile
status: final
created: 2026-10-26
updated: 2026-10-26
inputs:
  - _bmad-output/planning-artifacts/research/analisi-limiti-mactalkact-2026-10-26.md
  - README.md
  - Sources/MacTalkAct/
---

# PRD: MacTalkAct — upgrade «Mi capisce al primo colpo»

## 0. Scopo del documento

Questo PRD descrive il prossimo ciclo di sviluppo di MacTalkAct, l'app per macOS che permette di usare il computer con la voce quando le mani sono occupate. Non riscrive l'app: parte dalla versione attuale (dettatura, comandi rapidi, numeri sullo schermo, agente Claude con strumenti propri, memoria e macro) e ne corregge i limiti emersi dall'uso reale, documentati in `research/analisi-limiti-mactalkact-2026-10-26.md`. È scritto per Nico, unico utente e sviluppatore, e per gli agenti che realizzeranno le storie. I termini del Glossario (§3) vanno usati esattamente così. Le scelte tecniche sono in `addendum.md`.

## 1. Visione

La promessa di MacTalkAct è «la mia voce diventa le mie mani». Oggi la promessa regge quando l'app capisce la richiesta, ma si rompe nel momento più delicato: decidere se una frase va scritta, eseguita o ignorata. Nell'uso reale più della metà delle frasi dette mentre il cursore era in un notebook è finita scritta nel documento. Un assistente che sporca il lavoro è peggio di nessun assistente, perché costringe a usare proprio le mani che non sono libere.

Questo ciclo rende l'app **affidabile prima che potente**. Ogni frase riceve una sola decisione, presa da un unico Router che usa il modello linguistico Apple presente sul Mac per distinguere comandi, dettatura e chiacchiera in meno di un secondo, senza rete e senza consumare la subscription. La conversazione resta aperta dopo ogni risposta, così non serve ripetere «computer» a ogni frase, e l'agente ricorda le ultime cose fatte, così «rimetti com'era prima» diventa una richiesta valida.

In secondo luogo l'app diventa **veloce e sempre disponibile**: i comandi a un passo vengono eseguiti in locale in circa un secondo, l'agente usa un modello Claude proporzionato alla difficoltà, e quando la subscription è esaurita l'app continua a funzionare in Modalità ridotta invece di fermarsi.

## 2. Utente

### 2.1 Jobs To Be Done

- **Funzionale:** continuare il lavoro al Mac (scrivere, modificare, navigare, compilare) con il bambino in braccio, senza toccare tastiera e mouse.
- **Emotivo:** fidarsi che l'app non combini guai mentre l'attenzione è sul bambino; non dover controllare ogni volta che cosa ha scritto.
- **Contestuale:** parlare in modo naturale, anche rivolgendosi ad altre persone nella stanza, senza che l'app reagisca a ciò che non è per lei.

### 2.2 Non utenti (questo ciclo)

Altri utenti, altre lingue oltre all'italiano, chi usa l'app senza Apple Intelligence attiva (l'app deve comunque funzionare, ma in modo più prudente: vedi NFR-3).

### 2.3 Percorsi utente

- **UJ-1. Nico corregge un quiz nel notebook con il bambino in braccio.**
  Nico ha un notebook Jupyter aperto in Edge, con il cursore dentro una cella. Dice «computer, modifica la domanda: che cos'è il cloud computing diventa che cos'è Internet». Il Router riconosce un comando e lo passa all'Agente, che sostituisce il testo e lo conferma nell'HUD. Il bambino si agita; Nico dice «ciao amore, ora arrivo»: la frase è Chiacchiera e viene ignorata. Poi, senza ripetere «computer», dice «no, rimetti la domanda di prima»: la Finestra di conversazione è ancora aperta e l'Agente, grazie alla Memoria di conversazione, ripristina il testo originale. **Caso limite:** se qualcosa viene comunque scritto per errore, Nico dice «cancella quello che hai scritto» e l'ultimo Inserimento sparisce.

- **UJ-2. Nico naviga veloce tra le schede.**
  Con Edge in primo piano dice «computer, apri nuova tab», poi «chiudi questa scheda», poi «riapri la scheda che ho chiuso». Ogni comando viene eseguito dalla Corsia locale in circa un secondo, senza attendere l'Agente.

- **UJ-3. La subscription si esaurisce in serata.**
  Nico chiede all'Agente un compito lungo e riceve «Limite della subscription raggiunto, riprende alle 19». L'app entra in Modalità ridotta: dettatura, comandi rapidi, Corsia locale e numeri sullo schermo continuano a funzionare; le richieste che richiedono l'Agente ricevono subito una risposta chiara invece di un'attesa. Alle 19 l'HUD avvisa che l'Agente è tornato.

- **UJ-4. Nico spunta molte caselle in una tabella web.**
  Dice «computer, spunta le 18:30 per tutti quelli che hanno già le 21:30». L'Agente seleziona le caselle per numero, in blocco, e verifica che ognuna risulti spuntata, invece di cliccare decine di coordinate una alla volta.

## 3. Glossario

- **Frase** — un segmento di parlato chiuso dal rilevatore di voce o dal push-to-talk, già trascritto.
- **Parola di attivazione** — «computer» e le sue varianti configurate; indica che la Frase è rivolta all'app.
- **Router** — il componente che assegna a ogni Frase esattamente una Decisione di instradamento.
- **Decisione di instradamento** — l'esito del Router per una Frase: *Ignora*, *Scrivi*, *Comando rapido*, *Corsia locale* o *Agente*, con un motivo leggibile.
- **Comando rapido** — comando riconosciuto dalla grammatica fissa esistente (es. «annulla», «scorri giù»).
- **Corsia locale** — esecuzione di un comando a un passo proposto dal Classificatore on-device e approvato dal Validatore.
- **Agente** — Claude, eseguito tramite la CLI con la subscription, con gli strumenti di MacTalkAct.
- **Classificatore on-device** — il modello linguistico Apple sul Mac, usato per classificare Frasi e proporre azioni a un passo.
- **Validatore** — regole deterministiche che approvano o respingono una proposta del Classificatore on-device prima dell'esecuzione.
- **Chiacchiera** — Frase non rivolta al computer (parlare con altri, commenti, saluti).
- **Dettatura** — testo da inserire così com'è nel campo attivo.
- **Finestra di conversazione** — periodo dopo una risposta dell'app in cui le Frasi vengono valutate anche senza Parola di attivazione.
- **Memoria di conversazione** — elenco in RAM delle ultime interazioni (richiesta, esito, contesto) passato all'Agente. Diversa dalla **Memoria permanente** (`memoria.md`).
- **Inserimento** — un blocco di testo scritto dall'app nel campo attivo, registrato per poterlo annullare.
- **Modalità ridotta** — stato dell'app quando l'Agente non è disponibile (limite della subscription o CLI assente).
- **Corpus** — l'elenco di Frasi di prova, con contesto ed esito atteso, usato per verificare il Router.

## 4. Funzionalità

### 4.1 Router affidabile

**Descrizione:** ogni Frase passa da un unico Router che restituisce una Decisione di instradamento con un motivo. L'ordine di precedenza resta quello attuale per i casi espliciti (numeri sullo schermo, modalità dettatura, «stop»), poi Comandi rapidi, poi il Classificatore on-device. Quando il cursore è in un campo di testo, il Router non scrive più una Frase solo perché non inizia con un verbo noto: chiede al Classificatore on-device se è un comando, una Dettatura o Chiacchiera. Nel dubbio non scrive. Realizza UJ-1.

#### FR-1: Una sola Decisione di instradamento per Frase

Il Router assegna a ogni Frase non vuota esattamente una Decisione di instradamento e la registra nel log con motivo e tempo impiegato.

**Conseguenze (verificabili):**
- Ogni Frase arrivata al Router produce una riga di log `Instradamento: <decisione> · <motivo> · <ms>`.
- Le Frasi scartate prima del Router (vuote, durante il parlato dell'app) producono una riga con il motivo dello scarto.
- Per le Frasi decise come Chiacchiera o Ignora il log riporta solo la lunghezza, non il testo.

#### FR-2: La Parola di attivazione non viene mai scritta

Una Frase composta solo dalla Parola di attivazione (con eventuali intercalari e punteggiatura) non viene mai inserita nel campo attivo, in nessuno stato dell'app; arma l'ascolto come oggi.

**Conseguenze (verificabili):**
- «Computer», «Computer.», «ehi computer», «computer?» con il cursore in un campo di testo e app già armata → nessun Inserimento, HUD «Dimmi pure…».

#### FR-3: Classificazione nei campi di testo

Quando il cursore è in un campo di testo e la Frase non è una Dettatura esplicita né un Comando rapido, il Router usa il Classificatore on-device per decidere tra comando, Dettatura e Chiacchiera. Realizza UJ-1.

**Conseguenze (verificabili):**
- Comando → Decisione *Agente* (o *Corsia locale*, vedi §4.3); Dettatura → *Scrivi*; Chiacchiera → *Ignora*.
- Le 6 frasi della sessione del 26/10 (analisi §1.2) vengono instradate correttamente.

#### FR-4: Nel dubbio non scrivere

Se il Classificatore on-device non è disponibile, supera il tempo massimo o non è sicuro, il Router non scrive la Frase: mostra nell'HUD il testo con l'indicazione «Di' "scrivilo" per inserirlo» e, se entro 8 secondi arriva «scrivilo», la inserisce.

**Conseguenze (verificabili):**
- Con il Classificatore on-device disattivato, una Frase ambigua in un campo di testo non produce alcun Inserimento automatico.

#### FR-5: La Dettatura esplicita ha sempre la precedenza

«Scrivi …», la modalità dettatura e il push-to-talk in un campo di testo con una Frase classificata Dettatura continuano a scrivere senza ulteriori domande.

**Conseguenze (verificabili):**
- «computer, scrivi ciao a tutti» inserisce «ciao a tutti» anche se il Classificatore on-device lo considererebbe Chiacchiera.

#### FR-6: Corpus di verifica del Router

Esiste un Corpus di almeno 80 Frasi (contesto editabile sì/no, Decisione attesa) e un comando di debug che esegue il Router sul Corpus e riporta accuratezza ed errori per tipo.

**Conseguenze (verificabili):**
- Il comando termina con errore se anche una sola Frase attesa come comando o Chiacchiera viene decisa *Scrivi*.
- Il Corpus non contiene testo privato: frasi scritte a mano o anonimizzate.

### 4.2 Conversazione continua

**Descrizione:** dopo ogni risposta dell'app la conversazione resta aperta: Nico può continuare senza ripetere «computer», mentre la Chiacchiera viene ignorata. L'Agente riceve le ultime interazioni, quindi capisce i riferimenti a ciò che è appena successo. Qualunque Inserimento fatto dall'app può essere annullato a voce. Realizza UJ-1.

#### FR-7: Finestra di conversazione

Dopo ogni risposta (riuscita, fallita o domanda dell'Agente) si apre una Finestra di conversazione di 20 secondi [ASSUMPTION: durata da tarare]: le Frasi senza Parola di attivazione vengono classificate e quelle che sono comandi vengono eseguite. Ogni comando riapre la finestra.

**Conseguenze (verificabili):**
- Durante la finestra l'HUD mostra un indicatore discreto «conversazione aperta».
- Le Frasi classificate Chiacchiera durante la finestra vengono ignorate e non la prolungano.
- «basta così», «grazie», «a posto» chiudono la finestra subito.

#### FR-8: Memoria di conversazione per l'Agente

L'Agente riceve, insieme alla richiesta, la Memoria di conversazione: al massimo 5 interazioni degli ultimi 10 minuti, ognuna con richiesta, esito, app e, quando noto, il testo prima e dopo la modifica.

**Conseguenze (verificabili):**
- Dopo «modifica la domanda X in Y», la richiesta «rimetti la domanda di prima» ripristina X.
- La Memoria di conversazione vive solo in RAM, si svuota dopo 10 minuti di inattività, alla chiusura dell'app e con «dimentica la conversazione».

#### FR-9: Risposte coerenti alle domande dell'Agente

Quando l'Agente fa una domanda aperta e la risposta è solo «sì», «no» o non contiene informazione utile, l'app ripete la domanda una volta invece di inoltrare la risposta.

**Conseguenze (verificabili):**
- Alla domanda «con quale testo sostituisco?» la risposta «sì» genera la ripetizione della domanda, non un'azione.

#### FR-10: Annullare l'ultimo Inserimento

«Cancella quello che hai scritto» (e varianti come «non era da scrivere») rimuove l'ultimo Inserimento fatto dall'app, se il campo è lo stesso e il testo dopo l'Inserimento non è cambiato; altrimenti usa Annulla (Cmd+Z) e lo dice nell'HUD.

**Conseguenze (verificabili):**
- Dopo un Inserimento di «Bellissimo, ok, stop», il comando lo rimuove carattere per carattere senza toccare il testo precedente.

### 4.3 Corsia locale veloce

**Descrizione:** i comandi a un passo che la grammatica fissa non conosce non vanno più all'Agente: il Classificatore on-device propone un'azione (combinazione di tasti, app da aprire, sito da aprire, scorrimento) e il Validatore la approva solo se rientra in regole sicure. Tutto il resto va all'Agente. Realizza UJ-2.

#### FR-11: Comandi a un passo in locale

Una Frase classificata come comando a un passo viene eseguita dalla Corsia locale quando la proposta supera il Validatore.

**Conseguenze (verificabili):**
- «apri nuova tab», «chiudi questa scheda», «metti a schermo intero», «apri Spotify» vengono eseguiti senza avviare l'Agente.
- Tempo dalla fine della Frase all'azione: vedi NFR-1.

#### FR-12: Validatore della Corsia locale

Il Validatore approva solo combinazioni di tasti presenti in un elenco consentito, app installate trovate con la ricerca esistente, URL con schema esplicito o dominio riconosciuto; ogni altra proposta passa all'Agente.

**Conseguenze (verificabili):**
- Una proposta «tasti: ingrandisci» viene respinta e la Frase va all'Agente.
- Nessuna combinazione considerata rischiosa da `Safety.isRiskyKeys` viene eseguita dalla Corsia locale.

### 4.4 Agente efficiente e sempre disponibile

**Descrizione:** l'Agente consuma meno quota e tempo usando un modello adatto alla difficoltà, lavora meglio su liste ed editor web, e quando la subscription è esaurita l'app passa in Modalità ridotta in modo trasparente. Realizza UJ-3 e UJ-4.

#### FR-13: Modello proporzionato alla difficoltà

Il Router indica all'Agente se la richiesta è semplice (1–3 passi previsti) o complessa. Le richieste semplici usano un modello più rapido con effort basso; quelle complesse il modello configurato. Dire «pensaci bene» forza il modello configurato.

**Conseguenze (verificabili):**
- Nelle impostazioni si possono scegliere i due modelli; i valori predefiniti sono Sonnet 5.5 e Opus 5.5 [ASSUMPTION].
- Il log riporta il modello usato per ogni richiesta.

#### FR-14: Modalità ridotta

Quando la CLI segnala il limite della subscription, l'app entra in Modalità ridotta fino all'ora di ripresa indicata (o per 30 minuti se l'ora non è leggibile): le richieste per l'Agente ricevono subito un messaggio chiaro e il resto dell'app funziona. All'ora di ripresa l'app riprova e avvisa quando l'Agente è tornato. Realizza UJ-3.

**Conseguenze (verificabili):**
- In Modalità ridotta nessuna richiesta avvia la CLI; l'HUD risponde in meno di 0,5 s.
- La voce di menu mostra lo stato «Agente in pausa fino alle …».

#### FR-15: Azioni in blocco verificate

L'Agente dispone di uno strumento che esegue la stessa azione su più elementi numerati in una sola chiamata e restituisce lo stato di ciascuno dopo l'azione (per esempio casella spuntata sì/no). Realizza UJ-4.

**Conseguenze (verificabili):**
- Il compito di UJ-4 richiede meno di 10 chiamate di strumento (contro 39 del 26/10).
- I clic a coordinate restano possibili solo come ripiego e ogni risposta invita a verificare.

#### FR-16: Modifica affidabile negli editor web

L'Agente dispone di uno strumento che sostituisce un testo dentro il campo attivo anche quando il campo non espone il testo all'Accessibilità (editor di codice, celle di notebook), e verifica il risultato.

**Conseguenze (verificabili):**
- In una cella Jupyter in Edge, la sostituzione di una riga riesce al primo tentativo e il testo finale corrisponde a quello richiesto.

## 5. Requisiti non funzionali trasversali

- **NFR-1 Tempi.** Decisione del Router ≤ 0,8 s (90° percentile, modello caldo) dalla fine della Frase; azione della Corsia locale ≤ 1,5 s (90° percentile); primo strumento dell'Agente su richiesta semplice ≤ 3 s.
- **NFR-2 Privacy.** Classificazione, Memoria di conversazione e Corpus restano sul Mac. La Chiacchiera non viene salvata nel log. La Memoria di conversazione non viene mai scritta su disco.
- **NFR-3 Degrado prudente.** Senza Classificatore on-device l'app funziona con regole deterministiche e applica FR-4 (non scrive Frasi ambigue).
- **NFR-4 Qualità del Router.** Accuratezza sul Corpus ≥ 95%, zero comandi o Chiacchiera decisi *Scrivi*.
- **NFR-5 Sicurezza invariata.** Le conferme esistenti per azioni rischiose (invio, eliminazione, acquisto) restano obbligatorie in tutte le corsie.

## 6. Non obiettivi

- Non si cambia il motore di riconoscimento vocale né il rilevatore di voce.
- Non si aggiunge una parola di attivazione «sempre in ascolto» a basso consumo.
- Non si sostituisce l'Agente Claude con il modello on-device per compiti a più passi.
- Non si risolvono in questo ciclo i limiti minori del README (profili del browser, verso dello scorrimento, ⌘[ e ⌘] con tastiera italiana).

## 7. Perimetro

### 7.1 Incluso

Router unico con Classificatore on-device, Finestra di conversazione, Memoria di conversazione, annullamento dell'ultimo Inserimento, Corpus e comando di verifica, Corsia locale con Validatore, modello proporzionato alla difficoltà, Modalità ridotta, strumenti dell'Agente per azioni in blocco e modifica negli editor web.

### 7.2 Escluso

Supporto multilingue, sincronizzazione tra Mac, interfaccia grafica per modificare il Corpus, coda delle richieste da eseguire quando torna l'Agente.

## 8. Metriche di successo

**Primarie**
- **SM-1 Inserimenti indesiderati:** da 6 su 11 Frasi elaborate (26/10) a non più di 1 per ora d'uso, misurati con il log del Router e il numero di «cancella quello che hai scritto». Valida FR-2, FR-3, FR-4, FR-10.
- **SM-2 Richieste riuscite al primo tentativo:** almeno l'80% delle richieste non viene ripetuto entro 60 secondi. Valida FR-7, FR-8, FR-9.

**Secondarie**
- **SM-3 Tempo dei comandi a un passo:** mediana sotto 1,5 s. Valida FR-11.
- **SM-4 Uso di Opus:** almeno metà delle richieste all'Agente servite dal modello rapido. Valida FR-13.

**Contro-metriche (da non ottimizzare)**
- **SM-C1 Comandi ignorati:** le Frasi rivolte al computer decise *Ignora* non devono crescere per abbassare SM-1. Bilancia SM-1.
- **SM-C2 Conferme saltate:** nessuna riduzione dei tempi può passare dall'eliminare conferme. Bilancia SM-3.

## 9. Domande aperte

1. La Finestra di conversazione di 20 secondi è giusta, o in presenza di altre persone serve più corta? Da tarare dopo una settimana d'uso con SM-C1.
2. Il modello rapido (Sonnet 5.5, effort basso) è abbastanza preciso con gli strumenti di MacTalkAct? Da verificare con 10 richieste tipiche prima di renderlo predefinito.
3. Lo strumento di modifica negli editor web funziona allo stesso modo in Jupyter, Colab e VS Code web? Da verificare durante FR-16.

## 10. Indice delle assunzioni

- §4.2 FR-7 — Finestra di conversazione di 20 secondi.
- §4.4 FR-13 — Sonnet 5.5 ed Opus 5.5 come modelli predefiniti.
- Generale — Apple Intelligence resta attiva sul Mac (verificato il 26/10 su macOS 27.0.1).
- Generale — Memoria di conversazione: 5 interazioni, 10 minuti.
