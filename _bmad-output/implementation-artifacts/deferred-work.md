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
- ~~Scenario di FR-50~~: fatto il 28/10 (canarino obbedito, ora blocco con approvazione per impronta).
- Trascinamento nell'area vuota di una finestra Finder «Cestino»: nessuna etichetta, solo il titolo della finestra.
- `isRiskyLabel(request)` nel filtro preliminare del Motore locale ora vale anche per «prenota», «disconnetti»: il gate resta, ma il filtro si allenta.
- ~~`--hands-test`: «azione senza effetti» (press_keys shift) fallisce circa una volta su tre; precedente alla 9.4.~~ Storia 10.1, 28/10: la prova ora confronta con una pagina ferma (due osservazioni uguali di fila prima del tasto).
- Esito delle azioni (AD-19): nell'uso vero i cambi di Accessibilità che arrivano tardi dopo un'azione possono finire nell'esito dell'azione successiva. Il `--hands-test` ora aspetta una pagina ferma, il prodotto no (`settle()` guarda solo titolo, fogli, fuoco e figli diretti dell'area web). Visto nella Storia 10.1.
- cmux (`com.cmuxterm.app`) è un terminale ma non è nell'elenco «solo clic» predefinito (visto nella Storia 10.1): decidere se aggiungerlo.

## Dalla review della Storia 9.5 (28/10/2026)

- ~~Decisione SM-C7~~: Nico, 28/10: acceso, budget 0,9 s, soglia della PRD aggiornata.
- Secondo strato e clic per coordinate: il punto può cambiare durante il giudizio; le regole fisse ricontrollano al clic.
- FoundationModels dentro l'app (LSUIElement, in background mentre l'agente lavora): rate limit e concorrenza col Motore locale da misurare nell'app vera.
- La Corsia locale non passa dal secondo strato (manca `ActionOrigin`).

## Dalle prove con Nico (28/10/2026, mattina)

- Webmail: primo token a 12,7 s su Gmail (scalata dall'istantaneo 6,1 s, avvio MCP 3,5 s).
- Mail via Apple Events: la ricerca su una casella da 45.915 messaggi richiede 3,43 s, oltre il limite di 3 s dello spike.
- FR-50: il controllo dell'`AGENTS.md` non copre istruzioni messe in altri file che Codex potrebbe leggere in versioni future; da ricontrollare quando cambia la versione di `codex`.

## Storia da pianificare nel prossimo ciclo (decisa da Nico il 28/10/2026)

- **AccessGate unico con ActionOrigin (AD-21, AD-22).** Oggi il gate, i livelli di accesso per app e il secondo strato vivono in `AgentTools`: la Corsia locale (comandi semplici senza agente) non ci passa. Costruire `AccessGate` con `ActionOrigin` (`.user`, `.model`) e `ConfirmationGrant`, usato da agente e Corsia locale, e spostare lì i controlli di 9.2, 9.3 e 9.5 senza cambiarne il comportamento (la suite di sicurezza e `--hands-test` sono la rete).

- source_spec: `_bmad-output/implementation-artifacts/spec-11-1-riga-di-base-ciclo-3.md`
  summary: Test del collegamento della «prima risposta visibile» nell'app (`HUDController.show` chiama `onFirstShow` una volta; il Coordinator lo toglie per `ignora`).
  evidence: i selftest coprono solo `FirstResponseMeter`; il collegamento richiede un `NSPanel` vivo. Da verificare a mano nel log durante l'uso.
- source_spec: `_bmad-output/implementation-artifacts/spec-11-1-riga-di-base-ciclo-3.md`
  summary: Riga di base con Nico presente: webmail (primo token ≤ 4 s), Calendario e Mail sul Banco del ciclo 3.
  evidence: senza `MACTALK_BENCH_WEBMAIL` e senza Nico la soglia webmail è «non misurata» (§28); serve prima della misura finale (Storia 11.6).

- source_spec: `_bmad-output/implementation-artifacts/spec-10-1-accessgate-unico.md`
  summary: Test deterministico del ciclo di rilettura di `set_value` sui cursori web (letture AX dietro un punto d'iniezione).
  evidence: oggi solo `--hands-test` lo esercita e il guasto originale compariva circa una volta su dieci.
