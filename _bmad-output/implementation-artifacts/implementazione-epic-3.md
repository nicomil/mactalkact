---
title: Implementazione Epic 3 — Tutto sotto controllo dalle impostazioni
date: 2026-10-27
epics: [epic-3]
---

# Implementazione Epic 3

## Cosa è stato fatto

| Storia | Realizzazione |
| --- | --- |
| 3.1 Finestra a sezioni | `SettingsWindow.swift`: `NavigationSplitView` con barra laterale e 9 sezioni a schede, dimensione esplicita (880×620, minimo 760×520), posizione ricordata, ultima sezione ricordata. **Causa del bug:** il `Form` raggruppato dentro `NSHostingController` non ha un'altezza ideale, quindi la finestra si apriva alta zero e restava solo la barra del titolo. La finestra ora viene anche portata davanti a tutto, perché macOS può non attivare un'app che vive nella barra dei menu. |
| 3.2 Ascolto e conversazione | Silenzio di fine frase, soglia minima, rapporto sul rumore, durata massima, pausa e silenzio della dettatura lunga, chiusura della sessione; finestra di conversazione, attese (attivazione, «scrivilo», risposta all'agente, conferma), dimensione e durata della memoria di conversazione, pulsante «Svuota ora». Il rilevatore di voce riceve i valori con `AudioRouter.configure` a ogni modifica. |
| 3.3 Comprensione e agente | Interruttori del modello Apple e della corsia locale, tempo massimo del classificatore, frasi massime della corsia locale; accesso a Claude, percorso, chiave; modelli ed effort per i due livelli; passi, turni e tempo massimi; validità di una conferma; ripulitura della dettatura. Se cambia qualcosa che riguarda `claude`, il processo tenuto pronto viene sostituito. |
| 3.4 Voce, suoni e messaggi | Volume e velocità della voce, suoni sì/no e volume, durata dei messaggi di riuscita, risposta ed errore. |
| 3.5 Numeri, memoria, permessi, stato | Durata e numero massimo dei numeri; elenco di fatti e macro con eliminazione, file, ricarica; permessi aggiornati ogni 2 s con «Concedi…»; modello Apple, router, `claude`, agente, versione, log, cartella dei dati, guida. |
| 3.6 Menu della barra | Stato dell'agente e della comprensione (cliccabili), modalità di ascolto, «Impostazioni rapide» con 7 interruttori, durata della conversazione e modello per i compiti lunghi, sottomenu con tutte le sezioni, permessi mancanti, log. |

## Architettura

- **AD-11:** 45 proprietà in `AppSettings`; nessuna costante duplicata nel codice. I componenti leggono il valore quando serve; il rilevatore di voce (thread audio) viene aggiornato da `Coordinator.applyListeningSettings()`, chiamato all'avvio e a ogni modifica.
- **AD-12:** predefiniti in `AppSettings.Defaults`, verificati da `--selftest` contro le costanti precedenti; `reset(_:)` limitato alla sezione.

## Verifica

| Verifica | Risultato |
| --- | --- |
| `--selftest` | tutto ok, compresi: predefiniti uguali a prima, ripristino solo della sezione, rilevatore riconfigurato |
| `--route-test` | 116/116, 0 scritture indebite: nessun cambiamento di comportamento del Router |
| `--settings-shot` | 9 sezioni disegnate fuori schermo e controllate a vista |
| App vera | menu aperto con AppleScript: voci di stato, impostazioni rapide e sezioni presenti; «Apri le impostazioni…» apre una finestra 880×620 con contenuto visibile (catturata per identificativo di finestra); «Impostazioni › Agente» apre la sezione giusta; «Impostazioni rapide › Suoni» cambia subito il valore salvato (spento e poi riacceso) |

## Scostamenti

- Nessuna funzionalità nuova (NFR-6). Unica aggiunta tecnica: il comando di prova `--settings-shot`.
- Versione dell'app portata a 0.3.0 (3) per distinguere questa build nella sezione Stato.
