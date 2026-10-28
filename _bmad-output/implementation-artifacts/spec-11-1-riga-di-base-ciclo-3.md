---
title: 'Storia 11.1 — Riga di base del ciclo 3 e CLI riverificate'
type: 'feature'
created: '2026-10-28'
status: 'done'
baseline_commit: '9f7d8d28a49e5fc7cbba1945638ff91540d6860f'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Le storie del ciclo 3 vanno giudicate su numeri confrontabili, ma il Banco usa ancora le soglie di NFR-12 del 27/10 (primo strumento ≤ 1,5 s) e non misura la prima reazione visibile né il primo token sulla webmail; le versioni delle CLI vanno rilette entro il 1° novembre 2026.

**Approach:** Il Banco adotta NFR-12 rivista (primo strumento ≤ 2,0 s, compito ≤ 4,5 s, istantaneo ≤ 2,5 s, prima risposta visibile ≤ 0,5 s, primo token sulla webmail ≤ 4 s), registra la «prima risposta visibile» per compito e la riporta nel riepilogo e nel TSV; l'app scrive nel log la stessa misura nell'uso vero. Si riverificano `claude` e `codex` contro le minime di AD-14, si esegue il Banco con Claude e si scrive la riga di base nella ricerca (§28).

## Boundaries & Constraints

**Always:** esito dichiarato per ogni soglia anche quando non è rispettata; la «prima risposta visibile» non entra nella somma delle fasi (resta somma = totale); il log dell'app non contiene testo della Frase per questa misura.

**Never:** nessun cambiamento al comportamento dell'Agente o del Router; nessun compito su Calendario, Mail o webmail senza Nico presente (restano «saltato» o esclusi con `--only`, come nella Storia 7.5).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Prima risposta nell'app | Frase consegnata dal riconoscimento, decisione del Router, primo `hud.show` dopo la decisione | riga `Prima risposta visibile: N ms · <decisione>` | decisione `ignora`: nessuna riga |
| Prima risposta nel Banco | ogni compito | tempo del Router sulla richiesta (misurato fuori dall'orologio dei compiti non-frase) | compito saltato: colonna vuota |
| Soglia webmail | nessun compito webmail eseguito | «primo token sulla webmail: non misurata» | — |
| Altro Motore | `--engine codex` | tutte le soglie «non applicabile» | — |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/DebugCLI.swift` -- `nfr12Verdicts` (riga ~1771): soglie da aggiornare e due nuove (prima risposta, primo token webmail); selftest «Soglie NFR-12» (riga ~263); `agentBench` (riga ~2227): `Row`, stampa per compito, riepilogo, TSV e file `.soglie.txt`.
- `Sources/MacTalkAct/Coordinator.swift` -- `handle(_:addressed:)` (riga ~489): `started` prima di `router.decide`; qui parte la misura della prima risposta.
- `Sources/MacTalkAct/HUD.swift` -- `HUDController.show`: punto unico in cui l'HUD cambia; aggiungere un aggancio per il primo `show` dopo la decisione.
- `Sources/MacTalkAct/ClaudeCLI.swift` (`minimumForSession`), `CodexCLI.swift` (`minimumVersion`) -- minime di AD-14, invariate se le versioni installate le superano.
- ricerca `technical-agente-precisione-velocita-e-strumenti-2026-10-27/research.md` -- nuovo §28.

## Tasks & Acceptance

**Execution:**
- [x] `Sources/MacTalkAct/HUD.swift` -- callback facoltativo `onFirstShow` consumato al primo `show` -- un solo punto di misura.
- [x] `Sources/MacTalkAct/Coordinator.swift` -- in `handle` armare la misura dopo la decisione (non per `.ignore`) e loggare `Prima risposta visibile: N ms · <etichetta>`.
- [x] `Sources/MacTalkAct/DebugCLI.swift` -- soglie rivista in `nfr12Verdicts` con prima risposta e primo token webmail; nel Banco misurare il Router su ogni compito (fuori dall'orologio per i compiti non-frase), colonna `prima_risposta_s`, riga per compito e mediana nel riepilogo; selftest aggiornati, più controlli per ogni riga della matrice (misura consumata al primo `show`, nessuna misura per `ignora`, webmail «non misurata», altro Motore «non applicabile»): la logica della misura sta in un piccolo tipo puro testabile senza HUD.
- [x] ricerca -- §28 con versioni CLI, esito di `--session-test`, riga di base e tabella.

**Acceptance Criteria:**
- Given `--selftest`, when finisce, then i controlli delle soglie usano 2,0 s per il primo strumento e coprono prima risposta e primo token webmail.
- Given `--agent-bench --engine claude`, when finisce, then stampa cinque soglie con esito e la mediana della prima risposta visibile, e il TSV ha la colonna `prima_risposta_s`.
- Given `claude --version` e `codex --version`, when confrontate con le minime, then il §28 annota versioni, esito e prova della Sessione lunga con `--session-test`.

## Design Notes

Nell'app la «fine della Frase» è il momento in cui il riconoscimento consegna il testo a `handle`; la prima risposta è il primo `hud.show` dopo la decisione del Router (l'eco del testo ascoltato in `pttUp` viene prima e non conta). Nel Banco non c'è HUD: subito dopo la decisione l'app mostra «Ci penso…», quindi la prima risposta coincide con il tempo del Router.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` -- expected: Build complete
- `.build/debug/MacTalkAct --selftest` -- expected: Tutto ok.
- `.build/debug/MacTalkAct --session-test` -- expected: due risposte dalla Sessione lunga
- `.build/debug/MacTalkAct --agent-bench Tests/bench/agente.tsv --engine claude --only <tutti tranne calendario-evento, mail-bozza>` -- expected: riepilogo con cinque soglie

## Implementation Notes

- Spec approvata in autonomia (Nico, 28/10: «builda tutto fin quando non finiscono»).
- Il primo token sulla webmail richiede un dato che il Banco non aveva: `PhaseTimer.firstTokenAt` (`AgentEngine.swift`) e `AgentRunner.lastFirstTokenAt`, solo misura, nessun cambio di comportamento. Colonna in più nel TSV: `primo_token_webmail_s`.
- Nel Banco la mediana della prima risposta visibile è su tutti i compiti eseguiti, Frasi spurie comprese (la matrice dice «ogni compito»).
- Riga di base: `~/Library/Logs/MacTalkAct-bench-2026-10-28-1240-claude.tsv`, ricerca §28. Webmail esclusa (variabile non impostata), Calendario e Mail esclusi.

## Spec Change Log

## Review Triage Log

| # | Fonte | Rilievo | Verdetto | Evidenza / esito |
|---|---|---|---|---|
| 1 | blind, edge | misura armata resta tale se la decisione non mostra l'HUD; `guard !busy` non disarma | medium | `.confirmation` senza `pending` e `.number` tornano senza `show`: la riga successiva avrebbe tempo ed etichetta sbagliati → patch |
| 2 | blind, edge, verifica | `started` preso dopo l'attesa in `routeChain` | low | il commento dice «dalla consegna del riconoscimento»; correzione diretta → patch |
| 3 | edge | `update`/`hide` non misurati | false | `update` serve solo alla trascrizione dal vivo; la risposta a una decisione passa sempre da `show` |
| 4 | blind, edge | `firstTokenAt` del primo tentativo resta se il secondo fallisce prima del primo token | medium | `PhaseTimer` lo sovrascrive solo al nuovo primo token → patch con selftest |
| 5 | edge, verifica | nel Banco le Frasi spurie ignorate contano nella prima risposta, nell'app no | false | la matrice approvata dice «ogni compito»; il §28 lo dichiara |
| 6 | edge | webmail fallita conta nel primo token | false | il primo token è arrivato davvero; l'esito del compito è un'altra misura |
| 7 | verifica | `lastFirstTokenAt` mai controllato attraverso `AgentRunner` | medium | `--fallback-test` non lo legge → patch |
| 8 | verifica, blind | collegamento HUD/Coordinator senza test | medium (non verificato a schermo) | serve un `NSPanel` vivo nel selftest → defer |
| 9 | blind | primo token webmail misurato da `agent.run`, non dalla Frase | low | NFR-12 non fissa l'inizio; dichiarato nel §28 → patch (testo) |
| 10 | blind | `router.decide` in più prima di ogni compito: condizione del Banco cambiata, non dichiarata | medium | può scaldare o contendere il modello Apple → patch (§28) |
| 11 | blind | spiegazione del +2,5 s nel §28 non torna (+1,4–1,5 s dalle fasi) | medium | → patch (§28) |
| 12 | blind | verdetto sulla mediana nasconde il 43% oltre 0,5 s | false | NFR-12 è una mediana; il 90° percentile è già stampato e nel §28 |
| 13 | blind | Router in due configurazioni diverse nella mediana | low | rifiutato: differenza voluta (Frasi spurie in ascolto continuo, come nell'app) |
| 14 | blind | «fase nuova» dell'epic diventa misura fuori dalla somma | false | la spec approvata (Always) lo impone |
| 15 | blind | nessun seguito per webmail, Calendario e Mail | medium | serve Nico presente → defer |
| 16 | blind | doppia cattura delle etichette nel Banco | low | correzione diretta (una cattura) → patch |
| 17 | blind | colonne TSV in mezzo e README non aggiornato | low | ordine delle colonne: rifiutato (già cambiato in passato, confronto per nome); README → patch |
