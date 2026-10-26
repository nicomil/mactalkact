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

Dopo ogni risposta la **conversazione resta aperta per 20 secondi** (l'HUD mostra «💬 Ti ascolto ancora»): puoi continuare senza ripetere «Computer» («cambia anche la seconda», «no, quella sotto»), mentre la chiacchiera con chi è nella stanza viene ignorata. «Basta così» o «grazie» la chiudono subito; la durata si cambia nelle impostazioni. Se dici solo «Computer», la frase successiva viene accettata qualunque sia, e la parola «Computer» da sola non viene mai scritta.

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

## Impostazioni

La **parola di attivazione** si sceglie in Impostazioni › Ascolto: al posto di «computer» puoi usare la parola che preferisci. L'app accetta da sola anche «ok …», «ehi …», «hey …» e le storpiature tipiche del riconoscimento («i …», «e …»), si possono aggiungere altre frasi e sotto il campo compare l'elenco completo. Conviene una parola di almeno 4 lettere che in casa non si dice per caso; se il riconoscimento la scrive in modo diverso, il log mostra come l'ha sentita e quella forma si aggiunge tra le altre.

Dal menu ✋ › **Impostazioni** si apre una finestra con una barra laterale a sezioni: Ascolto, Conversazione, Comprensione, Agente, Voce e suoni, Numeri, Memoria e macro, Permessi, Stato e diagnostica. Ogni comportamento regolabile dell'app è lì, con il suo valore, una spiegazione e il valore predefinito: silenzio che chiude una frase, sensibilità del rilevatore di voce, durata della conversazione aperta, attese di conferma, modelli ed effort dell'agente, passi e tempo massimi di un compito, volume della voce e dei suoni, durata dei messaggi, numeri sullo schermo. Ogni sezione ha «Ripristina predefiniti»: i predefiniti coincidono con il comportamento dell'app prima che le impostazioni esistessero. Le modifiche valgono dall'azione successiva, senza riavviare.

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

| Strumento | Cosa fa |
|---|---|
| `observe` | Descrive la finestra in primo piano: elementi visibili con un ID, ruolo, testo e posizione. Con `query` cerca un testo in tutta la finestra, utile nelle pagine enormi come le webmail. |
| `screenshot` | Immagine della finestra, ridotta a 1400 px, con un **numero arancione su ogni elemento cliccabile** (set-of-marks): l'agente clicca per numero invece di stimare le coordinate |
| `click` | Per ID o per coordinate dello screenshot; pressione accessibile, clic vero, doppio o destro |
| `type_text`, `press_keys`, `scroll` | Scrivere (qualsiasi lunghezza), scorciatoie, scorrimento |
| `open_app`, `open_url` | Apre e porta davvero in primo piano app e siti, anche nel browser indicato |
| `get_text`, `edit_text` | Legge e modifica il campo di testo attivo (sostituire la selezione, riscrivere la frase prima del cursore) |
| `replace_text` | Sostituisce un testo nel campo attivo **e verifica il risultato**, anche negli editor web (Jupyter, Colab, editor di codice) che non espongono il testo all'Accessibilità: prova l'Accessibilità, poi la riga corrente, poi l'intera cella |
| `click_many` | Clic su più elementi in una chiamata (ad esempio tutte le caselle di una colonna), con lo stato di ognuno dopo il clic (spuntata o no) |
| `browser_profiles` | Elenca i profili di Edge, Chrome e Brave, quando macOS lo consente |
| `remember`, `forget`, `save_macro`, `delete_macro` | Memoria personale e macro vocali |
| `ask_user`, `confirm` | Domande a voce; **conferma obbligatoria** per inviare, eliminare, comprare o chiudere: l'app blocca queste azioni finché non rispondi «sì» |

Gli ID degli elementi non vengono mai riutilizzati durante un compito: dopo una nuova osservazione, un ID vecchio viene rifiutato invece di finire su un elemento diverso. Dopo uno scorrimento le coordinate dello screenshot precedente non valgono più.

Durante un compito l'HUD mostra cosa sta facendo («Cerco «LangChain»…», «Clicco «Apri»»), e «stop» lo interrompe. Un compito tipico richiede 5–30 secondi; i comandi rapidi restano istantanei.

### Dettagli tecnici

- I browser Chromium (Edge, Chrome, Brave, Arc) espongono le pagine web all'Accessibilità solo se l'app attiva `AXEnhancedUserInterface`, cosa che MacTalkAct fa da sola.
- macOS non permette a un'app in background di portarne un'altra in primo piano con le API pubbliche. MacTalkAct prova prima quelle e poi, come i commutatori di finestre (ad esempio AltTab), usa la funzione di sistema `_SLPSSetFrontProcessWithOptions`.

## Claude tramite abbonamento

L'app lancia `claude -p` senza strumenti, server MCP, hook né plugin, con un prompt di sistema dedicato e un JSON Schema per la risposta. Claude quindi decide soltanto: le azioni le esegue l'app.

L'avvio di `claude` richiede circa 2 secondi. Per non farli pesare, l'app tiene **sempre un processo pronto** in attesa della richiesta e, appena lo usa, ne avvia un altro. Così una richiesta libera risponde in circa 2–4 secondi dalla fine della frase. Il prezzo è un processo `claude` sempre in memoria.

L'agente ha due livelli, ognuno con il suo processo pronto: le richieste **semplici** usano **Claude Sonnet 5.5** con effort basso, quelle **lunghe** (più passi, mail, ricerche, «tutte le…») usano **Claude Opus 5.5** con effort medio. Dire «pensaci bene» forza il secondo. Entrambi i modelli si scelgono nelle impostazioni. Le prime tre corsie non usano mai Claude e non consumano l'abbonamento.

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
| `AgentRunner.swift` | Prompt e avvio dell'agente `claude -p` (rapido o profondo), disponibilità e pausa per il limite |
| `AgentTools.swift` | Gli strumenti dell'agente: osservare, cliccare, scrivere, confermare… |
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
| `HUD.swift` | La pillola in basso, che non prende mai il focus |
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
say -v Alice -o /tmp/t.aiff "Scorri giù"
.build/debug/MacTalkAct --transcribe /tmp/t.aiff   # riconoscimento vocale su un file
.build/debug/MacTalkAct --context                  # cosa vede l'app dello schermo (dopo 3 s)
.build/debug/MacTalkAct --mic-test 20              # frasi riconosciute dal microfono vero
.build/debug/MacTalkAct --wake-test 60             # ascolto continuo completo, senza eseguire nulla
tail -f ~/Library/Logs/MacTalkAct.log              # cosa sente e decide l'app, in tempo reale
.build/debug/MacTalkAct --agent-test "apri la Calcolatrice"   # un compito completo dell'agente (agisce davvero!)
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

L'agente usa la stessa subscription di Claude Code. Se si raggiunge il limite d'uso, l'app entra in **modalità ridotta** fino all'ora di ripresa letta dal messaggio (o per 30 minuti): le richieste per l'agente ricevono subito una risposta chiara invece di un'attesa, il menu mostra «Agente in pausa fino alle …» e l'icona cambia. Comandi rapidi, corsia locale, dettatura e «mostra numeri» continuano a funzionare. All'ora di ripresa l'app riprepara Claude e avvisa che l'agente è tornato.

## Idee per il futuro

- Agente che parte mentre stai ancora parlando: scartata per ora. L'attesa vera è il ragionamento del modello, non l'avvio, che è già nascosto tenendo un processo pronto. Partire da una frase incompleta rischierebbe azioni sbagliate.
