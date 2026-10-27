---
title: 'Storia 9.3 — Campi sicuri e livelli di accesso per app'
type: 'feature'
created: '2026-10-28'
status: 'in-review'
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
