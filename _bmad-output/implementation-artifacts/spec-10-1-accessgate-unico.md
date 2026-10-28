---
title: 'Storia 10.1 — AccessGate unico, stesso comportamento'
type: 'refactor'
created: '2026-10-28'
status: 'done'
baseline_commit: '445788bd8a312e18ec94dd776d1454facce40636'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Livelli di accesso, conferma per singola azione, regole fisse e secondo strato sono scritti dentro `AgentTools`: ogni nuova strada verso l'`Executor` (per prima la Corsia locale, Storia 10.2) dovrebbe ricopiarli.

**Approach:** Un nuovo `AccessGate.swift` con `ActionOrigin` (`.user`, `.model`) e la classe `AccessGate` che possiede le decisioni: livello di accesso dell'app, campo password, «conferma ogni azione», secondo strato con cache, domanda di conferma con `ConfirmationTarget` e grant, conteggi e righe del log. `AgentTools` raccoglie i fatti (elemento risolto, etichette, azioni da giudicare) e chiede al gate; le chiamate dell'Agente sono `.model` (FR-56). Prima del rifacimento si rende stabile `--hands-test` «azione senza effetti».

## Boundaries & Constraints

**Always:** nessun messaggio al modello, domanda all'utente o riga del log cambia (stesso testo, stesso ordine dei controlli); budget del secondo strato 0,9 s; cache del secondo strato con la stessa chiave e le stesse regole (solo verdetti validi, svuotata oltre 500); il grant resta per una sola azione e una sola richiesta; `riskJudge` resta iniettabile per i test.

**Never:** nessun cambiamento alla Corsia locale in questa storia (è la 10.2); nessun giudizio anticipato (è la 10.3); nessuna nuova impostazione o interruttore.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Solo clic | `.model`, Terminal, `type_text` | stesso errore di oggi, `refusals` +1 | — |
| Password | `.model`, `type_text` su `AXSecureTextField` | stesso errore di oggi | — |
| Conferma ogni azione | Impostazioni di Sistema, `click` | una domanda «Vuoi che faccia …», «no» → stesso errore di negazione | nessuna risposta = no |
| Regola fissa | `click` su «Invia» | domanda col bersaglio `.element(id, click)` | cambio di app durante la domanda = no |
| Secondo strato | etichetta non coperta, verdetto esterno | domanda; verdetto in cache alla seconda volta | timeout non in cache |
| Origine utente | `.user` | il gate non interviene | — |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/AgentTools.swift` -- `perform(_:_:)` (~340): livello di accesso, «solo clic», password, «conferma ogni azione», secondo strato con `riskCache`; `riskActions`/`riskAction` (~430): restano in `AgentTools` (usano il registro degli id), passano al gate le `RiskAction`; `ConfirmationTarget`, `gate(...)`, `denied`, `logLine`, `logBlock`, `requestMentions`, `scenarioRow` (~838–960): si spostano nel gate; chiamate a `gate(...)` dentro `dispatch` (~640, 698, 702, 1580–1621, 1748, 1762, 1796) diventano chiamate al gate; stato `currentRequest`, `deniedThisRequest`, `confirmationsAsked`, `deniedConfirmations`, `refusals`, `onQuestion`, `askUser`, `onAccessNotice`, `onClassified`, `riskJudge`, `riskClassifier`: passano al gate, con proprietà di inoltro in `AgentTools` dove altri file le usano (`AgentRunner`, `Coordinator`, `DebugCLI`) così i chiamanti non cambiano.
- `Sources/MacTalkAct/Privacy.swift` -- `PrivacyGuard.accessLevel()`: letto dal gate, invariato.
- `Sources/MacTalkAct/RiskClassifier.swift` -- `OnDeviceRiskClassifier`, `RiskAction`, `RiskVerdict`: invariati.
- `Sources/MacTalkAct/LLMPlanner.swift` -- `enum Safety`: invariato, chiamato dal gate per le regole fisse dove serve.
- `Sources/MacTalkAct/DebugCLI.swift` -- `handsTest` (~1797): «azione senza effetti» (`press_keys` shift subito dopo il clic su «Accessori», ~1846) fallisce circa una volta su tre; selftest con le righe del log del gate.
- `reset()` di `AgentTools` azzera per richiesta lo stato del gate come oggi.

## Tasks & Acceptance

**Execution:**
- [x] `Sources/MacTalkAct/DebugCLI.swift` -- prima di tutto: capire perché «azione senza effetti» è instabile (pagina ancora in cambiamento dopo la navigazione?) e renderla stabile senza indebolire il controllo; poi selftest per ogni riga della matrice con `riskJudge` finto e `askUser` finto, senza schermo dove possibile.
- [x] `Sources/MacTalkAct/AccessGate.swift` -- nuovo: `ActionOrigin`, `AccessGate` con `ConfirmationTarget`, domanda/grant, livello di accesso, password, «conferma ogni azione», secondo strato e cache, log.
- [x] `Sources/MacTalkAct/AgentTools.swift` -- `perform` e `dispatch` chiamano il gate con origine `.model`; nessuna logica di decisione resta duplicata.
- [x] ricerca -- breve nota nel §28 o in un nuovo §30 con i risultati della rete prima e dopo.

**Acceptance Criteria:**
- Given `--hands-test`, when eseguito 10 volte di fila, then 10 corse su 10 sono verdi.
- Given la rete (suite di sicurezza con Claude e Codex, `--security-coverage`, `--risk-classifier-test`, `--route-test`, `--hands-test`, `--selftest`), when confronto prima e dopo, then i risultati sono gli stessi.
- Given `AgentTools.swift`, when lo leggo, then non contiene più controlli di livello, password, «conferma ogni azione», secondo strato né la funzione della domanda di conferma.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest` -- expected: Tutto ok.
- `for i in $(seq 10); do .build/debug/MacTalkAct --hands-test | tail -1; done` -- expected: 10 esiti verdi
- `.build/debug/MacTalkAct --security-coverage`, `--risk-classifier-test`, `--route-test` -- expected: come prima
- `.build/debug/MacTalkAct --security-suite --engine claude` e `--engine codex` -- expected: come prima (10/10 e 8/8 con Claude, 8/8 con Codex)

## Implementation Notes

- Spec approvata in autonomia (Nico, 28/10: «builda tutto fin quando non finiscono»).
- Oltre al gate: `set_value` rilegge il valore del cursore web prima di fermarsi (instabilità vista in `--hands-test`), e la prova `--hands-test` non agisce se Safari non è in primo piano (aveva scritto nel terminale di Nico). Suite di sicurezza e serie di 10 `--hands-test` ancora da rifare con il Mac libero.

- 28/10 pomeriggio: Nico usa il Mac, corse sullo schermo sospese. Verdi senza schermo: build, `--selftest`, `--fallback-test`, `--security-coverage`, `--route-test` 164/164. Da fare dopo il «via»: `--hands-test` 10 volte, `--security-suite` con Claude e con Codex; poi la riga «suite di sicurezza» del §30.

- 28/10 sera, Mac libero: `--hands-test` 10/10 verdi; suite di sicurezza Claude 15/15 scenari e 12/12 blocchi, uguale con `--no-risk-classifier`; Codex 15/15 e 11/12 (`scorciatoia-invio` non provata). Ricerca §30.
- 28/10, deciso con Nico: cmux (`com.cmuxterm.app`) aggiunto alle app «solo clic» predefinite (commit 222a018).

## Spec Change Log

## Review Triage Log

| # | Fonte | Rilievo | Verdetto | Evidenza / esito |
|---|---|---|---|---|
| 1 | blind | regole fisse (`Safety`) ancora decise in `dispatch`, il gate fa solo la domanda | medium | la storia chiede le regole fisse chiamate dal gate; la 10.2 le richiede da un secondo chiamante → patch (metodi del gate) |
| 2 | edge | in `AgentTools` restano le regole «solo clic» di visibilità per i Motori cloud | medium | righe ~278, ~294, ~993 leggono `PrivacyGuard` → patch |
| 3 | blind, edge | `ActionFacts` con predefiniti permissivi (password «no», secondo strato spento) | medium | un nuovo chiamante con `ActionFacts()` spegne due controlli → patch |
| 4 | edge | `Int(d)` va in crash con id enorme, NaN o infinito | medium | codice nuovo nel gate; crash dell'app su input del modello → patch |
| 5 | verifica | nessun test senza schermo prova `AgentTools.call` → `gate.check` | medium | cambiare `.model` in `.user` non farebbe fallire nulla fuori da `--hands-test` → patch |
| 6 | verifica | `--fallback-test` dipende dal terminale in primo piano | low | con un terminale «solo clic» davanti la domanda cmd+q non parte → patch (ambiente finto) |
| 7 | blind | rami del gate non coperti dal selftest | medium | elenco preciso nella review → patch |
| 8 | edge, blind | `set_value`: lettura nil, lettura finale vecchia, cancellazione che lancia | low | correzioni dirette → patch |
| 9 | edge, blind | `handsTest`: attesa della pagina ferma che rinuncia in silenzio; doppia lettura dell'app davanti | low | → patch |
| 10 | blind | l'attesa della pagina ferma nasconde un problema del prodotto (cambi tardivi attribuiti all'azione dopo) | medium (non verificato) | pre-esistente → defer |
| 11 | blind | gate creato dentro ogni `AgentTools`, tabelle con nomi degli strumenti dell'Agente | low | riguarda la condivisione, prevista dalla Storia 10.2 → rifiutato qui |
| 12 | blind | `refusals` non azzerato da `reset` | false | comportamento di prima: la suite lo azzera da sé |
| 13 | blind, edge | criteri non soddisfatti (10/10, suite) | — | corse sullo schermo sospese su richiesta di Nico; la storia resta in review finché non girano |
| 14 | blind | `ActionOrigin.user` senza chiamante reale | false | le azioni dell'utente non passano dal gate per costruzione (FR-56) |
| 15 | edge | `reset` durante l'attesa di `askUser` | maybe-false | pre-esistente; servirebbe un reset concorrente dimostrato → rifiutato (sarebbe low) |
| 16 | blind | diff con pezzi di `TestKillSwitch` | false | artefatto del diff (commit ec6d252 separato) |
| 17 | blind | commenti duplicati sulle proprietà di inoltro, parametro `origin` di `logLine` | low | nessun danno nominato → rifiutato |
| 18 | verifica | ciclo di rilettura di `set_value` senza test deterministico | medium (non verificato) | servirebbe un punto d'iniezione per le letture AX → defer |
