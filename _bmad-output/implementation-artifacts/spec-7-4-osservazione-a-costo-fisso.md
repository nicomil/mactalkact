---
title: 'Storia 7.4 — Osservazione a costo fisso'
type: 'feature'
created: '2026-10-27'
status: 'in-review'
baseline_commit: '7332d19a4c7525f71f407a9c5c4723b4b1cecaf1'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-7-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** La lettura dello schermo (`AgentTools.scan`) visita l'albero in ampiezza con tetti solo globali: 220 elementi, 12.000 nodi, 1,8 s. Su una lista di mille righe la lista consuma da sola il budget, i pulsanti degli altri contenitori possono restare fuori e la scansione costa più di quanto serva. Sulle app Electron e Chromium l'albero può essere ancora vuoto alla prima lettura.

**Approach:** Ogni contenitore espone i figli visibili (`AXVisibleChildren` e `AXVisibleRows`) quando li ha, ha un tetto di figli e non si scende nei ruoli che non portano elementi utili. Così il costo dipende da ciò che si vede e non da quanto è lunga la lista. Per Electron e Chromium, alla prima osservazione, l'app attende che l'albero si popoli. Un interruttore riporta alla scansione di prima.

## Boundaries & Constraints

**Always:**
- Contenitori (`AXList`, `AXTable`, `AXOutline`, `AXBrowser`, `AXGrid`, `AXScrollArea`): figli visibili quando disponibili, poi al massimo 60 figli per contenitore. Il troncamento viene segnalato come oggi.
- Nessuna discesa nei ruoli `AXStaticText`, `AXImage`, `AXScrollBar`, `AXValueIndicator`, `AXBusyIndicator`, `AXProgressIndicator`, `AXSplitter` (il nodo stesso resta osservato).
- Restano: budget di tempo e tetto globale di elementi, ricerca con `query` sull'albero intero (una ricerca guarda anche fuori vista), id stabili, campi sicuri.
- Electron/Chromium: alla prima osservazione di un processo, se la finestra ha meno di 3 figli si riprova ogni 100 ms fino a 1 s.
- Interruttore `fixedCostObservation` in `AppSettings` (predefinito attivo); spento = comportamento di prima.

**Never:**
- Nessun cambiamento al formato delle righe osservate né a `outcome()`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Lista lunga | pagina con barra di 5 pulsanti e lista di 1.000 righe | i 5 pulsanti nell'osservazione, righe limitate, scansione < 1 s | troncamento segnalato |
| Pagina semplice | `modulo.html` | stesso elenco di prima | — |
| Ricerca | `observe(query: "riga 900")` | trovata anche se fuori vista | — |
| Interruttore spento | stessa pagina lunga | scansione di prima | — |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/AgentTools.swift:770-870` -- `scan(query:)`: dove si accodano i figli (`v[4]`), il filtro dei rami fuori vista e i tetti.
- `Sources/MacTalkAct/Accessibility.swift:65-118` -- `prepare` (imposta già `AXManualAccessibility`), `frontApp`: aggiungere l'attesa dell'albero per Chromium/Electron alla prima volta.
- `Sources/MacTalkAct/Settings.swift` -- `fixedCostObservation`.
- `Tests/bench/pages/grande.html`, `Tests/bench/agente.tsv` -- pagina e compito con lista lunga e barra.
- `Sources/MacTalkAct/DebugCLI.swift` -- `--hands-test` (la barra della pagina grande resta visibile, tempo della scansione) e righe del Banco.

## Tasks & Acceptance

**Execution:**
- [x] `Sources/MacTalkAct/AgentTools.swift` -- figli visibili, tetto per contenitore, filtro per ruolo, interruttore.
- [x] `Sources/MacTalkAct/Accessibility.swift` -- attesa dell'albero Electron/Chromium.
- [x] `Sources/MacTalkAct/Settings.swift` -- interruttore (anche nelle impostazioni dell'Agente).
- [x] `Tests/bench/pages/grande.html`, `Tests/bench/agente.tsv` -- pagina e compito.
- [x] `Sources/MacTalkAct/DebugCLI.swift` -- controllo in `--hands-test`.
- [x] ricerca -- tempo di scansione prima/dopo sulla pagina grande e sul Banco.

**Acceptance Criteria:**
- Given la pagina grande, when la osservo, then i pulsanti della barra ci sono e la scansione resta sotto 1 s; con l'interruttore spento torna il comportamento di prima.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest`, `--fallback-test`, `--hands-test` -- expected: nessun FAIL (`--hands-test` agisce sullo schermo)

## Implementation Notes

- Spec approvata in autonomia (Nico: «committa e procedi»). Webmail di prova non disponibile: la pagina grande ne fa le veci per il criterio «sotto 1 s».
- Risultato (ricerca §16): 0,07 s contro 0,10 s, barra visibile in entrambi i casi. Il filtro dei rami fuori finestra, che c'era già, faceva il grosso del lavoro.

## Spec Change Log

## Review Triage Log
