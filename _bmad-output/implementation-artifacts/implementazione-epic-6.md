---
title: Implementazione Epic 6 — Mani da computer use
date: 2026-10-27
epics: [epic-6]
---

# Implementazione Epic 6

Riferimenti: ricerca `computer-use-claude-codex-2026-10-27.md` (studio di Claude e Codex e risultati, §8), AD-19 e AD-20.

| Storia | Realizzazione |
| --- | --- |
| 6.1 Banco esteso | Pagine `kanban.html` (trascinamento con eventi del puntatore, senza alternativa da tastiera), `menu.html` (voci che compaiono solo passando sopra), `cursore.html`, `iscrizione.html` (sei campi), `etichetta.html` (numero d'ordine solo nella foto). Cinque compiti nuovi in `agente.tsv`. Il Banco chiude le proprie pagine anche quando Safari chiede conferma (`closeBenchPages`, `--bench-cleanup`). |
| 6.2 Esito e id stabili | `AgentTools`: registro per `CFEqual` (`id(for:)`), `resolve` che riconosce gli elementi spariti, `scan`/`render` al posto di `observe` monolitico, `settle()` (firma di app, titolo, fogli, focus e pagina; `AXLoadingProgress`), `outcome()` con differenze di titolo, focus, selezione ed elementi (al massimo 25 righe, oppure l'inizio della nuova vista se cambia tutto). L'esito si aggiunge in `call()` per gli strumenti che agiscono. |
| 6.3 Mani complete | `set_value` (con ripiego Incrementa/Decrementa), `select_text` (prefisso/suffisso, cursore prima/dopo), `perform_action`, `drag`, `hover`, `menu` (`AppMenu.swift`), `click` con `modifiers`, `count`, `middle`; `screenshot` con `region` a piena risoluzione Retina. `observe` aggiunge `value=`, `settable`, `actions=`. `Executor`: `moveMouse`, `drag`, clic con modificatori espliciti, eventi marcati. |
| 6.4 Azioni in serie | `act`: ogni passo passa da `perform` (stessi controlli: permesso, app cambiata, conferme), si ferma al primo errore, un solo esito alla fine; ogni passo conta per il limite di chiamate. |
| 6.5 Esc e disciplina | `EscapeMonitor` attivo solo mentre l'Agente lavora; ignora gli Esc marcati (`eventSourceUserData`) e quelli entro 0,5 s da un Esc dell'Agente. Prompt di sistema: regole di persistenza e verifica, uso dell'esito, `act`, le mani nuove, tassonomia breve delle conferme. |
| 6.6 Misura finale | Tabella prima/dopo nella ricerca, §8. In più: elementi con id già nella richiesta per i Motori cloud (`initialObservation`, blocco `<elements>`), uso dei token di Codex nel log. README aggiornato. |

## Verifica

| Verifica | Risultato |
| --- | --- |
| `--hands-test` | tutte le mani senza modello: id stabili, hover, clic con esito, «nothing changed», drag, slider, `act` su tre campi, `select_text`, stop al primo errore, menu di Safari, zoom; Esc dell'Agente ignorato (l'Esc dell'utente non è verificabile da riga di comando: serve il permesso Monitoraggio input del terminale) |
| `--selftest`, `--fallback-test` | tutto ok |
| `--route-test` | 115/116, nessuna scrittura indebita; «No aspetta, quella sotto» decisa *Ignora* dal classificatore Apple (codice del Router invariato in questa epic) |
| Banco | Claude 25/25, Codex 24/25, modello Apple 17/20 sui compiti originali (ricerca, §8) |

## Scostamenti

- **Elementi nella richiesta**, non previsti nelle storie: aggiunti nella 6.6 perché quasi tutti i compiti cominciavano con un `observe`; emendamento di AD-19.
- **Il Motore locale non riceve l'esito** delle azioni: il suo ciclo a piano osserva da solo e l'esito aggiungerebbe solo tempo.
- **NFR-11 per Codex** rispettato solo nelle chiamate (−49%), non nel tempo: dipende dal carico del servizio (ricerca, §8).
- **Lavoro in background** (input a finestre non in primo piano, app nascoste) rinviato: chi usa la voce guarda l'app in primo piano.
