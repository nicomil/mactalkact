# MacTalkAct

Controlla il Mac con la voce quando hai le mani occupate. Funziona come un'app di dettatura alla Wispr Flow, ma oltre a scrivere **agisce**: scorre, clicca, apre app, preme scorciatoie e modifica il testo. Quello che dici viene scritto oppure eseguito, e l'app capisce da sola quale delle due cose vuoi.

## Come funziona

Ogni frase arriva a un **Router**, che prende una sola decisione: ignorarla, scriverla, eseguirla con un comando rapido, eseguirla in locale o affidarla all'agente. La decisione e il motivo finiscono nel log (`Instradamento: … · motivo · ms`).

1. **Comandi rapidi** (grammatica fissa, nessuna AI, meno di 150 ms): «giù», «invio», «annulla», «apri Safari», «clicca Invia»…
2. **Dettatura**: con il cursore in un campo di testo, il **modello linguistico Apple sul Mac** (FoundationModels) decide in circa 0,7 secondi se la frase è testo da scrivere, un comando o chiacchiera con chi è nella stanza. Funziona offline e non consuma la subscription. **Nel dubbio non scrive**: mostra la frase e aspetta «scrivilo».
3. **Corsia locale** ⚡️: i comandi di un solo passo che la grammatica non conosce («riapri la scheda che ho chiuso», «metti a schermo intero», «aprimi il calendario») vengono tradotti dal modello Apple in un'azione, che regole fisse controllano prima di eseguirla. Circa 1,2 secondi, senza Claude.
4. **Agente**: tutto il resto («apri la mail di LangChain», «modifica la domanda», «rispondi a Marco che confermo e invia») viene affidato a un agente Claude che guarda lo schermo, agisce, controlla il risultato e continua finché il compito è fatto, come il computer use di Claude o Codex. Le richieste semplici usano un modello più rapido.

Il riconoscimento vocale avviene **interamente sul Mac** con il modello italiano di Apple (`SpeechAnalyzer` + `DictationTranscriber`, macOS 27). A Claude arriva solo il testo, insieme a una descrizione dello schermo letta tramite Accessibilità.

Claude viene usato tramite il comando `claude` (Claude Code), quindi con il tuo **abbonamento Claude**: non serve una chiave API. In alternativa, nelle impostazioni si può usare una chiave API.

## Requisiti

- macOS 27 su Apple Silicon
- Xcode installato (serve per il plugin delle macro SwiftUI)
- Per la corsia 3: [Claude Code](https://claude.com/claude-code) installato, con l'accesso già fatto almeno una volta (`claude` nel Terminale). In alternativa, una chiave API Anthropic

## Compilare e avviare

```bash
scripts/build-app.sh
open build/MacTalkAct.app
```

Al primo avvio:

1. **Microfono**: consenti.
2. **Accessibilità**: Impostazioni di Sistema › Privacy e sicurezza › Accessibilità › attiva MacTalkAct. Serve per leggere lo schermo, premere tasti e cliccare.
3. **Registrazione schermo** (consigliata): permette all'agente di fare screenshot della finestra in primo piano quando l'albero dell'interfaccia non basta. Le immagini vengono inviate a Claude solo durante un compito. Dopo averla concessa, riapri l'app.
4. Il modello vocale italiano viene scaricato la prima volta, se non è già presente.
5. Nelle impostazioni (icona ✋ nella barra dei menu › Impostazioni…) controlla che il comando `claude` sia stato trovato. Se usi una chiave API, scegli «Chiave API Anthropic» e incollala: viene salvata nel Portachiavi.

> **Nota sulla firma.** Senza certificato l'app viene firmata in modalità ad-hoc: macOS la riconosce dall'impronta del file, che cambia a ogni ricompilazione, quindi il permesso di Accessibilità concesso a una build non vale per la successiva (nella lista compare ancora attiva, ma l'app risulta «da concedere»). Per evitarlo, una volta sola:
>
> ```bash
> scripts/setup-signing.sh   # crea il certificato locale «MacTalkAct Local Signing»
> scripts/build-app.sh       # da qui in poi firma con quel certificato
> ```

## Come si usa

| Modo | Come | Quando |
|---|---|---|
| **Push-to-talk** | Tieni premuto **⌥ destro**, parla, rilascia | Hai una mano libera |
| **Sessione a mani libere** | **Doppio tocco** su ⌥ destro. Si chiude dicendo «basta» o dopo 60 s di silenzio | Sequenze di comandi |
| **Ascolto continuo** | Dal menu: «Ascolto continuo». Poi di' «**Computer**, apri Mail» | Zero mani |

Dopo ogni risposta la **conversazione resta aperta per 20 secondi** (una piccola pillola «Ti ascolto»): puoi continuare senza ripetere «Computer» («cambia anche la seconda», «no, quella sotto»), mentre la chiacchiera con chi è nella stanza viene ignorata. «Basta così» o «grazie» la chiudono subito; la durata si cambia nelle impostazioni. Se dici solo «Computer», la frase successiva viene accettata qualunque sia, e la parola «Computer» da sola non viene mai scritta.

L'agente ricorda le **ultime 5 interazioni dei 10 minuti precedenti**, con il testo prima e dopo ogni modifica: «rimetti la domanda di prima» funziona. Questa memoria vive solo in RAM; «dimentica la conversazione» la svuota. Se l'app ha scritto qualcosa che non volevi, «**cancella quello che hai scritto**» toglie esattamente quel testo (se il campo è cambiato nel frattempo usa Annulla e te lo dice).

In ascolto continuo un rilevatore di voce divide l'audio in frasi: una frase inizia quando cominci a parlare e finisce dopo 0,8 secondi di silenzio. Ogni frase viene trascritta da sola, come nel push-to-talk, e il comando parte circa 1,5 secondi dopo che hai smesso di parlare.

Il tasto si cambia nelle impostazioni (⌥ destro, ⌘ destro o Fn). Se scegli Fn, imposta prima Impostazioni › Tastiera › «Premi il tasto 🌐 per» › «Non fare nulla».

### Cosa puoi dire

- **Scrivere**: parla con il cursore in un campo di testo. Oppure «scrivi …», «a capo», «invio», «cancella», «cancella parola», «seleziona tutto».
- **Muoverti**: «giù», «su», «scorri molto giù», «pagina giù», «vai in cima», «vai in fondo», «ancora» (ripete l'ultimo comando).
- **Navigare**: «indietro», «avanti», «ricarica», «nuova scheda», «scheda successiva», «barra indirizzi».
- **Cliccare e aprire**: «clicca Invia», «premi Salva», «apri Safari», «vai su Slack», «apri youtube.com», «app precedente».
- **Modificare**: «copia», «incolla», «taglia», «annulla», «ripristina», «salva», «chiudi».
- **Con Claude**: «cancella l'ultima frase», «sostituisci martedì con giovedì», con testo selezionato «traducilo in inglese», «rispondi a Marco che confermo e invia».
- **Fermarsi**: «stop» interrompe un'azione in corso.

La guida completa è nel menu › Guida ai comandi.

### Sicurezza

- Le azioni difficili da annullare (inviare, eliminare, comprare, chiudere un'app) chiedono **sempre conferma**: rispondi «sì», qualsiasi altra risposta annulla.
- Il testo letto dallo schermo viene passato a Claude come dato e mai come istruzione, per difendersi da email o pagine che cercano di dare ordini all'agente.
- La chiave API sta nel Portachiavi. La trascrizione audio non lascia il Mac.

### Privacy

**Cosa resta sul Mac.** L'audio non viene mai salvato. Restano solo:

| Dove | Cosa | Per quanto |
|---|---|---|
| `~/Library/Logs/MacTalkAct.log` | Decisioni e tempi. Il testo compare solo per le frasi accettate come comandi; delle chiacchiere e del testo dettato resta solo la lunghezza. Email, telefoni, IBAN, numeri di carta, codici fiscali e codici segreti sono sempre mascherati (`[email]`, `[telefono]`…). | Un file al giorno (`MacTalkAct-AAAA-MM-GG.log`), conservato per 7 giorni |
| `~/Library/Application Support/MacTalkAct/memoria.md` | Fatti e macro che hai chiesto di ricordare | Finché non li cancelli |
| Preferenze e Portachiavi | Impostazioni e chiave API | Finché non le cambi |

Log e memoria sono leggibili solo dal tuo utente. La memoria della conversazione (ultime 5 interazioni) vive solo in RAM. Claude e Codex vengono avviati senza salvare le sessioni.

**Cosa va a Claude e Codex.** Solo durante un compito dell'agente: la richiesta, la descrizione della finestra in primo piano ed eventuali screenshot. Prima dell'invio, numeri di carta, IBAN, codici fiscali e codici segreti letti dallo schermo diventano `[carta]`, `[IBAN]`, `[codice fiscale]`, `[segreto]`. Email e telefoni restano, perché servono per scrivere a qualcuno. I campi password non vengono mai letti.

**App e siti riservati.** Gestori di password (Password, Portachiavi, 1Password, Bitwarden, KeePassXC), banche, pagamenti e siti della pubblica amministrazione sono riservati: lì Claude e Codex non leggono e non toccano niente. L'agente lavora con il modello sul Mac oppure si ferma. Se un compito arriva su una finestra riservata a metà strada, il motore cloud viene fermato. Gli elenchi si modificano in Impostazioni › Privacy.

**Modalità privata.** «Modalità privata» (o dal menu ✋) attiva per 30 minuti: niente Claude né Codex, niente testo delle frasi nel log, niente memoria (né fatti né conversazione). «Esci dalla modalità privata» la chiude prima. Mentre è attiva, l'icona nella barra dei menu diventa un lucchetto.

**Memoria.** L'agente non salva mai fatti che contengono password, codici, dati bancari o di carta, e lo dice.

**Log dettagliato.** Per una diagnosi, Impostazioni › Privacy › «Log dettagliato» aggiunge cosa l'agente ha letto e fatto e il testo delle frasi ignorate (anche questo mascherato). «Cancella i log ora» elimina tutti i file di log.

## Impostazioni

La **parola di attivazione** si sceglie in Impostazioni › Ascolto: al posto di «computer» puoi usare la parola che preferisci. L'app accetta da sola anche «ok …», «ehi …», «hey …» e le storpiature tipiche del riconoscimento («i …», «e …»), si possono aggiungere altre frasi e sotto il campo compare l'elenco completo. Conviene una parola di almeno 4 lettere che in casa non si dice per caso; se il riconoscimento la scrive in modo diverso, attiva il log dettagliato (Impostazioni › Privacy): mostra come l'ha sentita, e quella forma si aggiunge tra le altre.

Dal menu ✋ › **Impostazioni** si apre una finestra con una barra laterale a sezioni: Ascolto, Conversazione, Comprensione, Agente, Voce e suoni, Numeri, Memoria e macro, Privacy, Permessi, Stato e diagnostica. Ogni comportamento regolabile dell'app è lì, con il suo valore, una spiegazione e il valore predefinito: silenzio che chiude una frase, sensibilità del rilevatore di voce, durata della conversazione aperta, attese di conferma, modelli ed effort dell'agente, passi e tempo massimi di un compito, volume della voce e dei suoni, durata dei messaggi, numeri sullo schermo. Ogni sezione ha «Ripristina predefiniti»: i predefiniti coincidono con il comportamento dell'app prima che le impostazioni esistessero. Le modifiche valgono dall'azione successiva, senza riavviare.

La sezione **Memoria e macro** elenca fatti e macro con un pulsante per eliminarli; **Permessi** mostra lo stato aggiornato dei tre permessi di macOS; **Stato e diagnostica** dice se il modello Apple è disponibile, dove si trova `claude`, se l'agente è in pausa e apre il log.

Il menu della barra mostra lo stato dell'agente e della comprensione, un sottomenu **Impostazioni rapide** (modello Apple, corsia locale, modello rapido, Claude sì/no, risposte a voce, suoni, durata della conversazione, modello per i compiti lunghi) e un collegamento a ogni sezione.

## Numeri, memoria e macro

### «Mostra numeri»

Mette un numero arancione su ogni elemento cliccabile della finestra in primo piano, comprese le icone senza nome. Poi basta dire il numero: «12», «dodici», «clicca il 12», «doppio clic 12», «destro 12». I numeri spariscono dopo il clic, con «nascondi numeri» o dopo 30 secondi. Mentre sono visibili, in ascolto continuo non serve dire «Computer».

### Memoria personale

Il file `~/Library/Application Support/MacTalkAct/memoria.md` (menu ✋ › Memoria e macro…) contiene fatti e preferenze che l'agente legge a ogni richiesta:

```markdown
## Fatti
- «profilo aula IB» = Microsoft Edge, profilo «Aulab»
- La mia mail di lavoro è su Outlook web in Edge

## Macro
- modalità lavoro: apri Slack; apri Mail; apri Visual Studio Code
```

A voce: «ricorda che…», «dimentica…». L'agente salva da solo anche ciò che scopre e che probabilmente ti servirà di nuovo, per esempio quale profilo del browser intendi.

### Macro vocali

«Crea una macro modalità lavoro: apri Slack, apri Mail e apri Visual Studio Code» la salva nel file. Da lì in poi basta dire «modalità lavoro» (oppure «esegui modalità lavoro»). Ogni passo viene eseguito come un comando detto a voce: comando rapido quando possibile, altrimenti agente. «Elimina la macro…» la cancella.

### Profili dei browser

«Apri Edge profilo aula IB»: l'agente prova a leggere l'elenco dei profili di Edge, Chrome o Brave. Su questo Mac macOS impedisce di leggere i dati degli altri browser, quindi l'agente apre il browser, sceglie il profilo dal suo menu e lo memorizza per la volta dopo.

## L'agente

L'agente è `claude -p` (Claude Code, sulla tua subscription) collegato a un server MCP che vive dentro l'app, raggiungibile solo da `127.0.0.1` e con un token casuale. Claude non ha altri strumenti: niente terminale, file o internet, solo questi.

Gli strumenti sono costruiti come il computer use di Claude e di Codex (studio in `_bmad-output/planning-artifacts/research/computer-use-claude-codex-2026-10-27.md`):

| Strumento | Cosa fa |
|---|---|
| `observe` | Descrive la finestra in primo piano: elementi visibili con un ID, ruolo, testo, posizione, valore (`value=`), se il valore si può impostare (`settable`) e le azioni in più (`actions=`). Con `query` cerca un testo in tutta la finestra, utile nelle pagine enormi come le webmail. |
| `screenshot` | Immagine della finestra, ridotta a 1400 px, con un **numero arancione su ogni elemento cliccabile** (set-of-marks): l'agente clicca per numero invece di stimare le coordinate. Con `region` ingrandisce una parte a piena risoluzione (testo piccolo, foto, etichette). |
| `click` | Per ID o per coordinate dello screenshot; pressione accessibile, clic vero, doppio, triplo, destro o centrale, anche con ⌘/⇧/⌥/⌃ tenuti premuti |
| `hover`, `drag` | Passare sopra (menu che compaiono al passaggio del mouse) e trascinare (schede, file, cursori) |
| `set_value`, `select_text`, `perform_action` | Impostare un valore (cursori, campi nativi), selezionare un pezzo di testo o mettere il cursore prima/dopo, eseguire un'azione esposta dall'elemento (Incrementa, Espandi, azioni delle app) |
| `menu` | Usa la barra dei menu dell'app per nome («Formato > Font > Grassetto»); con un percorso parziale elenca le voci e le scorciatoie |
| `act` | Più azioni in una sola chiamata (un modulo intero, una sequenza nota), ferma al primo errore |
| `type_text`, `press_keys`, `scroll` | Scrivere (qualsiasi lunghezza), scorciatoie, scorrimento |
| `open_app`, `open_url` | Apre e porta davvero in primo piano app e siti, anche nel browser indicato |
| `get_text`, `edit_text` | Legge e modifica il campo di testo attivo (sostituire la selezione, riscrivere la frase prima del cursore) |
| `replace_text` | Sostituisce un testo nel campo attivo **e verifica il risultato**, anche negli editor web (Jupyter, Colab, editor di codice) che non espongono il testo all'Accessibilità: prova l'Accessibilità, poi la riga corrente, poi l'intera cella |
| `click_many` | Clic su più elementi in una chiamata (ad esempio tutte le caselle di una colonna), con lo stato di ognuno dopo il clic (spuntata o no) |
| `browser_profiles` | Elenca i profili di Edge, Chrome e Brave, quando macOS lo consente |
| `remember`, `forget`, `save_macro`, `delete_macro` | Memoria personale e macro vocali |
| `ask_user` | Domande a voce. **Conferma obbligatoria** per inviare, eliminare, comprare o chiudere: l'azione si ferma, l'app chiede «Vuoi che clicchi «Invia»?» (con «che tu non hai chiesto» se la richiesta non la nominava) ed esegue solo con un «sì», che vale per quella sola azione. Non esiste più una finestra di tempo in cui un «sì» sblocca altre azioni. Vale anche per le scorciatoie che inviano o eliminano, per l'Invio nelle chat e per i trascinamenti nel Cestino. `confirm` resta per compatibilità e non dà permessi |

**Ogni azione dice da sola cosa è cambiato.** Dopo un clic, una scrittura o un trascinamento lo strumento aspetta che l'interfaccia si fermi (anche il caricamento della pagina, fino a 6 secondi) e risponde con le differenze: nuovo titolo, elemento attivo, testo selezionato, elementi comparsi, scomparsi o cambiati. L'agente non deve riguardare lo schermo dopo ogni passo e non può dire «fatto» se non è cambiato nulla.

**L'agente parte già sapendo cosa c'è sullo schermo:** con Claude e Codex la richiesta contiene gli elementi della finestra con i loro ID, così il primo passo è già un'azione. Sul Banco di prova Claude riesce 25 compiti su 25 con 1–2 chiamate in media (prima 3) e 6 secondi invece di 9.

**Gli ID restano gli stessi per tutto il compito** finché l'elemento esiste: lo stesso pulsante ha lo stesso numero in `observe`, negli screenshot e negli esiti; se un elemento sparisce, l'ID viene rifiutato con un messaggio chiaro. Dopo uno scorrimento le coordinate dello screenshot precedente non valgono più.

**Il pianto non tiene aperto l'ascolto.** Un rumore continuo (pianto, televisione, aspirapolvere) impedisce al silenzio di chiudere la frase; l'app la chiude lo stesso quando dopo 4 secondi non contiene parole, o quando le parole riconosciute non cambiano più da 2,5 secondi (3,5 in dettatura): hai finito di parlare, il rumore continua. Il rilevatore scarta anche i suoni acuti e regolari (strilli oltre i 400 Hz). Una frase detta mentre il bambino piange viene comunque presa.

**La pillola dei messaggi** è larga quanto il suo testo. In posizione automatica sta in basso e sale in alto quando coprirebbe il punto in cui scrivi o il puntatore. In alternativa si può fissare in alto, in alto a destra o in basso a destra (Impostazioni › Voce e suoni › Messaggi sullo schermo). In dettatura «fine» chiude anche ripetuto («fine fine») o in coda a una frase («…a domani. Fine.»).

Durante un compito l'HUD mostra cosa sta facendo («Cerco «LangChain»…», «Clicco «Apri»»); «stop» a voce oppure **Esc** lo interrompono (gli Esc premuti dall'agente stesso non contano). Un compito tipico richiede 5–30 secondi; i comandi rapidi restano istantanei.

### Dettagli tecnici

- I browser Chromium (Edge, Chrome, Brave, Arc) espongono le pagine web all'Accessibilità solo se l'app attiva `AXEnhancedUserInterface`, cosa che MacTalkAct fa da sola.
- macOS non permette a un'app in background di portarne un'altra in primo piano con le API pubbliche. MacTalkAct prova prima quelle e poi, come i commutatori di finestre (ad esempio AltTab), usa la funzione di sistema `_SLPSSetFrontProcessWithOptions`.

## Claude tramite abbonamento

L'app lancia `claude -p` senza strumenti, server MCP, hook né plugin, con un prompt di sistema dedicato e un JSON Schema per la risposta. Claude quindi decide soltanto: le azioni le esegue l'app.

L'avvio di `claude` richiede circa 2 secondi. Con la **Sessione lunga** (predefinita) l'app tiene aperto un solo processo `claude` per livello e lo riusa tra una richiesta e l'altra. Non c'è avvio, e il prompt di sistema e gli strumenti restano nella cache del modello: dalla seconda richiesta Claude rilegge solo la parte nuova. La sessione parte alla prima richiesta, mai in anticipo. Riceve solo le voci della memoria di conversazione che non ha ancora visto, e non lascia file su disco (`--no-session-persistence`).

La sessione si riavvia da sola, scrivendo il motivo nel log e «Riavvio l'Agente» nell'HUD, in questi casi:
- dopo 8 richieste (si regola nelle impostazioni);
- dopo 10 minuti di inattività;
- quando il turno supera il tempo massimo;
- al cambio di modello o di effort;
- con «dimentica la conversazione»;
- entrando o uscendo dalla modalità privata.

Se la sessione si chiude a metà senza aver fatto azioni, la richiesta viene ripetuta una volta. L'interruttore **Impostazioni › Agente › Claude › Sessione lunga** spento torna al comportamento di prima: un processo pronto, usato una volta per richiesta.

La Sessione lunga richiede `claude` 2.1.299 o successivo. L'app legge la versione con `claude --version` e la mostra in **Stato e diagnostica**, insieme a quella di `codex` (minima 0.131.0). Con una versione non verificata, o se `claude` parte senza il login dell'abbonamento, l'app usa un processo per richiesta. Le versioni minime vanno rilette entro il **1° novembre 2026**.

L'agente ha tre livelli, ognuno con la sua sessione: **istantaneo** (Claude Haiku 5.5, effort basso) per i comandi a un passo, descritto qui sotto; **rapido** (Claude Sonnet 5.5, effort basso) per le richieste semplici; **profondo** (Claude Opus 5.5, effort medio) per quelle lunghe (più passi, mail, ricerche, «tutte le…»). Dire «pensaci bene» forza il profondo. I modelli si scelgono nelle impostazioni, e ogni sessione si riavvia per conto suo con le regole qui sopra. Le prime tre corsie non usano mai Claude e non consumano l'abbonamento.

**Livello istantaneo.** Le richieste a un passo su qualcosa che l'app conosce vanno a **Claude Haiku 5.5** con effort basso, in una Sessione lunga propria: per esempio «apri la mail di Laura» o «clicca il preventivo». Conta come noto un elemento visibile sullo schermo, un'app installata, un sito, o qualcosa detto prima nella conversazione.

A questo livello l'Agente ha una sola chiamata di strumento (più azioni stanno in un solo `act`). La richiesta passa da sola al livello rapido, senza ripetere quello che è già stato fatto, in questi casi:
- l'azione fallisce;
- l'azione non cambia niente;
- serve una seconda chiamata;
- il turno finisce senza azioni, o con una risposta che ammette di non esserci riuscito.

Alla scalata il turno istantaneo si interrompe ma la sua sessione resta aperta per la richiesta successiva. Vale solo con Claude: con Codex o con il modello locale si usa il livello rapido. Interruttore («Livello istantaneo per i comandi a un passo»), modello ed effort sono in **Impostazioni › Agente › Claude**. Le frasi che la grammatica conosce già, come «clicca Salva», restano Comandi rapidi e non arrivano all'Agente.

**Osservazione a costo fisso.** Delle liste lunghe si legge solo la parte visibile, al massimo 60 elementi per contenitore, con un budget di 0,9 s. Così la lettura dello schermo costa lo stesso su una webmail e su una pagina semplice; il resto si trova scorrendo o con una ricerca (`observe` con `query`). Al primo contatto con un'app Electron o Chromium l'app aspetta fino a 1 s che la pagina sia leggibile. Interruttore «Osservazione a costo fisso» in **Impostazioni › Agente**; spento, la lettura torna quella di prima.

I numeri di ciascuna di queste parti (riga di base, Sessione lunga, Livello istantaneo, osservazione) sono nella ricerca `_bmad-output/planning-artifacts/research/technical-agente-precisione-velocita-e-strumenti-2026-10-27/research.md`, §13–§17. `--agent-bench` dichiara a ogni corsa se le soglie di velocità (NFR-12) sono rispettate, e scrive il verdetto in un file `…-soglie.txt` accanto alla tabella.


## Motori: Claude, Codex o il Mac

L'agente può ragionare con tre **motori**, che usano gli stessi strumenti, lo stesso prompt e le stesse conferme:

| Motore | Come funziona | Cosa serve |
|---|---|---|
| **Claude** (predefinito) | `claude -p` con l'abbonamento Claude, come descritto sopra | Claude Code con l'accesso fatto |
| **Codex** | `codex exec` con l'accesso di ChatGPT; richiesta semplice con GPT-6 Luna, compiti lunghi con GPT-6.1 Sol | L'app ChatGPT (contiene Codex) o Codex CLI, con l'accesso fatto |
| **Locale** | Il modello Apple sul Mac (o un modello servito da Ollama/LM Studio), con meno strumenti e al massimo 8 passi | Apple Intelligence attiva |

Il motore si sceglie dal menu della barra (**Motore dell'agente**) o da Impostazioni › **Motori**.

**Catena di riserva.** Se il motore scelto non è disponibile (quota finita, comando non installato, accesso da rifare) l'app usa da sola l'altro motore cloud e, se manca anche quello, il modello locale. Ogni passaggio viene detto una volta nell'HUD: «Codex in pausa fino alle 17:40 · uso Claude», «Claude e Codex non disponibili · passo al modello locale». Quando il motore scelto torna, l'app torna a usarlo e lo dice («Codex è tornato»). Con **Locale** scelto non c'è passaggio al cloud: i dati restano sul Mac. La catena si può spegnere («Passa agli altri motori quando serve»).

**Mai due volte la stessa azione.** Se un motore si ferma per la quota *prima* di aver fatto qualcosa (ha solo guardato lo schermo), la stessa richiesta passa subito al motore successivo. Se invece aveva già cliccato o scritto, l'app si ferma e dice quanti passi ha fatto: ripetere potrebbe, ad esempio, inviare due volte la stessa mail.

**Codex come Claude, solo con i nostri strumenti.** L'app avvia `codex exec` senza la configurazione personale (`--ignore-user-config`), senza terminale, computer use, browser, plugin né ricerca web, in sola lettura e senza salvare sessioni; il token del server degli strumenti passa solo nell'ambiente del processo. I dettagli e le misure sono in `_bmad-output/planning-artifacts/research/valutazione-motori-agente-2026-10-27.md`.

## Senza abbonamenti: il motore locale

Con **Locale** scelto (o quando Claude e Codex non ci sono) l'agente lavora interamente sul Mac. Per un modello piccolo il ciclo «osserva, agisci, verifica» libero funziona male, quindi l'app lo guida:

1. l'app osserva la finestra e tiene solo gli elementi che c'entrano con la richiesta (al massimo 30, cercando nell'intera pagina le parole o i numeri che non vede);
2. il modello sceglie **un solo passo** tra pochi possibili (clicca, clicca più elementi, scrivi, sostituisci, tasti, apri app o sito, scorri, fatto, impossibile), con generazione vincolata: non può inventare azioni né formati;
3. l'app esegue il passo con gli stessi strumenti e le stesse conferme dell'agente cloud, e ricomincia, fino a «fatto» o a 8 passi.

Se non ce la fa lo dice («Col modello locale non ci riesco: …») invece di dichiarare il compito riuscito.

**Un modello più capace sul Mac.** In Impostazioni › Motori › Locale si può scegliere «Server sul Mac»: qualunque server compatibile con l'API OpenAI (Ollama, LM Studio, `mlx_lm.server`, Rapid-MLX). L'app legge l'elenco dei modelli dal server, il pulsante **Prova** misura il tempo al primo strumento, e il modello viene tenuto in memoria solo per il tempo indicato (10 minuti). Per Ollama:

```bash
ollama pull qwen3.5:9b                    # il migliore sul banco di prova (90%)
OLLAMA_CONTEXT_LENGTH=8192 ollama serve   # contesto ridotto: molta meno memoria
# Impostazioni › Motori › Locale › Server sul Mac › http://127.0.0.1:11434/v1
```

Risultati sul banco di prova (M1, 16 GB):

| Modello | Compiti riusciti | Tempo per compito (mediana) | Memoria |
|---|---|---|---|
| Modello Apple (predefinito) | 80% | 6,5 s | di sistema |
| qwen3.5:9b su Ollama | 90% | 20 s | ~10 GB |
| qwen3.5:4b su Ollama | 65% | 13 s | ~9 GB |
| gemma4:e4b su Ollama | 45% | 16 s | ~10 GB |

Ollama usa già il motore MLX di Apple Silicon. I modelli Qwen 3.5 «ragionano» prima di rispondere: l'app lo disattiva (`reasoning_effort: none`), perché per i passi dell'agente non serve e costerebbe decine di secondi. Con il motore locale le modifiche a testi già scritti (celle di notebook, documenti) vengono rifiutate invece di rischiare di rovinarli: per quelle serve Claude o Codex.

Se il server è spento l'app usa il modello Apple e lo dice. Un indirizzo fuori da questo Mac richiede una conferma esplicita, perché la richiesta e il contenuto dello schermo lascerebbero il Mac.

**Il resto dell'app non ha bisogno del cloud.** Comandi rapidi, corsia locale, Router, numeri sullo schermo e ripulitura della dettatura (con il modello Apple quando il motore in uso non è Claude) funzionano senza rete. I passi liberi delle macro vanno al motore in uso, compreso quello locale.

**Banco di prova.** `Tests/bench/agente.tsv` contiene 20 compiti su pagine HTML locali (posta, tabella con caselle, notebook, modulo, elenco lungo, sito) che scrivono il loro stato nel titolo della finestra; `--agent-bench` li esegue in Safari con un motore e verifica l'esito:

```bash
.build/debug/MacTalkAct --agent-bench --engine local                  # modello Apple (agisce davvero!)
.build/debug/MacTalkAct --agent-bench --engine local --model qwen3.5:4b   # modello servito da Ollama
.build/debug/MacTalkAct --agent-bench --engine claude --only posta-apri,tabella-tutti
```

## Struttura del codice

| File | Ruolo |
|---|---|
| `SpeechEngine.swift` | Microfono → `AnalyzerInputConverter` → `SpeechAnalyzer` con `DictationTranscriber` italiano |
| `HotkeyMonitor.swift` | Tasto push-to-talk: pressione prolungata, tocco, doppio tocco |
| `CommandGrammar.swift` | Comandi rapidi in italiano, frase di attivazione, confronto tra etichette, diff del testo |
| `IntentRouter.swift` | Il Router: una sola decisione per frase, con motivo, senza effetti collaterali |
| `IntentClassifier.swift` | Classificatore on-device (modello Apple) e classificatore a regole prudente |
| `LocalLane.swift` | Corsia locale: proposta del modello Apple e validatore con regole fisse |
| `Conversation.swift` | Finestra di conversazione, memoria a breve termine, registro di ciò che l'app scrive |
| `Coordinator.swift` | Modalità di ascolto, dettatura lunga, esecuzione delle decisioni del Router, domande dell'agente, feedback |
| `AgentRunner.swift` | Prompt e messaggio dell'agente, scelta del motore, catena di riserva, ripetizione solo prima delle azioni |
| `AgentEngine.swift` | Protocollo dei motori, `EngineSelector`, lettura dei messaggi di limite di Claude e Codex |
| `ClaudeEngine.swift`, `CodexEngine.swift`, `CodexCLI.swift` | I due motori cloud: avvio delle CLI, Sessione lunga, livelli istantaneo, rapido e profondo, pause per la quota |
| `LocalEngine.swift` | Motore locale: sessione FoundationModels con gli strumenti dell'app, prompt corto, passi limitati |
| `LocalStepAgent.swift` | Il ciclo guidato del motore locale: elementi pertinenti, un passo vincolato alla volta |
| `OpenAICompatibleModel.swift` | Modello servito sul Mac (Ollama, LM Studio, MLX) tramite l'API compatibile OpenAI |
| `LocalText.swift` | Ripulitura della dettatura con il modello Apple |
| `AgentTools.swift` | Gli strumenti dell'agente: osservare, cliccare, trascinare, scrivere, confermare…, con ID stabili ed esito di ogni azione |
| `AppMenu.swift` | La barra dei menu dell'app in primo piano, percorsa per nome |
| `EscapeMonitor.swift` | Esc ferma l'agente mentre lavora |
| `MCPServer.swift` | Server MCP HTTP locale (solo 127.0.0.1, con token) |
| `ScreenCapture.swift` | Screenshot della finestra in primo piano (ScreenCaptureKit) |
| `FrontProcess.swift` | Porta davvero un'app in primo piano |
| `NumberOverlay.swift` | «Mostra numeri» |
| `Speaker.swift` | Risposte a voce facoltative |
| `Memory.swift` | Memoria personale e macro (`memoria.md`) |
| `BrowserProfiles.swift` | Profili dei browser Chromium |
| `Accessibility.swift` | Lettura dello schermo: app, campo attivo, testo prima del cursore, etichette cliccabili |
| `Executor.swift` | Le "mani": tasti, incolla, clic per nome, scroll, apertura app |
| `LLMPlanner.swift` | Prompt, schema del piano e rete di sicurezza; sceglie tra abbonamento e chiave API |
| `ClaudeCLI.swift` | Esegue `claude -p` tenendo sempre pronto un processo in anticipo |
| `HUD.swift` | La pillola dei messaggi, che non prende mai il focus e si sposta in alto se copre il punto in cui scrivi o il puntatore |
| `Settings.swift` | Tutte le impostazioni con i loro predefiniti (`AppSettings.Defaults`), sezioni, Portachiavi |
| `SettingsWindow.swift` | Finestra delle impostazioni: barra laterale, sezioni, ripristino dei predefiniti |

## Strumenti di test

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
.build/debug/MacTalkAct --selftest                 # test della grammatica e degli helper
.build/debug/MacTalkAct --route-test               # Router sul Corpus (Tests/corpus/instradamento.tsv): accuratezza e tempi
.build/debug/MacTalkAct --route-test Tests/corpus/instradamento-verifica.tsv   # frasi mai viste in taratura
.build/debug/MacTalkAct --route-test --rules       # come si comporta senza il modello Apple
.build/debug/MacTalkAct --settings-shot /tmp/shots     # un'immagine per sezione della finestra impostazioni, disegnata fuori schermo
.build/debug/MacTalkAct --tools-test Tests/pages/prova-strumenti.html   # click_many e replace_text su una pagina di prova (agisce davvero!)
.build/debug/MacTalkAct --hands-test               # le mani dell'agente senza modello: hover, drag, set_value, act, menu, zoom (agisce davvero!)
.build/debug/MacTalkAct --listen-file file.wav    # un file audio attraverso tutto l'ascolto dell'app, in tempo reale: quali frasi escono e quando
.build/debug/MacTalkAct --vad-test file.wav       # il rilevatore della voce su un file: quando apre e chiude le frasi, quanto è pianto
.build/debug/MacTalkAct --bench-cleanup            # chiude le pagine del Banco rimaste aperte in Safari
say -v Alice -o /tmp/t.aiff "Scorri giù"
.build/debug/MacTalkAct --transcribe /tmp/t.aiff   # riconoscimento vocale su un file
.build/debug/MacTalkAct --context                  # cosa vede l'app dello schermo (dopo 3 s)
.build/debug/MacTalkAct --mic-test 20              # frasi riconosciute dal microfono vero
.build/debug/MacTalkAct --wake-test 60             # ascolto continuo completo, senza eseguire nulla
tail -f ~/Library/Logs/MacTalkAct.log              # cosa sente e decide l'app, in tempo reale
.build/debug/MacTalkAct --agent-test "apri la Calcolatrice"   # un compito completo dell'agente (agisce davvero!)
.build/debug/MacTalkAct --agent-test "…" --engine codex       # lo stesso con un motore preciso (claude, codex, local), senza riserva
.build/debug/MacTalkAct --fallback-test            # catena di riserva con motori finti: nessuna azione ripetuta dopo un limite; fasi; Sessione lunga con un claude finto
.build/debug/MacTalkAct --session-test             # Sessione lunga con il claude vero: due risposte brevi (usa l'abbonamento)
.build/debug/MacTalkAct --apple-events-spike       # Storia 8.4: azioni dirette via Apple Events, solo con il consenso già dato; --avvia apre Calendario e Mail
.build/debug/MacTalkAct --local-vision-test        # Storia 8.3: il modello Apple sul Mac con lo screenshot di 5 pagine del Banco
.build/debug/MacTalkAct --mcp-serve                # solo il server degli strumenti, per provare a mano altri client MCP
.build/debug/MacTalkAct --observe-stats com.microsoft.edgemac # quanto vede l'agente di un'app (senza contenuti)
.build/debug/MacTalkAct --activate-test Calculator # porta un'app in primo piano e torna indietro
.build/debug/MacTalkAct --phase3-test              # memoria, macro (temporanea), profili, numeri su Edge
.build/debug/MacTalkAct --plan "cancella l'ultima frase"   # piano di Claude (abbonamento o chiave)
```

## Limiti noti

- La direzione dello scroll sintetico può risultare invertita con alcune impostazioni del trackpad. Se succede, va invertito il segno in `Executor.scroll`.
- «Indietro» e «avanti» usano ⌘[ e ⌘], che con il layout italiano non funzionano in tutte le app.
- Il testo viene inserito con gli appunti (incolla e poi ripristino del contenuto precedente), come fa Wispr Flow.
- L'agente costa tempo (2–4 secondi per passo) e consuma più subscription di una singola richiesta.
- Durante un compito, una frase detta senza «Computer» può essere presa come risposta a una domanda dell'agente.
- Il modello Apple richiede Apple Intelligence attiva. Senza, il Router usa regole prudenti: nei campi di testo chiede «scrivilo» prima di scrivere una frase ambigua, e nella finestra di conversazione riconosce solo i comandi della grammatica.
- Nella finestra di conversazione la dettatura senza «Computer» viene ignorata, per prudenza: per dettare di seguito usa «scrivi…».
- Il Router è tarato su 106 frasi (100%) e verificato su 41 frasi nuove (97,6%), senza scritture indebite; nell'uso reale la precisione sarà più bassa e il Corpus va arricchito con i casi sbagliati.

## Risposte a voce

Facoltative, da Impostazioni › «Rispondi a voce». L'app pronuncia a basso volume l'esito dell'agente e le sue domande, così sai com'è andata senza guardare lo schermo. Mentre parla non ascolta, per non sentire sé stessa; «stop» la interrompe.

## Limiti della subscription

Claude e Codex hanno ciascuno il proprio limite d'uso. Quando un motore lo raggiunge, l'app legge l'ora di ripresa dal messaggio («resets 7pm», «try again at 5:40 PM», «try again in 2 hours», anche con un giorno diverso per il limite settimanale; 30 minuti se l'ora non c'è) e lo mette in pausa fino ad allora, passando agli altri motori come descritto sopra. Solo se nessun motore è disponibile (o la catena di riserva è spenta) l'app entra in **modalità ridotta**: le richieste per l'agente ricevono subito una risposta chiara, il menu mostra lo stato di ogni motore e l'icona cambia. Comandi rapidi, corsia locale, dettatura e «mostra numeri» continuano a funzionare.

## Idee per il futuro

- Agente che parte mentre stai ancora parlando: scartata per ora. L'attesa vera è il ragionamento del modello, non l'avvio, che è già nascosto tenendo un processo pronto. Partire da una frase incompleta rischierebbe azioni sbagliate.
