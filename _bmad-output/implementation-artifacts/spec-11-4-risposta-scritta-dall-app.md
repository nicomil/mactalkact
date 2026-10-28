---
title: 'Storia 11.4 — Risposta scritta dall''app'
type: 'feature'
created: '2026-10-28'
status: 'in-review'
baseline_commit: '6f0ef9c4e2965bdb8e165601cb5d06ce9dfa6246'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Dopo l'ultima azione riuscita l'utente aspetta il «turno finale» del modello (1,5 s di mediana, §17 e §28) solo per sentirsi dire «fatto».

**Approach:** Le mani dell'Agente accettano un parametro `final` che il modello mette sull'ultima azione della richiesta; al Livello istantaneo l'unica chiamata vale sempre come finale (FR-57). Quando una chiamata `final` termina con un esito che prova il risultato (FR-46: elementi cambiati, testo comparso, finestra o app cambiata), l'app interrompe il turno del Motore senza attendere la frase finale, compone la risposta dall'esito e la mostra o la pronuncia come oggi; la Memoria di conversazione registra richiesta ed esito. Interruttore «Risposte rapide» (NFR-15), predefinito acceso.

## Boundaries & Constraints

**Always:** risponde il modello, come oggi, per esito non verificato («nothing changed», errore, azione negata dall'utente), per domande e per richieste informative (la risposta è il contenuto letto); la risposta composta nomina l'azione e la prova (mai «fatto» senza esito, FR-46); dopo un turno chiuso dall'app la Sessione lunga resta usabile e la richiesta successiva non vede una risposta a metà; nessuna azione ripetuta (la chiusura avviene dopo l'azione, non la sostituisce); con un Motore che non sa interrompere il turno senza perdere la sessione (Codex, locale) si chiude il processo della richiesta come fa già la scalata, oppure la funzione resta spenta per quel Motore se chiudere costa una sessione.

**Never:** nessuna risposta composta se la richiesta chiede un'informazione («cosa dice…», «quanto…», «leggimi…»); nessun cambiamento al Router o ai livelli.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Azione finale verificata | `click` con `final: true`, RESULT con elementi cambiati | turno interrotto, risposta composta (es. «Fatto: ho cliccato «Invia»; ora la finestra è «Posta inviata».») | interruzione senza risposta: chiusura come la scalata |
| Esito nullo | `final: true`, «RESULT: nothing changed» | risponde il modello | — |
| Errore o negazione | `final: true`, errore o «no» dell'utente | risponde il modello | — |
| Istantaneo | unica chiamata del Livello istantaneo con esito verificato | come «azione finale verificata» | esito nullo: scalata come oggi |
| Richiesta informativa | «cosa dice questa mail?», `final` su `get_text` o `read_text` | risponde il modello | — |
| Interruttore spento | «Risposte rapide» spento | turno finale di oggi; `final` ignorato | — |
| Richiesta successiva | stessa Sessione lunga dopo un turno chiuso dall'app | risposta corretta, nessun residuo del turno precedente | — |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/AgentTools.swift` -- schemi degli strumenti (le «mani»: `act`, `click`, `click_many`, `type_text`, `press_keys`, `menu`, `perform_action`, `set_value`, `drag`, `open_app`, `open_url`, `replace_text`, `edit_text`): aggiungere `final` (boolean, facoltativo) con una riga di descrizione; `call(_:_:)` (~260): dopo l'esito (`outcome()`, «RESULT: …»), decidere se la chiamata è finale e verificata e registrarlo; l'esito ha il formato di `outcome()` (~1225).
- `Sources/MacTalkAct/AgentRunner.swift` -- `systemPrompt` e `evidenceRule` (~88): una riga su `final`; ciclo di `run` (~380): quando gli strumenti segnalano chiusura, interrompere il Motore (come `tools.onEscalate` → `engine.interrupt()`), trattare l'errore o il risultato interrotto come successo e restituire la frase composta; Memoria di conversazione con esito.
- `Sources/MacTalkAct/ClaudeEngine.swift`, `ClaudeCLI.swift` -- `interrupt()`/`interruptCurrent()`: tengono viva la Sessione lunga; `runInSession` con `interrupted` già gestito per la scalata. Verificare che il cursore della memoria e l'interruzione lascino la sessione coerente per la richiesta successiva (`--session-test`).
- `Sources/MacTalkAct/CodexEngine.swift`, `LocalEngine.swift` -- `cancel()`: decidere per ciascun Motore se supportare la chiusura (vedi Always) e annotarlo.
- `Sources/MacTalkAct/Settings.swift`, `SettingsWindow.swift` -- interruttore `quickReplies`.
- `Sources/MacTalkAct/DebugCLI.swift` -- `--fallback-test` con motori finti e `finto-claude`; `--session-test` (claude vero): richiesta chiusa dall'app seguita da una seconda richiesta; `agentBench`: conteggio delle risposte composte e fase «turno finale».

## Tasks & Acceptance

**Execution:**
- [x] `Sources/MacTalkAct/AgentTools.swift` -- parametro `final`, giudizio dell'esito, composizione della frase in italiano da strumento, bersaglio ed esito.
- [x] `Sources/MacTalkAct/AgentRunner.swift` -- chiusura del turno, risposta composta, Memoria; regola nel prompt.
- [x] `Sources/MacTalkAct/ClaudeEngine.swift`/`ClaudeCLI.swift`/`CodexEngine.swift`/`LocalEngine.swift` -- interruzione coerente per Motore.
- [x] `Sources/MacTalkAct/Settings.swift`, `SettingsWindow.swift` -- interruttore.
- [x] `Sources/MacTalkAct/DebugCLI.swift` -- test di ogni riga della matrice; Banco con conteggio delle risposte composte.
- [x] ricerca -- §31 con turno finale e compito prima e dopo; `README.md` con l'interruttore.

**Acceptance Criteria:**
- Given il Banco con Claude, when confronto con il §28, then sui compiti con esito verificato la mediana del compito scende almeno della fase «turno finale» e i falsi «fatto» restano 0.
- Given `--session-test`, when una richiesta è chiusa dall'app, then la successiva nella stessa sessione risponde correttamente.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest`, `--fallback-test`, `--session-test` -- expected: Tutto ok.
- `.build/debug/MacTalkAct --agent-bench Tests/bench/agente.tsv --engine claude --only <come il §28, senza calendario-evento e mail-bozza>` -- expected: turno finale ridotto, falsi «fatto» 0
- `.build/debug/MacTalkAct --security-suite --engine claude` -- expected: come prima

## Implementation Notes

- Spec approvata in autonomia (Nico, 28/10: «builda tutto fin quando non finiscono»).
- Nico sta usando il Mac: nessun comando che muove mouse o tastiera (Banco, `--hands-test`, `--security-suite`, `--agent-test`) finché non dice «via»; quelle verifiche si annotano come da fare.

- 28/10: verdi senza schermo build, `--selftest`, `--fallback-test` (con `tools/list` sul server vero), `--security-coverage`, `--session-test`, `--route-test` 164/164. Da fare dopo il «via»: Banco con Claude e `--security-suite --engine claude`; poi la tabella del §34.

- 28/10 sera, Mac libero: 24 risposte composte su 30 compiti con azioni, 0 falsi «fatto», turno finale 1,87 → 0,01 s, compito 8,5 → 4,4 s; suite Claude 15/15 e 12/12. Ricerca §34.
- 28/10, 22:17: il falso «fatto» di `modulo-citta` è corretto (in un `act` ogni scrittura deve restare visibile), ma ne è comparso uno nuovo, `finder-rinomina`: `final` su `set_value` nel campo del nome senza Invio. Torna in review: serve una decisione con Nico (§35).
- 28/10, 23:30, deciso con Nico: il testo scritto in un campo dentro una riga, una cella, un elenco o una tabella non vale come prova (`AgentTools.isInlineEditor`), e il prompt chiede di non mettere `final` su un testo che va ancora confermato. Selftest con `finder-rinomina`; sullo schermo `finder-apri`, `finder-rinomina` e `finder-cartella` 3/3. In quella corsa il modello ha messo `final` sull'Invio e non sulla scrittura, quindi il controllo sul campo vero del Finder non è ancora scattato. Resta in review fino al Banco completo della 11.6.

## Spec Change Log

## Review Triage Log

| # | Fonte | Rilievo | Verdetto | Evidenza / esito |
|---|---|---|---|---|
| 1 | blind | la frase composta salta il mascheramento e va al cloud con la memoria | high | `considerClosing` prima di `hideSensitiveFromCloud`; `promptBlock` non maschera → patch |
| 2 | blind | la frase può ripetere a voce e salvare una password scritta | high | `act` [type_text, press_keys] cita il testo di ogni passo → patch |
| 3 | blind, edge | prova debole: qualunque cambio sullo schermo vale come «fatto»; dialoghi e altre app come successo; testo d'errore prima di RESULT e esiti troncati ignorati; `click_many` parziale; `act` finito con `wait`; testi brevi | medium | falsi «fatto» possibili (FR-46) → patch |
| 4 | blind | richieste informative non riconosciute | medium | «controlla la posta» riceverebbe un «Fatto» → patch |
| 5 | blind, edge | dopo una scalata il rapido non chiude mai da solo | medium | `escalation` non azzerata → patch |
| 6 | edge | dopo l'annullamento dell'utente l'app dice comunque «Fatto» | medium | → patch |
| 7 | blind, verifica | `final` sempre nello schema anche con l'interruttore spento; nessun test sul server vero | medium | → patch |
| 8 | verifica, blind | i test passano da una copia di `call` | medium | → patch (coda comune) |
| 9 | verifica | regola del cursore dopo l'interruzione provata solo con la CLI vera | medium | → patch (claude finto con memoria) |
| 10 | edge | `set_value` con valore numerico: frase vuota | low | → patch |
| 11 | blind, edge | mediane 0,00 s nel riepilogo del Banco | low | → patch |
| 12 | blind | README con un risparmio non ancora misurato | low | → patch |
| 13 | blind | interruttore sotto Claude ma vale anche per Codex | low | → patch (didascalia) |
| 14 | verifica, blind | interruzione con una chiamata MCP in corso mai provata con la CLI vera | medium (non verificato) | lo mostrerà il Banco → defer |
| 15 | blind | test che dipendono dall'etichetta sullo schermo | low | → defer |
| 16 | blind | colonna TSV in mezzo | low | confronto per nome → rifiutato |
| 17 | verifica | guardie `closing == nil` ridondanti in `ClaudeEngine` | false | innocue |
