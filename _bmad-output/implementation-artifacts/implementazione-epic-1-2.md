---
title: Implementazione Epic 1 e 2 — MacTalkAct
date: 2026-10-26
epics: [epic-1, epic-2]
inputs:
  - _bmad-output/planning-artifacts/epics.md
  - _bmad-output/planning-artifacts/architecture/architecture-mactalkact-2026-10-26/ARCHITECTURE-SPINE.md
---

# Implementazione Epic 1 e 2

Questo documento riassume come sono state realizzate le 10 storie, come sono state verificate e dove l'implementazione si discosta dal piano. I commit sono nel repository git del progetto, creato all'inizio del lavoro.

## Nuovi file

| File | Contenuto | Storie |
| --- | --- | --- |
| `IntentRouter.swift` | `RouterState`, `RouteDecision`, `IntentRouter.decide`, frasi fisse della conversazione | 1.1, 1.3, 2.1, 2.3 |
| `IntentClassifier.swift` | Protocollo, `OnDeviceClassifier` (FoundationModels), `RuleClassifier`, regole di complessità | 1.2, 2.2 |
| `Conversation.swift` | `ConversationState`, `ConversationLog`, `InsertionJournal` | 1.3, 1.4, 1.5 |
| `LocalLane.swift` | `LocalAction`, `LocalActionProposer`, `LocalActionValidator` | 2.1 |
| `Tests/corpus/instradamento.tsv` | Corpus del Router: 116 frasi | 1.1, 1.2, 2.1, 2.3 |
| `Tests/corpus/instradamento-verifica.tsv` | 41 frasi scritte dopo la taratura, per controllare che il Router non sia adattato al solo Corpus | 1.2 |
| `Tests/pages/prova-strumenti.html` | Pagina locale con caselle, campo nativo e cella modificabile | 2.4, 2.5 |

File modificati: `Coordinator.swift` (esegue le decisioni del Router e non ha più euristiche proprie), `AgentRunner.swift` (due livelli di modello, disponibilità, blocco `<recent>`), `AgentTools.swift` (`click_many`, `replace_text`, id mai riusati, blocco se cambia l'app in primo piano, risposte vuote), `Executor.swift` (registro degli inserimenti, annullamento, sostituzione di testo), `Settings.swift`, `AppDelegate.swift`, `CommandGrammar.swift`, `DebugCLI.swift`, `main.swift`, `README.md`.

## Verifica

| Verifica | Risultato |
| --- | --- |
| `--selftest` (grammatica, router, corsia locale, limite della subscription) | tutto ok |
| `--route-test` sul Corpus, modello Apple | 115–116/116 (99–100%), **0 scritture indebite**; l'unico errore occasionale è «No aspetta, quella sotto» classificata come chiacchiera (ignorata, non scritta) |
| `--route-test` sul set di verifica (frasi nuove) | 40/41 (97,6%), 0 scritture indebite; l'errore è «Torna su» eseguito dalla corsia locale invece che dalla grammatica, con lo stesso effetto |
| `--route-test --rules` (senza modello Apple) | 107/116, 0 scritture indebite; nella finestra di conversazione i comandi senza verbo noto vengono ignorati, come previsto da NFR-3 |
| Tempi del Router (modello caldo) | dettatura ~0,7 s, decisioni «chiedi» ~0,6 s, corsia locale ~1,2 s, grammatica e frasi fisse 0 ms |
| `--tools-test` in Safari | `click_many`: 3 caselle su 3 spuntate e verificate; id vecchio rifiutato; `replace_text` riuscito e verificato nel campo nativo e nella cella, sia via Accessibilità sia con le sole vie da tastiera (`MTA_KEYBOARD_REPLACE=1`: «riga» e «campo intero») |
| `--converse-test`, agente vero, modello rapido (Sonnet 5.5) | «modifica la domanda…» 3,0 s e 1 chiamata, poi «rimetti la domanda di prima» 5,2 s e 1 chiamata: testo ripristinato grazie al blocco `<recent>` (la stessa modifica il 26/10 richiedeva 22,6 s e 7 passi, e falliva al primo tentativo) |
| Agente vero, compito delle caselle (UJ-4, modello profondo) | 4 chiamate in 10,1 s (il 26/10: 39 passi in 41,6 s); in un primo tentativo l'agente aveva cliccato le celle della tabella e se n'è accorto dallo stato restituito, che ora lo dice esplicitamente |
| Modello rapido su 5 richieste tipiche | 5/5 corrette, 5,6–13,8 s (spuntare, togliere la spunta, scrivere in un campo, annullare l'ultima modifica, andare in fondo) |

### Prove che restano manuali

- La Finestra di conversazione e l'indicatore «💬 Ti ascolto ancora» richiedono il microfono: vanno provati con l'app in ascolto continuo.
- `replace_text` in un vero notebook Jupyter non è stato provato (nessun Jupyter aperto sul Mac durante il lavoro); le vie da tastiera che servono in quei casi sono state provate sulla pagina di prova.
- La Modalità ridotta è verificata dal Corpus (stato `pausa`) e dai test sulla lettura dell'ora di ripresa, non da un limite reale.

## Scostamenti dal piano

1. **Timeout del classificatore 1,5 s invece di 1,0 s (AD-2).** A modello caldo la risposta arriva in circa 0,7 s; il margine serve per la prima frase dopo l'avvio.
2. **Complessità decisa da regole, non dal modello (AD-6, Storia 2.2).** Misurato: il modello Apple giudicava «semplice» ogni richiesta, e chiedergli tipo e complessità insieme peggiorava sia l'accuratezza (12/16 contro 14/16) sia il tempo (0,90 s contro 0,63 s).
3. **Corsia locale solo fuori dai campi di testo e per frasi di al massimo 6 parole.** Nei documenti le modifiche riguardano il significato e vanno all'agente. Il Validatore inoltre accetta «apri X» solo se X spiega tutta la frase, così «apri la prima mail» non diventa «apri Mail» e «cerca su YouTube una ninna nanna» non perde la ricerca.
4. **Id mai riusati invece di id con generazione esplicita (AD-8).** Stesso effetto, numeri più corti sugli screenshot.
5. **Nuova regola di sicurezza.** (vedi sotto)
6. **`observe` senza doppioni.** Safari raggiunge gli stessi elementi da più genitori: ora ogni elemento compare una volta sola, con meno token per l'agente.
7. **Chiacchiera durante una domanda dell'agente.** «ok», «bravo», «ciao amore» non vengono più passati come risposta.

Dettaglio della regola di sicurezza: Gli strumenti che agiscono si fermano se l'app in primo piano cambia senza che l'agente l'abbia aperta. È emersa durante i test: tornando al Mac a metà prova, alcuni tasti di selezione sono finiti nella finestra di cmux.
8. **Dettatura nella Finestra di conversazione ignorata.** Senza «computer», una frase classificata come dettatura non viene scritta: per dettare di seguito si usa «scrivi…».
9. **«Apri X» con X che non è un'app.** La grammatica fissa lo tratta come comando rapido solo se X è un'app installata o un sito noto; altrimenti decide il resto del Router (per esempio «apri una finestra privata» → corsia locale).

## Domande aperte per l'uso reale

- Durata della Finestra di conversazione (20 s): da tarare guardando nel log quante frasi vengono ignorate subito dopo.
- Precisione del modello rapido (Sonnet 5.5, effort basso) con gli strumenti di MacTalkAct: il log riporta ora il modello usato e la durata di ogni richiesta.
- Arricchire il Corpus con le frasi decise male nell'uso reale: ogni riga di log `Instradamento:` contiene decisione, motivo e tempo.
