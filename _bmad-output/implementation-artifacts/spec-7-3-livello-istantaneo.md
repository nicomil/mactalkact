---
title: 'Storia 7.3 — Livello istantaneo per i comandi a un passo'
type: 'feature'
created: '2026-10-27'
status: 'done'
baseline_commit: 'b294d2232d687743c798bb42607be30dcfa7a953'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-7-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** I comandi semplici che la grammatica non conosce («apri la mail di Laura», «clicca Salva») passano dal livello rapido (Sonnet) e impiegano 6–7 s di mediana (ricerca §14). Il tempo è quasi tutto nel modello.

**Approach:** Un terzo livello dell'Agente, `.instant`, con Haiku 5.5 ed effort basso in una Sessione lunga propria, per le richieste a un passo con un bersaglio noto. Dopo la prima chiamata con effetti l'esecutore giudica l'esito con una regola. Al primo esito negativo, o alla seconda chiamata di strumento, interrompe il turno e riparte al livello rapido senza perdere ciò che è stato fatto.

## Boundaries & Constraints

**Always:**
- Decisione nel Router: richiesta a un passo (non complessa, al massimo 8 parole, senza «e»/virgole che legano due azioni) con bersaglio noto (`RouteHeuristics.hasKnownTarget`: app installata, elemento visibile, sito, voce della Memoria di conversazione) e Livello istantaneo attivo → `.agent(level: .instant)`.
- Solo per Claude. In Catena di riserva, o con il Motore scelto diverso da Claude, la richiesta usa `.fast`.
- Scalata: l'esecutore ammette una sola chiamata di strumento. Una chiamata con effetti che fallisce o riporta `nothing changed`, oppure una seconda chiamata qualsiasi, interrompe il turno con il messaggio di controllo `interrupt` della sessione (il processo resta vivo; senza sessione si chiude il processo). La richiesta riparte su `.fast` senza `tools.reset()`, con la richiesta, le azioni già eseguite con il loro esito e gli elementi attuali. `effectfulCalls`, conferme e id restano quelli già contati; nessuna Azione con effetti viene ripetuta.
- Log: «Agente: istantaneo → rapido, <motivo>».
- Impostazioni: interruttore (predefinito attivo), modello (predefinito `claude-haiku-5-5`) ed effort (predefinito `low`) del Livello istantaneo.

**Never:**
- Nessun Livello istantaneo per Codex o per il Motore locale.
- Nessun cambiamento alle conferme, al gate o alla Corsia locale.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Istantaneo riuscito | «clicca Salva», pulsante Salva visibile | `.instant`, una chiamata, esito con cambiamento, nessuna scalata | — |
| Nessun effetto | il clic riporta `nothing changed` | turno interrotto, riparte su `.fast` con «già fatto: click … → nothing changed» | — |
| Seconda chiamata | Haiku chiama `observe` dopo `click` | la seconda chiamata non viene eseguita, scalata | — |
| Bersaglio ignoto | «clicca Pippo», nessun Pippo | `.fast` | — |
| Richiesta lunga | «apri la mail e rispondi a Marco» | `.fast` o `.deep` come oggi | — |
| Codex scelto | richiesta a un passo, Motore Codex | `.fast` | — |
| Interruttore spento | «clicca Salva» | `.fast` | — |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/AgentEngine.swift:51` -- `AgentLevel` aggiunge `.instant`.
- `Sources/MacTalkAct/IntentClassifier.swift:200-235` -- `RouteHeuristics`: `isOneStep`, `hasKnownTarget(text, knownApp:, labels:, memory:)` puri.
- `Sources/MacTalkAct/IntentRouter.swift:4-25,240-250` -- `RouterState.knownTarget: (String) -> Bool` e `instantLevel`; `.agent(String, level: AgentLevel, reason:)`.
- `Sources/MacTalkAct/Coordinator.swift:164-185,582,832-890` -- riempie `knownTarget` (app con `executor.findApp`, siti, etichette visibili catturate solo quando serve, parole della memoria); passa il livello.
- `Sources/MacTalkAct/ClaudeEngine.swift` -- terzo `ClaudeCLI` per `.instant` con modello ed effort propri; `interrupt()`.
- `Sources/MacTalkAct/ClaudeCLI.swift` -- `interruptCurrent()`: `control_request` `interrupt` sulla sessione, altrimenti `terminate`.
- `Sources/MacTalkAct/AgentTools.swift:240-300` -- `instantGuard`: regola di scalata in `call`, `onEscalate`, registro delle chiamate fatte.
- `Sources/MacTalkAct/AgentRunner.swift:290-380` -- livello effettivo, scalata con `engine.cancel`/interrupt, nuova richiesta `.fast` con azioni fatte e elementi attuali; `lastEscalation` per il Banco.
- `Sources/MacTalkAct/Settings.swift`, `SettingsWindow.swift` -- `instantLevel`, `instantModel`, `instantEffort`.
- `Sources/MacTalkAct/DebugCLI.swift` -- test puri; Banco con colonne `livello_usato` e `scalata`.

## Tasks & Acceptance

**Execution:**
- [x] `AgentEngine.swift`, `IntentClassifier.swift`, `IntentRouter.swift` -- livello, euristiche, decisione.
- [x] `ClaudeCLI.swift`, `ClaudeEngine.swift` -- terzo livello e interruzione del turno.
- [x] `AgentTools.swift`, `AgentRunner.swift` -- regola di scalata e ripartenza.
- [x] `Coordinator.swift` -- bersaglio noto e livello.
- [x] `Settings.swift`, `SettingsWindow.swift` -- impostazioni.
- [x] `DebugCLI.swift` -- `--selftest` (euristiche, regola di scalata), `--fallback-test` (scalata con Motore finto, interrupt col claude finto), Banco con livello e scalata.
- [x] `Tests/corpus/instradamento.tsv` -- righe nuove per `.instant` (convenzione: ogni regola nuova del Router aggiunge righe al Corpus).
- [x] ricerca -- Banco con il Livello istantaneo: compiti a un passo senza scalata, costo della scalata, confronto con il rapido.

**Acceptance Criteria:**
- Given il Banco con Claude, when lo eseguo con il Livello istantaneo, then la ricerca riporta quota dei compiti a un passo senza scalata (obiettivo ≥ 70%), costo di una scalata (obiettivo ≤ 1 s) e compiti falliti rispetto al rapido.
- Given `--selftest`, `--fallback-test` e `--route-test`, when girano, then passano.

## Design Notes

Spike del 27/10: con `{"type":"control_request","request":{"subtype":"interrupt"}}` la CLI chiude il turno in corso (`result` con `error_during_execution`) e la sessione resta viva. Il messaggio seguente risponde in 0,9 s. Così la scalata non uccide la Sessione lunga del Livello istantaneo, che si avvia solo alla prima richiesta.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest`, `--fallback-test`, `--route-test` -- expected: nessun FAIL
- `.build/debug/MacTalkAct --agent-bench --engine claude` -- expected: colonne livello e scalata (agisce sullo schermo)

## Implementation Notes

- Spec approvata in autonomia (Nico: «committa e procedi»).
- Implementazione diretta (commit `c62ff37` e successivo).
  - `ClaudeCLI.interruptCurrent` (control_request interrupt) con sessione tenuta viva dopo l'interruzione voluta.
  - Regola `AgentTools.instantFailure` più `instantGaveUp`.
  - Ripartenza in `AgentRunner` con `<already_done>` ed elementi attuali.
  - Avviso `<instant>` (una sola chiamata, più azioni in un `act`).
- «clicca X» resta alla grammatica (Comando rapido), che viene prima dell'Agente; il Corpus lo registra.
- «mail»/«messaggio» rendono «complessa» una frase per la scelta del modello, ma non ne fanno più passi: `isOneStep` ha i suoi segni di più passi.
- Regola aggiunta dopo il Banco: scalata anche se il turno istantaneo finisce senza azioni con effetti o con una risposta che ammette di non esserci riuscito. Senza, Haiku si arrendeva dentro la sua chiamata (4 fallimenti su 16).
- Dopo la review (giro 4): 77% senza scalata, 12/13 riusciti, scalata 4,7 s di mediana (obiettivo ≤ 1 s non raggiunto), un fallimento per Invio non chiesto (tocca all'Epic 9).
- Esito dei criteri prima della review (ricerca §15): 69% senza scalata; scalata da 1,8 a 6,5 s (obiettivo ≤ 1 s, non raggiunto); 1 fallimento contro 0 del rapido (non raggiunto); mediana 4,4 s contro circa 7 s.

## Spec Change Log

## Review Triage Log

Prima review (3 revisori). Nessun rilievo di intento o di spec; patch salvo tre rinvii.

| Rilievo | Verdetto | Evidenza / esito |
|---|---|---|
| La regola «nessun effetto» guarda il risultato prima che ci sia l'esito; `act` mai giudicato | high | `instantFailure` girava prima di `outcome()`. Patch: controllo dopo l'esito, anche per `act`; il già fatto riporta la riga `RESULT` |
| Ogni scalata riavvia due volte la sessione rapida (generazione −1) | medium | `SessionPolicy` vedeva «memoria azzerata». Patch: istantanea vera della memoria, messaggio delta col già fatto |
| Dopo un annullamento il rapido può partire; nessun controllo di scadenza dopo una scalata | medium | Patch: controllo di `cancelled` in tutti i rami e in cima al ciclo, insieme al tempo rimasto del turno |
| Interrupt senza `result`: attesa fino a 240 s | medium | Patch: processo chiuso dopo 3 s se il turno non si chiude |
| Cursore della sessione istantanea avanzato dopo un'interruzione | low | L'esito arriva dal rapido. Patch: cursore fermo, la voce viene mandata la volta dopo |
| Ripetizione della sessione morta e ripiego senza login rieseguono l'istantaneo durante una scalata | medium | Patch: nessuna ripetizione con una scalata in corso |
| `instant` insieme a `deep` porta Haiku su un compito «medio» | medium | Il Banco li passava insieme. Patch: `instant && !deep` |
| Errore di Haiku (modello assente, rete) trattato come guasto di Claude | medium | Patch: scalata a Claude rapido, salvo il limite d'uso (che vale per tutto l'abbonamento) |
| `isOneStep` su sottostringhe («ricerca», «sogni»), congiunzioni mancanti | medium | Patch: parole intere, «ed/quindi/dopo/oppure/infine/o», punteggiatura |
| `hasKnownTarget` troppo largo: memoria con le risposte dell'Agente, verbi non esclusi | medium | Patch: dalla memoria solo le richieste, più verbi esclusi; memoria letta solo quando serve |
| Resa letta su tutta la risposta («Fatto. Vuoi che…?»), frasi mancanti | medium | Patch: solo la prima frase, elenco ampliato, «vuoi che»/«dimmi se» tolti |
| Istantaneo mai riscaldato con la Sessione lunga spenta | low | Patch: prewarm anche dell'istantaneo |
| Colonna `livello_usato` con due vocabolari; livello iniziale perso; costo della scalata non calcolato | low | Patch: «istantaneo», «istantaneo→rapido», «rapido», «profondo»; `firstLevel`; mediana del costo |
| Test che dipendono dall'Accessibilità (`menu`) e dall'impostazione dell'utente | low | Patch: `observe`, impostazione salvata e rimessa |
| Nessun test per «nessuna azione», errore dopo l'interrupt, azione fallita, `interruptCurrent`, mappa dei livelli | gap | Patch: Motore finto in tre modi, «ASPETTA» nel claude finto, `ClaudeEngine.effective` puro |
| Didascalia: solo con Claude | low | Patch |
| Collegamento Coordinator → `agent.run(instant:)` senza test | gap | Rinviato: nessuna impalcatura per il Coordinator |
| Interrupt in ritardo che colpisce il turno dopo | maybe-false | Rinviato: va provato con la CLI vera, servirebbe attendere il `control_response` |
| Schermo letto due volte sul percorso istantaneo | low | Rinviato: va misurato prima (fase scansione) |
| Domini detti a voce («repubblica.it») | low | Respinto: raro, resta il rapido |
| Frasi spurie del Banco senza istantaneo | false | Voluto: le Frasi spurie misurano il Router, l'Epic 8 le filtra |
| Interruttore spento a metà turno | low | Respinto: caso raro, il turno resta coerente |
