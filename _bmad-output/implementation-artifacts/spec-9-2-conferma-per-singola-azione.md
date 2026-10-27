---
title: 'Storia 9.2 — Conferma legata alla singola azione e un solo orologio del turno'
type: 'feature'
created: '2026-10-27'
status: 'in-review'
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
