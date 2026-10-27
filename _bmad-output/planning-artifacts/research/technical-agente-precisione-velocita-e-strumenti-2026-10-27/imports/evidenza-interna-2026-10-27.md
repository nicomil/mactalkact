---
import: evidenza interna
dimension: 1 — Dove l'Agente perde tempo e precisione oggi
sources:
  - ~/Library/Logs/MacTalkAct-bench-2026-10-27-0907-claude.tsv (Banco esteso, 25 compiti, Claude Sonnet 5.5 rapido / Opus 5.5 profondo, 27/10/2026 09:07)
  - ~/Library/Logs/MacTalkAct-bench-2026-10-27-0902-codex.tsv (Banco esteso, 25 compiti, Codex gpt-6-luna / gpt-6.1-sol, 27/10/2026 09:02)
  - _bmad-output/planning-artifacts/research/computer-use-claude-codex-2026-10-27.md §8 (misure dopo l'Epic 6)
  - ~/Library/Logs/MacTalkAct.log del 27/10/2026, 11:55–12:00 (uso reale, sessione a mani libere)
  - Sources/MacTalkAct/*.swift al commit 614df3f (27/10/2026)
accessed: 2026-10-27
---

# Evidenza interna: comportamento dell'Agente al 27/10/2026

Tutti i numeri sono calcolati dai file TSV del Banco (una riga per compito: passi, secondi al primo strumento, secondi totali). I compiti sono 25 pagine HTML locali in Safari; non rappresentano le app native né le webmail reali.

## Claims

- C1. Claude riesce 25/25 compiti del Banco esteso; chiamate medie 1,88 per compito; primo strumento mediana 2,6 s; tempo totale mediana 7,0 s, 90° percentile 11,8 s. | bench-0907-claude.tsv | confidence high | class performance
- C2. In 9 compiti su 25 Claude completa con **una sola chiamata** ma il tempo totale supera di 4–10 s il tempo al primo strumento (es. modulo-news: primo strumento 2,2 s, totale 12,1 s; posta-apri 6,3 → 11,1; menu-accessori 2 chiamate, 3,0 → 14,0). Il tempo dopo l'ultima azione (attesa di assestamento fino a 3 s, 6 s se la pagina carica; calcolo dell'esito; giro finale del modello per la risposta; chiusura del processo) pesa quanto l'azione stessa. | bench-0907-claude.tsv; AgentTools.settle() (150 ms per sonda, max 3 s/6 s) | confidence high | class performance
- C3. Il primo strumento di Claude varia da 1,2 s a 6,3 s sullo stesso Banco e lo stesso modello (Sonnet 5.5, effort low): la varianza non dipende dagli strumenti ma dall'avvio della sessione `claude -p` e dal servizio. | bench-0907-claude.tsv | confidence medium | class performance
- C4. Codex riesce 23/25; primo strumento mediana 7,9 s (min 4,6, max 16,5); totale mediana 13,4 s, 90° percentile ~22,9 s. Fallisce i due compiti di modifica nell'editor web (notebook-domanda: modifica non verificata; notebook-risposta: «il campo è rimasto invariato» dopo 7 chiamate). | bench-0902-codex.tsv | confidence high | class performance
- C5. Codex legge ~17.000 token per chiamata, quasi tutti del proprio meccanismo interno (misurati da `turn.completed`); lo stesso compito costava 6,1 s alle 5:30 e 12,5 s alle 9:20: la latenza dipende dal carico del servizio. | computer-use-claude-codex-2026-10-27.md §8 | confidence medium | class performance
- C6. Motore locale con modello Apple dopo l'Epic 6: 17/20, 4,2 chiamate per compito, totale mediana 5,9 s, primo strumento 5,3 s. Con qwen3.5:9b su Ollama: 18/20 ma 20,2 s di mediana e 10 GB di memoria su M1 16 GB. | computer-use-claude-codex-2026-10-27.md §8; valutazione-motori-agente-2026-10-27.md §6 | confidence high | class performance
- C7. Ogni richiesta cloud è una sessione nuova: `ClaudeCLI.run` termina il processo dopo la risposta e ne prepara un altro (`--no-session-persistence`, nessun `--resume`); il prompt di sistema (~1.100 parole) e le 24 definizioni di strumento vengono reinviati a ogni richiesta. Non è noto se Anthropic riusi la cache del prompt tra processi `-p` distinti. | ClaudeCLI.swift (run, spawn), AgentRunner.systemPrompt | confidence high | class pattern
- C8. Prima di avviare il motore cloud l'app esegue `tools.initialObservation()`: una scansione dell'albero di Accessibilità con limite di 1,8 s, 220 elementi, 12.000 nodi; con `query` fino a 4 s e 40.000 nodi. Questo tempo precede il primo token del modello. | AgentTools.scan() | confidence high | class performance
- C9. Due soli livelli di modello: rapido = Sonnet 5.5 effort low; profondo = Opus 5.5 effort medium. La scelta è un'euristica testuale (`RouteHeuristics.isComplex`: più di 14 parole o marcatori come «tutte le», «mail», «cerca»). Nessun livello più rapido (Haiku 5.5) e nessuna scelta in base alla finestra. | IntentClassifier.swift:221, ClaudeEngine.model(for:) | confidence high | class pattern
- C10. Uso reale 27/10 11:55–12:00: una frase di 12 caratteri non rivolta al computer («Spegni invia», errore di riconoscimento) è arrivata all'Agente Claude, che ha lavorato 9,7 s prima dell'interruzione; «Statico» (7 caratteri) ha prodotto un `ask_user`. Il classificatore on-device ha superato il limite di 1,5 s in 2 frasi su 5 (1521 e 1638 ms) con modello freddo. | MacTalkAct.log 27/10 | confidence high | class performance
- C11. Sicurezza delle conferme: `Safety.isRiskyLabel` riconosce le azioni rischiose da una lista di 27 parole (it/en) nell'etichetta dell'elemento o nella voce di menu; `Safety.isRiskyKeys` da 8 combinazioni. Un pulsante di invio senza etichetta testuale (solo icona), un Invio premuto in un campo di chat (`press_keys return`) o un `type_text` seguito da `return` in un modulo non sono riconosciuti. Una conferma vale 45 s (`confirmValiditySeconds`) per qualunque azione rischiosa successiva, non solo per quella confermata. | LLMPlanner.swift:237–273, AgentTools.swift:408, 531–545, 993, 1148, 1161, 1193 | confidence high | class security
- C12. Isolamento dei motori: Claude riceve `--tools ""`, `--strict-mcp-config`, `--setting-sources ""`, `--disable-slash-commands`; Codex `--ignore-user-config --ignore-rules --strict-config --sandbox read-only` e 13 feature disattivate (shell, exec, computer use, browser, app, plugin, immagini, skill, view_image, sleep, goals, multi-agent, web search). Il token MCP di Codex viaggia in una variabile d'ambiente; `~/.codex/AGENTS.md` viene comunque letto. | ClaudeCLI.swift:185–198, CodexCLI.swift:88–118, valutazione-motori §4.1 | confidence high | class security
- C13. Il server MCP ascolta su 127.0.0.1 con porta casuale e bearer token di 72 caratteri; protocollo Streamable HTTP solo JSON. Non c'è controllo dell'intestazione `Origin` né `Host` (da verificare in `HTTPConnection`). Qualunque processo locale che conosca porta e token può chiamare gli strumenti (che agiscono con i permessi di Accessibilità dell'app). | MCPServer.swift:1–100 | confidence medium | class security
- C14. Le mani sintetiche usano `CGEvent` (tastiera con sorgente `combinedSessionState`, mouse con sorgente nil e modificatori azzerati, marcatore `eventSourceUserData`) e la funzione privata `_SLPSSetFrontProcessWithOptions` per portare in primo piano le app. | Executor.swift:67–72, 347–437; FrontProcess.swift:16 | confidence high | class pattern
- C15. Lo screenshot con numeri (set-of-marks) arriva a 1400 px e viene inviato al cloud come JPEG; il testo nelle immagini è letto dal modello cloud (compito etichetta-ordine: 3 chiamate, 8,2 s con Opus). Nessun OCR locale. | AgentTools.screenshot(), bench-0907-claude.tsv | confidence high | class pattern
- C16. Il Motore locale usa un ciclo «piano» con generazione vincolata, senza esito delle azioni (`reportOutcome = false`), massimo 8 passi, e rifiuta le modifiche di testo esistente; lo scorrimento in fondo alla pagina è instabile (elenco-fondo fallito). | LocalEngine, LocalStepAgent.instructions; bench local | confidence high | class pattern

## Leads

- Quanto del tempo «dopo l'ultima azione» (C2) è attesa di assestamento, quanto il giro finale del modello, quanto la chiusura del processo: misurabile aggiungendo marche temporali nel log del Banco.
- Se la cache del prompt sopravvive tra processi `claude -p` (C7) la riscrittura del prompt in blocchi stabili vale 1–2 s per richiesta; altrimenti serve una sessione persistente o l'API diretta.
- La varianza del primo strumento (C3) somiglia a quella di Codex (C5): parte è il servizio, parte l'avvio; separabile misurando `claude -p` a vuoto.

## Cercato e non trovato

- Nessuna misura su app native (Mail, Calendario, Finder): il Banco è solo su pagine HTML in Safari.
- Nessuna misura di quante richieste reali usano Opus rispetto a Sonnet (SM-4) nel log odierno.

## Aggiunta (verifica del 27/10, 12:30)

- C17. Per Claude il token del server MCP viaggia nell'argomento `--mcp-config <JSON>` del processo `claude` (`ClaudeEngine.swift:68`): gli argomenti di un processo sono leggibili da ogni altro processo dello stesso utente (`ps -o args`). Per Codex viaggia solo nell'ambiente (`MACTALK_MCP_TOKEN`). | ClaudeEngine.swift:68, CodexCLI.swift:118 | confidence high | class security
- C18. `MCPServer`/`HTTPConnection` non contengono alcun controllo delle intestazioni `Origin` o `Host` (grep senza risultati): una pagina web aperta nel browser dell'utente potrebbe tentare richieste verso `http://127.0.0.1:<porta>/mcp`; senza il token le chiamate falliscono, ma il server risponde comunque. | MCPServer.swift | confidence high | class security

## Misure dirette del 27/10 (12:35), `claude -p` a vuoto

Comando: `claude -p ok --output-format json --model <m> --effort low --system-prompt <~2.250 token> --tools "" --setting-sources "" --no-session-persistence --strict-mcp-config`, tre esecuzioni consecutive, processo nuovo ogni volta, Claude Code 2.1.311.

| Modello | Tempo totale (processo) | `duration_api_ms` | input | cache creata | cache letta |
| --- | --- | --- | --- | --- | --- |
| claude-haiku-5-5 (freddo) | 3,04 s | 1.310 ms | 2 | 2.269 | 0 |
| claude-sonnet-5-5 (freddo) | 4,75 s | 3.213 ms | 2 | 2.248 | 0 |
| claude-sonnet-5-5 (subito dopo) | 2,71 s | 1.241 ms | 2 | 0 | 2.248 |

- C19. La cache del prompt di Anthropic sopravvive tra processi `claude -p` distinti: la seconda esecuzione con lo stesso prompt di sistema ha letto 2.248 token dalla cache e il tempo API è sceso da 3.213 a 1.241 ms (−61 %). La durata della cache (5 minuti o 1 ora) va verificata con una misura a distanza. | misura diretta 27/10 12:35 | confidence high (una misura, da ripetere) | class performance
- C20. L'avvio del processo `claude` costa 1,3–1,6 s oltre al tempo API (tempo totale meno `duration_ms`): è il costo che il processo pronto dell'app già nasconde. | misura diretta 27/10 | confidence high | class performance
- C21. A freddo (senza cache) Haiku 5.5 risponde in 1.310 ms contro 3.213 ms di Sonnet 5.5 sullo stesso prompt (effort low). | misura diretta 27/10 | confidence medium (una misura) | class performance

## Misura diretta del 27/10 (12:38), `codex exec` a vuoto

- C22. `codex exec - --json --ephemeral … -m gpt-6-luna` (codex-cli 0.164.0-alpha.11.1) ha risposto in 2,6–3,3 s con `turn.failed`: «You've hit your usage limit … try again at 3:15 PM». Il limite di Codex è scattato durante la giornata di prove (il Banco delle 09:02 lo aveva consumato); dalle 12:38 alle 15:15 la catena di riserva dispone solo di Claude e del modello locale. Il tempo fino alla risposta del servizio (2,6–3,3 s) è un limite inferiore dell'avvio di Codex. | misura diretta 27/10 12:38 | confidence high | class performance

## Verifiche locali del 27/10 (12:50)

- C23. Ollama 0.40.11 su questo M1 da 16 GB usa il runner MLX: il log del server riporta «starting mlx runner subprocess model=qwen3.5:4b» (02:22) e «mlx runner is ready» (02:22, 02:48) per qwen3.5:4b e qwen3.5:9b. L'affermazione «backend MLX solo oltre 32 GB» (blog Ollama 0.19, marzo 2026) non vale più per la 0.40. | ~/.ollama/logs/server*.log, 27/10/2026 | confidence high | class version
- C24. Dizionari AppleScript presenti su macOS 27.0.1 (`sdef` con Xcode): Mail 19 comandi e 27 classi (tra cui send, reply, forward, redirect, move, delete, check for new mail, mailto); Calendar 8 comandi e 7 classi (make, save, show, view calendar); Safari 10 comandi; Messages 3 (send, login, logout); Contacts 8 comandi e 17 classi; Notes 2 comandi e 4 classi; Reminders 1 comando e 3 classi; Finder 25 comandi; Microsoft Edge, Google Chrome e Brave 23 comandi e 5 classi ciascuno (dizionario Chromium: schede, finestre, JavaScript). | `sdef` eseguito il 27/10 su /System/Applications e /Applications | confidence high | class version
- C25. Cache del prompt dopo circa 15 minuti dall'ultima richiesta (stesso prompt di sistema, Sonnet 5.5): lettura parziale, 1.181 token letti dalla cache e 896 ricreati, tempo API 1.238 ms. La parte di prefisso comune a tutte le sessioni di Claude Code resta in cache; la parte propria dell'app (prompt di sistema) scade con il TTL di 5 minuti se non rinnovata. Una richiesta ogni meno di 5 minuti (anche a vuoto) tiene la cache calda. | misura diretta 27/10 12:32 | confidence medium (una misura) | class performance
