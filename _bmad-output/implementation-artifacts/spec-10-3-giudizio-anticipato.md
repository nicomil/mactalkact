---
title: 'Storia 10.3 — Giudizio anticipato del secondo strato'
type: 'feature'
created: '2026-10-28'
status: 'in-review'
baseline_commit: '0d62a2c7b4e3cce74ef934a7677f51249f3b7233'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Il secondo strato (modello Apple sul Mac) giudica un pulsante solo quando l'Agente lo clicca: costa circa 1 s per clic giudicato (§28) e sotto carico va in timeout (il verdetto «timeout» lascia passare e non entra in cache).

**Approach:** Dopo un `observe` o sugli elementi iniziali della richiesta, l'`AccessGate` giudica in background i controlli premibili visibili che le regole fisse non coprono e che non sono in cache: uno alla volta, al massimo 12 per osservazione [ASSUMPTION], partendo dai più vicini al fuoco, e mette in cache solo i verdetti validi con la chiave di oggi (FR-60). Al clic usa la cache, oppure aspetta il giudizio in corso di quel controllo solo per quanto resta del budget di 0,9 s; se il controllo manca, lo giudica come oggi. Il log dice «dalla cache (anticipato)».

## Boundaries & Constraints

**Always:** il giudizio anticipato può solo aggiungere conferme, mai toglierle (un verdetto «interno» anticipato vale quanto uno preso al clic, come oggi); stessa chiave di cache (strumento, etichetta, ruolo, app, finestra, dialogo) e stesse regole (solo verdetti `on-device`, svuotata oltre 500); una nuova osservazione o la fine della richiesta annullano i giudizi in coda; con il Motore locale al lavoro (stesso modello Apple) il giudizio anticipato è sospeso; solo con il secondo strato attivo, solo per i Motori cloud e mai con «conferma ogni azione» (il gate chiede già); le azioni che le regole fisse fermano o che sono inerti (campi, schede, righe, pulsanti che aprono una bozza) non si giudicano, come oggi.

**Never:** nessun giudizio per `press_keys` (resta alle regole fisse); nessuna modifica al budget di 0,9 s; nessun cambiamento alla Corsia locale.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Cache anticipata | `observe` con «Archivia»; poi `click` su «Archivia» | nessuna attesa al clic; log «dalla cache (anticipato)» | — |
| Giudizio in corso | clic su un controllo il cui giudizio è partito da 0,3 s | aspetta al massimo 0,6 s (resto del budget), poi usa il verdetto | oltre il budget: «timeout» come oggi |
| Fuori dall'anticipo | clic su un controllo oltre i 12 | giudizio al clic come oggi | — |
| Nuova osservazione | `observe` di nuovo mentre la coda lavora | coda annullata, nuova coda dai controlli nuovi | il giudizio già partito finisce e, se valido, entra in cache |
| Fine richiesta | richiesta finita con coda piena | coda annullata | — |
| Motore locale | Catena di riserva sul Motore locale | nessun giudizio anticipato | — |
| Timeout anticipato | modello lento in background | verdetto non in cache; al clic si giudica di nuovo | — |
| Verdetto esterno | anticipo dice «esterno» | al clic la domanda di conferma come oggi | — |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/AccessGate.swift` -- `check(...)` (~109–165): secondo strato con `riskCache`, `riskJudge ?? riskClassifier.judge`, log «dalla cache»; `fixedRuleAsks`; `Environment`; `reset(keepCounters:)` (fine richiesta). Qui vivono la coda anticipata, i giudizi in corso per chiave e l'attesa limitata al budget.
- `Sources/MacTalkAct/AgentTools.swift` -- `riskAction(_:_:app:)` e `riskActions` (costruiscono le `RiskAction` dalle etichette e dai ruoli, con i filtri inerti e «apre una bozza»); `observe` e `initialObservation()` (~988) con `lastView`: da qui il gate riceve i candidati (controlli premibili visibili, ordinati per distanza dal fuoco); `cloudEngine`.
- `Sources/MacTalkAct/RiskClassifier.swift` -- `OnDeviceRiskClassifier.judge`, `budget` 0,9 s, sorgenti dei verdetti: invariati.
- `Sources/MacTalkAct/AgentRunner.swift` -- sa quale Motore lavora (`engine.id == .local` → sospendere); `tools.reset()` a inizio richiesta.
- `Sources/MacTalkAct/DebugCLI.swift` -- `accessGateTest()` con `riskJudge` finto (ritardi controllati): test per ogni riga della matrice senza schermo; `agentBench`: conteggio dei verdetti anticipati, dei timeout e del costo per azione (fase «classificatore») al 90° percentile.

## Tasks & Acceptance

**Execution:**
- [x] `Sources/MacTalkAct/AccessGate.swift` -- coda anticipata (massimo 12, una alla volta, dal fuoco), giudizi in corso per chiave, attesa entro il resto del budget, annullamento, sospensione col Motore locale, log.
- [x] `Sources/MacTalkAct/AgentTools.swift` -- dopo `observe` e `initialObservation()` passa al gate i candidati come `RiskAction`, con gli stessi filtri di oggi.
- [x] `Sources/MacTalkAct/AgentRunner.swift` -- sospensione col Motore locale, annullamento a fine richiesta.
- [x] `Sources/MacTalkAct/DebugCLI.swift` -- test di ogni riga della matrice con giudice finto; misure nel Banco.
- [x] ricerca -- §31 (o il numero libero successivo) con timeout, costo per azione e concorrenza di FoundationModels, da riempire dopo il Banco. (§32 scritto; la tabella del Banco resta da riempire dopo il «via»)

**Acceptance Criteria:**
- Given `--selftest`, when finisce, then ogni riga della matrice è coperta e verde.
- Given il Banco con Claude (solo dopo il «via» di Nico), when misuro sui compiti positivi, then zero timeout del secondo strato e al massimo 0,3 s in più per azione al 90° percentile (NFR-16).
- Given `--security-suite --engine claude` con secondo strato acceso e con `--no-risk-classifier` (dopo il «via»), when finiscono, then passano uguali (NFR-14).

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest`, `--fallback-test`, `--risk-classifier-test` -- expected: Tutto ok / come prima
- Solo dopo il «via» di Nico: `--agent-bench … --engine claude` e `--security-suite --engine claude` (acceso e `--no-risk-classifier`)

## Implementation Notes

- Spec approvata in autonomia (Nico, 28/10: «builda tutto fin quando non finiscono»).
- Nico sta usando il Mac: nessun comando che muove mouse o tastiera finché non dice «via».

- 28/10: dopo la review `RiskClassifier.judge` accetta l'annullamento (`withTaskCancellationHandler`), altrimenti il modello Apple continuerebbe a lavorare accanto al giudizio del clic; budget e sorgenti dei verdetti invariati.
- Verdi senza schermo: build, `--selftest`, `--fallback-test`, `--security-coverage`, `--route-test` 164/164, `--risk-classifier-test` 10/10 e 0/7. Da fare dopo il «via»: Banco con Claude (NFR-16) e `--security-suite --engine claude` acceso e `--no-risk-classifier`; poi la tabella del §32.

- 28/10 sera, Mac libero: suite Claude 15/15 con e senza secondo strato (NFR-14 ok). **NFR-16 non rispettato:** 112 verdetti in anticipo ma 0 clic serviti dalla cache anticipata, 2 timeout al clic, costo per azione 0,87 s alla mediana e 0,93 s al 90°. Il Motore clicca prima che la coda arrivi al controllo giusto. Resta in review: serve una decisione con Nico (§32).

## Spec Change Log

## Review Triage Log

| # | Fonte | Rilievo | Verdetto | Evidenza / esito |
|---|---|---|---|---|
| 1 | blind, edge | clic su un altro controllo durante un giudizio anticipato: due giudizi insieme, timeout del clic, azione esterna senza conferma | high | l'anticipo toglierebbe una conferma (vietato) → patch (precedenza al clic) |
| 2 | blind | giudizio in corso finito senza verdetto valido usato al clic; `left <= 0` dà timeout con verdetto pronto | medium | → patch |
| 3 | blind, verifica, edge | tetto di 12 prima del filtro sulla cache | medium | oltre i 12 più vicini nulla è mai anticipato → patch |
| 4 | blind | lettura del fuoco in ogni `scan`, anche senza anticipo | medium | costo fisso nuovo in `observe` (FR-44) → patch |
| 5 | edge | coda che continua dopo cambio di livello o secondo strato spento | low | → patch |
| 6 | blind, edge | passaggio a un altro Motore cloud: coda annullata e non riavviata | low | → patch |
| 7 | blind | `[unowned self]` in un Task che può sopravvivere | medium | possibile crash → patch |
| 8 | blind, edge | contatori del Banco sul compito sbagliato, `costs` svuotato, mancano `misses` e `cancelled`, chiavi anticipate contate per sempre | low | → patch |
| 9 | blind | test con soglie di tempo strette dentro `build-app.sh` | medium | build bloccato su un Mac carico → patch |
| 10 | verifica | `anticipationCandidates` senza test | medium | → patch (funzione pura + selftest) |
| 11 | verifica | collegamento di `anticipationAllowed` in `AgentRunner` senza test | medium | → patch (`--fallback-test`) |
| 12 | verifica | regola «la coda aspetta il clic» senza test | medium | → patch |
| 13 | blind | ruoli premibili senza effetto esterno occupano posti | low | un `AXMenuButton` può avere effetti → rifiutato |
| 14 | edge | NFR-16 ignora i timeout anticipati | low | → patch (stampati accanto al verdetto) |
