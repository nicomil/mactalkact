---
title: 'Cancello dell''attenzione dalla webcam e «no» con la testa'
type: 'feature'
created: '2026-10-30'
status: 'done'
baseline_commit: '80d367614b628d2338d4e60c6f01341ea4846f2f'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/planning-artifacts/research/technical-agente-precisione-velocita-e-strumenti-2026-10-27/research.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** In ascolto continuo (sessione a mani libere e Finestra di conversazione) la Chiacchiera con chi è nella stanza è il rischio principale. Lo spike del 29/10 (§40) mostra che «girato verso la stanza» si riconosce in modo solido dalla webcam (±25° su yaw e pitch) e che il «no» con la testa è affidabile (5/5, nessun falso); il «sì» no (3/5).

**Approach:** Impostazione facoltativa, spenta di serie, «Attenzione dalla fotocamera». Con l'impostazione attiva e l'ascolto continuo acceso, la camera misura gli angoli della testa. Una Frase detta mentre Nico è girato verso la stanza, senza Parola di attivazione né push-to-talk, è Chiacchiera; altrimenti il Router decide come oggi. Un «no» con la testa annulla la domanda in attesa. Approvato da Nico il 30/10/2026.

## Boundaries & Constraints

**Always:** tutto sul Mac; si tengono solo angoli e tempi, mai immagini; camera accesa solo con impostazione attiva **e** ascolto continuo acceso (modalità «parola di attivazione» o sessione), spenta appena una delle due cade; permesso Fotocamera chiesto solo quando Nico attiva l'impostazione; limiti ±25° su yaw e pitch, tenuta 300 ms; ogni guasto (permesso negato, nessuna camera, nessun fotogramma, nessun riferimento) lascia il comportamento di oggi, mai un comando ignorato per errore; la Parola di attivazione e il push-to-talk passano sempre; logica di giudizio pura e provata in `--selftest`.

**Never:** nessun «sì» con la testa (non conferma né scrive nulla); nessun modello di terze parti né rete; non toccare `--gesture-spike` se non per riusarne il codice.

**Decisioni di Nico (30/10):**
- *Riferimento «guardo lo schermo»: guidato + adattamento lento.* Pulsante «Calibra» nelle Impostazioni: 5 s guardando lo schermo, riferimento salvato nelle impostazioni (solo yaw e pitch). Poi il riferimento segue lentamente i campioni che cadono dentro i limiti. Senza calibrazione fatta il cancello è ignoto: comportamento di oggi.
- *Il «no» con la testa annulla tutte le domande in attesa:* proposta «scrivilo» (`proposedText`), conferma del piano (`pending`) e domande di conferma di Agente e Corsia locale (`askByVoice` con `confirmation: true`, risposta nil). Le domande dell'Agente che non sono conferme non si annullano con la testa.
- *Spec tenuta intera* (~2.200 token, sopra il tetto di 1.600): il «no» dipende dalla camera del cancello.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Girato verso la stanza | sessione, Frase senza «computer», gate «altrove» per la maggior parte della Frase | `.ignore` «girato verso la stanza» | — |
| Guarda lo schermo | idem, gate «schermo» | decisione di oggi | — |
| Parola di attivazione | girato, «computer, apri Safari» | decisione di oggi | — |
| Push-to-talk | girato, tasto premuto | decisione di oggi | — |
| Volto assente | nessun volto nella Frase | decisione di oggi (ignoto, non «altrove») | — |
| Guasto camera | permesso negato o zero fotogrammi | decisione di oggi; avviso una volta nell'HUD | impostazione resta attiva, riprova al prossimo avvio dell'ascolto |
| «Sì» girato | conferma in attesa, «sì» detto alla stanza | `.ignore`, la conferma resta in attesa | scade come oggi |
| «No» con la testa | domanda in attesa, camera attiva | domanda annullata, HUD «Annullato» | — |
| Cenno di «sì» | domanda in attesa | nulla | — |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/HeadGestures.swift` -- riusare `HeadSample`, `HeadPose`, `HeadCalibration`, `AttentionGate` (Config ±25°), `HeadGestureDetector` (solo `.no`). Aggiungere qui il giudizio puro della Frase.
- `Sources/MacTalkAct/GestureSpike.swift:17-60` e `GestureRecorder` -- avvio della camera (VGA, 15 fps, `VNDetectFaceRectanglesRequest` rev. 3, volto più grande): estrarre in un servizio condiviso, lo spike lo riusa.
- `Sources/MacTalkAct/IntentRouter.swift:3` `RouterState` -- campo nuovo `facingAway: Bool`; `decide`: subito dopo l'estrazione della Parola di attivazione, prima dei numeri (passo 1) e delle risposte (passo 3): se `facingAway && wakeRest == nil && !pushToTalk && !armed` → `.ignore`.
- `Sources/MacTalkAct/Coordinator.swift` -- `setMode` `:364` avvia/ferma l'osservatore; `engine.onSpeechStart` `:71` segna l'inizio Frase; `routerState` `:184` riempie `facingAway`; `handleUtterance` `:489` ramo `busy`/`agentQuestion`: stesso gate per le risposte all'Agente; `perform` `.confirmation` `:651` e `.askToType` `:673` sono gli stati che il «no» annulla; `answerAgent(nil)` annulla una domanda dell'Agente.
- `Sources/MacTalkAct/Settings.swift`, `SettingsWindow.swift` `ListeningSection` `:223` -- interruttore, pulsante «Calibra», riferimento salvato.
- `Resources/Info.plist:28` -- `NSCameraUsageDescription` oggi parla solo della prova di sviluppo.
- `Sources/MacTalkAct/DebugCLI.swift` -- blocco selftest «Spike gesti» da affiancare con «Attenzione».
- `README.md` -- sezione impostazioni.

## Tasks & Acceptance

**Execution:**
- [x] `Sources/MacTalkAct/HeadGestures.swift` -- `PhraseAttention.judge(samples, from:to:, reference:)` → `.screen`/`.away`/`.unknown`: «altrove» solo se più di metà dei campioni con volto della Frase è fuori dai limiti e i volti coprono almeno metà della Frase; altrimenti ignoto o schermo. `ReferenceTracker`: parte dal riferimento calibrato e lo sposta lentamente (costante di tempo ~2 min) solo con campioni dentro i limiti -- logica pura.
- [x] `Sources/MacTalkAct/HeadWatcher.swift` (nuovo) -- camera + Vision + gate + detector `.no` + buffer degli ultimi 30 s di campioni; `start()`/`stop()`, `calibrate() async -> HeadPose?` (5 s), `attention(from:to:)`, callback `onNo`; stato di guasto -- condiviso con lo spike.
- [x] `Sources/MacTalkAct/GestureSpike.swift` -- usare l'avvio camera di `HeadWatcher` senza cambiare il report.
- [x] `Sources/MacTalkAct/IntentRouter.swift` -- `facingAway` e regola sopra.
- [x] `Sources/MacTalkAct/Coordinator.swift` -- ciclo di vita della camera, `facingAway` per Frase, gate sul ramo `agentQuestion`, «no» → annulla secondo Q2 con `Sound.cancel()` e «Annullato».
- [x] `Sources/MacTalkAct/Settings.swift`, `SettingsWindow.swift` -- `headAttention` (falso di serie), riferimento calibrato (yaw, pitch, data), pulsante «Calibra» con istruzione a voce, richiesta del permesso all'attivazione, stato «camera attiva / permesso mancante / da calibrare».
- [x] `Resources/Info.plist`, `README.md` -- testo d'uso della camera per la funzione vera; riga nelle impostazioni.
- [x] `Sources/MacTalkAct/DebugCLI.swift` -- selftest della matrice (giudizio della Frase, regola del Router con e senza Parola di attivazione/push-to-talk, volto assente = ignoto, «sì» girato ignorato, senza calibrazione = ignoto, adattamento che non segue i campioni fuori dai limiti).

**Acceptance Criteria:**
- Given impostazione spenta, when l'ascolto continuo parte, then la camera non si accende e il Corpus dà gli stessi esiti di oggi.
- Given impostazione attiva, when l'ascolto continuo si spegne o l'impostazione si disattiva, then la camera si spegne entro 1 s.
- Given `--selftest`, when finisce, then i blocchi «Spike gesti» e «Attenzione» sono verdi.

## Implementation Notes

- 30/10: implementato direttamente dalla sessione di pianificazione (contesto già caricato), non da un subagente.
- La logica viva del sink è la struct pura `HeadLiveState` (riferimento, cancello, ultimi 30 s, «no» armato una volta), così il «no» si prova in `--selftest` senza camera. La scelta di cosa annullare è `Coordinator.headNoTarget` (pura).
- Il cancello è alimentato solo dai fotogrammi con volto e parte acceso (`startOn`): il volto assente lo giudica `PhraseAttention`, non il cancello.
- `startRunning`/`stopRunning` girano sulla coda della camera, non sul main actor. Nessun fotogramma in 3 s → stato «la fotocamera non dà immagini», avviso nell'HUD una volta, poi come senza.
- La regola nel Router sta dopo la Parola di attivazione e prima delle risposte (passo 3); il passo 1 (numeri sullo schermo) resta prima. Stessa regola nel ramo delle domande dell'Agente in `handleUtterance` («stop» resta prima e funziona sempre).
- Verifica: `--selftest` tutto ok (27 controlli nuovi nel blocco «Attenzione dalla fotocamera», lo spike resta verde); `--fallback-test` tutto ok (144); `--route-test --rules` identico alla baseline (il «FALLITO» senza modello Apple c'era già).
- Resta con Nico al Mac: calibrazione, frase girato verso la stanza in mani libere, «no» con la testa su «scrivilo», LED spento a sessione chiusa.

## Spec Change Log

- 30/10, review 1. *Rilievo:* il Code Map faceva passare i numeri sullo schermo prima del cancello e non esentava la Frase dopo «computer» da solo (`armed`), contro l'intento congelato («senza Parola di attivazione né push-to-talk è Chiacchiera»; «la Parola di attivazione passa sempre»). *Modifica:* riga del Router nel Code Map: cancello prima dei numeri, `armed` esente. *Stato evitato:* un «7» detto alla stanza che clicca; una richiesta dopo «computer» ignorata. *Applicato come patch* (due righe nel Router più test) invece di rifare il codice da zero: il resto dell'implementazione non dipendeva da quella riga. *KEEP:* `HeadLiveState` e `headNoTarget` puri; regola nel Router prima di ogni altra decisione; volto assente = ignoto.

## Review Triage Log

| # | Fonte | Rilievo | Verdetto | Evidenza | Esito |
|---|-------|---------|----------|----------|-------|
| 1 | blind, edge, verif. | Frase dopo «computer» da solo ignorata se girato (`armed` non esente) | medium | `decide` controllava solo `wakeRest` e `pushToTalk`; `handleLive` mostra «Dimmi pure…» e poi il Router scartava | patch: `&& !state.armed` + test |
| 2 | blind, edge, verif. | numeri sullo schermo prima del cancello: un «7» detto alla stanza clicca | medium | passo 1 prima del cancello; intento congelato: senza Parola di attivazione è Chiacchiera | patch (Code Map corretto, vedi Spec Change Log) + 2 test |
| 3 | blind, edge | finestra della Frase chiusa a consegna del testo: comprende silenzio finale e riconoscimento | medium | `end = hostNow()` in `handleUtterance`, dopo `vadEndSilence` e `finish()` | patch: `SpeechEngine.onSpeechEnd`, fine = chiusura VAD − silenzio finale |
| 4 | edge | inizio Frase unico condiviso: con frasi ravvicinate una frase usa la finestra dell'altra | medium | `phraseStartHost` sovrascritto da `onSpeechStart` prima che `finish()` consegni la precedente | patch: giudizio a chiusura VAD, coda in ordine |
| 5 | verif. | nessun test sul passaggio di `facingAway` dal Coordinator al Router e al ramo domande dell'agente | medium | parametri con `= false`; ramo `busy` non provato | patch: default tolti (lo controlla il compilatore), `Coordinator.ignoredAgentAnswer` puro + 3 test |
| 6 | verif. | «spenta di serie» non nel controllo dei predefiniti | low | `Df.headAttention` assente nel check | patch: `&& !Df.headAttention` |
| 7 | blind, edge | calibrazione senza immagini: messaggio «volto non visto» e avviso HUD a metà | medium | watchdog → `.noFrames`, poi `stop()` → `.off` prima della lettura | patch: `calibrate()` restituisce l'esito; watchdog muto in calibrazione |
| 8 | blind, edge | dopo `.noFrames` lo stato non torna attivo se arrivano fotogrammi | low | `start()` usciva con `running != nil`; `attention()` richiedeva `.active` | patch: `attention()` su `running` (i fotogrammi decidono), `start()` ripristina `.active` |
| 9 | edge | prima attivazione: il debounce avvia la camera con il dialogo del permesso ancora aperto | medium | stato `.denied` e avviso, camera spenta fino al cambio successivo | patch: «non ancora chiesto» non è un guasto; `applyHead` dopo la risposta al dialogo |
| 10 | blind | avviso di guasto ripetuto a ogni riavvio dell'ascolto | low | `stop()` rimette `.off`, poi di nuovo `.denied` | patch: ultimo guasto ricordato fino a camera attiva |
| 11 | blind, edge | stato nelle Impostazioni fermo (onAppear, attesa fissa) | low | watchdog a 3 s e cambi di modalità non visibili | patch: aggiornamento ogni secondo |
| 12 | blind, verif. | `disarmNo()` mai chiamato | low | il «no» armato dopo la risposta non trova bersagli (`headNoTarget` = nil): nessun effetto, API morta | patch: API rimossa |
| 13 | edge | data della calibrazione non salvata (task: «yaw, pitch, data») | low | solo `[yaw, pitch]` | patch: `headCalibratedAt`, mostrata nella scheda |
| 14 | edge | «non si apre» etichettato come «non dà immagini» | low | catch generico in `openCamera` | patch: etichetta «(occupata o staccata)» |
| 15 | blind | di profilo il volto si perde: «ignoto» invece di «altrove» | false | scelta dell'intento congelato (riga «Volto assente» della matrice); nello spike la stanza a 40° aveva il volto nel 75–100% dei fotogrammi | scartato |
| 16 | blind | camera accesa anche in «parola di attivazione» a finestra chiusa; modalità privata non la spegne | false | l'intento congelato la vuole accesa con ascolto continuo («parola di attivazione» o sessione); la camera resta sul Mac | scartato |
| 17 | edge | il giudizio usa lo stato del cancello (tenuta 300 ms), non i campioni grezzi | low | la tenuta di 300 ms è un vincolo congelato; conta solo quando ci si gira proprio all'inizio della Frase | scartato |
| 18 | edge | fotogrammi in volo della sessione precedente dopo `stop()` | low | raro; servirebbe una generazione di sessione | scartato (improbabile, stato in più) |
| 19 | edge | due calibrazioni insieme se la vista si ricostruisce | low | pulsante disabilitato durante la calibrazione | patch minima: `calibrate()` rifiuta la seconda (`.busy`) |
| 20 | blind | CHANGELOG senza voce; pannello Permessi senza Fotocamera; tabella privacy del README | low | CHANGELOG si scrive al rilascio (commit di versione); lo stato del permesso è nella scheda | patch: righe nella tabella privacy del README; resto scartato |
| 21 | blind | nessun recupero se la camera si stacca dopo i primi 3 s | low | senza fotogrammi nuovi `PhraseAttention` dà «ignoto» (< 3 fotogrammi): comportamento di oggi | scartato |

## Design Notes

- Il giudizio usa l'intervallo [inizio Frase − 0,3 s, fine Frase], non l'istante della decisione: chi parla con la stanza spesso si rigira a fine Frase.
- Volto assente = ignoto (non «altrove» come nello spike): luce scarsa o Nico in piedi non devono far ignorare comandi.
- Il «no» si cerca solo mentre una domanda è in attesa; il detector si azzera all'apertura della domanda.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest` -- expected: Tutto ok

**Manual checks (if no CLI):**
- Con Nico al Mac: sessione a mani libere, frase girato verso la stanza → ignorata; «no» con la testa su «scrivilo» → annullato; LED spento a sessione chiusa.
