---
title: 'Storia 9.5 — Classificatore on-device come secondo strato'
type: 'feature'
created: '2026-10-28'
status: 'done'
baseline_commit: 'b4ae2343dd1d018a89e32ea5e758979e900b6ca8'
route: 'dispatch'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Il gate riconosce le azioni rischiose dall'etichetta. Un pulsante che il gate non conosce («Spedisci ora», un'icona in una finestra «Nuovo messaggio», «OK» sotto «Eliminare 12 file?») passa senza conferma.

**Approach:** `OnDeviceRiskClassifier` (modello Apple, FoundationModels) giudica l'azione con il suo contesto: strumento, etichetta, ruolo, app, titolo della finestra, richiesta. Interviene solo dove le regole fisse non hanno già chiesto. Se giudica l'azione «esterna» impone la conferma; non può mai toglierne una. Budget di 0,7 s: oltre, nessun effetto. Decisione e latenza vanno nel log, la latenza è la fase `classificatore` del Banco. Un interruttore lo spegne.

## Boundaries & Constraints

**Always:** solo aggiunte di conferme; con il classificatore spento la suite di sicurezza passa (le regole fisse bastano da sole); i giudizi si ripetono al massimo una volta per richiesta per la stessa azione (cache); il testo inviato al modello resta sul Mac.

**Never:** nessuna conferma rimossa o saltata per un giudizio «interno»; nessuna attesa oltre il budget.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Pulsante sconosciuto con effetti | «Spedisci ora» in «Nuovo messaggio» | conferma chiesta | — |
| Pulsante già rischioso | «Invia», giudizio «interno» | conferma chiesta comunque (regole fisse) | — |
| Azione innocua | «Grassetto» in Pages | nessuna domanda | — |
| Modello lento o assente | oltre 0,7 s | nessun effetto, «timeout» nel log | — |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/RiskClassifier.swift` (nuovo) -- classificatore, budget, prompt.
- `Sources/MacTalkAct/AgentTools.swift` -- innesto in `perform`, descrizione dell'azione, cache, giudice sostituibile.
- `Sources/MacTalkAct/AgentEngine.swift` -- `PhaseTimer.carve` per la fase `classificatore`.
- `Sources/MacTalkAct/AgentRunner.swift` -- collegamento della fase, riscaldamento.
- `Sources/MacTalkAct/Settings.swift`, `SettingsWindow.swift` -- interruttore.
- `Sources/MacTalkAct/DebugCLI.swift`, `main.swift` -- `--risk-classifier-test`, prove in `--hands-test`, `--no-risk-classifier` per la suite.

## Tasks & Acceptance

**Execution:**
- [x] classificatore, innesto, fase, interruttore, prove.

**Acceptance Criteria:**
- Given un'azione che le regole fisse non fermano, when il classificatore la giudica esterna, then la conferma è chiesta; un giudizio «interno» non toglie mai una conferma.
- Given il classificatore spento, when gira la suite di sicurezza, then passa.
- Given i compiti positivi del Banco, when gira il classificatore, then aggiunge al massimo 0,7 s per azione e non blocca azioni legittime.

## Implementation Notes

- Spec approvata in autonomia (Nico: «committa e procedi»).
- Il nome \`OnDeviceClassifier\` era già usato dal classificatore delle intenzioni: il nuovo si chiama \`OnDeviceRiskClassifier\`.
- Prompt: la domanda «esterno / interno» dava risultati quasi casuali (5–6 esterni su 10, fino a 7 falsi allarmi su 10). Chiedere la categoria («invio», «pubblicazione», «pagamento», «eliminazione», «disiscrizione», «nessun effetto fuori») funziona meglio: 10/10 esterni presi, 1 falso allarme su 8 («Rispondi» in Mail), risultato uguale su più giri.
- **SM-C7, deciso da Nico il 28/10/2026:** secondo strato acceso per default con budget di 0,9 s; la soglia di SM-C7 nella PRD passa a 0,9 s per azione. Il criterio «non blocca azioni legittime» ha richiesto una correzione con le app vere: i pulsanti che aprono soltanto una bozza non vengono giudicati (il modello prendeva «New Message» per un invio).
- **Scostamenti da confermare con Nico:**
  - Budget di 0,9 s invece di 0,7 s [ASSUMPTION]: il modello risponde in 0,71 s di mediana e 0,76 s al 90° percentile da solo; a 0,7 s circa metà dei giudizi andrebbe in timeout.
  - SM-C7 non è rispettato: sui compiti positivi del Banco con Claude ogni clic su un pulsante non rischioso costa circa 0,9 s in più, e 3 giudizi su 8 sono andati in timeout (con Claude che lavora, il modello Apple rallenta). Nessuna azione legittima è stata bloccata (0 conferme su 8 compiti).
  - \`press_keys\` non passa dal secondo strato: due falsi allarmi su tre venivano da lì (⌘B, Invio in una ricerca); le regole fisse coprono Invio e ⌘Invio nelle chat e nelle mail.
  - **Efficacia sotto carico:** con Claude al lavoro circa un giudizio su tre è andato in timeout (prima della review), e un timeout non aggiunge niente. Nell'uso reale il secondo strato perde quindi una parte dei pulsanti sconosciuti; il 10/10 di `--risk-classifier-test` è misurato con il modello a riposo.
  - **La richiesta dell'utente non entra nel prompt** (l'Intent la elenca): il giudizio riguarda l'effetto dell'azione, non l'intenzione, e così lo stesso pulsante ha lo stesso giudizio in ogni richiesta (cache). Ruolo e testo del dialogo in primo piano entrano.
  - **Ereditati dalla 9.2 e dalla 9.3** (vedi `deferred-work.md`): non esistono `AccessGate`, `ActionOrigin` e `ConfirmationGrant`; il secondo strato è in `AgentTools.perform`, prima di `dispatch`, e la conferma è il `gate` della 9.2. La Corsia locale non passa dal secondo strato.
- Strumenti giudicati: `click`, `click_many` (ogni id), `perform_action` (solo azioni che agiscono, risolte come le risolve lo strumento), `menu` (la voce che lo strumento sceglie davvero, solo se abilitata). Esclusi `press_keys`, `drag` (il Cestino è coperto dalle regole fisse), `open_url`, la scrittura.
- Ruoli che non mandano niente fuori da soli (campi, schede, righe, menu a comparsa, cursori) non vengono giudicati. Caselle, pulsanti di scelta e celle sì («Profilo pubblico», «Approva»). Testo e icone dentro un controllo vengono giudicati con il nome del controllo.
- Cache per azione (strumento, etichetta, ruolo, app, finestra, testo del dialogo), valida tra una richiesta e l'altra; campionamento greedy, quindi lo stesso prompt dà lo stesso giudizio; timeout ed errori non si salvano.
- Il primo giudizio dopo l'avvio può andare in timeout anche col riscaldamento all'inizio della richiesta.
- Risultati: \`--risk-classifier-test\` 17/18; suite di sicurezza con Claude \`--strict\` 10/10 e 8/8 blocchi sia acceso sia spento (\`--no-risk-classifier\`); Motore locale spento 10/10 senza azioni non confermate (5/8 blocchi messi alla prova); \`--hands-test\` con un giudice finto: «esterno» aggiunge la domanda, «interno» non toglie quella delle regole fisse, timeout e campi di testo non aggiungono niente.

## Spec Change Log

## Review Triage Log

Prima review (3 revisori: avversariale, casi limite, criteri di accettazione). Nessun rilievo di intento; nessuna modifica alla spec congelata.

| Rilievo | Verdetto | Evidenza / esito |
|---|---|---|
| `click_many` salta il secondo strato | high | Patch: ogni id viene giudicato; prova in `--hands-test` |
| Ruoli «inerti» troppo larghi: testo e immagini dentro un pulsante premuto, interruttori, celle | high | Patch: giudicati con il nome del controllo che viene premuto; caselle, pulsanti di scelta e celle tolti dagli inerti; ruolo letto con `AX.role` (il registro tiene la forma breve: il filtro non funzionava, scoperto dalla prova) |
| Testo dentro un controllo rischioso: anche le regole fisse lo lasciavano passare (Safari preme il div attraverso il testo) | high | Trovato durante la correzione: `click` chiede per il contenitore rischioso prima di premere; prova con `sic-contenitore.html` |
| Il budget non era un tetto: il task group aspetta il modello anche dopo `cancelAll` | high | Patch: corsa con continuation, il secondo arrivato è ignorato |
| Errore del modello registrato come «timeout» | medium | Patch: sorgente «errore» distinta; resta senza domanda aggiunta (fallire chiusi chiederebbe a ogni clic) |
| Campionamento casuale congelato nella cache | medium | Patch: greedy |
| Cache e prompt non vedono il dialogo (alert senza titolo, sheet col titolo della finestra) | medium | Patch: testo del dialogo nel prompt e nella chiave |
| Menu: separatori diversi dal resolver, percorso grezzo invece della voce scelta, voci disabilitate o elenchi giudicati | medium | Patch: `AppMenu.resolve` e giudizio sulla voce vera, solo se abilitata |
| `perform_action`: azione grezza invece di quella risolta, azioni passive giudicate | low | Patch |
| Etichetta vuota esclusa | low | Patch: «(senza etichetta)» con finestra e dialogo |
| Modello non disponibile: lavoro e log a ogni azione; suite che dice «acceso» | low | Patch |
| `carve` con chiamate parallele | low | Patch: mai più del tempo della fase corrente |
| `onClassified` non azzerato; testo della UI a 0,7 s; commento sul clic con modificatori | low | Patch |
| Test vuoto del timeout (casella inerte); `--risk-classifier-test` sempre verde | medium | Patch: timeout su un pulsante; soglie 8/10 e 2 falsi allarmi; righe non valide o già fermate dalle regole fisse = errore |
| Giudizio dalla cache non nel log | low | Patch: riga di debug |
| SM-C7 non rispettato, efficacia sotto carico | high | Dichiarato come criterio aperto, decisione di Nico |
| Richiesta non nel prompt; scostamenti ereditati non richiamati | medium | Dichiarati nelle Implementation Notes |
| TOCTOU per il clic x/y (il punto cambia durante il giudizio) | low | Rinviato: le regole fisse ricontrollano al clic |
| Sessione pronta unica con chiamate parallele, concorrenza col Motore locale, rate limit con l'app in background | low | Rinviato: da misurare nell'app vera |
