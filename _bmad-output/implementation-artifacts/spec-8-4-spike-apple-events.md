---
title: 'Storia 8.4 — Spike: le azioni dirette via Apple Events reggono su macOS 27?'
type: 'chore'
created: '2026-10-27'
status: 'done'
baseline_commit: 'fc4cc75387a948d8c0a57d4dc960a2ecb89b0896'
route: 'dispatch'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Non si sa se Mail, Calendario, Safari, Finder e i browser Chromium rispondono in tempo via Apple Events su macOS 27.

**Approach:** Un comando di debug esegue cinque azioni con 3 s al massimo ciascuna e registra tempo, errore, consenso Automazione e versione dell'app. I risultati vanno nella ricerca; la decisione è del ciclo seguente.

## Boundaries & Constraints

**Always:** nessuno strumento dell'Agente (AD-20); niente `do shell script` né `execute javascript`; consenso letto senza finestre (`askUserIfNeeded = false`); nessun invio senza conferma.

**Never:** nessuna integrazione in questo ciclo.

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/AppleEventsSpike.swift` -- nuovo: azioni, consenso, tempo.
- `Sources/MacTalkAct/main.swift` -- `--apple-events-spike`.

## Tasks & Acceptance

**Execution:**
- [x] `AppleEventsSpike.swift`, `main.swift` -- comando.
- [x] ricerca -- §21.

**Acceptance Criteria:**
- Given `--apple-events-spike`, when gira, then stampa per ogni azione app, versione, consenso, tempo ed errore, senza chiedere permessi.

## Implementation Notes

- Spec approvata in autonomia (Nico: «committa e procedi»). La misura è parziale: senza Nico al Mac non si possono dare i consensi né aprire Calendario e Mail. Da rilanciare con Nico presente.

## Spec Change Log

## Review Triage Log

| Rilievo | Verdetto | Evidenza / esito |
|---|---|---|
| Manca `NSAppleEventsUsageDescription`: dal bundle il consenso sarebbe negato senza chiedere | high | Patch: voce aggiunta a `Resources/Info.plist` |
| Il report non dice a chi va il consenso | medium | Patch: «binario lanciato dal terminale» o «app <bundle>» |
| App installate ma chiuse saltate in silenzio | medium | Patch: `--avvia` apre Calendario e Mail in secondo piano prima di leggere il consenso |
| Tracce rimaste se lo script si interrompe (evento, bozza, scheda) | medium | Patch: `try … on error` che cancella; bozza chiusa con `close … saving no` |
| Tempo con compilazione e `delay 0.5`; tetto di 3 s per evento, non per azione | low | Patch: `delay` tolto, «entro 3 s / oltre» dichiarato, −1712 riconosciuto; la compilazione resta, detta nel commento |
| `NSAppleScript` fuori dal main thread; script nullo contato come riuscito | low | Patch: main thread, «script non valido» |
| Nomi delle app localizzati | low | Patch: `tell application id` ovunque |
| Nessuna prova del risultato | low | Patch: il valore restituito dallo script entra nel report |
| Percorsi relativi non controllati | low | Patch: controllo con messaggio chiaro |
| Report solo su stdout; flag non documentato | low | Patch: file in `~/Library/Logs`, righe nel README |
| Mappa consenso → azione senza test | gap | Patch: funzioni pure `mayRun`, `consentLabel`, `askUser` fissato a falso, in `--selftest` |
| Finestra del Finder lasciata aperta da `reveal` | low | Respinto: è l'effetto dell'azione misurata |
| Codice d'uscita sempre 0 | low | Respinto: spike di sola misura |
