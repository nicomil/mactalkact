---
title: Analisi dei limiti di MacTalkAct
type: research-brownfield
created: 2026-10-26
author: Mary (BMad Analyst) per Nico
sources:
  - ~/Library/Logs/MacTalkAct.log (26/10/2026, 17:12–20:52, solo statistiche e frasi di comando)
  - Sources/MacTalkAct/*.swift (5.382 righe)
  - README.md (sezione «Limiti noti»)
  - Esperimenti locali con il modello Apple on-device (FoundationModels, macOS 27.0.1)
---

# Analisi dei limiti di MacTalkAct

## In sintesi

MacTalkAct oggi **esegue bene quando capisce**, ma **capisce male quando conta**. Il problema più grave non è la potenza dell'agente: è la decisione che avviene prima, cioè se una frase va scritta, eseguita o ignorata. Nell'ultima sessione reale di lavoro su un notebook Jupyter in Edge (20:45–20:52) **6 frasi su 11 sono finite scritte dentro il notebook** invece di essere eseguite o ignorate. Ogni errore di questo tipo sporca il lavoro dell'utente e costringe a usare le mani, cioè proprio quello che l'app deve evitare.

Il secondo problema è la **mancanza di memoria a breve termine**: ogni richiesta all'agente parte da zero, quindi una frase naturale come «rimetti la domanda di prima» non può funzionare.

Il terzo è **lentezza e fragilità dell'agente**: anche «apri nuova tab» passa da Claude Opus (3,8 s), un compito ripetitivo su una tabella ha richiesto 39 passi e 42 s con clic a coordinate, e quando la subscription esaurisce la quota l'agente scompare del tutto.

Un esperimento locale ha mostrato che il **modello linguistico Apple on-device**, già presente sul Mac, classifica correttamente le frasi critiche della sessione (6 su 6) in circa 0,6 s, senza rete e senza consumare la subscription. È la leva tecnica che rende risolvibili i primi due problemi.

## 1. Evidenze dall'uso reale

### 1.1 Numeri della giornata

| Misura | Valore |
| --- | --- |
| Frasi rilevate dal rilevatore di voce | 99 (durata media 4,6 s; 9 oltre i 10 s) |
| Frasi arrivate al router | 15 |
| Frasi ignorate per mancanza di «computer» | 10 |
| Frasi senza esito registrato | circa 74 (rumore, trascrizione vuota o scarto silenzioso: il log non permette di distinguere) |
| Frasi scritte come testo | 6, tutte per errore |
| Esecuzioni dell'agente | 8 (da 3,2 s a 41,6 s) |
| Interruzioni per limite della subscription | 1 (18:25, agente fuori uso fino alle 19:00) |

### 1.2 La sessione sul notebook (20:45–20:52)

| Ora | Frase | Cosa è successo | Esito |
| --- | --- | --- | --- |
| 20:45:55 | «selezionale check box accanto a quelle già selezionate» | Agente: 39 passi, 36 clic a coordinate, 41,6 s | Riuscito, ma lento e fragile |
| 20:48:53 | «Modifica la domanda» | Agente: chiede quale domanda, riceve «Sì», seleziona testo con 30× shift+freccia e rinuncia | Fallito |
| 20:49:23 | «Computer» | La sola parola di attivazione viene scritta nel notebook | Errore |
| 20:49:37 | «Rimetti la domanda di prima» | Scritta nel notebook (nessun verbo nella lista fissa) | Errore |
| 20:50:02–21 | 4 frasi | Ignorate perché manca «computer» (probabilmente tentativi di ripetere il comando) | Frustrazione |
| 20:50:32 | «Modifica la domanda che cos'è il cloud computing in che cos'è Internet?» | Scritta nel notebook | Errore |
| 20:50:45 | «Modifica la domanda» | Scritta nel notebook | Errore |
| 20:51:06 | «Ciao» | Scritta nel notebook | Errore |
| 20:51:20 | «modifica la domanda» | Agente: chiede, l'utente risponde, sostituisce la riga | Riuscito dopo 2,5 minuti di tentativi |
| 20:51:50 | «Bellissimo, ok, stop» | Scritta nel notebook | Errore |
| 20:52:00 | «apri nuova TAB» | Agente Opus per un solo Cmd+T: 3,8 s | Riuscito, lento |

## 2. Limiti, in ordine di impatto

### L1 — Il router scrive frasi che non sono dettatura (critico)

**Causa nel codice.** `Coordinator.runSmart` decide così: se il cursore è in un campo di testo e la frase non inizia con uno dei 70 verbi della lista `Grammar.actionVerbs`, la frase viene scritta. «Modifica», «rimetti», «cambia», «sostituiscilo», ma anche «ciao» e «bellissimo», non sono nella lista, quindi finiscono nel documento. Allungare la lista non risolve: la lingua parlata ha troppe forme.

**Bug collegato.** Se l'app è già «armata» (finestra dopo la parola di attivazione) e l'utente ripete solo «computer», la parola stessa viene scritta: in `handle()` il testo viene ripulito dalla parola di attivazione solo quando resta qualcosa.

**Impatto.** È il difetto più dannoso: produce testo spazzatura nel lavoro dell'utente, che poi deve ripulire a mano.

### L2 — Nessuna memoria di conversazione (alto)

Ogni richiesta avvia l'agente da zero (`--no-session-persistence`, messaggio con solo schermo, memoria permanente e richiesta). Riferimenti come «quella di prima», «anche per l'altra riga» o «no, intendevo quella sotto» non hanno senso per l'agente. Anche le risposte alle domande dell'agente sono fragili: alla domanda «con quale domanda sostituisco?» l'app ha passato la risposta «Sì».

### L3 — La conversazione si chiude troppo presto (alto)

Dopo una risposta, per 8 secondi vengono accettati senza «computer» solo i comandi rapidi della grammatica fissa. Tutto il resto viene scartato. Nella sessione, quattro frasi consecutive sono state ignorate mentre l'utente cercava di completare la stessa richiesta.

### L4 — Tutto passa dall'agente più costoso (medio-alto)

Ogni frase che la grammatica fissa non riconosce va all'agente Claude Opus con effort medio: circa 2,5 s solo per arrivare al primo strumento, 3,8 s per un Cmd+T. Ogni richiesta consuma la stessa quota della subscription usata per lavorare con Claude Code.

### L5 — Quando la subscription è esaurita, l'agente sparisce (medio)

Alle 18:25 il messaggio «You've hit your session limit» ha lasciato l'app senza agente per 35 minuti. Ora l'errore è spiegato in modo chiaro, ma non esiste alcun piano B oltre alla grammatica fissa.

### L6 — L'agente è impreciso sulle pagine web complesse (medio)

Nel compito delle caselle l'agente ha fatto 36 clic a coordinate dedotte dallo screenshot, uno alla volta, senza verificare lo stato di ogni casella. È andata bene, ma basta uno scorrimento imprevisto per cliccare la riga sbagliata. Negli editor web (Jupyter, Colab, editor di codice) il campo non espone il testo all'Accessibilità, quindi modificare una riga richiede trucchi da tastiera: il primo tentativo è fallito.

### L7 — Il log non spiega le decisioni (medio, abilitante)

Per circa 74 frasi su 99 non si sa che cosa sia successo. Senza una riga «frase → decisione → motivo» non si può misurare se una modifica al router migliora o peggiora le cose.

### Limiti minori già noti (fuori da questa analisi)

Profili del browser non leggibili per protezione di macOS, verso dello scorrimento da verificare, scorciatoie ⌘[ e ⌘] con la tastiera italiana. Sono piccoli e restano nel README.

## 3. Esperimento: modello Apple on-device

Sul Mac è disponibile `SystemLanguageModel.default` (framework FoundationModels): `availability: available`, lingua italiana supportata.

**Test A — instradamento.** Istruzione: «il cursore è in un campo di testo, decidi se la frase è un comando, una dettatura o chiacchiera», con generazione vincolata a tre valori.

| Frase | Risposta | Corretta |
| --- | --- | --- |
| Rimetti la domanda di prima | comando | sì |
| Modifica la domanda che cos'è il cloud computing in che cos'è Internet? | comando | sì |
| Ciao amore, vuoi la pappa? | chiacchiera | sì |
| Caro Marco ti scrivo per confermare la riunione di domani | dettatura | sì |
| apri nuova tab | comando | sì |
| Bellissimo, ok, stop | chiacchiera | sì |

Tempi: 0,55–0,63 s a modello caldo (2,3 s solo alla prima chiamata dopo l'avvio).

**Test B — traduzione diretta in azione.** Su 12 comandi semplici: 8 corretti, 4 sbagliati («vai su youtube» trattato come app, «torna indietro» → tasto «[», «ingrandisci il testo» → tasto inesistente, «seleziona le caselle» → scorrimento). Tempi 0,8–0,9 s.

**Test C — modello di decisione locale Laya (Ollama).** Stesse 6 frasi su `laya:322m-multilingual-bf16` (322 milioni di parametri, 658 MB, Apache 2.0) tramite l'endpoint locale `/v1/systemone` di Ollama 0.40.11, in tre varianti: scelta con istruzioni in italiano **1/6**, scelta con istruzioni in inglese **3/6**, due domande sì/no separate **2/6**. Tende a rispondere «dettatura» quasi sempre. È molto veloce (51–169 ms, tipicamente 55 ms) ma, senza addestramento specifico, non è affidabile in italiano. Scartato per ora; resta un'opzione se in futuro esce una variante addestrata sull'italiano o se si vuole addestrarlo sul Corpus.

**Conclusione.** Il modello on-device è affidabile per **classificare** e utile per **proporre** azioni semplici, ma una proposta va sempre controllata da regole deterministiche (scorciatoie note, app installate, URL validi) prima di essere eseguita. Non sostituisce l'agente Claude per i compiti a più passi.

## 4. Raccomandazione

Concentrare il prossimo ciclo su due epic, nell'ordine:

1. **«Mi capisce al primo colpo»**: un router unico con classificatore on-device, conversazione che resta aperta in modo intelligente, memoria a breve termine per l'agente e annullamento vocale di quello che l'app ha scritto. Risolve L1, L2, L3 e L7.
2. **«Veloce e sempre disponibile»**: una corsia locale per i comandi a un passo, il modello Claude scelto in base alla difficoltà, una modalità ridotta quando la subscription è esaurita e strumenti dell'agente più precisi per liste ed editor web. Risolve L4, L5 e L6.

Il primo epic viene prima perché elimina il danno (testo scritto per errore) e perché introduce il classificatore on-device su cui si appoggia il secondo.
