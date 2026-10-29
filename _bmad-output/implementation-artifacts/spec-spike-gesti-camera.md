---
title: 'Spike: attenzione e sì/no con la testa dalla webcam'
type: 'chore'
created: '2026-10-29'
status: 'done'
baseline_commit: 'c1920be1be27e9914d100c1d6feec86a5f73aeb1'
route: 'dispatch'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** In ascolto continuo la Chiacchiera con chi è nella stanza resta il rischio principale, e quando l'app è in dubbio serve dire «scrivilo». Due segnali della webcam potrebbero aiutare: dove guarda Nico (cancello dell'attenzione) e il sì/no fatto con la testa. Prima di progettarli serve sapere, sui numeri, se Vision sulla webcam di Nico è abbastanza preciso, rapido e leggero.

**Approach:** Un comando di sviluppo `--gesture-spike [--fps N] [--secondi-fase K]` guida Nico, a voce e nel terminale, in un protocollo a fasi (calibrazione, lettura guardando lo schermo, sguardo verso la stanza, ritorno, 5 sì, 5 no, sguardo in basso). Per ogni fotogramma registra solo angoli della testa e tempi, poi produce un report con precisione dell'attenzione per fase, sì/no riconosciuti e falsi, latenza di Vision e CPU. Il report va in `~/Library/Logs` e diventa il §40 della ricerca con una raccomandazione; la decisione su un'eventuale funzione resta a Nico.

## Boundaries & Constraints

**Always:** tutto sul Mac; nessuna immagine salvata, inviata o mostrata: si conservano solo angoli (yaw, pitch, roll), dimensione del volto e tempi; la camera è accesa solo durante il comando e spenta a fine corsa o in caso di errore; il permesso Fotocamera si chiede solo con Nico presente; la logica di riconoscimento (calibrazione, cancello, sì/no) è codice puro, provato in `--selftest` senza camera.

**Never:** nessuna integrazione nel Router, nel Coordinator o nelle impostazioni; nessun mouse o tastiera simulati; nessuna rete; nessun modello di terze parti (solo Vision e AVFoundation).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Corsa completa | permesso dato, volto visibile | report con le 7 fasi, tabelle e TSV degli angoli | — |
| Permesso negato o limitato | Fotocamera negata | messaggio con il percorso in Impostazioni e uscita senza report | uscita con codice 1 |
| Nessuna camera | nessun dispositivo video | «nessuna fotocamera trovata» | uscita con codice 1 |
| Volto assente | Nico fuori inquadratura | fotogrammi contati come «volto assente», attenzione = spenta | calibrazione senza volto: fase ripetuta una volta, poi uscita |
| Tremolio | angoli che oscillano ±2° | nessun sì/no, attenzione stabile | — |
| Girarsi e restare girati | yaw che cambia di 40° e resta | attenzione spenta, nessun «no» | — |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/MailSearchSpike.swift` -- modello di spike: enum `@MainActor`, `run()`, `report() -> [String]` puro, file `~/Library/Logs/MacTalkAct-<nome>-yyyy-MM-dd-HHmm.txt`.
- `Sources/MacTalkAct/main.swift:137` -- registrazione dei comandi spike (`MainActor.assumeIsolated { _ = NSApplication.shared }`, `Task`, `dispatchMain()`); `argument(after:)` per le opzioni.
- `Sources/MacTalkAct/TestKillSwitch.swift` -- NON aggiungere il comando a `screenFlags`: non guida schermo né tastiera.
- `Sources/MacTalkAct/Speaker.swift` -- `Speaker().say(_:)` per i comandi a voce delle fasi (Nico non legge il terminale mentre guarda altrove).
- `Sources/MacTalkAct/DebugCLI.swift:382` -- selftest degli spike: aggiungere qui il blocco «Spike gesti».
- `Resources/Info.plist` -- manca `NSCameraUsageDescription`.
- `README.md:362` -- elenco dei comandi di sviluppo.
- ricerca `technical-agente-precisione-velocita-e-strumenti-2026-10-27/research.md` -- ultimo paragrafo §39; il nuovo è §40.

## Tasks & Acceptance

**Execution:**
- [x] `Sources/MacTalkAct/HeadGestures.swift` (nuovo) -- tipi puri: `HeadSample`, calibrazione (mediana), `AttentionGate` con isteresi, `HeadGestureDetector` per sì/no, metriche e report -- testabile senza camera.
- [x] `Sources/MacTalkAct/GestureSpike.swift` (nuovo) -- camera (AVFoundation), Vision per fotogramma, fasi guidate, CPU, report e TSV -- la corsa con Nico.
- [x] `Sources/MacTalkAct/main.swift` -- comando `--gesture-spike` con `--fps` (predefinito 15) e `--secondi-fase`.
- [x] `Sources/MacTalkAct/DebugCLI.swift` -- selftest delle funzioni pure (casi della matrice).
- [x] `Resources/Info.plist`, `README.md` -- descrizione d'uso della camera («prova di sviluppo») e riga del comando.
- [ ] ricerca -- §40 con tabelle e raccomandazione, dopo la corsa con Nico.

**Acceptance Criteria:**
- Given `--selftest`, when finisce, then il blocco «Spike gesti» è verde: un sì sintetico dà 1 sì e 0 no, un no dà 1 no e 0 sì, tremolio e girarsi-e-restare non danno gesti, il cancello si spegne solo dopo il tempo di tenuta.
- Given `--gesture-spike` con Nico presente, when finisce, then il report ha per fase la percentuale di fotogrammi con attenzione corretta, sì/no attesi e trovati con i falsi, latenza di Vision (mediana e 95° percentile), latenza camera→decisione, fps reali e CPU media, più una griglia di soglie rivalutate sugli stessi angoli; la camera è spenta.

## Design Notes

- Angoli da `VNDetectFaceRectanglesRequest` revisione 3 (yaw, pitch, roll): più leggera dei punti del volto, basta per testa e sguardo grossolano. Si tiene il volto più grande.
- Calibrazione: la camera sta sopra lo schermo, quindi «guardare lo schermo» non è yaw = pitch = 0. Mediana dei primi 5 s = posizione di riferimento; il cancello lavora sullo scarto (predefinito ±15° yaw, ±15° pitch, tenuta 300 ms).
- Sì/no a zigzag: un'oscillazione conta quando l'angolo inverte direzione dopo aver percorso almeno A gradi (predefinito 8° pitch, 10° yaw) in non più di 600 ms. Sì = 2 oscillazioni di pitch nell'arco di 1,5 s con yaw quasi fermo; no = 2 di yaw con pitch quasi fermo; poi 1 s di pausa. Girarsi e tornare lentamente non fa un «no» perché ogni oscillazione deve essere rapida.
- Il riconoscimento gira dal vivo (per la latenza) e, a fine corsa, di nuovo sugli angoli registrati con A ∈ {6, 8, 10, 12} e oscillazioni ∈ {2, 3}: la griglia dice quale soglia sceglierebbe Nico senza rifare la corsa.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest` -- expected: Tutto ok, blocco «Spike gesti» verde

**Manual checks (if no CLI):**
- Solo con Nico presente: `.build/debug/MacTalkAct --gesture-spike` -- report e TSV in `~/Library/Logs`, LED della camera spento a fine corsa.

## Implementation Notes

- Oscillazione: un'inversione è confermata solo quando l'angolo torna indietro di almeno max(5°, A/2) dall'estremo, così il tremolio di ±2° non inverte nulla. La durata del tratto parte dall'ultimo istante in cui l'angolo era ancora vicino al punto di partenza (stare fermi prima di muoversi non allunga il tratto).
- Finestra di 1,5 s contata da adesso, non dall'ultima oscillazione: un'oscillazione viene confermata solo all'inversione successiva, che può arrivare secondi dopo (due occhiate rapide distanti 2 s davano un «no» falso).
- «Quasi fermo»: l'altro asse si muove meno della metà dell'asse del gesto nello stesso arco di tempo.
- Un'occhiata rapida di lato e ritorno dà al massimo un'oscillazione (il ritorno non si inverte), quindi nessun «no».
- Attenzione per fase giudicata dopo 1 s dall'inizio della fase (Nico si sta ancora girando). Il volto assente conta come «non guarda», con la stessa tenuta.
- Fasi sì/no: l'app dice i numeri da 1 a 5, uno ogni 3 s; la CPU di queste fasi include la voce ed è esclusa dalla media.
- Report: anche lo scarto mediano yaw/pitch per fase, la risoluzione degli angoli (per accorgersi se Vision li quantizza) e la griglia del cancello a ±10/15/20/25°.
- Il §40 della ricerca resta da scrivere dopo la corsa con Nico.
- Verifica della matrice: le righe «tremolio», «girarsi e restare girati» e «volto assente» (cancello e calibrazione) sono coperte dal selftest; «permesso negato», «nessuna camera», la ripetizione della calibrazione e la «corsa completa» dipendono dalla camera vera e si verificano solo nella corsa con Nico.
- 29/10: codice chiuso dopo la review (24 controlli verdi). Restano con Nico al Mac: la corsa `--gesture-spike` e il §40 della ricerca.

## Spec Change Log

## Review Triage Log

| # | Fonte | Rilievo | Verdetto | Evidenza | Esito |
|---|-------|---------|----------|----------|-------|
| 1 | edge | `--secondi-fase nan` fa crashare `Task.sleep` | low | `Double("nan")` passa e `min/max` restituiscono NaN; serve digitarlo a mano | scartato (improbabile, guardia in più) |
| 2 | edge, blind | con `--fps` sotto 5 la calibrazione fallisce sempre (servono 10 volti in 5 s) e i sì/no sono impossibili (tratto ≤ 600 ms) | medium | `minFaces: 10` fisso, clamp di `--fps` a 1 | patch: minimo 5 fps |
| 3 | edge, blind | fotocamera senza fotogrammi (occupata, staccata) riportata come «nessun volto» | medium | il messaggio di calibrazione non distingue zero fotogrammi da zero volti | patch |
| 4 | edge | `synchronizationClock` nil lascia i tempi nell'orologio della camera | maybe-false | da vedere se è nil prima di `startRunning`; si vede nella corsa (fps reali 0) | rimandato |
| 5 | edge, blind | errori di Vision contati come volto assente | low | `try?` sul `perform`; la revisione 3 è supportata su macOS 27 | scartato (improbabile, contatore in più) |
| 6 | edge | fotogramma letto in una fase e aggiunto dopo il cambio di fase | low | fase letta e `append` in due sezioni del lock distinte | patch (append condizionato, correzione diretta) |
| 7 | edge | la tenuta del cancello attraversa i buchi tra le fasi | low | il primo secondo di ogni fase è escluso dal giudizio | scartato (effetto assorbito dalla tolleranza, stato in più) |
| 8 | edge | risoluzione letta da `activeFormat`, non dai fotogrammi elaborati | low | con il preset VGA il buffer può essere ridimensionato | patch |
| 9 | edge, blind | scrittura del report silenziosa; due corse nello stesso minuto si sovrascrivono | low | `try?` sul `write`, nome al minuto | patch |
| 10 | verif. | il controllo «quasi fermo» non è provato: un zigzag diagonale potrebbe dare un sì | medium | mutazione di `quiet` non cambia nessun esito del selftest | patch: test |
| 11 | verif., blind | pausa dopo il gesto e finestra di 1,5 s non provate | medium | mutazioni `pause = 0` e `window = 1000` non rilevate | patch: test |
| 12 | verif., blind | righe per fase, fps reali e CPU media del report non verificate; volto perso nel zigzag e `resolutionLine` non provati | medium | il selftest controlla tre sottostringhe sole | patch: test |
| 13 | blind | camera avviata e fermata sul main actor, fps impostati a sessione avviata | false | comando di sviluppo da terminale: bloccare il main actor durante l'avvio non ha effetti; il cambio di fps a sessione avviata è permesso con `lockForConfiguration` e gli fps reali sono nel report | scartato |
| 14 | blind | la dispersione della calibrazione non è mostrata | medium | se Nico si muove nei 5 s, il riferimento si sposta e nulla lo segnala | patch: deviazione assoluta mediana accanto al riferimento |
| 15 | blind | i tempi dei numeri detti non sono registrati, quindi due gesti su un solo numero contano 2/5 | low | conteggio solo per fase; il TSV ha i tempi dei gesti | scartato (fuori dagli AC, struttura in più) |
| 16 | blind | la CPU esclude Neural Engine e GPU; memoria non misurata | low | `getrusage` conta solo la CPU | patch: nota nel report (solo testo) |
| 17 | blind | frasi a voce con numeri scritti a mano | low | «cinque secondi», «Cinque volte» duplicano le costanti | patch |
| 18 | blind | volume della voce delle impostazioni, può essere 0,1 | low | predefinito 0,45; le istruzioni sono anche stampate | scartato (si avvisa Nico prima della corsa) |
| 19 | blind | rivelatore dal vivo non azzerato al nuovo tentativo di calibrazione | low | il tentativo fallisce solo con meno di 10 volti, e il volto assente azzera già il zigzag | scartato |
| 20 | blind | README non dice che il permesso va al terminale | low | binario senza bundle | patch: README |
| 21 | blind | stringa della camera nel plist dell'app distribuita | low | la stringa compare solo se la camera viene chiesta, e l'app non la chiede | scartato |
| 22 | blind | force unwrap di `yesPhase!`/`noPhase!` | false | `yes` non nil implica `yesPhase` non nil | scartato |
| 23 | blind | stampe dalla coda della camera mescolate a quelle del main actor | low | solo estetica del terminale | scartato |
