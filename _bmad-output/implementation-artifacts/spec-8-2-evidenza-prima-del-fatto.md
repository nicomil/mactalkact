---
title: 'Storia 8.2 — Evidenza prima del «fatto»'
type: 'feature'
created: '2026-10-27'
status: 'in-progress'
baseline_commit: '15c9da36b480a3c2f45483784cf1232f0046492e'
route: 'dispatch'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** L'Agente può dire «fatto» senza che lo schermo lo mostri (nel Banco: «Ho scelto Torino, ma…», «Ho aperto il menu…» con verifica fallita). Inoltre la Memoria di conversazione porta le risposte intere dell'Agente, che possono essere lunghe.

**Approach:** Il prompt dei Motori cloud chiede di chiudere citando la prova presa dall'ultimo `RESULT` (titolo, elemento, testo cambiato), oppure di dire che cosa non si è potuto verificare. Un interruttore riporta al prompt di prima. Il Banco conta i «falsi fatti»: risposte che dichiarano il successo su compiti la cui verifica fallisce. La Memoria di conversazione tiene di ogni interazione l'esito accorciato e il testo cambiato, al massimo 300 parole in tutto.

## Boundaries & Constraints

**Always:** interruttore `evidenceBeforeDone` (predefinito attivo); con l'interruttore spento il prompt è identico a quello di prima. Esito di ogni voce della memoria al massimo 40 parole; blocco `<recent>` al massimo 300 parole, si tolgono prima le voci più vecchie; i `changes` restano.

**Never:** nessun cambiamento agli strumenti né al Motore locale (che non usa questo prompt).

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/AgentRunner.swift:20-90` -- `systemPrompt`: regola dell'evidenza, aggiunta solo con l'interruttore (il prompt fa parte della configurazione della sessione: cambiarlo la riavvia).
- `Sources/MacTalkAct/Conversation.swift` -- `promptBlock(after:)`: esiti accorciati, tetto di 300 parole.
- `Sources/MacTalkAct/Settings.swift` -- `evidenceBeforeDone`.
- `Sources/MacTalkAct/DebugCLI.swift` -- Banco: colonna `falso_fatto` e conteggio; `--selftest` per la memoria.

## Tasks & Acceptance

**Execution:**
- [ ] `AgentRunner.swift`, `Settings.swift`, `SettingsWindow.swift` -- regola e interruttore.
- [ ] `Conversation.swift` -- memoria compatta.
- [ ] `DebugCLI.swift` -- falsi fatti nel Banco, test della memoria.
- [ ] ricerca -- prima/dopo: falsi fatti, turni sui compiti a una chiamata, tempo.

**Acceptance Criteria:**
- Given il Banco con Claude, when confronto prima e dopo, then i falsi fatti scendono a zero o sono spiegati, i turni sui compiti a una chiamata crescono al massimo di 1 e il tempo mediano è riportato.
- Given `--selftest`, when gira, then la memoria resta entro 300 parole con esiti accorciati.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest`, `--fallback-test` -- expected: nessun FAIL

## Implementation Notes

- Spec approvata in autonomia (Nico: «committa e procedi»).

## Spec Change Log

## Review Triage Log
