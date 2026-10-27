---
title: 'Storia 8.4 — Spike: le azioni dirette via Apple Events reggono su macOS 27?'
type: 'chore'
created: '2026-10-27'
status: 'in-review'
baseline_commit: 'fc4cc75387a948d8c0a57d4dc960a2ecb89b0896'
route: 'dispatch'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Non si sa se Mail, Calendario, Safari, Finder e i browser Chromium rispondono in tempo via Apple Events su macOS 27.

**Approach:** Un comando di debug esegue cinque azioni con 3 s al massimo ciascuna e registra tempo, errore, consenso Automazione e versione dell'app. I risultati vanno nella ricerca; la decisione è del ciclo seguente.

## Boundaries & Constraints

**Always:** nessuno strumento dell'Agente (AD-20); niente `do shell script` né `execute javascript`; consenso letto senza finestre (`askUserIfNeeded = false`); nessun invio senza conferma.

**Never:** nessuna integrazione in questo ciclo.

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/AppleEventsSpike.swift` -- nuovo: azioni, consenso, tempo.
- `Sources/MacTalkAct/main.swift` -- `--apple-events-spike`.

## Tasks & Acceptance

**Execution:**
- [x] `AppleEventsSpike.swift`, `main.swift` -- comando.
- [x] ricerca -- §21.

**Acceptance Criteria:**
- Given `--apple-events-spike`, when gira, then stampa per ogni azione app, versione, consenso, tempo ed errore, senza chiedere permessi.

## Implementation Notes

- Spec approvata in autonomia (Nico: «committa e procedi»). La misura è parziale: senza Nico al Mac non si possono dare i consensi né aprire Calendario e Mail. Da rilanciare con Nico presente.

## Spec Change Log

## Review Triage Log
