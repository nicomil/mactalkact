---
title: 'Storia 10.2 — La Corsia locale passa dal cancello'
type: 'feature'
created: '2026-10-28'
status: 'in-review'
baseline_commit: 'cd7b80e66c6f01715958931cf0c2eac3bfd5e162'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Una `LocalAction` proposta dal modello Apple (`LocalActionProposer`) e approvata da `LocalActionValidator` raggiunge l'`Executor` senza livelli di accesso né conferma: in un'app «solo clic» un tasto passa, con «conferma ogni azione» nessuno chiede, e una scorciatoia che invia o elimina dipende solo dall'elenco del Validatore.

**Approach:** `Coordinator.runLocal` fa passare ogni `LocalAction` dall'`AccessGate` come `.model` prima di eseguirla, con lo stesso nome di strumento che userebbe l'Agente (`press_keys`, `open_app`, `open_url`, `scroll`): «solo clic» rifiuta i tasti, «conferma ogni azione» chiede, le scorciatoie rischiose (`Safety.isRiskyKeys` con l'app davanti) chiedono con `ConfirmationTarget.shortcut` (FR-56). La domanda usa lo stesso meccanismo di domanda a voce del Coordinator già usato dall'Agente (AD-24): «sì» esegue, qualunque altra Frase annulla, e l'annullamento non passa all'Agente. Comandi rapidi, Dettatura, numeri e macro restano `.user` e non passano dal gate.

## Boundaries & Constraints

**Always:** il gate si aggiunge dopo il Validatore, non lo sostituisce; i messaggi del gate restano quelli della 10.1, ma all'utente la Corsia locale mostra una frase italiana breve nell'HUD (rifiuto: «In <app> posso solo cliccare: fallo tu o chiedilo all'Agente»; annullata: «Annullato»); un rifiuto o un «no» non passa all'Agente e non ripete l'azione; il gate aggiunge al massimo 20 ms [ASSUMPTION] alla Corsia locale, che resta entro NFR-1 (≤ 1,5 s); una richiesta della Corsia locale azzera lo stato per richiesta del gate come fa una richiesta dell'Agente.

**Never:** nessun passaggio dal gate per Comandi rapidi, Dettatura, numeri, macro; nessuna nuova voce in `LocalActionValidator.allowedKeys`; nessun cambiamento all'Agente.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Solo clic | `.keys(cmd+w)` con app «solo clic» | rifiuto, nessun tasto, HUD con la frase di rifiuto, nessun Agente | — |
| Conferma ogni azione | `.keys(cmd+s)` con «conferma ogni azione» | domanda; «sì» esegue; altra Frase annulla | nessuna risposta = annullata |
| Scorciatoia rischiosa | `.keys(cmd+shift+d)` forzata con app Mail (il Validatore non la propone: prova di difesa in profondità) | domanda con bersaglio `.shortcut`; «no» non preme nulla | — |
| Apertura app o sito | `.openApp`, `.openURL` in app «normale» | nessuna domanda, come oggi | — |
| Azione dell'utente | Comando rapido «chiudi scheda» in Terminal | nessun gate, come oggi | — |
| Annullata | «no» alla domanda | HUD «Annullato», nessun `runSmart` | — |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/Coordinator.swift` -- `runLocal(_:text:app:)` (~686): esegue `executor.press/openApp/openURL/scroll`; oggi in caso di errore passa a `runSmart`. `perform` → `case .local` (~639). `askByVoice(_:confirmation:)` (~293) e `answerAgent` (~315): la risposta arriva da `handleUtterance` solo quando `busy` è vero, quindi la Corsia locale deve risultare occupata mentre chiede.
- `Sources/MacTalkAct/AccessGate.swift` -- `check(_:_:origin:facts:)` (~102), `confirm(...)` (~231), `ActionFacts`, `Environment`, `reset(keepCounters:)`; `askUser`/`onQuestion` sono già collegati per l'Agente in `Coordinator.setupAgent()`: la Corsia locale usa la stessa istanza del gate (`agent.tools.gate` o equivalente) o una sua istanza con gli stessi collegamenti; scegliere la soluzione che non mescola i contatori della richiesta dell'Agente.
- `Sources/MacTalkAct/AccessGate.swift` -- dopo la 10.1 le regole fisse sono già nel gate: `confirmKeys(_:origin:)` (scorciatoie rischiose con l'app davanti, Invio in una chat) è il punto comune da usare per `.keys`; `AgentTools` lo chiama già per `press_keys`.
- `Sources/MacTalkAct/LocalLane.swift` -- `LocalAction` e `summary`; `LocalActionValidator.validate` (~144): invariato.
- `Sources/MacTalkAct/DebugCLI.swift` -- `accessGateTest()` (selftest della 10.1): aggiungere i casi della matrice con `Environment` finto; `--security-suite` (`securitySuite`): righe nuove per la Corsia locale con azione forzata; `--route-test`: misura del tempo del gate sui comandi locali del Corpus.
- `Tests/bench/sicurezza.tsv` -- tre scenari nuovi: «manda» in Mail (scorciatoia forzata), tasti in Terminal («solo clic» simulato come le righe esistenti), scorciatoia con «conferma ogni azione»; l'oracolo resta lo stato della pagina.

## Tasks & Acceptance

**Execution:**
- [x] `Sources/MacTalkAct/Coordinator.swift` -- `runLocal` passa dal gate come `.model`; domanda a voce con busy; rifiuto e annullamento senza Agente.
- [x] `Sources/MacTalkAct/AccessGate.swift` -- solo se serve: un ingresso per le `LocalAction` che riusa `check` e `confirmKeys` senza duplicare regole.
- [x] `Sources/MacTalkAct/DebugCLI.swift` -- selftest per ogni riga della matrice; righe della suite con azione locale forzata; tempo del gate nel `--route-test`.
- [x] `Tests/bench/sicurezza.tsv` -- tre scenari.
- [x] ricerca -- riga nel §30 o nuovo paragrafo con tempo del gate e suite.

**Acceptance Criteria:**
- Given `--selftest`, when finisce, then ogni riga della matrice è coperta e verde.
- Given `--route-test`, when finisce, then riporta il tempo aggiunto dal gate ai comandi locali (≤ 20 ms [ASSUMPTION]).
- Given `--security-suite --engine claude` (da eseguire dopo il «via» di Nico), when finisce, then i tre scenari nuovi sono bloccati e lo stato della pagina non cambia.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest` -- expected: Tutto ok.
- `.build/debug/MacTalkAct --route-test` -- expected: 164/164 come prima, più il tempo del gate
- Solo dopo il «via» di Nico: `.build/debug/MacTalkAct --security-suite --engine claude` -- expected: scenari nuovi bloccati

## Implementation Notes

- Spec approvata in autonomia (Nico, 28/10: «builda tutto fin quando non finiscono»).
- Nico sta usando il Mac: nessun comando che muove mouse o tastiera finché non dice «via».

- 28/10: verdi senza schermo build, `--selftest`, `--fallback-test`, `--security-coverage`, `--route-test` 164/164. Da fare dopo il «via»: `--security-suite --engine claude` (righe locali, controllo positivo, campo password).
- Da riportare a Nico: la frase approvata «fallo tu o chiedilo all'Agente» indica l'Agente, che però rifiuta per la stessa regola «solo clic».

## Spec Change Log

## Review Triage Log

| # | Fonte | Rilievo | Verdetto | Evidenza / esito |
|---|---|---|---|---|
| 1 | blind | «ripeti» ripreme un tasto della Corsia locale senza gate | high | `lastRepeatable = .keys(..., confirm: false)` → `runFast` → patch |
| 2 | verifica, edge | i rami di `runLocal` (rifiuto, annullamento, niente Agente) senza test; suite che reimplementa la decisione | medium | → patch (funzione comune + selftest) |
| 3 | blind | motivo del rifiuto dedotto dal contatore, `nil` → frase del campo password | medium | → patch |
| 4 | edge | fuoco che entra in un campo password durante la domanda | medium | → patch (ricontrollo dopo il «sì») |
| 5 | blind, edge | frase «posso solo cliccare» per `open_url`; «chiedilo all'Agente» indica una strada che l'Agente rifiuta | medium | `open_url` → patch; la frase dei tasti è nella spec approvata → da riportare a Nico |
| 6 | blind | domanda «i tasti in …, che tu non hai chiesto?» dopo «salva» | medium | → patch (etichetta dell'azione, senza «che tu non hai chiesto») |
| 7 | blind, edge | `onAccessNotice`/`onQuestion` non collegati, Esc non annulla, log «Risposta all'agente» | medium | → patch |
| 8 | blind | rifiuto `.info` non letto a voce; log con URL in modalità privata | medium | privacy → patch |
| 9 | blind, edge | suite senza controllo positivo, `try?` sul tasto, righe «locale:» malformate al Motore | medium | → patch (+ scenario campo password) |
| 10 | edge | dopo un «sì» un errore dell'`Executor` passa all'Agente, che richiede | low | → patch insieme al #2 |
| 11 | verifica | `--selftest` non è nel build | medium | → patch (`build-app.sh`) |
| 12 | verifica, blind | limite dei 20 ms non asserito, misurato su una copia del collegamento | medium (non verificato) | asserzioni a tempo rumorose → defer |
| 13 | blind | `composerApp`/`windowTitle` con lettura completa | low | solo con tasti Invio o rischiosi, che il Validatore non propone → rifiutato |
| 14 | edge | doppia domanda con «conferma ogni azione» e tasto rischioso | low | caso raggiungibile solo forzando l'azione → rifiutato |
| 15 | edge | una frase breve non indirizzata non annulla subito | false | comportamento di `askByVoice` già in uso per l'Agente (AD-24) |
| 16 | verifica | scenari locali della suite subordinati a un Motore disponibile | low | → rifiutato |
