# Novità

## 0.3.1 (29 ottobre 2026)

Correzioni emerse dall'uso del primo giorno.

- **Cambiare desktop a voce.** Nuovi comandi rapidi: «cambia desktop», «desktop a destra», «desktop a sinistra», «vai al desktop di sinistra», «mission control». Funzionano con qualsiasi app davanti, anche un terminale.
- **Scorciatoie di sistema anche nelle app «solo clic».** L'agente può usare ⌃← ⌃→ ⌃↑ ⌃↓ (desktop e Mission Control) anche quando davanti c'è un terminale: le gestisce macOS e non scrivono niente nell'app. Invio e gli altri tasti restano bloccati.
- **Mission Control non resta aperto.** «chiudi mission control» o «torna normale» lo chiudono. Se l'agente lo apre e non finisce il compito, l'app lo richiude da sola. Con Mission Control aperto l'agente può premere Esc.
- **Permesso Accessibilità mancante.** Prima l'app diceva «✓» anche quando macOS scartava i tasti per mancanza del permesso. Ora la pillola dice che manca e dove concederlo.
- **Release.** `scripts/package-release.sh` prepara zip e DMG senza rifirmare l'app di chi sviluppa, che così mantiene i permessi.

## 0.3.0 «Ciclo 3» (29 ottobre 2026)

Il terzo ciclo ha chiuso i limiti della versione precedente su sicurezza e velocità dell'agente. I numeri completi sono nella ricerca (`_bmad-output/planning-artifacts/research/technical-agente-precisione-velocita-e-strumenti-2026-10-27/research.md`, §28–§39) e nella pagina `docs/come-funziona.html`.

**Sicurezza**
- Un solo cancello (`AccessGate`) decide per l'agente, per ogni motore e per la Corsia locale: livelli di accesso, campi password, «conferma ogni azione» e secondo controllo.
- La Corsia locale (le azioni brevi decise sul Mac) passa dallo stesso cancello. Se rifiuta lo dice: «In Terminal posso solo cliccare: fallo tu».
- Nuovo riquadro «App» in Impostazioni › Privacy: le app installate, con un menu per il livello di accesso e l'interruttore «Riservata».
- cmux è tra le app «solo clic».
- Il secondo controllo (modello Apple sul Mac) giudica in anticipo i pulsanti della finestra, ha un tempo massimo di 1,2 s, così un clic non passa più senza verdetto, e non giudica le cartelle di posta.

**Velocità**
- Sessione pronta all'ascolto: quando dici la parola di attivazione, Claude è già avviato e collegato agli strumenti (da 0,45 s a 0,07 s).
- Scalata più rapida: quando il livello istantaneo si arrende, il livello rapido riceve la richiesta in circa 0,05 s, con la stessa lettura dello schermo.
- Risposta scritta dall'app: quando l'ultima azione prova da sola il risultato, l'app risponde subito, senza aspettare un altro turno del modello. Non ripete mai il testo scritto, che potrebbe essere una password.
- Sul Banco di prova la mediana di un compito è scesa da 8,5 s a circa 4,5 s.

**Precisione**
- L'app riconosce meglio quando il livello istantaneo si arrende («non è ancora visibile», «dimmi di continuare»).
- L'app non dice «fatto» se il testo scritto non è più visibile, né se è in un campo da confermare con Invio, come il nome di un file nel Finder.

**Prove**
- `--mail-search-spike`: misura la ricerca in Mail via Apple Events (sotto il secondo sulla posta in arrivo degli ultimi 30 giorni). Non è ancora uno strumento dell'agente.
- `--risk-classifier-test --batch n`: prova il giudizio di più pulsanti con una domanda sola. È più veloce ma meno preciso, quindi non viene usato.
