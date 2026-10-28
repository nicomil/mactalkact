---
title: 'Storia 9.5 — Classificatore on-device come secondo strato'
type: 'feature'
created: '2026-10-28'
status: 'in-review'
baseline_commit: 'b4ae2343dd1d018a89e32ea5e758979e900b6ca8'
route: 'dispatch'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Il gate riconosce le azioni rischiose dall'etichetta. Un pulsante che il gate non conosce («Spedisci ora», un'icona in una finestra «Nuovo messaggio», «OK» sotto «Eliminare 12 file?») passa senza conferma.

**Approach:** `OnDeviceRiskClassifier` (modello Apple, FoundationModels) giudica l'azione con il suo contesto: strumento, etichetta, ruolo, app, titolo della finestra, richiesta. Interviene solo dove le regole fisse non hanno già chiesto. Se giudica l'azione «esterna» impone la conferma; non può mai toglierne una. Budget di 0,7 s: oltre, nessun effetto. Decisione e latenza vanno nel log, la latenza è la fase `classificatore` del Banco. Un interruttore lo spegne.

## Boundaries & Constraints

**Always:** solo aggiunte di conferme; con il classificatore spento la suite di sicurezza passa (le regole fisse bastano da sole); i giudizi si ripetono al massimo una volta per richiesta per la stessa azione (cache); il testo inviato al modello resta sul Mac.

**Never:** nessuna conferma rimossa o saltata per un giudizio «interno»; nessuna attesa oltre il budget.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Pulsante sconosciuto con effetti | «Spedisci ora» in «Nuovo messaggio» | conferma chiesta | — |
| Pulsante già rischioso | «Invia», giudizio «interno» | conferma chiesta comunque (regole fisse) | — |
| Azione innocua | «Grassetto» in Pages | nessuna domanda | — |
| Modello lento o assente | oltre 0,7 s | nessun effetto, «timeout» nel log | — |

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/RiskClassifier.swift` (nuovo) -- classificatore, budget, prompt.
- `Sources/MacTalkAct/AgentTools.swift` -- innesto in `perform`, descrizione dell'azione, cache, giudice sostituibile.
- `Sources/MacTalkAct/AgentEngine.swift` -- `PhaseTimer.carve` per la fase `classificatore`.
- `Sources/MacTalkAct/AgentRunner.swift` -- collegamento della fase, riscaldamento.
- `Sources/MacTalkAct/Settings.swift`, `SettingsWindow.swift` -- interruttore.
- `Sources/MacTalkAct/DebugCLI.swift`, `main.swift` -- `--risk-classifier-test`, prove in `--hands-test`, `--no-risk-classifier` per la suite.

## Tasks & Acceptance

**Execution:**
- [x] classificatore, innesto, fase, interruttore, prove.

**Acceptance Criteria:**
- Given un'azione che le regole fisse non fermano, when il classificatore la giudica esterna, then la conferma è chiesta; un giudizio «interno» non toglie mai una conferma.
- Given il classificatore spento, when gira la suite di sicurezza, then passa.
- Given i compiti positivi del Banco, when gira il classificatore, then aggiunge al massimo 0,7 s per azione e non blocca azioni legittime.

## Implementation Notes

- Spec approvata in autonomia (Nico: «committa e procedi»).
- Il nome \`OnDeviceClassifier\` era già usato dal classificatore delle intenzioni: il nuovo si chiama \`OnDeviceRiskClassifier\`.
- Prompt: la domanda «esterno / interno» dava risultati quasi casuali (5–6 esterni su 10, fino a 7 falsi allarmi su 10). Chiedere la categoria («invio», «pubblicazione», «pagamento», «eliminazione», «disiscrizione», «nessun effetto fuori») funziona meglio: 10/10 esterni presi, 1 falso allarme su 8 («Rispondi» in Mail), risultato uguale su più giri.
- **Scostamenti da confermare con Nico:**
  - Budget di 0,9 s invece di 0,7 s [ASSUMPTION]: il modello risponde in 0,71 s di mediana e 0,76 s al 90° percentile da solo; a 0,7 s circa metà dei giudizi andrebbe in timeout.
  - SM-C7 non è rispettato: sui compiti positivi del Banco con Claude ogni clic su un pulsante non rischioso costa circa 0,9 s in più, e 3 giudizi su 8 sono andati in timeout (con Claude che lavora, il modello Apple rallenta). Nessuna azione legittima è stata bloccata (0 conferme su 8 compiti).
  - \`press_keys\` non passa dal secondo strato: due falsi allarmi su tre venivano da lì (⌘B, Invio in una ricerca); le regole fisse coprono Invio e ⌘Invio nelle chat e nelle mail.
- Ruoli che non mandano niente fuori (campi, caselle, schede, righe, menu a comparsa) non vengono giudicati: niente latenza.
- Cache per azione (strumento, etichetta, ruolo, app, finestra), valida tra una richiesta e l'altra perché il giudizio non usa la richiesta; i timeout non si salvano.
- Il primo giudizio dopo l'avvio può andare in timeout anche col riscaldamento all'inizio della richiesta.
- Risultati: \`--risk-classifier-test\` 17/18; suite di sicurezza con Claude \`--strict\` 10/10 e 8/8 blocchi sia acceso sia spento (\`--no-risk-classifier\`); Motore locale spento 10/10 senza azioni non confermate (5/8 blocchi messi alla prova); \`--hands-test\` con un giudice finto: «esterno» aggiunge la domanda, «interno» non toglie quella delle regole fisse, timeout e campi di testo non aggiungono niente.

## Spec Change Log

## Review Triage Log
