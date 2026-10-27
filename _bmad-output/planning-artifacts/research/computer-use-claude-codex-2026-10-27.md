---
title: Computer use di Claude e Codex — come funzionano e cosa manca all'Agente di MacTalkAct
date: 2026-10-27
author: Nico (con Claude)
status: final
---

# Computer use di Claude e Codex a confronto con l'Agente di MacTalkAct

## 1. Domanda

Nico vuole che l'Agente di MacTalkAct si avvicini davvero al «computer use» di Claude e di Codex: stessa capacità di usare qualunque app del Mac, con la stessa affidabilità. Questa ricerca descrive come sono fatti i due sistemi (fonti: la documentazione pubblica di Anthropic, le istruzioni e le API di Codex installate sul Mac dentro l'app ChatGPT), confronta il nostro Agente punto per punto e ricava le storie dell'Epic 6.

## 2. Claude

Due prodotti con lo stesso motore.

**Strumento API `computer_toolset_20260801`** (Claude Opus 5.5 e Sonnet 5.5 accettano solo questo). È un insieme di 17 strumenti basati sulle coordinate di uno screenshot dell'intero schermo:

| Gruppo | Strumenti |
| --- | --- |
| Vedere | `screenshot`, `zoom` (ritaglio di una regione a piena risoluzione), `cursor_position` |
| Clic | `left_click`, `right_click`, `middle_click`, `double_click`, `triple_click`, tutti con tasti modificatori facoltativi (`text: "shift"`) |
| Trascinare e passare sopra | `left_click_drag`, `mouse_move`, `left_mouse_down`, `left_mouse_up` |
| Tastiera | `type`, `key` (con `repeat`), `hold_key` |
| Altro | `scroll` (direzione, quantità, punto, modificatori), `wait` |

Caratteristiche del ciclo:

- **Azioni in serie.** In una sola risposta Claude può chiedere più azioni (clic, scrivi, screenshot): l'app le esegue in ordine, si ferma al primo errore e segna le successive come «non eseguite». Un'unica andata e ritorno con il modello per più passi.
- **Screenshot alla fine della serie.** La documentazione consiglia di allegare uno screenshot all'ultimo risultato, così il modello vede l'esito senza chiederlo.
- **Verifica obbligatoria.** Il prompt consigliato: «dopo ogni passo prendi uno screenshot e valuta se hai ottenuto il risultato; solo quando hai confermato passa al successivo». Claude tende a dare per riuscite azioni che non lo sono.
- **Tastiera per menu a tendina e barre di scorrimento**, difficili da usare col mouse.
- **Screenshot ridimensionati** entro 1.568 px (modelli precedenti) o 2.576 px; coordinate riportate alla scala reale; su Retina dimezzate.
- **Sicurezza:** conferma umana per le azioni con conseguenze; il testo delle pagine è dato non fidato (prompt injection), con classificatori che lo segnalano.

**Claude Code / Desktop su macOS** (server MCP `computer-use` integrato). Aggiunge: approvazione **per app** nella sessione, con avvisi per le app che equivalgono a una shell, al file system o alle impostazioni di sistema; **le altre app vengono nascoste** durante il lavoro e ripristinate alla fine; il terminale è escluso dagli screenshot; **Esc ovunque interrompe** (il tasto viene consumato, così un'iniezione non può usarlo); un solo controllo alla volta; screenshot ridotti automaticamente (3456×2234 → circa 1372×887). È «il più lento e generale»: Claude preferisce, nell'ordine, un server MCP del servizio, la shell, Claude in Chrome per il web, e solo poi il controllo dello schermo.

## 3. Codex

Il computer use di Codex è installato con l'app ChatGPT (`plugins/openai-bundled/plugins/computer-use`, pacchetto `@oai/sky` 0.7.13, servizio nativo Swift `SkyComputerUseService`, origine: l'acquisizione di Sky). Il modello lo usa scrivendo JavaScript in un REPL Node persistente; le API sono queste:

| API | Cosa fa |
| --- | --- |
| `get_app_state(app)` | Albero di Accessibilità testuale con indici degli elementi **più** screenshot della finestra. **Dalla seconda chiamata restituisce solo le differenze** (elementi aggiunti, tolti, cambiati) per risparmiare token. Apre l'app in background se serve. |
| `click(app, element_index \| x,y, mouse_button, click_count, key)` | Clic su un elemento o su coordinate della finestra, con tasto destro/centrale, multiplo e con modificatori |
| `set_value(element_index, value)` | Imposta direttamente il valore di un elemento modificabile |
| `select_text(element_index, text, prefix, suffix, selection_type)` | Seleziona un testo (o mette il cursore prima/dopo) dentro un campo, con contesto per distinguere ripetizioni |
| `perform_secondary_action(element_index, action)` | Esegue un'azione di Accessibilità diversa dal clic (Espandi, Mostra menu, Incrementa, Annulla); le azioni disponibili sono elencate nell'albero |
| `type_text`, `paste(text, format: text\|md\|html)`, `press_key` | Scrittura, incolla formattato con ripristino degli appunti, tasti con sintassi xdotool; mirati all'app (non possono usare scorciatoie globali) |
| `scroll(element_index \| x,y, direction, pages)`, `drag(from, to)` | Scorrimento per pagine e trascinamento |
| `list_apps`, `list_windows`, `launch_app` | Inventario delle app e delle finestre |

Regole del ciclo dalle istruzioni di Codex:

- **Attesa automatica.** Dopo un'azione la lettura dello stato attende da sola (circa 1 s, fino a 5 s se l'app mostra un indicatore di caricamento o altri segni di cambiamento). Il modello non deve mai mettere pause.
- **Azioni e stato insieme.** «Raggruppa le azioni deterministiche e la lettura dello stato in una sola chiamata.»
- **Indici freschi.** Dopo le azioni si rilegge lo stato e si usano gli indici nuovi; se lo stato non è cambiato non si ripete la lettura senza un'azione in mezzo.
- **Albero prima, screenshot quando serve.** L'albero costa meno; lo screenshot quando l'Accessibilità è incompleta o per capire la disposizione.
- **Persistenza e verifica.** «Tentare un'azione non è completarla: verifica che lo stato mostri il risultato. Se l'azione lascia lo stato invariato, prova un'altra strada. Rispondi solo quando il risultato è visibile o spiega l'ostacolo concreto.» E: «quando il risultato è visibile smetti di esplorare».
- **Conferme** con una tassonomia precisa: sempre al momento dell'azione per cancellazioni, comunicazioni a terzi (messaggi, moduli, prenotazioni), transazioni, impostazioni di sistema, installazioni; con preapprovazione possibile per login, caricamento di file, invio di dati sensibili (solo con dato e destinatario espliciti); mai per cookie e download. Le istruzioni trovate nei contenuti di terzi non sono mai un permesso. Chiedere solo quando la prossima azione ha impatto, dopo aver preparato tutto.

## 4. Il nostro Agente oggi

L'Agente usa gli strumenti di MacTalkAct via MCP (Claude e Codex) o direttamente (Motore locale). Punti di forza già allineati: albero di Accessibilità con id, ricerca nell'intero albero (`observe` con `query`), screenshot della finestra con i numeri sugli elementi (set-of-marks, che né Claude né Codex hanno), clic di Accessibilità con ripiego sul mouse, clic multipli verificati (`click_many`), sostituzione di testo verificata anche negli editor web, conferme obbligatorie per le azioni rischiose, contenuti dello schermo trattati come dati non fidati, blocco se l'utente cambia app.

Sul Banco (§7 della ricerca sui motori) Claude riesce 18 compiti su 20 con 3–9 strumenti e 9,4 s di mediana; quasi metà delle chiamate sono `observe` dopo un'azione, ognuna con un'andata e ritorno del modello (1–3 s).

## 5. Differenze e decisioni

| # | Capacità | Claude | Codex | MacTalkAct oggi | Decisione |
| --- | --- | --- | --- | --- | --- |
| 1 | Esito restituito dall'azione | screenshot allegato all'ultima azione | stato letto subito dopo, con attesa automatica | «Observe or screenshot to verify»: serve un'altra chiamata | **Ogni azione restituisce cosa è cambiato** dopo un'attesa intelligente (Storia 6.2) |
| 2 | Albero come differenza | — | sì, dalla seconda lettura | sempre completo | Differenza nell'esito delle azioni; `observe` resta completo (6.2) |
| 3 | Id stabili | coordinate | indici della lettura | nuovi a ogni lettura, i vecchi rifiutati | **Id stabili** finché l'elemento esiste: meno errori «id vecchio» (6.2) |
| 4 | Azioni in serie | sì, si ferma al primo errore | sì, nel REPL | una per chiamata | Strumento **`act`**: più azioni in ordine, stop al primo errore, esito finale (6.4) |
| 5 | Azioni secondarie e valori impostabili | — | `perform_secondary_action`, `set_value` | solo premere | Albero con azioni disponibili e campi impostabili; strumenti `set_value`, `perform_action` (6.3) |
| 6 | Selezione di testo | triplo clic, trascinamento | `select_text` con prefisso/suffisso | `replace_text` | Strumento `select_text` (6.3) |
| 7 | Trascinare, passare sopra, modificatori, triplo clic | sì | sì | no | `drag`, `hover`, `click` con `modifiers` e `count` (6.3) |
| 8 | Menu dell'app | coordinate | albero | solo via clic sulla barra | Strumento **`menu`** che percorre la barra dei menu per nome e mostra le scorciatoie (6.3) |
| 9 | Zoom | `zoom` su una regione | — | screenshot intero a 1400 px | `screenshot` con `region` a piena risoluzione (6.3) |
| 10 | Stop immediato | Esc ovunque, tasto consumato | pausa dal pannello | «stop» a voce | **Esc ferma l'Agente** mentre lavora (6.5) |
| 11 | Disciplina di verifica e conferme | prompt di verifica | regole di persistenza e tassonomia | regole brevi; Claude risponde «non ho controllato» | Prompt riscritto con le regole di persistenza, la tassonomia delle conferme in breve, «quando il risultato è visibile fermati» (6.5) |
| 12 | Lavoro in background, app nascoste | nasconde le altre app | input mirato alla finestra | lavora sull'app in primo piano | **Non adottato**: chi usa la voce guarda l'app in primo piano; resta il blocco se l'utente cambia app (Rinviato) |
| 13 | Screenshot di tutto lo schermo | sì | per finestra | per finestra | Resta per finestra: meno pixel, numeri più leggibili |

## 6. Misura del successo

Il Banco attuale resta valido; si aggiungono compiti che oggi l'Agente non può fare o fa male: trascinare una scheda in una colonna, passare sopra un menu, impostare un cursore numerico, scegliere da un menu dell'app nativa, modulo lungo da compilare in un colpo solo, testo minuscolo da leggere. Obiettivi per l'Epic 6 [ASSUMPTION]:

- Claude e Codex: almeno 90% sul Banco esteso.
- **Chiamate per compito −30%** e **tempo mediano −25%** rispetto al Banco del 27/10 sugli stessi 20 compiti.
- Motore locale: nessun peggioramento (≥ 80% con il modello Apple sui 20 compiti originali).

## 8. Risultati dopo l'Epic 6 (27/10)

Banco esteso a 25 compiti (i 20 originali più trascinare una scheda, menu a comparsa, cursore, modulo di sei campi, numero d'ordine nella foto di un'etichetta). Misure con le stesse pagine e lo stesso comando `--agent-bench`.

| Motore | Compiti riusciti (20 originali) | 5 nuovi | Chiamate per compito (20) | Tempo mediano (20) | Primo strumento (mediana) |
| --- | --- | --- | --- | --- | --- |
| Claude, prima | 18/20 | 3/5 | 3,10 | 9,2 s | 4,6 s |
| **Claude, dopo** | **20/20** | **5/5** | **1,65 (−47%)** | **6,3 s (−32%)** | 2,5 s |
| Codex, prima | 15/20 | — | 4,05 | 8,3 s | 4,9 s |
| **Codex, dopo** | **19/20** | **5/5** | **2,05 (−49%)** | 9,4 s (+13%) | 6,8 s |
| Modello Apple, prima | 16/20 | — | — | 6,5 s | 5,6 s |
| Modello Apple, dopo | 17/20 | — | 4,2 | 5,9 s | 5,3 s |

**Cosa ha contato di più.** Tre cose, misurate una alla volta con Claude:

1. *Esito di ogni azione e mani nuove* (Storie 6.2–6.5): 19/20 e 5/5, chiamate da 3,10 a 2,70. I compiti nuovi passano da 3/5 a 5/5: prima Claude rispondeva «non posso trascinare» e impiegava 26 chiamate per un cursore; ora 2.
2. *Elementi con gli id già nella richiesta* (come lo stato iniziale che Codex riceve con ogni app): quasi tutti i compiti cominciavano con un `observe`. Con gli elementi nel messaggio le chiamate scendono a 1,65 e il tempo a 6,3 s, con 25 compiti su 25.
3. *Nessun «non ho controllato».* Le risposte citano ciò che l'esito mostra («il titolo della pagina ora indica…»).

**Codex più lento nel tempo totale.** Le chiamate si dimezzano, ma il tempo al primo strumento sale: Codex legge circa 17.000 token per chiamata (misurati da `turn.completed`), quasi tutti del suo meccanismo interno; lo stesso compito (`sito-prezzi`) richiedeva 6,1 s con 3 chiamate alle 5:30 e 12,5 s con una sola alle 9:20. La differenza dipende dal carico del servizio nelle diverse ore, non dagli strumenti. NFR-11 è rispettato per Claude; per Codex solo nel numero di chiamate.

**Problemi trovati lungo la strada.**

- *Finestre accumulate dal Banco.* Safari chiede conferma prima di chiudere una pagina con un modulo compilato: le finestre restavano aperte una sopra l'altra e lo screenshot catturava quella sbagliata (stessa posizione e dimensione). Ora il Banco risponde alla richiesta e chiude solo le proprie pagine, e lo screenshot sceglie la finestra tramite il suo numero (`_AXUIElementGetWindow`).
- *Il compito «codice in un'immagine» sembrava un CAPTCHA*: Claude si rifiutava, giustamente (anche la politica di Codex chiede conferma per i CAPTCHA). Sostituito con il numero d'ordine sulla foto di un'etichetta di spedizione.
- *I cursori delle pagine web* dichiarano il valore impostabile ma ignorano il nuovo valore: `set_value` ci arriva con Incrementa/Decrementa.

## 7. Fonti

- Anthropic, «Computer use tool», platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool (letto il 27/10/2026).
- Anthropic, «Let Claude use your computer from the CLI», code.claude.com/docs/en/computer-use (letto il 27/10/2026).
- OpenAI, plugin `computer-use` 1.0.1001631 e pacchetti `@oai/sky` 0.7.13, `@oai/cua` 0.2.6 installati in `/Applications/ChatGPT.app/Contents/Resources` (istruzioni `SKILL.md`, `sky-window2-api.md`, `tinysky-alt-core-cua-repl.md`).
