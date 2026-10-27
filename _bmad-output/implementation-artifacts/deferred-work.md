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
