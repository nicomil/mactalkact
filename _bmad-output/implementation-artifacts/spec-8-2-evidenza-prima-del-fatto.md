---
title: 'Storia 8.2 — Evidenza prima del «fatto»'
type: 'feature'
created: '2026-10-27'
status: 'done'
baseline_commit: '15c9da36b480a3c2f45483784cf1232f0046492e'
route: 'dispatch'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** L'Agente può dire «fatto» senza che lo schermo lo mostri (nel Banco: «Ho scelto Torino, ma…», «Ho aperto il menu…» con verifica fallita). Inoltre la Memoria di conversazione porta le risposte intere dell'Agente, che possono essere lunghe.

**Approach:** Il prompt dei Motori cloud chiede di chiudere citando la prova presa dall'ultimo `RESULT` (titolo, elemento, testo cambiato), oppure di dire che cosa non si è potuto verificare. Un interruttore riporta al prompt di prima. Il Banco conta i «falsi fatti»: risposte che dichiarano il successo su compiti la cui verifica fallisce. La Memoria di conversazione tiene di ogni interazione l'esito accorciato (con la frase finale che nomina la prova) e il testo cambiato, al massimo 300 parole per interazione.

## Boundaries & Constraints

**Always:** interruttore `evidenceBeforeDone` (predefinito attivo); con l'interruttore spento il prompt è identico a quello di prima. Esito di ogni voce al massimo 40 parole, tenendo l'ultima frase; ogni `change` al massimo 30 parole; ogni voce al massimo 300 parole; il numero di voci resta quello delle impostazioni.

**Never:** nessun cambiamento agli strumenti né al Motore locale (che non usa questo prompt).

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/AgentRunner.swift:20-90` -- `systemPrompt`: regola dell'evidenza, aggiunta solo con l'interruttore (il prompt fa parte della configurazione della sessione: cambiarlo la riavvia).
- `Sources/MacTalkAct/Conversation.swift` -- `promptBlock(after:)`: esiti accorciati, tetto di 300 parole.
- `Sources/MacTalkAct/Settings.swift` -- `evidenceBeforeDone`.
- `Sources/MacTalkAct/DebugCLI.swift` -- Banco: colonna `falso_fatto` e conteggio; `--selftest` per la memoria.

## Tasks & Acceptance

**Execution:**
- [x] `AgentRunner.swift`, `Settings.swift`, `SettingsWindow.swift` -- regola e interruttore.
- [x] `Conversation.swift` -- memoria compatta.
- [x] `DebugCLI.swift` -- falsi fatti nel Banco, test della memoria.
- [x] ricerca -- prima/dopo: falsi fatti, turni sui compiti a una chiamata, tempo.

**Acceptance Criteria:**
- Given il Banco con Claude, when confronto prima e dopo, then i falsi fatti scendono a zero o sono spiegati, i turni sui compiti a una chiamata crescono al massimo di 1 e il tempo mediano è riportato.
- Given `--selftest`, when gira, then ogni interazione resta entro 300 parole con l'esito accorciato e la prova finale.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest`, `--fallback-test` -- expected: nessun FAIL

## Implementation Notes

- Spec approvata in autonomia (Nico: «committa e procedi»).
- `AgentRunner.systemPrompt` è ora `basePrompt` più `evidenceRule` con l'interruttore acceso. Il prompt fa parte della configurazione della Sessione lunga, quindi cambiarlo la riavvia.
- Il rilevatore dei falsi «fatto» del Banco considera onesta ogni risposta con una negazione. La prima versione, basata su `instantGaveUp`, dava falsi positivi.
- Risultato (ricerca §19): 0 falsi «fatto» prima e dopo, +0 turni sui compiti a una chiamata, compito 5,95 → 5,45 s.

- **Confermato da Nico il 28/10/2026:** tetto di 300 parole per interazione nella memoria della conversazione.

## Spec Change Log

- Review 1 (bad_spec): la storia chiede «ogni interazione … entro 300 parole», la spec diceva «300 parole in tutto» e toglieva le voci più vecchie. Questo accorciava senza dirlo il «di prima» e faceva saltare al cursore della Sessione lunga voci mai inviate. Rivisti Intent, Boundaries e criteri: tetto per voce, ultima frase dell'esito tenuta (lì l'Agente nomina la prova), `changes` accorciati. KEEP: regola del prompt con interruttore, rilevatore dei falsi «fatto», test dell'interruttore. Modifica fatta in autonomia (Nico assente): da confermare.

## Review Triage Log

| Rilievo | Verdetto | Evidenza / esito |
|---|---|---|
| Tetto di 300 parole sul blocco invece che per interazione | bad_spec | Story 8.2: «ogni interazione … entro 300 parole». Spec rivista, codice rifatto (vedi Spec Change Log) |
| L'esito accorciato perde la frase con la prova, che sta alla fine | high | `shorten` teneva le prime 40 parole. Patch: `keepEvidence` tiene l'inizio e l'ultima frase |
| Tetto non rigido: prima voce sempre ammessa, `changes` mai accorciati | medium | Patch: ogni `change` ≤ 30 parole, ogni voce ≤ 300 |
| Il tetto sul blocco faceva saltare voci mai inviate alla Sessione lunga | medium | Risolto togliendo il tetto sul blocco: il numero di voci resta quello delle impostazioni |
| Rilevatore: «non» dentro le virgolette, «non è più spuntata», «Errore:» con la maiuscola, risposta vuota | medium | Patch: virgolette ignorate, «non (è) più» escluso, prefisso sul testo normalizzato, vuoto dopo la normalizzazione; parole «fallito», «nemmeno», «neanche» aggiunte |
| Account webmail personale: risposta cancellata prima del controllo | low | Patch: giudizio prima della cancellazione |
| Frasi spurie contate come falsi «fatto» | low | È un fallimento di FR-48, non di FR-46. Patch: escluse |
| Falsi «fatto» e stato dell'interruttore mancanti nel file del verdetto | low | Patch: aggiunti in `…-soglie.txt` |
| Test della memoria mai oltre il tetto (5 voci), controllo vuoto («richiesta 1 »), prompt mai letto con l'interruttore, predefinito non fissato | gap | Patch: 10 voci con impostazione rimessa, voce e ordine controllati, `systemPrompt` acceso/spento, predefinito |
| Commento con il requisito sbagliato (FR-47) e commento sul simbolo sbagliato | low | Eliminati con il codice nuovo |
| Costo della regola su Livello istantaneo e turni non misurato con l'interruttore | low | Respinto: il Banco 22:36 riporta +0 turni sui compiti a una chiamata; l'interruttore è nel file del verdetto |
