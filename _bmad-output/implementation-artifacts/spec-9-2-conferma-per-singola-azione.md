---
title: 'Storia 9.2 — Conferma legata alla singola azione e un solo orologio del turno'
type: 'feature'
created: '2026-10-27'
status: 'done'
baseline_commit: '3bc7016b4796f560cbae4aa42eb1f39d72514822'
route: 'dispatch'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Il «sì» dato allo strumento `confirm` apriva una finestra di 45 s (`confirmValiditySeconds`) in cui qualunque azione rischiosa passava. Era il Motore a chiedere, con parole sue, e una seconda azione poteva sfruttare la conferma data alla prima. Il turno poi continuava a scorrere mentre l'app aspettava la risposta.

**Approach:** Un gate unico in `AgentTools` (`perform` e ogni passo di `act`) riconosce le Azioni con effetti esterni (pulsanti, azioni e voci di menu per etichetta, scorciatoie rischiose, Invio nelle chat, trascinamenti verso un bersaglio rischioso). La chiamata si ferma lì, chiede con un `ConfirmationTarget` tipizzato ed esegue solo con un «sì» valido per quella sola azione, senza passare di nuovo dal Motore. La domanda nomina il bersaglio e aggiunge «che tu non hai chiesto» quando la richiesta non lo nomina. Lo strumento `confirm` non dà più permessi e `confirmValiditySeconds` sparisce. Il `TurnClock` resta in pausa mentre una domanda aspetta. Ogni blocco va nel log in un formato fisso, che la Storia 9.4 riusa.

## Boundaries & Constraints

**Always:** il gate vale per ogni Motore (Claude, Codex, locale) perché tutti passano da `AgentTools.call`. Le azioni dell'utente (Comandi rapidi, Dettatura, numeri) non passano dal gate. Una domanda del Motore non produce mai un permesso.

**Never:** nessuna finestra di tempo; nessun interruttore che spenga il gate.

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/AgentTools.swift` -- `ConfirmationTarget`, `gate`, `logLine`, `requestMentions`, `isSendKey`, `composerApp`; i cinque punti rischiosi; `confirm` senza permessi; pausa dell'orologio anche per `ask_user`.
- `Sources/MacTalkAct/AgentEngine.swift` -- `TurnClock` con pausa, condiviso per riferimento, `untilExpired()`.
- `Sources/MacTalkAct/ClaudeCLI.swift`, `CodexCLI.swift`, `ClaudeEngine.swift`, `CodexEngine.swift` -- scadenza dal `TurnClock`.
- `Sources/MacTalkAct/AgentRunner.swift` -- `currentRequest`, `onQuestion` → pausa e ripresa, prompt.
- `Sources/MacTalkAct/LocalEngine.swift`, `Settings.swift`, `SettingsWindow.swift`, `README.md` -- testi e impostazione rimossa.

## Tasks & Acceptance

**Execution:**
- [x] gate, orologio, prompt, impostazione, test.

**Acceptance Criteria:**
- Given `--fallback-test`, when `press_keys cmd+q` riceve «no», then la scorciatoia non parte, la domanda nomina il bersaglio con «che tu non hai chiesto» e l'orologio si ferma.
- Given `--hands-test`, when l'Agente clicca Invia con la richiesta «invia il modulo» e la risposta «sì», then la domanda è una sola, senza «che tu non hai chiesto», e il modulo risulta inviato.
- Given il Banco, when confronto prima e dopo, then le conferme per compito con una sola Azione con effetti esterni non aumentano (SM-C5).

## Implementation Notes

- Spec approvata in autonomia (Nico: «committa e procedi»).
- **Scostamenti dalla storia, da confermare con Nico.**
  - `ActionOrigin` non è stato aggiunto a ogni chiamata dell'`Executor`. Il gate sta in `AgentTools`, unica porta dei Motori (AD-20). Le azioni dell'utente passano dall'`Executor` senza gate, come chiede la storia. La Corsia locale esegue azioni già filtrate da `LocalActionValidator`.
  - `PendingQuestion` e la decisione `.answer` del Router non sono state introdotte. Il percorso attuale delle risposte già fa quello che chiede la storia: «sì» conferma, qualunque altra frase rifiuta, e una domanda nuova sostituisce la precedente. Rifarlo nel Router era un rischio troppo alto in autonomia.
- Il riconoscimento per costruzione copre le scorciatoie rischiose, l'Invio nelle app di chat (Messaggi, WhatsApp, Slack, Telegram, Discord, Teams, Signal) e i trascinamenti verso un bersaglio con etichetta rischiosa. Il riconoscimento per etichetta copre pulsanti, azioni di accessibilità e voci di menu (`Safety.isRiskyLabel`).
- Banco (3 compiti): conferme per compito 0/1/1 prima e dopo; `posta-elimina` da 3 a 2 passi e da 12,2 a 7,1 s, perché non serve più il giro `confirm` del modello.
- Corretto anche un blocco di Codex: alla scadenza ora chiude il processo, prima il lettore poteva restare appeso.

## Spec Change Log

## Review Triage Log

Prima review (3 revisori). Nessun rilievo di intento o di spec; patch salvo tre rinvii.

| Rilievo | Verdetto | Evidenza / esito |
|---|---|---|
| Clic e trascinamenti per coordinate x/y saltano il gate | high | L'etichetta era «x,y». Patch: `AX.labelAt` legge l'elemento sotto il punto (e i suoi antenati); il gate lo giudica |
| Un «sì» usato su un'altra app se l'utente cambia finestra durante la domanda | high | Patch: l'app in primo piano deve essere la stessa prima e dopo la domanda |
| Invio in una sequenza («tab return»), a fine testo in `type_text`, nelle chat web | medium | Patch: `containsSendKey`, gate su `type_text` con a capo, `needsComposerGate` per app e pagine di chat |
| Domande sovrapposte: la prima che finisce fa ripartire l'orologio | medium | Patch: profondità di pausa nel `TurnClock` |
| Timer di una domanda vecchia che risponde «nessuna risposta» a quella nuova | medium | Patch: ogni timer risolve solo la sua domanda; la domanda sostituita va nel log |
| Dopo un «no» il Livello istantaneo scala e il rapido chiede di nuovo | medium | Patch: `deniedThisRequest` ferma ogni scalata |
| Motore locale con un tempo fisso che non conosce la pausa | medium | Patch: `untilExpired()` anche lì |
| Schema di `confirm` ancora «REQUIRED»; giro morto in `LocalStepAgent`; `confirm` tra gli strumenti del modello locale | medium | Patch: descrizione aggiornata, giro tolto, strumento tolto dal locale; `confirmFirst` eliminato |
| Log senza dettaglio con titolo della finestra, percorso del menu ed etichetta del bersaglio | medium | Patch: senza dettaglio si registra solo il tipo di bersaglio |
| `requestMentions`: bersagli corti, «post» dentro «posta», negazione, radici | low | Patch: parole intere, bersagli corti come parola, negazione = non chiesta, radice di almeno 5 lettere; testato |
| Menu con l'id sentinella −1; virgolette doppie nella domanda | low | Patch: `case menu(path:)`; il verbo porta la sorgente, l'etichetta resta semplice |
| `onQuestion(false)` senza `defer` | low | Patch |
| `confirmValiditySeconds` rimasto nelle preferenze | low | Patch: rimosso al caricamento |
| Test: un «sì» per una sola azione, `untilExpired` in pausa, ripresa, collegamento dell'`AgentRunner`, gate su azione, Cestino ed Elimina con «no» | gap | Patch: tutti in `--selftest`, `--fallback-test`, `--hands-test` (Cestino aggiunto a `kanban.html`) |
| Timeout di Codex senza test | gap | Rinviato: serve un `codex` finto come `finto-claude` |
| Gate dell'Invio senza controllo del campo a fuoco | low | Rinviato: oggi chiede per ogni Invio in una chat, anche nella ricerca: prudente |
| Sinonimi e altre lingue in `requestMentions` | low | Rinviato: aggiunge solo «che tu non hai chiesto» in più, la direzione prudente |
| Parametro `timeout` ancora presente accanto a `clock` | low | Respinto: serve ai chiamanti senza turno (prove e pianificatore); con `clock` non conta |
