---
title: 'Storia 11.5 — Spike: ricerca in Mail sotto il secondo'
type: 'chore'
created: '2026-10-28'
status: 'done'
baseline_commit: ''
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Nello spike 8.4 cercare in Mail via Apple Events su una casella da 45.915 messaggi ha richiesto 3,43 s, oltre il limite di 3 s; la scelta su Apple Events come strumento va fatta sui numeri (AD-20, FR-61).

**Approach:** Un comando `--mail-search-spike` in `DebugCLI` (nessuno strumento dell'Agente) misura due strade su 5 ricerche nella casella di Nico, con Nico presente: (a) Apple Events su un perimetro ridotto (posta in arrivo, ultimi 30 giorni); (b) indice di Spotlight sui messaggi di Mail (`mdfind` / `NSMetadataQuery`) con apertura del messaggio per identificativo. Per ognuna: mediana, massimo, permessi richiesti (Automazione, accesso completo al disco) e completezza rispetto alla ricerca di Mail. Report in `~/Library/Logs`, §34 della ricerca con la raccomandazione; la decisione su AD-20 resta a Nico.

## Boundaries & Constraints

**Always:** sola lettura: la casella non cambia (nessun messaggio spostato, letto/non letto invariato) e nessuna finestra resta aperta; nel report e nel log solo tempi, conteggi e permessi, mai oggetti, mittenti o testo dei messaggi; si esegue solo con il consenso già dato, senza aprire richieste di permesso nuove senza Nico davanti; termini di ricerca neutri scelti da Nico o generici («fattura», «riunione»).

**Never:** nessuna integrazione nell'Agente; nessun invio, bozza, eliminazione; nessun accesso a file di Mail fuori da ciò che restituiscono Spotlight e Apple Events.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Consenso presente | Automazione verso Mail già data | 5 ricerche per strada, tempi | — |
| Consenso assente | Automazione non data | strada (a) «non eseguita: manca il consenso», nessuna richiesta | — |
| Spotlight senza indice | Mail non indicizzata | strada (b) «indice assente», tempi delle query vuote | — |
| Apertura per id | risultato di Spotlight | messaggio aperto in Mail e richiuso; tempo | finestra non richiusa: errore nel report |
| Completezza | stessa ricerca in Mail | conteggio confrontato (solo numeri) | — |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/AppleEventsSpike.swift` -- spike 8.4: `permissionStatus`, `mayRun`, `consentLabel`, `execute` (AppleScript), caso «cercare in una casella»: riusare, non cambiare il comportamento di `--apple-events-spike`.
- `Sources/MacTalkAct/main.swift` -- registrazione del nuovo comando; aggiungerlo a `TestKillSwitch.screenFlags` se apre finestre di Mail.
- `Sources/MacTalkAct/DebugCLI.swift` -- funzioni pure (mediana, formato del report) testate in `--selftest`.
- ricerca -- §34.

## Tasks & Acceptance

**Execution:**
- [x] `Sources/MacTalkAct/AppleEventsSpike.swift` (o file nuovo `MailSearchSpike.swift`) -- le due strade, sola lettura, report senza contenuti.
- [x] `Sources/MacTalkAct/main.swift` -- comando `--mail-search-spike` e stop con Esc.
- [x] `Sources/MacTalkAct/DebugCLI.swift` -- selftest delle funzioni pure.
- [x] ricerca -- §34 con tabella e raccomandazione (dopo la corsa con Nico).

**Acceptance Criteria:**
- Given `--mail-search-spike` con Nico presente, when finisce, then il report ha mediana e massimo per strada, permessi e completezza, e la casella non è cambiata.
- Given `--selftest`, when finisce, then le funzioni pure dello spike sono verdi.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest` -- expected: Tutto ok.
- Solo con Nico presente: `.build/debug/MacTalkAct --mail-search-spike` -- expected: report in `~/Library/Logs`

## Implementation Notes

- Spec approvata in autonomia (Nico, 28/10: «builda tutto fin quando non finiscono»).
- La corsa vera richiede Nico presente (casella personale): il codice si scrive e si prova senza eseguire ricerche nella casella.
- 29/10, 00:00, con Nico presente: file nuovo `MailSearchSpike.swift`. Strada (a) Apple Events mediana 0,60–0,62 s, massimo 1,9 s, 5/5 entro 3 s in tre corse; strada (b) Spotlight non vede la posta senza accesso completo al disco. Il paragrafo è il §38 della ricerca (la spec diceva §34, già usato).

## Spec Change Log

## Review Triage Log
