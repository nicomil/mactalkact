---
title: 'Storia 7.5 — Misura finale della velocità'
type: 'feature'
created: '2026-10-27'
status: 'in-review'
baseline_commit: '2c60c0acba24f906a821b79e91b1ebecf420a983'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-7-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Le Storie 7.1–7.4 hanno cambiato misura, sessione, livelli e osservazione, ma non c'è ancora una misura finale unica che dica se l'Epic 7 ha raggiunto gli obiettivi di NFR-12 e quali assunzioni restano.

**Approach:** `--agent-bench` dichiara l'esito delle soglie di NFR-12 (primo strumento ≤ 1,5 s, compito ≤ 4,5 s, livello istantaneo ≤ 2,5 s, mediane). Una corsa completa con tutto attivo va nella ricerca, confrontata con la riga di base, insieme a scalate e riavvii della Sessione lunga. Il README descrive Sessione lunga, Livello istantaneo, osservazione a costo fisso, i loro interruttori e la data entro cui rileggere le versioni delle CLI.

## Boundaries & Constraints

**Always:** esito dichiarato anche quando una soglia non è superata; stessi compiti della riga di base (pagine, canvas, Finder, Frasi spurie; Calendario, Mail e webmail restano fuori senza Nico).

**Never:** nessun cambiamento al comportamento dell'Agente in questa storia.

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/DebugCLI.swift` -- riepilogo di `agentBench`: soglie NFR-12 con esito, riavvii della sessione letti dal log del processo.
- `README.md` -- sezione dell'Agente.
- ricerca -- §17, misura finale.

## Tasks & Acceptance

**Execution:**
- [x] `Sources/MacTalkAct/DebugCLI.swift` -- soglie NFR-12 nel riepilogo e nel TSV (riga `# soglie`).
- [x] `README.md` -- Livello istantaneo, osservazione a costo fisso, interruttori, data delle CLI.
- [x] ricerca -- corsa finale e confronto con la riga di base.

**Acceptance Criteria:**
- Given `--agent-bench --engine claude`, when finisce, then stampa per ogni soglia di NFR-12 il valore e «superata» o «non superata».
- Given la ricerca, when la leggo, then trovo prima/dopo dell'Epic 7 con primo strumento, compito, fasi, scalate e riavvii.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --agent-bench --engine claude` -- expected: riepilogo con le soglie

## Implementation Notes

- Spec approvata in autonomia (Nico: «committa e procedi»).
- Riepilogo del Banco con le soglie di NFR-12 e i riavvii della Sessione lunga (contati dagli avvisi «Riavvio l'Agente»); riga `# soglie` in fondo al TSV.
- Corsa finale (ricerca §17): compito 7,6 → 6,0 s, primo strumento 2,6 → 2,7 s, tre soglie non superate, 28/30 riusciti.

## Spec Change Log

## Review Triage Log
