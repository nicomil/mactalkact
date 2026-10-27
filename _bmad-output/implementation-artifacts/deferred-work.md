- source_spec: `_bmad-output/implementation-artifacts/spec-7-1-riga-di-base-banco-per-fasi.md`
  summary: Verificare che `--agent-bench` da binario `.build/debug` ottenga l'accesso al Calendario (EventKit) e l'Automazione verso Mail; altrimenti aggiungere un Info.plist incorporato con NSCalendarsFullAccessUsageDescription e NSAppleEventsUsageDescription.
  evidence: maybe-false (medium se vero) — si chiarisce lanciando `--only calendario-evento,mail-bozza` con Nico davanti al Mac.
- source_spec: `_bmad-output/implementation-artifacts/spec-7-2-sessione-lunga-e-cli-sotto-controllo.md`
  summary: Test di `ConversationLog.expire()` che fa crescere la generazione (e riavvia la Sessione lunga), con un orologio iniettabile.
  evidence: oggi nessun test chiama `expire()`; tornare a `entries.removeAll()` passerebbe inosservato. Naturale con la Storia 9.2, che tocca l'orologio.
- source_spec: `_bmad-output/implementation-artifacts/spec-7-2-sessione-lunga-e-cli-sotto-controllo.md`
  summary: Valutare un tetto della Sessione lunga sui token letti dalla cache (in media 42 mila per turno nel Banco) o un `sessionMaxRequests` più basso.
  evidence: ricerca §14; il guadagno di velocità è piccolo e la storia accumulata cresce fino al riavvio.
