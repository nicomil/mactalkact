---
title: 'Calibrazione guidata dei gesti con la testa e «sì» facoltativo'
type: 'feature'
created: '2026-10-30'
status: 'done'
baseline_commit: '1c5528eedefa6d4ac0260e83d27bc904194808cc'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/spec-gesti-attenzione.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Le soglie di sì/no e il limite del cancello sono fisse, tarate sulle quattro corse del 29/10. Il «sì» con la testa ha dato 3/5 e per questo oggi non c'è: con soglie personali potrebbe bastare.

**Approach:** Nelle Impostazioni, una «Calibrazione completa» guidata a voce come `--gesture-spike`: guarda lo schermo (5 s), girati verso la stanza, 5 sì e 5 no a ogni numero detto, poi verifica con 3 sì e 3 no. Dagli angoli registrati l'app sceglie soglie personali e il limite del cancello, le salva e dice il risultato. Se la verifica del sì è perfetta compare l'opzione «Conferma con un sì della testa», spenta di serie. Chiesto da Nico il 30/10/2026; i gesti nuovi (doppio no = stop, girato a lungo = chiudi sessione) sono in deferred-work.

## Boundaries & Constraints

**Always:** solo angoli e tempi, mai immagini; soglie scelte solo tra quelle con **zero gesti falsi** su tutta la registrazione (gesti nelle fasi senza gesti o del tipo sbagliato); limite del cancello tra 15° e 25°, mai più stretto di quanto serve a non scambiare lo schermo per la stanza; senza un profilo valido restano i valori di oggi; la calibrazione si interrompe con «stop» o chiudendo le Impostazioni, e la camera torna allo stato di prima; il «sì» con la testa non è mai l'unico modo di confermare (la voce resta); logica di scelta pura e provata in `--selftest`.

**Never:** gesti nuovi oltre sì/no; gesti con le mani; il «sì» con la testa attivo senza una verifica passata; salvare la registrazione su disco.

**Decisioni di Nico (30/10):**
- *Il «sì» con la testa conferma solo la proposta «scrivilo»* (come dire «scrivilo»): scrivere si annulla con «cancella quello che hai scritto». Non conferma il «Confermi?» dei piani né le conferme dell'Agente e della Corsia locale.
- *Spec tenuta intera* (~2.000 token): il sì esiste solo se la calibrazione lo verifica.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Calibrazione riuscita | 5+5 gesti, verifica 3/3 e 3/3, nessun falso | profilo salvato; voce e scheda: «sì 3/3, no 3/3, nessun falso»; compare l'opzione del sì | — |
| Sì incerto | verifica sì 2/3 | profilo salvato, opzione del sì nascosta e spenta | — |
| Nessuna soglia senza falsi | ogni combinazione ha almeno un falso | profilo non cambiato; «non sono riuscito a tarare, resto come prima» | — |
| Ricalibrazione peggiore | profilo con sì verificato, nuova verifica sì 2/3 | opzione del sì nascosta e spenta | — |
| Volto assente | nessun volto nella prima fase | si ferma: «non vedo il tuo volto» | camera allo stato di prima |
| Interrotta | «stop» o Impostazioni chiuse a metà | nulla salvato | camera allo stato di prima |
| Sì con la testa | opzione attiva, domanda in attesa che il sì può confermare | come dire «sì» | — |
| Sì, opzione spenta | domanda in attesa | nulla | — |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/HeadGestures.swift` -- `HeadGestureDetector.Config` (ampiezze, `nodMaxDuration`; diventa `Codable`); `ExcursionTracker.maxDwell` è una costante: va in `Config` (`nodMaxDwell`, predefinito 0,5 s; nella corsa 4 due cenni lenti avevano sosta 0,47–0,53 s). Riusare `GestureSpikeReport.answers`/`tally`, `GesturePhase` (con `cues`) e il ciclo della griglia (`:598`) come modello. `HeadLiveState` arma solo il «no»: va esteso al «sì».
- `Sources/MacTalkAct/HeadWatcher.swift` -- `beginCalibration`/`endCalibration` registrano già tutti i campioni: si riusano per la registrazione dell'intera corsa; `calibrate()` resta per la calibrazione rapida.
- `Sources/MacTalkAct/GestureSpike.swift` -- protocollo a fasi con voce e numeri (`secondsPerGesture` 3 s) da cui copiare la sequenza.
- `Sources/MacTalkAct/Coordinator.swift` -- `calibrateHead()` (rapida), `handleHeadNo`/`headNoTarget` (modello per il sì), `perform(.confirmation(yes:))` e `.typeProposed` (cosa fa un sì), `routeChain` (serializzare).
- `Sources/MacTalkAct/Settings.swift`, `SettingsWindow.swift` `HeadAttentionCard` -- profilo salvato, opzione del sì, secondo pulsante.

## Tasks & Acceptance

**Execution:**
- [x] `Sources/MacTalkAct/HeadGestures.swift` -- `nodMaxDwell` in `Config`; `HeadProfile` (`Codable`: soglie, limite, sì verificato, data); `HeadProfileFit`: griglia (ampiezza pitch 5–12°, yaw 6–12°, durata del cenno 1,2–2 s, sosta 0,5–0,9 s), solo combinazioni con zero falsi, massimo di risposte giuste, a parità la più severa; limite = 0,6 × scarto mediano della fase stanza, tra 15° e 25°, e sopra il 95° percentile della fase schermo; valutazione della verifica; `HeadLiveState` arma il «no» per ogni domanda e il «sì» solo per la proposta «scrivilo» con l'opzione attiva -- puro.
- [x] `Sources/MacTalkAct/HeadCalibrationGuide.swift` (nuovo) -- la corsa guidata: fasi, voce, numeri, registrazione, interruzione, esito per la scheda e la voce.
- [x] `Sources/MacTalkAct/HeadWatcher.swift` -- profilo applicato al gate e al detector; arma del sì.
- [x] `Sources/MacTalkAct/Coordinator.swift` -- avvio e interruzione della guida («stop»); `handleHeadYes`: solo con una proposta «scrivilo» in attesa → come `.typeProposed`, serializzato in `routeChain`.
- [x] `Sources/MacTalkAct/Settings.swift`, `SettingsWindow.swift`, `AppDelegate.swift` -- `headProfile`, `headYesConfirms` (spento; azzerato se la verifica non passa); pulsanti «Calibra lo sguardo (5 s)» e «Calibrazione completa (circa 2 minuti)»; risultato e opzione del sì visibile solo con profilo verificato.
- [x] `README.md` -- calibrazione completa e sì facoltativo.
- [x] `Sources/MacTalkAct/DebugCLI.swift` -- selftest della matrice con corse sintetiche (cenni lenti, zigzag, falsi nelle fasi senza gesti).

**Acceptance Criteria:**
- Given una corsa sintetica con cenni lenti (sosta 0,6 s), when si sceglie il profilo, then i 5 sì sono riconosciuti e i falsi restano zero, mentre con le soglie di oggi no.
- Given `--selftest` e `--fallback-test`, when finiscono, then tutto ok.

## Implementation Notes

- 30/10: implementato direttamente nella sessione di pianificazione.
- La scelta guarda tutta la corsa per i falsi (fasi senza gesti e tipo sbagliato, verifica compresa) e le sole fasi di taratura per le risposte giuste; la verifica si conta con le soglie scelte. A parità vince la più severa (ampiezze maggiori, cenno e sosta più brevi). Griglia: 180 combinazioni, in un task staccato dal main actor.
- `HeadWatcher.beginRecording`/`endRecording` servono sia alla calibrazione rapida sia alla guidata; durante la registrazione i gesti armati sono spenti. Durante la guida il Coordinator ascolta solo «stop».
- Il «sì» si arma solo sulla proposta «scrivilo» con l'opzione attiva e il profilo verificato; scrive passando da `routeChain` come `.typeProposed`, dopo aver ricontrollato che la proposta sia ancora quella.
- Dopo la review: la scelta delle soglie usa solo la taratura e la verifica è contata a parte; nuovi esiti che non salvano (`falseInCheck`, `tooFewNo`, `roomUnclear`, `screenUnsteady`); il sì vale solo guardando lo schermo; nessuna arma e nessuno spegnimento durante la registrazione.
- Verifica: `--selftest` tutto ok (26 controlli nel blocco); `--fallback-test` ha 2 errori nel blocco della conferma per singola azione («l'orologio del turno è fermo», «nessun che tu non hai chiesto»), identici sulla baseline 1c5528e ricompilata: dipendono dall'app in primo piano (cmux, «solo clic», cmd+q rifiutato prima della domanda). Il resto è verde.

## Spec Change Log

## Review Triage Log

| # | Fonte | Rilievo | Verdetto | Evidenza | Esito |
|---|-------|---------|----------|----------|-------|
| 1 | blind | le fasi di verifica entravano nella scelta (zero falsi su tutto): «nessun falso» vero per costruzione, sì verificato ottimista | medium | `fit` filtrava i candidati su tutte le fasi | patch: scelta sulle sole fasi di taratura, verifica contata a parte; un falso in verifica non salva (`.falseInCheck`) |
| 2 | blind, edge | «non vedo il tuo volto» detto due volte | low | la guida lo diceva e il Coordinator ripeteva il messaggio | patch: lo dice solo il Coordinator |
| 3 | blind, verif., edge | una domanda armata durante la registrazione: i «no» della calibrazione la annullano | medium | `beginRecording` disarmava una volta sola | patch: `arm` non fa nulla mentre si registra |
| 4 | blind | un cenno fatto girato verso la stanza scrive la proposta | medium | il sì non guardava il cancello; dire «scrivilo» girato è già ignorato dal Router | patch: il sì vale solo con il cancello acceso |
| 5 | blind | nessun riscontro immediato al sì | low | la scrittura mostra già la pillola del testo inserito | scartato |
| 6 | blind, edge | il README diceva «nulla su disco tranne i due angoli» | low | contraddiceva la tabella privacy | patch |
| 7 | blind, edge | stanza non distinta dal limite, o schermo più mosso di 22°: profilo salvato con un cancello inutile o che scambia lo schermo per la stanza | medium | `limit` faceva solo clamp a [15, 25] | patch: `.roomUnclear` (stanza < limite + 5°) e `.screenUnsteady`; non si salva |
| 8 | blind | «Interrompi» durante il dialogo del permesso non ferma | low | raro: il permesso si concede all'attivazione dell'interruttore | scartato |
| 9 | blind, edge | «La fotocamera non funziona: calibrazione già in corso» | low | `.busy` trattato come guasto | patch: esito `.busy` con il suo messaggio |
| 10 | edge | una seconda corsa rifiutata spegneva la camera della prima | low | `applyHeadSettings` dopo il rifiuto | patch: il rifiuto esce subito |
| 11 | edge | cambiare modalità o l'interruttore durante la corsa spegne la camera a metà | medium | `stop()` immediato | patch: durante la registrazione lo spegnimento aspetta la fine |
| 12 | edge | interruttore dell'attenzione attivo durante la corsa | low | stessa causa del 11 | coperto dal 11 |
| 13 | blind, edge | profilo senza versione: un campo nuovo farebbe perdere il profilo salvato | low | oggi nessun campo cambia; conta solo a una modifica futura di `Config` | scartato (da ricordare se `Config` cambia) |
| 14 | blind | nessun modo di tornare alle soglie predefinite | low | una nuova calibrazione le sostituisce; non chiesto dall'intento | scartato |
| 15 | blind, edge | il selftest scrive nelle preferenze reali | low | stesso schema dei controlli già esistenti, ripristino subito dopo | scartato |
| 16 | verif. | il limite personale non è provato sul cancello dal vivo | medium | i test usavano sempre `.app` | patch: test a 20° con limite 15° e 25° |
| 17 | verif. | quale domanda arma il sì non è provato | medium | nessun controllo su `allowYes` per tipo di domanda | patch: `headArmsYes` e `headYesEnabled` puri + test |
| 18 | verif. | «solo stop durante la guida» non provato | low | logica dentro `handleUtterance` | patch: `stopsGuide` puro + test |
| 19 | edge | «stop» durante la scelta delle soglie salva lo stesso | medium | nessun controllo dopo il task staccato | patch: annullata dopo la scelta → `.cancelled` |
| 20 | edge | un profilo che non riconosce quasi nessun no sostituisce i valori di oggi | medium | nessuna soglia minima di riconoscimenti | patch: `.tooFewNo` se i no giusti non sono più della metà |
| 21 | verif., edge | al riavvio della camera resta il riferimento spostato | low | `clear()` non ricreava più il tracker | patch: `clearMarks` torna al riferimento calibrato |
| 22 | edge | un sì armato che scatta mentre si lavora consuma l'arma | low | proposta in attesa e lavoro in corso insieme è raro | scartato |
| 23 | edge | l'arma del sì resta dopo la risposta a voce | false | ogni nuova domanda riarma con il suo `allowYes`; senza domande il gesto non trova bersagli | scartato |
| 24 | edge | camera senza immagini in fase 1 detta «non vedo il volto» | low | messaggio deciso prima di leggere il guasto | patch |
| 25 | edge | la calibrazione rapida spegne l'arma di una domanda in attesa | low | calibrare con una domanda aperta è raro | scartato |

## Design Notes

- Limite del cancello: nello spike la stanza era a 30–40°; 0,6 × 40° = 24°. Una persona che si gira poco ottiene un limite più stretto, ma mai sotto 15° né sotto quello che serve allo schermo.
- Il sì si cerca solo con l'opzione attiva e una domanda che può confermare; la verifica usa le soglie scelte, sugli angoli nuovi, come in esercizio.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest` -- expected: Tutto ok
- `.build/debug/MacTalkAct --fallback-test` -- expected: Tutto ok

**Manual checks (if no CLI):**
- Con Nico al Mac: «Calibrazione completa», risultato detto e mostrato; con il sì verificato e l'opzione attiva, un sì con la testa su «scrivilo» scrive.
