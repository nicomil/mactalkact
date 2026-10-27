- source_spec: `_bmad-output/implementation-artifacts/spec-7-1-riga-di-base-banco-per-fasi.md`
  summary: Verificare che `--agent-bench` da binario `.build/debug` ottenga l'accesso al Calendario (EventKit) e l'Automazione verso Mail; altrimenti aggiungere un Info.plist incorporato con NSCalendarsFullAccessUsageDescription e NSAppleEventsUsageDescription.
  evidence: maybe-false (medium se vero) — si chiarisce lanciando `--only calendario-evento,mail-bozza` con Nico davanti al Mac.
