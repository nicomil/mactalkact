- source_spec: `_bmad-output/implementation-artifacts/spec-7-1-riga-di-base-banco-per-fasi.md`
  summary: Verificare che `--agent-bench` da binario `.build/debug` ottenga l'accesso al Calendario (EventKit) e l'Automazione verso Mail; altrimenti aggiungere un Info.plist incorporato con NSCalendarsFullAccessUsageDescription e NSAppleEventsUsageDescription.
  evidence: maybe-false (medium se vero) — si chiarisce lanciando `--only calendario-evento,mail-bozza` con Nico davanti al Mac.
- source_spec: `_bmad-output/implementation-artifacts/spec-7-2-sessione-lunga-e-cli-sotto-controllo.md`
  summary: Test di `ConversationLog.expire()` che fa crescere la generazione (e riavvia la Sessione lunga), con un orologio iniettabile.
  evidence: oggi nessun test chiama `expire()`; tornare a `entries.removeAll()` passerebbe inosservato. Naturale con la Storia 9.2, che tocca l'orologio.
- source_spec: `_bmad-output/implementation-artifacts/spec-7-2-sessione-lunga-e-cli-sotto-controllo.md`
  summary: Valutare un tetto della Sessione lunga sui token letti dalla cache (in media 42 mila per turno nel Banco) o un `sessionMaxRequests` più basso.
  evidence: ricerca §14; il guadagno di velocità è piccolo e la storia accumulata cresce fino al riavvio.
- source_spec: `_bmad-output/implementation-artifacts/spec-7-3-livello-istantaneo.md`
  summary: Ridurre il costo della scalata del Livello istantaneo (mediana 4,7 s, obiettivo ≤ 1 s): interrompere al primo segnale, o partire in parallelo col rapido.
  evidence: ricerca §15, giro 4.
- source_spec: `_bmad-output/implementation-artifacts/spec-7-3-livello-istantaneo.md`
  summary: Test del collegamento Coordinator → `agent.run(instant:)`; verifica con la CLI vera di un interrupt arrivato dopo la fine del turno; misura della doppia lettura dello schermo sul percorso istantaneo.
  evidence: review della Storia 7.3 (rinvii).
- source_spec: `_bmad-output/implementation-artifacts/spec-7-4-osservazione-a-costo-fisso.md`
  summary: Verificare l'attesa dell'albero su Chromium/Electron con un browser Chromium nel Banco, e misurare il costo fisso sulla webmail di prova (`MACTALK_BENCH_WEBMAIL`).
  evidence: review della Storia 7.4; la pagina sintetica non riproduce il costo di una webmail vera.
- source_spec: `_bmad-output/implementation-artifacts/spec-8-1-frasi-spurie.md`
  summary: Test del Coordinator per `.askIntent` (HUD, niente finestra, niente riavvio della sessione) e conteggio delle parole con apostrofo nella regola delle tre parole.
  evidence: review della Storia 8.1 (rinvii).
- source_spec: `_bmad-output/implementation-artifacts/spec-8-3-lettura-locale-del-testo.md`
  summary: Valutare `read_text` per il Motore locale (modalità piano) e un controllo automatico delle posizioni di `read_text` contro quelle di `observe`.
  evidence: review della Storia 8.3 (rinvii).
- source_spec: `_bmad-output/implementation-artifacts/spec-9-1-server-degli-strumenti-chiuso.md`
  summary: Prova NFR-14 con un `AGENTS.md` di stile ostile per Codex, in un `CODEX_HOME` separato con il login (senza toccare quello di Nico).
  evidence: `~/.codex/AGENTS.md` di Nico esiste (vuoto); la prova con il file reale non dimostra nulla sulle istruzioni di stile.
- source_spec: `_bmad-output/implementation-artifacts/spec-9-2-conferma-per-singola-azione.md`
  summary: `codex` finto per provare il timeout di Codex; controllo del campo a fuoco nel gate dell'Invio; sinonimi in `requestMentions`; `ActionOrigin` sulle chiamate dell'Executor e `PendingQuestion` nel Router (scostamenti dalla storia).
  evidence: review della Storia 9.2 e Implementation Notes della spec.

## Dalla review della Storia 9.4 (28/10/2026)

- Suite di sicurezza: lo stato si legge a fine turno; uno stato reversibile può tornare indietro prima della lettura. Servirebbe un registro degli eventi della pagina.
- Scenario di FR-50 (`AGENTS.md` di Codex con istruzioni di prova): serve `CODEX_HOME` separato, con Nico presente.
- Trascinamento nell'area vuota di una finestra Finder «Cestino»: nessuna etichetta, solo il titolo della finestra.
- `isRiskyLabel(request)` nel filtro preliminare del Motore locale ora vale anche per «prenota», «disconnetti»: il gate resta, ma il filtro si allenta.
- `--hands-test`: «azione senza effetti» (press_keys shift) fallisce circa una volta su tre; precedente alla 9.4.

## Dalla review della Storia 9.5 (28/10/2026)

- Decisione di Nico: SM-C7 non rispettato (circa 0,9 s per clic su pulsanti non rischiosi, un timeout su tre sotto carico). Opzioni: budget più alto, secondo strato spento per default, o accettare il costo.
- Secondo strato e clic per coordinate: il punto può cambiare durante il giudizio; le regole fisse ricontrollano al clic.
- FoundationModels dentro l'app (LSUIElement, in background mentre l'agente lavora): rate limit e concorrenza col Motore locale da misurare nell'app vera.
- La Corsia locale non passa dal secondo strato (manca `ActionOrigin`).
