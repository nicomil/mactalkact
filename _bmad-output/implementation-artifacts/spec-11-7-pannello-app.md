---
title: 'Storia 11.7 — Pannello delle app nelle Impostazioni'
type: 'feature'
created: '2026-10-29'
status: 'done'
baseline_commit: '420eff6'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Oggi il livello di accesso e la riservatezza delle app si scrivono a mano in due riquadri di testo (Impostazioni › Privacy), una riga per app con l'identificativo (`com.cmuxterm.app = solo clic`). Nico deve conoscere l'identificativo e non vede quali app ha installato. Lo ha chiesto il 28/10: «un pannello dove gestire tutte le app e i relativi permessi, come nelle impostazioni del Mac».

**Approach:** Un riquadro «App» in cima alla sezione Privacy. Mostra le app installate (in `/Applications`, `/System/Applications`, `~/Applications` e nelle loro sottocartelle di primo livello) e quelle aperte, con icona, nome e identificativo. Per ogni app c'è un menu con «normale / conferma ogni azione / solo clic» e un interruttore «Riservata». C'è un campo di ricerca, e le app con un'impostazione diversa da quella di base vengono prima. Il riquadro scrive negli stessi due elenchi di testo (`accessLevels`, `reservedApps`), che restano sotto in «Modifica come testo». Così nessuna regola si perde e il comportamento del gate non cambia.

## Boundaries & Constraints

**Always:** una sola fonte di verità, gli elenchi di testo che già legge `PrivacyGuard`. Il riquadro li modifica con funzioni pure provate dal selftest. Cambiare un'app tocca solo le righe di quell'app (per identificativo o per nome) e lascia commenti e altre righe come sono. Scegliere «normale» toglie le righe dell'app, perché un'app non elencata è «normale». La lettura delle app avviene fuori dal thread principale.

**Never:** nessun cambiamento alle regole del gate né ai valori predefiniti; nessuna lettura del contenuto delle app; nessun permesso nuovo.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Livello nuovo | Safari «normale» → «solo clic» | riga `com.apple.Safari = solo clic` in fondo all'elenco | — |
| Livello tolto | Terminal «solo clic» → «normale» | la riga di Terminal sparisce, le altre restano | — |
| Riga per nome | `Terminale = solo clic` scritta a mano | il menu di Terminal mostra «solo clic»; cambiandolo, la riga per nome viene sostituita | — |
| Riservata | interruttore acceso su un'app | identificativo aggiunto a `reservedApps`; spento: tolte le voci per identificativo o nome | — |
| App non installata | riga nell'elenco per un'app assente | resta nell'elenco di testo, non compare nel riquadro | — |
| Ricerca | «term» | solo le app con «term» nel nome o nell'identificativo | — |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/Privacy.swift` -- funzioni pure: `AccessLevel.setting(_:bundleID:name:in:)`, `Privacy.settingReserved(_:bundleID:name:in:)`.
- `Sources/MacTalkAct/InstalledApps.swift` (nuovo) -- elenco delle app installate e aperte, con icona.
- `Sources/MacTalkAct/SettingsWindow.swift` -- riquadro «App» in `PrivacySection`; gli elenchi di testo in «Modifica come testo».
- `Sources/MacTalkAct/DebugCLI.swift` -- selftest delle funzioni pure.

## Tasks & Acceptance

**Execution:**
- [x] funzioni pure ed elenco delle app
- [x] riquadro nelle Impostazioni
- [x] selftest e `--settings-shot`

**Acceptance Criteria:**
- Given `--selftest`, when finisce, then ogni riga della matrice è verde.
- Given `--settings-shot`, when si apre la sezione Privacy, then il riquadro mostra le app installate con menu e interruttore.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest` -- expected: Tutto ok.
- `.build/debug/MacTalkAct --settings-shot <cartella>` -- expected: immagine della sezione Privacy con il riquadro

## Implementation Notes

- Spec scritta il 29/10 su richiesta di Nico (28/10: «sì, dentro la pubblicazione»).
- 29/10: `InstalledApps.swift`, `AccessLevel.setting`, `Privacy.settingReserved`, riquadro `AppAccessCard` in Privacy; gli elenchi di testo restano sotto, in «Modifica come testo». `--selftest` verde con 6 controlli nuovi; `--settings-shot` mostra 131 app, con in cima quelle impostate. Anche la nota del secondo controllo ora dice 1,2 s.

## Spec Change Log

## Review Triage Log
