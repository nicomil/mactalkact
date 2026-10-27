---
title: MacTalkAct — Mi capisce al primo colpo, veloce e sempre disponibile
status: final
created: 2026-10-26
updated: 2026-10-27
inputs:
  - _bmad-output/planning-artifacts/research/analisi-limiti-mactalkact-2026-10-26.md
  - _bmad-output/planning-artifacts/research/valutazione-motori-agente-2026-10-27.md
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

Infine (aggiunta del 27/10) l'Agente **non dipende più da un solo fornitore**: Nico sceglie se farlo lavorare con Claude, con Codex o con il modello sul Mac; quando il Motore scelto esaurisce la quota l'app passa da sola all'altro e, se nessuno dei due è disponibile, al modello locale, avvisando. Il modello locale diventa abbastanza bravo da rendere l'app utilizzabile anche senza alcun abbonamento, eventualmente con un modello più capace servito da Ollama o MLX sul Mac.

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

- **UJ-5. Codex finisce la quota, risponde Claude.** (aggiunto il 27/10)
  Nico ha scelto Codex dal menu della barra. A metà pomeriggio chiede «computer, apri la mail di Marco» e Codex risponde con il limite d'uso. Prima che l'Agente abbia toccato lo schermo, l'app ripete la richiesta con Claude e l'HUD dice «Codex in pausa fino alle 17:40 · uso Claude». La mail si apre. Le richieste successive vanno a Claude senza altri avvisi; alle 17:40 l'HUD dice «Codex è tornato» e l'app torna a usarlo. **Caso limite:** se il limite arriva dopo che l'Agente ha già cliccato, l'app non ripete la richiesta (potrebbe fare due volte la stessa cosa): dice che cosa è stato fatto e che la prossima richiesta userà Claude.

- **UJ-6. Sera, in treno, senza quota né rete.** (aggiunto il 27/10)
  Claude e Codex sono entrambi in pausa, oppure manca la connessione. Alla prima richiesta l'HUD avvisa «Claude e Codex non disponibili · passo al modello locale». Nico chiede «apri il notebook del corso e vai all'ultima cella»: il Motore locale lo fa in pochi passi, senza rete. A una richiesta troppo lunga risponde con onestà che non ci riesce col modello locale, senza lasciare il lavoro a metà in modo silenzioso.

- **UJ-7. Un modello più capace sul Mac.** (aggiunto il 27/10)
  Nico avvia Ollama con un modello da 9 miliardi di parametri. In Impostazioni › Motori sceglie «Server locale», vede l'elenco dei modelli del server, ne sceglie uno e preme «Prova»: l'app mostra il tempo al primo strumento e lo stato «pronto». Da quel momento il Motore locale usa quel modello; se il server è spento torna al modello Apple e lo dice.

## 3. Glossario

- **Frase** — un segmento di parlato chiuso dal rilevatore di voce o dal push-to-talk, già trascritto.
- **Parola di attivazione** — «computer» e le sue varianti configurate; indica che la Frase è rivolta all'app.
- **Router** — il componente che assegna a ogni Frase esattamente una Decisione di instradamento.
- **Decisione di instradamento** — l'esito del Router per una Frase: *Ignora*, *Scrivi*, *Comando rapido*, *Corsia locale* o *Agente*, con un motivo leggibile.
- **Comando rapido** — comando riconosciuto dalla grammatica fissa esistente (es. «annulla», «scorri giù»).
- **Corsia locale** — esecuzione di un comando a un passo proposto dal Classificatore on-device e approvato dal Validatore.
- **Agente** — chi esegue le richieste a più passi con gli strumenti di MacTalkAct. Gira su uno dei Motori.
- **Motore** — il fornitore che fa ragionare l'Agente: *Claude* (CLI `claude`, abbonamento Claude), *Codex* (CLI `codex`, account ChatGPT) o *Locale* (modello sul Mac).
- **Motore scelto** — il Motore selezionato da Nico nel menu o nelle impostazioni.
- **Catena di riserva** — l'ordine in cui l'app prova i Motori quando il Motore scelto non è disponibile: prima l'altro Motore cloud, poi il Motore locale.
- **Passaggio di Motore** — il momento in cui l'app passa a un Motore di riserva o torna al Motore scelto; viene sempre segnalato nell'HUD.
- **Motore locale** — l'Agente eseguito interamente sul Mac, con il modello Apple oppure con un Modello locale esteso.
- **Modello locale esteso** — un modello più capace di quello Apple, servito sul Mac da Ollama, LM Studio o un server MLX.
- **Azione con effetti** — una chiamata di strumento che cambia qualcosa (clic, scrittura, tasti, apertura di app o siti); osservare e fare screenshot non lo sono.
- **Banco di prova dell'Agente** — l'elenco di compiti su pagine di prova locali, con esito atteso, usato per misurare i Motori.
- **Classificatore on-device** — il modello linguistico Apple sul Mac, usato per classificare Frasi e proporre azioni a un passo.
- **Validatore** — regole deterministiche che approvano o respingono una proposta del Classificatore on-device prima dell'esecuzione.
- **Chiacchiera** — Frase non rivolta al computer (parlare con altri, commenti, saluti).
- **Dettatura** — testo da inserire così com'è nel campo attivo.
- **Finestra di conversazione** — periodo dopo una risposta dell'app in cui le Frasi vengono valutate anche senza Parola di attivazione.
- **Memoria di conversazione** — elenco in RAM delle ultime interazioni (richiesta, esito, contesto) passato all'Agente. Diversa dalla **Memoria permanente** (`memoria.md`).
- **Inserimento** — un blocco di testo scritto dall'app nel campo attivo, registrato per poterlo annullare.
- **Modalità ridotta** — stato dell'app quando nessun Motore è disponibile, compreso il Motore locale (per esempio modello Apple spento e Catena di riserva disattivata).
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

### 4.5 Gestione dell'app dalle impostazioni

**Descrizione:** aggiunta il 27/10. Oggi la finestra delle impostazioni si apre vuota e molti comportamenti sono fissati nel codice (tempi, soglie, modelli, limiti dell'agente). Questa funzionalità non aggiunge capacità nuove: rende **visibile e modificabile** tutto ciò che l'app già fa, con valori predefiniti identici al comportamento attuale e un menu nella barra con gli interruttori più usati.

#### FR-17: Finestra delle impostazioni utilizzabile

Nico apre le impostazioni dal menu e vede una finestra con una barra laterale a sezioni (Ascolto, Conversazione, Comprensione, Agente, Voce e suoni, Numeri, Memoria e macro, Permessi, Stato e diagnostica).

**Conseguenze (verificabili):**
- La finestra si apre con il contenuto visibile, ridimensionabile, e ricorda l'ultima sezione aperta.

#### FR-18: Tempi e soglie dell'ascolto

Nico vede e modifica: la parola di attivazione (al posto di «computer», con le varianti «ok …», «ehi …» generate da sole), silenzio che chiude una frase, sensibilità del rilevatore di voce, durata massima di una frase, silenzio che chiude la dettatura lunga, chiusura automatica della sessione a mani libere.

**Conseguenze (verificabili):**
- I valori predefiniti coincidono con quelli attuali (0,8 s; 0,006; 60 s; 4 s; 60 s).
- Le modifiche valgono dalla frase successiva, senza riavviare l'app.

#### FR-19: Tempi della conversazione

Durata della Finestra di conversazione, dell'ascolto dopo «computer» da solo, della proposta «scrivilo», dell'attesa di una risposta all'Agente e di una conferma; numero e durata delle voci della Memoria di conversazione.

#### FR-20: Comprensione e Agente

Interruttori del Classificatore on-device e della Corsia locale, tempo massimo del classificatore, lunghezza massima per la Corsia locale; modelli rapido e profondo con il loro effort, numero massimo di passi e tempo massimo di un compito, finestra di validità di una conferma, accesso a Claude (abbonamento o chiave), ripulitura della dettatura.

#### FR-21: Voce, suoni e messaggi

Risposte a voce con volume e velocità, suoni sì/no e volume, durata dei messaggi dell'HUD (riuscita, risposta dell'Agente, errore).

#### FR-22: Numeri, memoria e macro

Durata e numero massimo dei numeri sullo schermo; elenco dei fatti e delle macro salvati con eliminazione e apertura del file; svuotamento della Memoria di conversazione.

#### FR-23: Permessi e stato

Stato di Accessibilità, Microfono e Registrazione schermo con il pulsante per concederli; disponibilità del modello Apple, comando `claude` trovato, stato dell'Agente (disponibile, in pausa fino alle…), file di log.

#### FR-24: Menu ricco nella barra

Il menu della barra mostra lo stato dell'Agente, un sottomenu «Impostazioni rapide» con gli interruttori principali e la durata della conversazione, e collegamenti diretti alle sezioni delle impostazioni.

**Feature-specific NFRs:**
- **NFR-6 Nessun cambiamento di comportamento.** Con i valori predefiniti l'app si comporta esattamente come prima; ogni sezione ha «Ripristina predefiniti».
- **NFR-7 Effetto immediato.** Ogni modifica vale dall'azione successiva, senza riavvio.

### 4.6 Più Motori per l'Agente

**Descrizione:** aggiunta il 27/10. L'Agente può lavorare con Claude, con Codex o con il Motore locale. Nico sceglie il Motore; quando non è disponibile l'app usa la Catena di riserva e lo dice. Gli strumenti, il prompt, la memoria e le conferme sono gli stessi per tutti i Motori: cambia solo chi ragiona. Realizza UJ-5 e UJ-6.

#### FR-25: Scelta del Motore

Nico sceglie il Motore scelto tra Claude, Codex e Locale dal menu della barra e dalle impostazioni. La scelta vale dalla richiesta successiva e resta dopo il riavvio.

**Conseguenze (verificabili):**
- Il valore predefinito è Claude: senza toccare nulla l'app usa l'Agente come prima.
- Un Motore non installato o non autenticato è visibile ma marcato («non trovato», «accesso da fare») e il menu lo spiega.

#### FR-26: Codex come Motore

Con Codex scelto, l'Agente esegue la richiesta con la CLI `codex` e il login ChatGPT dell'utente, usando solo gli strumenti di MacTalkAct, con due livelli (rapido e profondo) come per Claude (FR-13).

**Conseguenze (verificabili):**
- Codex non ha a disposizione shell, file, browser, computer use, plugin né la configurazione personale `~/.codex/config.toml`; non salva sessioni su disco.
- Memoria permanente, blocco `<recent>`, conferme e verifica dei risultati funzionano come con Claude.
- Il log riporta Motore e modello di ogni richiesta.

#### FR-27: Catena di riserva

Quando il Motore scelto non è disponibile (in pausa per limite, non installato, non autenticato), l'app usa il primo Motore disponibile della Catena di riserva: l'altro Motore cloud, poi il Motore locale. Quando il Motore scelto torna disponibile, l'app torna a usarlo.

**Conseguenze (verificabili):**
- Ogni Passaggio di Motore è segnalato una volta nell'HUD: «Codex in pausa fino alle 17:40 · uso Claude», «Claude e Codex non disponibili · passo al modello locale», «Codex è tornato».
- Nessun processo di un Motore in pausa viene avviato.
- La Catena di riserva si può disattivare; disattivata, l'app si comporta come la Modalità ridotta di FR-14.

#### FR-28: Limite a metà richiesta

Se un Motore si ferma per limite d'uso o errore di rete durante una richiesta, l'app ripete la richiesta con il Motore successivo della Catena di riserva solo se non è ancora stata eseguita nessuna Azione con effetti; altrimenti si ferma e dice che cosa è stato fatto.

**Conseguenze (verificabili):**
- Nessuna Azione con effetti viene mai eseguita due volte per effetto di un Passaggio di Motore.
- Al massimo un nuovo tentativo per Motore e per richiesta.

#### FR-29: Disponibilità di ogni Motore

Ogni Motore ha il proprio stato: disponibile, in pausa fino a una data e ora, non trovato, accesso da fare. Il messaggio di limite di Codex («try again at …», «try again in …», anche con un giorno diverso per il limite settimanale) viene letto come quello di Claude.

**Conseguenze (verificabili):**
- Menu della barra e Stato e diagnostica mostrano lo stato di tutti i Motori e quale è in uso adesso.
- Se l'ora di ripresa non è leggibile la pausa dura 30 minuti, come oggi.

### 4.7 Bravo anche da solo

**Descrizione:** aggiunta il 27/10. Il Motore locale deve dare risultati buoni senza Claude né Codex, con il modello Apple sempre presente e, se Nico lo vuole, con un Modello locale esteso servito sul Mac. La qualità si misura con un Banco di prova dell'Agente, non a sensazione. Realizza UJ-6 e UJ-7.

#### FR-30: Agente locale

Il Motore locale esegue richieste a più passi con gli strumenti di MacTalkAct, entro un numero massimo di passi più basso di quello cloud [ASSUMPTION: 8 passi]. Quando il compito supera le sue capacità si ferma e lo dice.

**Conseguenze (verificabili):**
- Senza rete e con entrambi i Motori cloud in pausa, «apri la mail di Marco» e «modifica la domanda in che cos'è Internet» riescono sulle pagine di prova del Banco.
- Le conferme di sicurezza sono identiche a quelle dei Motori cloud (NFR-5).

#### FR-31: Modello locale esteso

Nico può collegare il Motore locale a un server compatibile OpenAI sul Mac (Ollama, LM Studio, `mlx_lm.server`, Rapid-MLX), scegliere il modello dall'elenco del server e provarlo. Se il server non risponde, il Motore locale usa il modello Apple e lo segnala.

**Conseguenze (verificabili):**
- Il pulsante «Prova» mostra esito e tempo al primo strumento.
- Il modello viene tenuto in memoria solo per un tempo limitato dopo l'ultima richiesta [ASSUMPTION: 10 minuti], per lasciare memoria al resto del Mac.

#### FR-32: Banco di prova dell'Agente

Esiste un Banco di prova dell'Agente (almeno 20 compiti su pagine HTML locali e app di sistema, con esito atteso verificabile) e un comando di debug che lo esegue con un Motore scelto e riporta compiti riusciti, passi, tempo al primo strumento e tempo totale.

**Conseguenze (verificabili):**
- Lo stesso Banco gira con Claude, Codex, modello Apple e Modello locale esteso, e i risultati si confrontano in una tabella.
- Le pagine di prova non contengono dati privati.

#### FR-33: Niente cloud dove non serve

Le funzioni dell'app diverse dall'Agente non richiedono Claude: la ripulitura della dettatura e i passi delle macro che la grammatica non conosce usano il Motore in uso, compreso quello locale.

**Conseguenze (verificabili):**
- Con tutti i Motori cloud non disponibili, una macro con un passo libero («apri la posta e cerca Marco») viene eseguita invece di fallire con «Non so eseguire … senza Claude».

#### FR-34: Motori nelle impostazioni

Una sezione «Motori» mostra il Motore scelto, l'interruttore della Catena di riserva e, per ogni Motore, percorso del comando, stato dell'accesso, modelli rapido e profondo con il loro sforzo; per il Motore locale il modello Apple o il server esteso (indirizzo, modello, «Prova»).

**Feature-specific NFRs:**
- **NFR-8 Stesse mani per tutti.** Ogni Motore agisce solo tramite gli strumenti di MacTalkAct; nessun Motore riceve shell, accesso ai file o strumenti propri.
- **NFR-9 Tempi dei Motori.** Scelta del Motore ≤ 50 ms; primo strumento con Codex rapido ≤ 4 s [ASSUMPTION]; con il modello Apple ≤ 2 s; con il Modello locale esteso ≤ 5 s su M1 16 GB [ASSUMPTION da misurare con il Banco].
  *Misurato il 27/10:* Codex rapido 3,4–4,3 s ✓; modello Apple: prima azione 5,6 s ma compito intero 6,5 s (l'app osserva e pianifica prima di agire; il «primo strumento» non è più il passo giusto da misurare); `qwen3.5:9b` su M1 ~19 s ✗, limite dell'hardware.
- **NFR-10 Il locale resta locale.** Con il Motore locale nessun dato lascia il Mac: il server esteso è accettato senza avvisi solo su `localhost`; un indirizzo diverso richiede una conferma esplicita nelle impostazioni.

### 4.8 Mani da computer use

L'Agente usa il Mac come il computer use di Claude e di Codex (ricerca del 27/10, `computer-use-claude-codex-2026-10-27.md`): ogni azione dice da sola cosa è cambiato, gli elementi mantengono il proprio id, più azioni partono in una sola chiamata e le mani coprono anche trascinare, passare sopra, impostare valori, selezionare testo, usare i menu dell'app e ingrandire una parte dello schermo.

#### FR-35: Esito di ogni azione

Ogni strumento che agisce attende che l'interfaccia si assesti (al massimo 3 s, di più se la pagina sta caricando) e restituisce le differenze rispetto a prima: titolo della finestra, app in primo piano, elemento attivo, elementi comparsi, scomparsi o cambiati.

**Conseguenze (verificabili):**
- Dopo «clicca Prezzi» l'esito contiene il nuovo titolo della pagina senza che il Motore chiami `observe`.
- Un'azione che non cambia nulla lo dice esplicitamente («nothing changed»).

#### FR-36: Id stabili

Un elemento mantiene lo stesso id per tutta la richiesta finché esiste; un id che non esiste più dà un errore che lo dice.

#### FR-37: Mani complete

Gli strumenti coprono: impostare il valore di un campo o di un cursore, eseguire un'azione secondaria esposta dall'elemento (espandi, mostra menu, incrementa), selezionare un testo dentro un campo, trascinare da un elemento o punto a un altro, passare sopra un elemento, clic con tasti modificatori e clic multipli, scegliere una voce dai menu dell'app per nome (con l'elenco delle voci e delle scorciatoie), screenshot di una regione a piena risoluzione. `observe` segnala le azioni secondarie e i campi impostabili.

#### FR-38: Azioni in serie

Uno strumento esegue più azioni in ordine in una sola chiamata, si ferma al primo errore indicando quali azioni non sono state eseguite e restituisce l'esito finale. Le conferme e i controlli di sicurezza valgono per ogni azione della serie.

#### FR-39: Esc ferma l'Agente

Mentre l'Agente lavora, il tasto Esc premuto dall'utente lo ferma subito, come «stop» a voce. Gli Esc inviati dall'Agente stesso non lo fermano.

#### FR-40: Banco esteso

Il Banco di prova include compiti che richiedono le nuove mani: trascinare una scheda, passare sopra un menu, impostare un cursore, compilare un modulo lungo, leggere un numero dentro la foto di un'etichetta.

**Feature-specific NFRs:**
- **NFR-11 Meno giri.** Sui 20 compiti del Banco del 27/10, con Claude e Codex: chiamate per compito −30% e tempo mediano −25% [ASSUMPTION]; con il Motore locale nessun peggioramento.

## 5. Requisiti non funzionali trasversali

- **NFR-1 Tempi.** Decisione del Router ≤ 0,8 s (90° percentile, modello caldo) dalla fine della Frase; azione della Corsia locale ≤ 1,5 s (90° percentile); primo strumento dell'Agente su richiesta semplice ≤ 3 s.
- **NFR-2 Privacy.** Classificazione, Memoria di conversazione e Corpus restano sul Mac. La Chiacchiera non viene salvata nel log. La Memoria di conversazione non viene mai scritta su disco.
- **NFR-3 Degrado prudente.** Senza Classificatore on-device l'app funziona con regole deterministiche e applica FR-4 (non scrive Frasi ambigue).
- **NFR-4 Qualità del Router.** Accuratezza sul Corpus ≥ 95%, zero comandi o Chiacchiera decisi *Scrivi*.
- **NFR-5 Sicurezza invariata.** Le conferme esistenti per azioni rischiose (invio, eliminazione, acquisto) restano obbligatorie in tutte le corsie.

## 6. Non obiettivi

- Non si cambia il motore di riconoscimento vocale né il rilevatore di voce.
- Non si aggiunge una parola di attivazione «sempre in ascolto» a basso consumo.
- ~~Non si sostituisce l'Agente Claude con il modello on-device per compiti a più passi.~~ Superato il 27/10 da §4.6 e §4.7: il Motore locale esegue compiti a più passi, con un tetto di passi più basso.
- Non si usano chiavi API OpenAI né il modello Apple su Private Cloud Compute in questo ciclo (vedi Domande aperte).
- La gestione dalle impostazioni (§4.5) non aggiunge capacità nuove all'app.
- Non si risolvono in questo ciclo i limiti minori del README (profili del browser, verso dello scorrimento, ⌘[ e ⌘] con tastiera italiana).

## 7. Perimetro

### 7.1 Incluso

Router unico con Classificatore on-device, Finestra di conversazione, Memoria di conversazione, annullamento dell'ultimo Inserimento, Corpus e comando di verifica, Corsia locale con Validatore, modello proporzionato alla difficoltà, Modalità ridotta, strumenti dell'Agente per azioni in blocco e modifica negli editor web.

### 7.2 Escluso

Supporto multilingue, sincronizzazione tra Mac, interfaccia grafica per modificare il Corpus, coda delle richieste da eseguire quando torna l'Agente, esecuzione contemporanea di più Motori sulla stessa richiesta, download dei modelli locali dall'app (si usano quelli del server).

## 8. Metriche di successo

**Primarie**
- **SM-1 Inserimenti indesiderati:** da 6 su 11 Frasi elaborate (26/10) a non più di 1 per ora d'uso, misurati con il log del Router e il numero di «cancella quello che hai scritto». Valida FR-2, FR-3, FR-4, FR-10.
- **SM-2 Richieste riuscite al primo tentativo:** almeno l'80% delle richieste non viene ripetuto entro 60 secondi. Valida FR-7, FR-8, FR-9.

**Secondarie**
- **SM-3 Tempo dei comandi a un passo:** mediana sotto 1,5 s. Valida FR-11.
- **SM-4 Uso di Opus:** almeno metà delle richieste all'Agente servite dal modello rapido. Valida FR-13.

- **SM-5 Tempo senza Agente:** minuti in cui una richiesta per l'Agente non trova alcun Motore, da 35 minuti il 26/10 (18:25–19:00) a zero. Valida FR-27.
- **SM-7 Mani da computer use:** sul Banco esteso almeno il 90% dei compiti riusciti con Claude e con Codex [ASSUMPTION]. Valida FR-35…FR-40.
- **SM-6 Qualità del Motore locale:** sul Banco di prova almeno il 70% dei compiti riusciti con il modello Apple e almeno l'85% con il Modello locale esteso [ASSUMPTION]. Valida FR-30, FR-31.

**Contro-metriche (da non ottimizzare)**
- **SM-C1 Comandi ignorati:** le Frasi rivolte al computer decise *Ignora* non devono crescere per abbassare SM-1. Bilancia SM-1.
- **SM-C2 Conferme saltate:** nessuna riduzione dei tempi può passare dall'eliminare conferme. Bilancia SM-3.
- **SM-C3 Azioni doppie:** zero azioni ripetute per effetto di un Passaggio di Motore. Bilancia SM-5.

## 9. Domande aperte

1. La Finestra di conversazione di 20 secondi è giusta, o in presenza di altre persone serve più corta? Da tarare dopo una settimana d'uso con SM-C1.
2. Il modello rapido (Sonnet 5.5, effort basso) è abbastanza preciso con gli strumenti di MacTalkAct? Da verificare con 10 richieste tipiche prima di renderlo predefinito.
3. Lo strumento di modifica negli editor web funziona allo stesso modo in Jupyter, Colab e VS Code web? Da verificare durante FR-16.
4. `codex exec` può essere avviato in anticipo e attendere la richiesta su stdin, come fa oggi `claude`? Se no, serve `codex app-server`. Da decidere nello spike della Storia 4.1.
5. Quale Modello locale esteso conviene su un M1 con 16 GB (Qwen 3.5 4B o 9B, Gemma 4 E4B) e con quale server (Ollama o LM Studio)? Da decidere con il Banco di prova nella Storia 5.2.
6. Un'app firmata localmente può ottenere l'entitlement per il modello Apple su Private Cloud Compute? Se sì, è un Motore intermedio gratuito tra locale e cloud.

## 10. Indice delle assunzioni

- §4.2 FR-7 — Finestra di conversazione di 20 secondi.
- §4.4 FR-13 — Sonnet 5.5 ed Opus 5.5 come modelli predefiniti.
- Generale — Apple Intelligence resta attiva sul Mac (verificato il 26/10 su macOS 27.0.1).
- Generale — Memoria di conversazione: 5 interazioni, 10 minuti.
- §4.7 FR-30 — 8 passi massimi per il Motore locale.
- §4.7 FR-31 — Modello locale esteso tenuto in memoria 10 minuti dopo l'ultima richiesta.
- §4.6 NFR-9 — tempi al primo strumento di Codex e del Modello locale esteso.
- §8 SM-6 — soglie di qualità del Motore locale (70% Apple, 85% esteso).
- Generale — Codex resta installato tramite ChatGPT.app con login ChatGPT (verificato il 27/10: codex-cli 0.164.0-alpha.11.1).
- §4.8 NFR-11, SM-7 — riduzione di chiamate e tempi, 90% sul Banco esteso.
