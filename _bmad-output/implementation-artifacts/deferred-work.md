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
