# Epic 10 Context: Un solo cancello, e veloce

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Ogni azione proposta da un modello, che venga dall'Agente (qualunque Motore) o dalla Corsia locale, deve passare dallo stesso controllo: livelli di accesso per app, conferma legata alla singola azione e secondo strato. Con l'Epic 9 questi controlli sono finiti dentro `AgentTools`, così la Corsia locale (`LocalActionProposer` → `LocalActionValidator` → `Executor`) li salta: una scorciatoia proposta dal modello come ⌘⇧D in Mail parte senza domanda. L'epic estrae i controlli in un `AccessGate` unico, senza cambiarne il comportamento, ci fa passare la Corsia locale e toglie al secondo strato il suo costo al clic. Oggi il secondo strato costa circa 0,9 s per clic sotto carico, con 3 timeout su 8; l'epic lo fa giudicare in anticipo, mentre il modello pensa. Viene prima del ciclo di velocità (Epic 11) perché chiude un buco di sicurezza ancora aperto e perché il giudizio anticipato presuppone che il secondo strato stia già dentro il gate.

## Stories

- Story 10.1: AccessGate unico, stesso comportamento
- Story 10.2: La Corsia locale passa dal cancello
- Story 10.3: Giudizio anticipato del secondo strato

## Requirements & Constraints

- **Gate unico (FR-56).** Livelli di accesso, conferma per singola azione e secondo strato vivono in un solo `AccessGate`, chiamato per ogni azione di origine `.model`: l'Agente di ogni Motore e le `LocalAction` già approvate dal Validatore. Comandi rapidi, Dettatura, numeri e macro restano `.user` e non passano dal gate. Il comportamento delle Storie 9.2, 9.3 e 9.5 non cambia: messaggi, domande e righe del log restano identici.
- **Corsia locale nel gate.** In un'app «solo clic» (Terminal, iTerm) i tasti vengono rifiutati. Con «conferma ogni azione» (Impostazioni di Sistema) l'app chiede prima di agire. Le scorciatoie che inviano o eliminano (⌘⇧D in Mail, ⌘⌫ nel Finder) chiedono conferma. ⌘⇧D è rischioso solo in Mail o quando l'app è sconosciuta, perché nel Finder apre la Scrivania. Se la conferma viene annullata, la richiesta non passa all'Agente. Il gate aggiunge al massimo 20 ms alla Corsia locale [ASSUMPTION], che deve restare entro 1,5 s.
- **Giudizio anticipato (FR-60).** Dopo `observe`, o sugli elementi iniziali della richiesta, i controlli premibili visibili che le regole fisse non coprono vengono giudicati in background: uno alla volta, al massimo 12 per osservazione [ASSUMPTION], partendo dai più vicini al fuoco. Al clic il gate legge la cache, oppure attende il giudizio in corso per quanto resta del budget di 0,9 s; se il verdetto manca, giudica come oggi. Il giudizio anticipato può solo aggiungere conferme, mai toglierle.
- **Secondo strato sotto carico (NFR-16).** Sui compiti positivi del Banco non ci devono essere timeout, e il secondo strato può aggiungere al massimo 1,0 s per azione giudicata al 90° percentile (rivista il 28/10 sera, prima 0,3 s). SM-C7 (≤ 0,9 s per azione, zero azioni legittime bloccate) resta il tetto. Il rate limit e la concorrenza di FoundationModels nell'app vera vanno misurati e riportati nella ricerca.
- **Nessuna regressione di sicurezza (NFR-17, NFR-14).** Dopo ogni storia devono restare verdi: suite di sicurezza (Claude 10/10 scenari e 8/8 blocchi, Codex 8/8), `--security-coverage`, `--risk-classifier-test`, `--route-test` e `--hands-test`. L'oracolo della suite è lo stato della pagina o dell'app, mai il log del gate. La suite deve passare uguale con il secondo strato acceso e spento: le regole fisse devono bastare da sole. Ogni azione bloccata nell'uso reale diventa uno scenario.
- **Nuovi scenari.** Tre scenari in `Tests/bench/sicurezza.tsv` per la Corsia locale: «manda» in Mail, tasti in Terminal, scorciatoia nelle Impostazioni di Sistema.

## Technical Decisions

- **AD-21: le conferme vivono nell'esecutore.** `ActionOrigin` (`.user`, `.model`) e `AccessGate` diventano tipi propri in un nuovo `AccessGate.swift`. Il gate è chiamato da `AgentTools.perform`, per ogni strumento e per ogni passo di `act`, e da `Coordinator.runLocal`.
  - **Riconoscimento.** Le Azioni con effetti esterni sono riconosciute in due modi. Per costruzione: Invio in un campo di composizione, scorciatoie che inviano o eliminano, trascinamenti verso il Cestino. Per riconoscimento: pulsanti per etichetta, `AXIdentifier` o azione di accessibilità, sull'elenco canonico `Safety.externalEffect(for:)`.
  - **Bersaglio.** Il bersaglio della conferma è un `ConfirmationTarget` tipizzato: `.element(id, action)`, `.shortcut(keys, windowID)`, `.keyInComposer(fieldID)`, `.drop(onto: id)`. Non esistono indici di serie: `act` si sospende al passo, chiede e riprende.
  - **Grant.** Il `ConfirmationGrant` vale solo per quel bersaglio, nella stessa richiesta e finestra, ed è consumato dall'azione. Decade a fine richiesta o quando l'esito segnala che l'elemento è cambiato.
  - **Flusso.** La chiamata bloccata si sospende, chiede ed esegue, senza un giro in più verso il Motore. Una domanda del Motore in linguaggio naturale non produce grant. Nessun interruttore e nessuna finestra temporale (`confirmValiditySeconds` è stata rimossa).
- **Secondo strato (`RiskClassifier`, modello Apple on-device).** Interviene prima del `dispatch`, solo sulle azioni `.model` con effetti che il gate non ha già fermato, con un budget di 0,9 s. La cache dei verdetti è per richiesta, con la chiave di oggi: strumento, etichetta, ruolo, app, finestra, dialogo. In cache entrano solo i verdetti validi, mai timeout ed errori. Una nuova osservazione o la fine della richiesta annullano i giudizi in coda. Il giudizio anticipato è sospeso mentre lavora il Motore locale, che usa lo stesso modello Apple. Il modello funziona bene quando deve nominare la categoria dell'effetto (invio, pagamento, eliminazione) e male sulla domanda astratta «esterno/interno». Sui tasti da soli sbaglia, quindi `press_keys` resta alle regole fisse. I pulsanti che aprono soltanto una bozza (Nuovo messaggio, Componi, Rispondi, Compose, Reply) non passano dal secondo strato.
- **AD-22: livelli di accesso per app.** `PrivacyGuard.accessLevel(for:)` restituisce un `AccessLevel` su due assi: `cloudAllowed` e `.clickOnly` / `.fullWithConfirm` / `.full`. Il livello si applica nell'`AccessGate`, quindi ad Agente e Corsia locale ma non alla Dettatura.
  - **App riservate e modalità privata.** Motori cloud bloccati; il Motore locale lavora con conferma.
  - **Terminal e iTerm.** `.clickOnly`; ai Motori cloud l'osservazione restituisce solo ruoli ed etichette, mai valori, testo o immagini.
  - **Finder e Impostazioni di Sistema.** Finder chiede conferma per le Azioni con effetti esterni; le Impostazioni di Sistema per ogni azione con effetti.
  - **Campi sicuri.** Sono riconosciuti dal sottoruolo `AXSecureTextField` e la regola resta fail-closed.
  - **Elenco.** È in `AppSettings` ed è modificabile; l'HUD mostra il livello in vigore.
- **AD-24: una sola domanda in attesa.** Nel Coordinator c'è una sola `PendingQuestion` (`.confirm(target)` e altre); il Router la riceve in `RouterState.pending` e produce `.answer`. «Sì» risolve la conferma, qualunque altra Frase la rifiuta. Il `TurnClock` di `AgentRunner` va in pausa mentre una domanda è in attesa. Anche la conferma della Corsia locale usa questa `PendingQuestion`.
- **AD-3: Corsia locale.** Una `LocalAction` (`LocalLane.swift`) raggiunge l'`Executor` solo tramite `LocalActionValidator.validate(_:)`. Il gate si aggiunge dopo il Validatore e non lo sostituisce.

## UX & Interaction Patterns

- La domanda di conferma nomina il bersaglio; se l'azione non compare nella richiesta, aggiunge «che tu non hai chiesto».
- Il log registra ogni blocco con scenario, app, bersaglio, origine ed esito, nello stesso formato di `sicurezza.tsv`.
- Nel giudizio anticipato, il log segnala i verdetti presi dalla cache con «dalla cache (anticipato)».
- L'HUD mostra il livello di accesso in vigore mentre l'Agente lavora.

## Cross-Story Dependencies

- La 10.1 è la base per la 10.2 e la 10.3: la Corsia locale e il giudizio anticipato presuppongono il gate estratto.
- Prima del rifacimento della 10.1, `--hands-test` «azione senza effetti» (`press_keys` shift, che fallisce circa una volta su tre) va reso stabile: 10 corse verdi su 10. È la rete del rifacimento.
- La 10.3 misura sul Banco con Claude, con il log della concorrenza; serve la riga di base prima di cambiare (AD-18).
- L'Epic 11 non dipende da questo epic, ma lo usa come rete. La sovrapposizione di file è minima: con l'Epic 11 tocca `AgentTools` solo per l'esito che chiude il turno.
