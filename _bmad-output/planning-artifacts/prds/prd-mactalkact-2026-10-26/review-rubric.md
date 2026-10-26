# PRD Quality Review — MacTalkAct «Mi capisce al primo colpo»

Revisione eseguita in linea (senza subagenti) con `prd-validation-checklist.md`.

## Giudizio complessivo
Il PRD ha una tesi chiara e misurata sui dati reali: «affidabile prima che potente», con la causa del danno individuata nel codice e la leva tecnica già verificata sul Mac. Il rischio principale è la taratura di due valori presunti (Finestra di conversazione di 20 s, modello rapido Sonnet), entrambi dichiarati come domande aperte con un criterio di verifica.

## Decision-readiness — strong
Le alternative scartate sono in `addendum.md` con il motivo; le domande aperte sono davvero aperte e hanno un momento di verifica.

## Substance over theater — strong
Un solo utente reale, percorsi utente costruiti sulla sessione del 26/10, NFR con soglie numeriche.

## Strategic coherence — strong
Le 4 funzionalità discendono dalla tesi; le contro-metriche SM-C1 e SM-C2 impediscono di «vincere» SM-1 ignorando tutto o togliendo conferme.

## Done-ness clarity — adequate
### Findings
- **medium** FR-7 «indicatore discreto» (§4.2) — aspetto non definito. *Fix:* lasciato alla storia, criterio verificabile: indicatore visibile durante la finestra e assente dopo.
- **low** FR-16 (§4.4) — dipende dall'editor. *Fix:* la domanda aperta 3 delimita i casi; il criterio usa Jupyter in Edge, il caso reale.

## Scope discipline — strong
Non obiettivi espliciti, limiti minori del README esclusi per nome.

## Downstream usability — adequate
FR numerati e stabili; mancava «HUD» nel Glossario, ma è un termine già in uso nell'app e nel README: accettato.

## Mechanical notes
ID FR-1…FR-16 continui, UJ-1…UJ-4 citati nelle funzionalità, indice delle assunzioni allineato ai tag `[ASSUMPTION]`.
