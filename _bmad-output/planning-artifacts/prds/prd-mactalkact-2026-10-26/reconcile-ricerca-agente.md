# Riconciliazione: ricerca «Agente: precisione, velocità e strumenti» → PRD (aggiornamento 27/10 sera)

**Input:** `research/technical-agente-precisione-velocita-e-strumenti-2026-10-27/research.md` (sommario, §1, §3–§5, §6.3, §7, §8, §9 R0–R8 e «Non fare», §10, §12).
**Bersagli:** `prd.md` (§0, §2.3 UJ-8…UJ-10, §3, §4.9–§4.11, §5 NFR-5, §6, §8, §9, §10) e `addendum.md` (ultime tre sezioni).
**Esito in breve:** tutte le raccomandazioni R0–R8 hanno un approdo nel PRD o nell'addendum; i numeri principali coincidono. Si sono persi soprattutto i margini qualitativi: la reversibilità («ogni aggiunta è disattivabile»), la versione della CLI *bloccata* (non solo osservata), la mitigazione attiva del default `--bare`, la prova del modello Apple con immagini, il rischio privacy del contesto accumulato nella Sessione lunga, il costo in turni dell'«evidenza prima del fatto», il residuo `~/.codex/AGENTS.md` e la scadenza delle affermazioni di classe «versione» (1 novembre 2026). Un paio di frasi del PRD distorcono il dato (la cache «non viene riusata»; «tre punti deboli»; Impostazioni di Sistema in sola lettura/clic).

## 1. Mappa R0–R8 → PRD

| Racc. | Contenuto (confidenza nella ricerca) | Approdo nel PRD / addendum | Copertura | Nota |
|---|---|---|---|---|
| R0 | Prima misurare: tempi scomposti, app native, webmail, frasi spurie (alta) | FR-41; NFR-12 e SM-8 «da verificare con FR-41»; §4.9 descr. «misura prima e interviene poi» | Completa | La ricerca la vuole come *epic di apertura*; il PRD lo esprime solo come «riga di base pubblicata prima di ogni intervento» (FR-41). Basta. |
| R1 | Sessione lunga con cane da guardia; riavvio dopo N richieste / 10 min / blocco; `--no-session-persistence`; attesa MCP esplicita; **versione CLI bloccata** (alta) | FR-42, FR-45, glossario «Sessione lunga», addendum «Note tecniche per la Sessione lunga» | Parziale | Mancano: CLI *bloccata* (FR-45 la rende solo «verificata/segnalata»); rischio privacy del contesto accumulato (§8); reversibilità (interruttore). Vedi gap 1, 2, 3. |
| R2 | Livello istantaneo Haiku 5.5, solo a un passo, uscita a Sonnet al primo `RESULT` negativo o alla seconda chiamata, cache separata (media) | FR-43, glossario «Livello istantaneo», UJ-8, assunzione §10 | Completa | FR-13 e FR-20 parlano ancora di *due* modelli: vedi gap 12. |
| R3 | Osservazione a costo fisso: figli visibili, tetto per contenitore, budget di tempo, filtro per ruolo, `AXManualAccessibility` + ~150 ms (alta) | FR-44 | Quasi completa | Manca il «filtro per ruolo» (minore) e il complemento immagine/albero dove l'albero non vede (gap 13). |
| R4 | Evidenza prima del «fatto»; `<recent>` con esito e testo cambiato (media; studio sintetico, un autore) | FR-46 | Parziale | Perso il costo misurato (+0,9 turni, +4.653 token) e l'avvertenza [15]: controlli di stop più severi allungano le esecuzioni. Vedi gap 4. |
| R5 | OCR `RecognizeTextRequest` con riscaldamento, timeout 10 s, ripiego `fast`, tool `read_text(region)`, zoom arricchito; **prova del modello Apple con immagine** nel motore locale (media) | FR-47, UJ-9 | Parziale | La prova del modello Apple con immagini (candidato K-b, «provare», 3,90) è sparita da PRD e addendum. Il riscaldamento da 26,9 s non è trattato. Vedi gap 5, 6. |
| R6 | Sicurezza strutturale: (a) token fuori da argv + `Origin`/`Host`; (b) conferma per singola azione; (c) campi sicuri per ruolo e sottoruolo, fail-closed; (d) gate nell'esecutore; (e) livelli di accesso per app; (f) classificatore solo secondo strato (alta) | FR-50, FR-51, FR-52, FR-53, FR-54, FR-55, NFR-5, NFR-14, UJ-10 | Quasi completa | (e) distorto per Impostazioni di Sistema (ricerca: «con conferma»; PRD: sola lettura/clic). Persa la ritrattazione «riducono la superficie, non la chiudono» (§7). Residuo `~/.codex/AGENTS.md` non coperto. Vedi gap 7, 8, 9, 10. |
| R7 | Catena di riserva e policy: rilevare il cambio di default `--bare` **e passare esplicitamente la modalità non-bare**; Codex `exec` come riserva; app-server rinviato; modello locale sempre pronto (media) | FR-45; addendum tabella «Candidati» (`--bare`, app-server); FR-27/FR-31 esistenti | Parziale | FR-45 *rileva e segnala*; la ricerca chiede anche la mitigazione (flag esplicito). Vedi gap 11. |
| R8 | Spike AppleScript: cinque verbi, timeout 3 s, niente `do shell script` né JavaScript; integrazione solo se i tempi reggono, dietro `LocalActionValidator` (bassa) | FR-49; addendum «Note tecniche per lo spike»; §6 non obiettivi | Completa | Coerente. |
| Non fare | API/SDK con chiave; computer use di Claude Code/OpenAI; CDP/estensioni con token; grounding locale «finché l'albero non manca davvero l'elemento in un caso misurato» | §6 non obiettivi (ultimo punto); addendum tabella | Completa, con una sfumatura | La condizione di riapertura per il grounding locale (caso misurato in cui l'albero manca l'elemento) è diventata un «nessun» assoluto. Vedi gap 14. |
| §6.3 «Copertura della reversibilità» | «Ogni aggiunta è disattivabile da impostazioni»; punti di innesto `AgentEngine`, `LocalActionValidator`, `AgentTools.call` | Solo FR-43 («si può disattivare») e FR-55 (implicito) | Parziale | Vedi gap 3. |
| §12 Mappa di scadenza | Affermazioni di classe «versione» (`--bare`, thinking/effort, toolset) scadono il 1 novembre 2026: «da rileggere prima di avviare l'epic di velocità»; matrice da rifare entro aprile 2027 | Nessun approdo | Assente | Vedi gap 15. |

## 2. Gap (cosa la ricerca dice e il PRD ha perso o attenuato)

Ordine: prima i gap che toccano sicurezza e reversibilità, poi velocità/precisione, poi coerenza interna.

1. **Versione della CLI bloccata, non solo verificata.**
   *Ricerca:* sommario («Versione bloccata, cane da guardia e catena di riserva già esistente sono la condizione di ogni altra raccomandazione»), §7 primo punto («due obblighi: versione della CLI bloccata e verificata, cane da guardia con riavvio»), R1 («versione della CLI bloccata»), [116] blocchi ricorrenti di `-p` in 2.1.69, 2.1.232, 2.1.292.
   *PRD:* FR-45 «conosce la versione minima e quella verificata … segnala»; conseguenza: «Con una versione di `claude` non verificata lo stato mostra “versione X non verificata” e l'Agente funziona comunque».
   *Fix:* in FR-45 distinguere «versione verificata» (l'unica su cui si attiva la Sessione lunga) da «versione non verificata» (l'Agente funziona, ma torna al processo per richiesta e lo dice); aggiungere alle Conseguenze «la Sessione lunga non si avvia su una versione non verificata». In alternativa esplicitare perché Nico accetta il rischio.

2. **Privacy del contesto accumulato nella Sessione lunga.**
   *Ricerca:* §8 primo punto: la sessione lunga è «un rischio … di contesto accumulato tra richieste diverse (privacy, compattazione)»; §3 leva 3: «tutti i messaggi appartengono alla stessa sessione (nessun `/clear` in `-p`)».
   *PRD:* FR-42 dice solo «Nessuna sessione viene scritta su disco». Non dice cosa succede alla sessione quando arriva una richiesta in modalità privata o su app/siti riservati (funzionalità del commit 614df3f), né che il contenuto di una richiesta resta visibile al modello nelle richieste successive.
   *Fix:* aggiungere a FR-42: «Una richiesta in modalità privata o su un'app riservata non entra nella Sessione lunga (processo dedicato o riavvio prima e dopo); la compattazione del contesto è registrata nel log come riavvio». Estendere NFR-2 con una riga sul perimetro del contesto di sessione.

3. **Reversibilità: «ogni aggiunta è disattivabile da impostazioni».**
   *Ricerca:* §6.3 «Copertura della reversibilità»; §8 ultimo punto («la reversibilità vale più di ogni ottimizzazione»).
   *PRD:* solo FR-43 ha un interruttore; FR-42 (Sessione lunga), FR-44 (osservazione a costo fisso), FR-46 (evidenza), FR-47 (OCR) e FR-55 (classificatore, implicito) non ne hanno. Non esiste un ripiego dichiarato «processo per richiesta» se la Sessione lunga si rivela instabile (domanda aperta 7).
   *Fix:* aggiungere un NFR trasversale (per esempio NFR-15 «Reversibilità») oppure una riga in FR-20: ogni funzionalità di §4.9–§4.10 ha un interruttore nelle impostazioni e un ripiego al comportamento di oggi; per FR-42 il ripiego è esplicitamente il processo pronto attuale.

4. **Costo dell'«evidenza prima del fatto» e contro-metrica mancante.**
   *Ricerca:* §4 («al costo di 0,9 turni e 4.653 token per traiettoria [14] (studio sintetico, un solo autore). Controlli di stop più severi allungano però le esecuzioni [15]»); R4 confidenza media.
   *PRD:* FR-46 è un requisito fermo, senza [ASSUMPTION] né costo atteso; SM-8 (tempo) e SM-C4 (precisione) non si bilanciano con FR-46.
   *Fix:* aggiungere a FR-46 una conseguenza «sui compiti a una chiamata del Banco il numero di turni non cresce di più di 1 e il tempo mediano non peggiora oltre il margine di NFR-12» e marcare la fonte come studio sintetico; aggiungere a SM-C4 o a una nuova contro-metrica «turni per compito» che bilanci FR-46.

5. **Prova del modello Apple con immagini (candidato K-b) sparita.**
   *Ricerca:* R5 («prova del modello Apple con immagine per descrivere lo schermo nel motore locale»); §6.2 K-b «(provare)» 3,90; §2 e [75] (macOS 27: immagini nei prompt, `OCRTool`, contesto 8192).
   *PRD/addendum:* FR-47 dice «Il Motore locale può usare lo stesso strumento [OCR] al posto dello screenshot»: è l'OCR, non il modello con immagini. La tabella dei candidati nell'addendum non elenca K-b.
   *Fix:* o aggiungere a FR-47 (o a FR-30) una conseguenza di sola prova («il Motore locale viene provato con lo screenshot passato al modello Apple come immagine su 5 compiti del Banco; esito nella ricerca»), o registrare nell'addendum l'esclusione con il motivo (per esempio «descrive, non localizza»).

6. **Riscaldamento OCR da 26,9 s non trattato.**
   *Ricerca:* §4 OCR: 0,07–0,13 s a caldo «ma 26,9 s alla *prima* chiamata per la compilazione del modello sul Neural Engine [23]» (confidenza bassa); R5 «riscaldamento all'avvio, timeout di 10 s e ripiego `fast`».
   *PRD:* FR-47 «riscaldamento all'avvio dell'app» e conseguenza «La prima lettura dopo l'avvio non supera 1 s grazie al riscaldamento [ASSUMPTION]». Non dice cosa succede a una richiesta che arriva mentre il riscaldamento (potenzialmente ~27 s) è in corso, né che il riscaldamento deve essere in background e non ritardare l'avvio dell'ascolto.
   *Fix:* aggiungere a FR-47: «il riscaldamento è in background e non ritarda l'ascolto; una lettura chiesta prima della fine del riscaldamento usa il livello veloce o risponde “testo non leggibile ora” entro il timeout». Citare che la misura [23] è a confidenza bassa e va rifatta su M1 (domanda aperta 8 della ricerca, non ripresa nel PRD).

7. **Impostazioni di Sistema: «con conferma», non «sola lettura/solo clic».**
   *Ricerca:* R6(e) «Terminal e Finder “solo clic” o esclusi, Impostazioni di Sistema con conferma»; §5 (Claude Code: «avvisi per Terminal, Finder e Impostazioni di Sistema»).
   *PRD:* FR-54 «*solo lettura* o *solo clic* per Terminal, iTerm, Finder e Impostazioni di Sistema [ASSUMPTION]».
   *Fix:* separare: Terminal/iTerm «solo clic» (o esclusi), Finder «solo clic», Impostazioni di Sistema «tutto, con conferma per ogni Azione con effetti» (coerente con il glossario «Azione con effetti esterni» che già include «cambiare impostazioni di sistema»). Valutare anche il default della guida Anthropic [36]: siti di trading/crypto bloccati, banking sconsigliato → suggerire «sola lettura» predefinita per domini bancari e di trading nella lista dei siti riservati.

8. **Ritrattazione del red team persa: le difese «riducono la superficie, non la chiudono».**
   *Ricerca:* §7 ultimo punto («L'affermazione “insieme rendono il danno improbabile” è ritirata»); [110] 60–80 %, [111] fino al 100 %, [112] un terzo mancato; [115] calibrazione del modello Apple sotto il caso (seconda mano).
   *PRD:* §4.11 descr. e UJ-10 raccontano la difesa come se chiudesse il caso («l'esecutore blocca l'azione»); NFR-5 «nessun Motore, classificatore o impostazione può aggirarla». Nessuna frase ricorda che il gate copre solo le classi di azione elencate e che la suite misura quelle, non l'universo degli attacchi.
   *Fix:* aggiungere una riga a §4.11 descr. o a NFR-14: «La suite dimostra la tenuta sugli scenari elencati; non prova l'assenza di altri canali. Ogni nuovo canale osservato nell'uso (log delle azioni bloccate, FR-53) entra nella suite». In UJ-10, far dire all'HUD che l'azione *non era nella richiesta di Nico* («L'Agente voleva inoltrare la mail, che tu non hai chiesto: lo faccio?»), così la conferma non diventa un «sì» riflesso all'istruzione iniettata.

9. **Residuo `~/.codex/AGENTS.md` letto comunque.**
   *Ricerca:* §1 sicurezza, ultimo punto: isolamento completo «con un residuo: `~/.codex/AGENTS.md` viene letto comunque».
   *PRD/addendum:* nessuna traccia (l'addendum su Codex usa `--ignore-user-config --ignore-rules`, ma la ricerca sul codice al commit 614df3f dice che il file viene letto lo stesso).
   *Fix:* aggiungere a FR-50 (o a FR-26) una conseguenza: «un `~/.codex/AGENTS.md` con istruzioni di prova non cambia il comportamento dell'Agente (verificato nella suite di sicurezza)»; nell'addendum annotare il rimedio da provare (HOME dedicata al processo figlio o directory di lavoro vuota con regole disattivate).

10. **Dettagli di R6(c) e dell'esempio Claude Code non ripresi.**
    *Ricerca:* §5 campi password: «i caratteri di mascheramento vanno esclusi dai risultati (la lunghezza rivela la password)» [48]; «una password in un editor o terminale non è marcata sicura» [50]; Claude Code «esclude il terminale dagli screenshot» [35].
    *PRD:* FR-52 «non legge il valore, non lo riporta né lo scrive» copre il valore ma non dice esplicitamente che nemmeno la lunghezza (i pallini) deve comparire; FR-54 limita il Terminal al «solo clic» ma lo screenshot del Terminal resta ammesso.
    *Fix:* in FR-52 aggiungere «né la lunghezza (nessun carattere di mascheramento nell'osservazione)»; in FR-54 valutare «le app a livello *solo clic* sono escluse dagli screenshot inviati al Motore cloud» o motivare l'esclusione.

11. **`--bare`: la ricerca chiede la mitigazione, il PRD solo il rilevamento.**
    *Ricerca:* R7 «Rilevare il cambio di default di `--bare` (passare esplicitamente la modalità non-bare quando la CLI lo permetterà)»; §3 leve escluse («l'app dovrà esplicitare la modalità non-bare quando il default cambierà»).
    *PRD:* FR-45 «rileva un cambio di comportamento … e lo segnala in Stato e diagnostica prima che l'Agente fallisca»; addendum «FR-45 lo sorveglia».
    *Fix:* aggiungere a FR-45: «quando la CLI espone un'opzione per la modalità non-bare, l'app la passa sempre in modo esplicito; il rilevamento resta per i casi in cui l'opzione manca».

12. **Da due a tre livelli: FR-13, FR-20 e SM-4 non aggiornati.**
    *Ricerca:* R2 «estensione di FR-13».
    *PRD:* FR-43 è un FR nuovo (va bene), ma FR-13 dice ancora «si possono scegliere i due modelli», FR-20 «modelli rapido e profondo con il loro effort … finestra di validità di una conferma» (quest'ultima rimossa da FR-51), SM-4 misura «almeno metà delle richieste servite dal modello rapido» senza contare l'istantaneo.
    *Fix:* nota «esteso il 27/10 sera» in FR-13 e FR-20 (tre modelli; via la finestra di validità); SM-4 riformulata come «almeno metà delle richieste servite dal livello rapido o istantaneo».

13. **Complemento immagine/albero dove l'albero non vede.**
    *Ricerca:* §4 tecnica 1 («EFR confronta immagini, l'app confronta l'albero. I due sono complementari dove l'albero non vede (canvas, immagini)»); [29] «albero da solo debole nelle app con metadati incompleti».
    *PRD:* FR-44 e FR-46 restano sull'albero; nessuna menzione del caso canvas/immagine oltre l'OCR di FR-47.
    *Fix:* basso costo: aggiungere a FR-41 un compito su canvas/immagine (per esempio un editor grafico web) così il Banco mostra se il margine esiste; nessun FR nuovo finché il Banco non lo richiede (coerente con la disciplina «prima misurare»).

14. **Condizione di riapertura per il grounding locale.**
    *Ricerca:* «Non fare … modelli di grounding locali … finché l'albero non manca davvero l'elemento in un caso misurato».
    *PRD:* §6 «nessun modello di grounding locale» (assoluto).
    *Fix:* aggiungere «finché il Banco (FR-41) non registra un caso in cui l'albero manca l'elemento».

15. **Scadenza delle affermazioni di classe «versione» e della matrice.**
    *Ricerca:* §12 («Primo ricontrollo: 2026-10-28. Le affermazioni di classe “versione” (`--bare`, toolset, Ollama, mlx-swift-lm) scadono entro un mese: da rileggere prima di avviare l'epic di velocità»); §6.3 «matrice da rifare entro due trimestri (aprile 2027) o alla prima release di Claude Code che cambia il default di `-p`».
    *PRD:* nessuna traccia in §9 o §10.
    *Fix:* aggiungere a §10 «Generale — la base della §4.9 (`--bare`, thinking/effort, cache TTL) va riletta prima dell'epic velocità e comunque entro il 1 novembre 2026; la scelta dei Motori va rivalutata entro aprile 2027 o al primo cambio di default di `-p`».

16. **Timeout del Classificatore on-device come causa delle Frasi spurie.**
    *Ricerca:* §1 uso reale: «il classificatore on-device ha superato il limite di 1,5 s in 2 frasi su 5 a modello freddo [5]».
    *PRD:* FR-48 filtra per lunghezza e assenza di verbo/bersaglio, ma non dice che cosa fa il Router quando il classificatore va in timeout (oggi, verosimilmente, la Frase passa all'Agente).
    *Fix:* aggiungere a FR-48 (o a FR-4): «se il Classificatore on-device supera il tempo massimo, una Frase senza Parola di attivazione non va all'Agente: l'app chiede, come per le Frasi spurie».

17. **Sessione lunga e Codex: perimetro non detto.**
    *Ricerca:* R1 è solo per `claude -p --input-format stream-json`; per Codex `exec resume --last` [105] e `app-server` rinviato.
    *PRD:* glossario «un processo del Motore cloud» e FR-42 «per ogni livello di modello dell'Agente cloud» lasciano intendere che valga anche per Codex; FR-45 tiene Codex su `exec`; domanda aperta 4 resta.
    *Fix:* in FR-42 scrivere «dell'Agente Claude» e rimandare Codex alla domanda aperta 4 (o estenderla con `exec resume --last`).

18. **Confidenza delle raccomandazioni non riportata.**
    *Ricerca:* ogni R indica la confidenza (R2, R4, R5, R7 media; R8 bassa; R0, R1, R3, R6 alta) e la fonte [14] è «sintetico, un solo autore», [23] e [115] confidenza bassa.
    *PRD:* le etichette [ASSUMPTION] coprono i numeri ma non la solidità della raccomandazione.
    *Fix:* una riga in §10 o nelle descrizioni di §4.9–§4.11: «Le FR-43, FR-46, FR-47 e FR-49 poggiano su evidenza a confidenza media o bassa (ricerca §9): la riga di base di FR-41 decide se restano».

19. **Dati verso il cloud: conservazione 30 giorni / 5 anni.**
    *Ricerca:* §5 «Dati verso il cloud»: piani consumer di Claude 30 giorni (5 anni con consenso all'addestramento), ZDR solo Enterprise [54]; Codex segue le policy del workspace ChatGPT [55].
    *PRD:* NFR-2 parla solo dei dati che restano sul Mac.
    *Fix:* una riga in NFR-2 o nell'addendum: «il consenso all'addestramento resta disattivato negli account Claude e ChatGPT usati dall'app; verificato il …». Minore.

## 3. Contraddizioni e numeri non coincidenti

| # | PRD | Ricerca | Giudizio | Fix |
|---|---|---|---|---|
| C1 | §4.9 descr.: «la cache del prompt … scade in 5 minuti e **non viene riusata**» | §3 leva 1: la cache «**sopravvive tra processi `claude -p` distinti** (2.248 token letti dalla cache, tempo API −61 %)»; il processo pronto «non la crea né la rinnova» | Distorsione: oggi la cache *è* riusata quando due richieste distano meno di 5 minuti; ciò che manca è tenerla calda | Riscrivere: «scade in 5 minuti e il processo pronto non la tiene calda» |
| C2 | §4.11 descr.: «il codice ha **tre** punti deboli (token negli argomenti, conferma 45 s, parole chiave)» | §1 elenca **cinque** punti: in più il server MCP senza controllo `Origin`/`Host` e il residuo `~/.codex/AGENTS.md` (oltre alla funzione privata `_SLPSSetFrontProcessWithOptions`) | Il quarto è coperto da FR-50 ma non citato; il quinto manca del tutto (gap 9) | «cinque punti deboli …» e aggiungere il residuo Codex |
| C3 | FR-54: Impostazioni di Sistema a «sola lettura o solo clic» | R6(e): «Impostazioni di Sistema con conferma» | Distorsione del livello (gap 7) | Vedi gap 7 |
| C4 | FR-48: regola «Frase di **al massimo due parole**»; conseguenza: «“Selling counseling gesta” … non avvia nessun Motore» | — (incoerenza interna) | «Selling counseling gesta» ha tre parole: la conseguenza non discende dalla regola | O la regola diventa «al massimo tre parole» / «senza verbo d'azione né bersaglio noto, indipendentemente dalla lunghezza», o l'esempio esce |
| C5 | §0: l'aggiornamento «**Non cambia architettura** dei motori né strumenti» | R1 «sostituisce il processo pronto di AD-6»; R3 «emendamento AD-19»; R6 «AD nuovo “le conferme vivono nell'esecutore”»; R7 «emendamento AD-14/AD-16» | Non cambia i Motori, ma cambia quattro decisioni d'architettura | «Non cambia Motori né strumenti; cambia il ciclo di sessione (AD-6), l'osservazione (AD-19), la catena di riserva (AD-14/16) e aggiunge il gate nell'esecutore» |
| C6 | FR-51: la conferma vale per «lo stesso elemento **o la stessa serie di azioni**» | R6(d): rischiosi anche «i passi rischiosi dentro `act`»; [34] Anthropic chiede un controllo prima di ogni blocco perché un batch completa un'operazione a più passi in un turno; FR-38 «le conferme valgono per ogni azione della serie» | Ambiguità: una conferma «per la serie» potrebbe coprire due Azioni con effetti esterni nella stessa `act` | Riformulare: «per la stessa azione, anche se eseguita dentro una serie; una serie con due Azioni con effetti esterni ne chiede due» |
| C7 | NFR-12 / UJ-8: Livello istantaneo «≤ 2,5 s di mediana» / «in meno di tre secondi» | Nessun numero per compito su Haiku; solo primo turno API 1,3 s a freddo [7] | Numero inventato dal PRD, correttamente marcato [ASSUMPTION]; UJ-8 e NFR-12 sono coerenti tra loro | Nessuno, oltre a confermarlo con FR-41 |
| C8 | FR-46: «Il blocco `<recent>` non supera le 300 parole per interazione» | R4 dà solo il principio (esito e testo cambiato, non l'osservazione intera) | Soglia del PRD senza [ASSUMPTION] | Marcare [ASSUMPTION] e aggiungerla a §10 |
| C9 | FR-44: «scansione iniziale sotto 1 s [ASSUMPTION]» | §1: oggi «fino a 1,8 s, 220 elementi, 12.000 nodi»; nessun obiettivo numerico nella ricerca; domanda aperta 4 (costo su Gmail/Outlook non misurato) | Coerente come assunzione | Nessuno |
| C10 | Addendum, tabella «Candidati»: «su Tahoe **timeout di 2 minuti per Mail e Finder**» | [106]: Mail in timeout -1712 (2 min) o -600; Finder «empty trash» **appeso** (non timeout) | Imprecisione minore | «timeout di 2 minuti per Mail, Finder appeso su “empty trash”» |
| C11 | FR-47 conseguenza: il compito «riesce **senza inviare l'immagine al Motore cloud**»; UJ-9 «senza mandare lo screenshot a Claude» | R5: `read_text(region)` come tool **e** «arricchimento dello screenshot con zoom» (lo screenshot resta inviato, con il testo in più) | Promessa più forte della ricerca: dipende da quale strumento il modello sceglie | Riformulare: «riesce con `read_text` senza che il Motore cloud debba chiamare lo screenshot» oppure prescrivere che lo zoom con testo letto sostituisca l'immagine quando il testo basta |
| C12 | SM-9: «27/10: 2 in 5 minuti» | §1: una frase di 12 caratteri ha occupato Claude 9,7 s; una di 7 caratteri «ha prodotto una domanda all'utente» | Coerente se la seconda è passata dall'Agente; la ricerca non lo dice esplicitamente | Nessuno, o «1–2 in 5 minuti» |

**Numeri che coincidono** (verificati): 25/25; mediana 7,0 s → ≤ 4,5 s; primo strumento 2,6 s → ≤ 1,5 s; code 4–10 s; −61 % tempo API con cache; TTL 5 minuti; 10 minuti di inattività; 45 s di validità della conferma; timeout OCR 10 s; cinque verbi e 3 s per lo spike; 2 minuti per il timeout di Mail su Tahoe; 60–80 % e «un terzo»; 23 luglio 2026; 30 minuti dei thread di app-server; 3.32.3; 50,9 %; prova di 8 ore; revisione MCP 2026-07-28.

## 4. Domande aperte della ricerca senza approdo

- Ricerca Q8 (latenza di OCR e di un grounder da 4 miliardi su M1 16 GB): il PRD la assorbe solo nell'assunzione di FR-47; da aggiungere alla domanda aperta 8 del PRD o a §10.
- Ricerca Q9 e Q10 (ablazione a modello fissato; classifica OSWorld-Verified): non servono al PRD. Nessuna azione.
- Ricerca Q1, Q2, Q3, Q4, Q5, Q6, Q7 → coperte da FR-41, Q7, Q8, FR-41/FR-44, Q9, Q10, Q11 del PRD.
