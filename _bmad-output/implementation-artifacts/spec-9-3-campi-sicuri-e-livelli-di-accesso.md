---
title: 'Storia 9.3 — Campi sicuri e livelli di accesso per app'
type: 'feature'
created: '2026-10-28'
status: 'done'
baseline_commit: '4d6ddbf4acb3126bae1d5a6ffc8505acc1d3acc8'
route: 'dispatch'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** L'Agente poteva scrivere in un campo password, e un campo di cui non si legge il sottoruolo veniva trattato come normale. Terminal, Finder e Impostazioni di Sistema avevano le stesse regole di qualunque app, quindi un'istruzione nascosta su uno schermo poteva far scrivere comandi in Terminal, e il contenuto del terminale andava ai Motori cloud.

**Approach:** `PrivacyGuard.accessLevel()` su due assi: `cloudAllowed` (app e siti riservati, modalità privata, come oggi) e un livello per app preso da un elenco modificabile. Livelli: «solo clic» (Terminal, iTerm: si clicca e si scorre; ai Motori cloud solo i controlli, mai testo, valori o immagini), «conferma ogni azione» (Impostazioni di Sistema), «normale» (Finder e le altre: il gate della Storia 9.2). Campi password: `type_text` e `get_text` rifiutano; un campo a riga singola senza sottoruolo leggibile conta come password; il giornale degli inserimenti non registra ciò che si scrive in una password. Quando l'inserimento sicuro di macOS blocca la dettatura, l'HUD dice quale app lo ha attivato.

## Boundaries & Constraints

**Always:** vale per ogni Motore (passano da `AgentTools`); la dettatura non è toccata; l'HUD mostra il livello in vigore; gli elenchi sono modificabili, la regola dei campi password no.

**Never:** nessun valore né lunghezza di un campo password, in nessun percorso.

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/Privacy.swift` -- `AccessLevel`, `PrivacyGuard.accessLevel()`, `SecureInput`.
- `Sources/MacTalkAct/AgentTools.swift` -- livelli in `perform`, `controlsOnly`, osservazione ridotta ai Motori cloud, `type_text` nei campi password.
- `Sources/MacTalkAct/Accessibility.swift` -- `AX.isSecureField` (sottoruolo, o campo a riga singola non leggibile).
- `Sources/MacTalkAct/Conversation.swift` -- il giornale salta i campi password.
- `Sources/MacTalkAct/Coordinator.swift`, `AgentRunner.swift`, `Settings.swift`, `SettingsWindow.swift` -- avviso dell'inserimento sicuro, livello nell'HUD, elenco.
- `Tests/bench/pages/password.html`, `Sources/MacTalkAct/DebugCLI.swift` -- prove.

## Tasks & Acceptance

**Execution:**
- [x] livelli, campi password, giornale, avvisi, impostazioni, prove.

**Acceptance Criteria:**
- Given `password.html`, when l'Agente osserva e scrive, then `observe` non mostra valore né lunghezza e `type_text` rifiuta, mentre nessun campo delle altre pagine del Banco risulta password.
- Given un'app «solo clic», when l'Agente prova a scrivere o un Motore cloud osserva, then la scrittura è rifiutata e l'osservazione contiene solo i controlli, senza immagini.

## Implementation Notes

- Spec approvata in autonomia (Nico: «committa e procedi»).
- **Scostamento:** come nella Storia 9.2, i livelli si applicano in `AgentTools`, quindi all'Agente di ogni Motore. La Corsia locale esegue azioni già validate dall'`Executor` senza passare di qui: rinviato insieme a `ActionOrigin`.
- Il livello «normale» del Finder è il gate della Storia 9.2 (conferma per le Azioni con effetti esterni). «Conferma ogni azione» chiede una volta per chiamata, e i controlli interni della stessa chiamata non chiedono di nuovo.
- L'attesa dell'albero Electron (Storia 7.4) avviene prima di ogni decisione sul campo.

## Spec Change Log

## Review Triage Log

Prima review (3 revisori). Nessun rilievo di intento o di spec; patch salvo due rinvii.

| Rilievo | Verdetto | Evidenza / esito |
|---|---|---|
| In «solo clic» il messaggio iniziale ai Motori cloud porta titolo, selezione e 300 caratteri prima del cursore (la shell) | high | Patch: vuotati in `AgentRunner.message` quando il livello è «solo clic» |
| `SecureInput.ownerName` si blocca: aspetta la fine di `ioreg` prima di leggere la pipe (oltre 64 KB) | high | Riprodotto da un revisore. Patch: lettura prima dell'attesa; pid della sessione sulla console (`securePID`, testato) |
| Campi password protetti solo per `type_text` | high | Patch: controllo centrale in `perform` per `type_text`, `replace_text`, `edit_text`, `set_value`, `select_text` e `press_keys` (in un campo password sono ammessi solo Tab, Esc e frecce) |
| «Conferma ogni azione» faceva saltare le conferme specifiche (Elimina, Invio) | high | Patch: niente scorciatoia; la domanda generica e quella specifica restano separate, provato su Invia |
| Refusi nell'elenco (`solo click`, CRLF, spazi doppi) danno accesso pieno; prima riga vince | medium | Patch: livello sconosciuto = «conferma ogni azione», ultima riga vince, a capo e spazi normalizzati |
| Ripiego di `isSecureField` che non scattava quasi mai | medium | Patch: anche quando nemmeno il ruolo si legge; `observe` usa la stessa regola |
| Strumenti di lettura eseguiti e poi scartati; giornale delle chiamate con testo non filtrato | medium | Patch: rifiuto prima di eseguire; filtro applicato prima del giornale delle chiamate |
| Titolo della finestra e valori con «»» che passano nel filtro dei controlli | medium | Patch: titolo nascosto, valore tolto fino al marcatore successivo; testato |
| Inserimento sicuro controllato solo per la frase singola | medium | Patch: `blockedBySecureInput` anche nella dettatura lunga e nei comandi di scrittura |
| Bersaglio «elemento 0» per gli strumenti senza id; parole mancanti nella domanda | low | Patch: `.tool(name:)`, `.shortcut`, elenco delle parole completo |
| `click_many` e `perform_action` incoerenti in «solo clic» | low | Patch: `click_many` ammesso; `perform_action` resta escluso (può non essere un clic) |
| Nessuna app «solo clic» oltre Terminal e iTerm | low | Patch: Warp, Ghostty, kitty, Alacritty, Accesso Portachiavi, 1Password, Bitwarden; Script Editor e Automator a «conferma ogni azione» |
| App sconosciuta in primo piano con accesso pieno | low | Patch: «conferma ogni azione» quando non c'è un'app davanti |
| Livello mostrato solo all'inizio, non quando cambia app | low | Patch: avviso dagli strumenti a ogni cambio di app o di livello |
| Test: impostazione reale lasciata cambiata; «conferma ogni azione», `initialObservation`, `get_text`/`read_text`, giornale non provati | gap | Patch: `defer`, prove dal vivo in `--hands-test` |
| `cloudAllowed` calcolato e non usato | low | Respinto: resta come asse «chi» di AD-22, usato dal Router tramite `cloudBlockReason`; da unificare con `ActionOrigin` |
| Corsia locale non soggetta ai livelli | gap | Rinviato con `ActionOrigin` (Storia 9.2) |
| Etichette dei controlli che contengono testo della finestra | low | Rinviato: in «solo clic» restano solo le righe cliccabili; un filtro più stretto renderebbe inutilizzabili i pulsanti |
