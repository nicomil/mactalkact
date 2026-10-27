# Revisione «versioni e realtà» — ARCHITECTURE-SPINE (emendamenti del 27/10 sera)

- **Lente:** ogni decisione impegnata deve essere stata verificata sul web, sul progetto o sui binari installati, non asserita da memoria. Versioni correnti, esistenza e adeguatezza delle tecnologie nominate, comportamento attuale delle CLI su cui l'architettura si appoggia.
- **Data della revisione:** 2026-10-27.
- **Documento esaminato:** `ARCHITECTURE-SPINE.md` (aggiornato 2026-10-27), con attenzione alla tabella Stack e agli AD-6, AD-14, AD-16, AD-18, AD-19, AD-21, AD-22, AD-23.
- **Evidenza usata:** appendice §11 della ricerca tecnica del 27/10 (121 fonti datate), `imports/evidenza-interna-2026-10-27.md`, binari locali (`claude --version`, `~/.local/bin/codex --version`, `ollama --version`, `sw_vers`, `swift --version`, `Package.swift`), header dell'SDK macOS installato, log del Banco; otto accessi web (changelog di Claude Code, pagine `headless`, `cli-reference`, `model-config` di code.claude.com, pagina di versioning di modelcontextprotocol.io, release GitHub di `openai/codex` e `ollama/ollama`, una ricerca web sul flag non-bare).

## Verdetto

**Approvato con riserve.** Lo Spine è insolitamente ben ancorato: quasi ogni numero della tabella Stack coincide con il binario installato e quasi ogni affermazione tecnica degli AD risale a una fonte datata nell'appendice della ricerca. Nessuna delle tecnologie nominate è scomparsa o inadatta. Restano tre punti da correggere prima dell'implementazione (nessuno critico): un canale di passaggio del token che Claude Code non espone (stdin per `--mcp-config`), una mitigazione del modo «bare» che oggi va fatta sull'ambiente e non con un flag, e una regola su `Origin` che potrebbe rifiutare lo stesso client che vogliamo servire se non viene prima misurata. Più alcune imprecisioni di nomenclatura AX e una versione minima da alzare per la Sessione lunga.

Conteggio: **24 affermazioni confermate, 6 non confermate, 3 errate** (con correzione). Gravità: 0 critiche, 2 alte, 5 medie, 6 basse (le confermate non hanno gravità).

## 1. Tabella Stack

| Riga | Esito | Fonte | Gravità |
| --- | --- | --- | --- |
| Swift (modalità linguaggio 5) 6.4 | **Confermata** | `swift --version` → «Apple Swift version 6.4 (swiftlang-6.4.0.34.1)»; `Package.swift` → `.swiftLanguageMode(.v5)`. Nota: `swift-tools-version: 6.0` nel manifest, coerente. | — |
| macOS piattaforma minima 27.0 | **Confermata** | `Package.swift` → `platforms: [.macOS("27.0")]`. | — |
| FoundationModels, Speech/SpeechAnalyzer, Vision: macOS 27.0.1 | **Confermata** (come versione del sistema in uso) | `sw_vers` → ProductVersion 27.0.1, Build 26A434. Sono framework di sistema: la «versione» è quella dell'OS. | — |
| Claude Code CLI 2.1.311 (verificata) | **Confermata** | `claude --version` → «2.1.311 (Claude Code)»; il CHANGELOG ufficiale (`raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md`, letto il 27/10) ha 2.1.311 come prima voce: **è ancora l'ultima pubblicata**. | — |
| Minima 2.1.293 per Haiku 5.5 | **Confermata** | `code.claude.com/docs/en/model-config` (27/10): «Use v2.1.293 or later with Haiku 5.5». La stessa pagina dà Opus 5.5 ≥ 2.1.280 e Sonnet 5.5 ≥ 2.1.284, entrambe coperte dalla 2.1.293. | — |
| Modello profondo `claude-opus-5-5` | **Confermata** | `model-config`: «pin to a specific version, use the full model name, for example `claude-opus-5-5`»; il Banco Claude del 27/10 (`~/Library/Logs/MacTalkAct-bench-2026-10-27-0907-claude.tsv`) riporta 8 compiti con quell'ID. | — |
| Modello rapido `claude-sonnet-5-5` | **Confermata per uso reale, non per documento** | La pagina `model-config` non scrive l'ID completo di Sonnet 5.5 (`sonnet` → «Sonnet 5.5»). L'ID è però **accettato dal servizio**: 17 compiti del Banco del 27/10 e due righe di `MacTalkAct.log` «Agente (claude/claude-sonnet-5-5)». Basta. | bassa (annotare che la conferma è empirica) |
| Modello istantaneo `claude-haiku-5-5` (7 ottobre 2026) | **Confermata** | `model-config`: «Its model ID is `claude-haiku-5-5`»; data di annuncio da ricerca [85] (anthropic.com/news/claude-haiku-5-5, 2026-10-07); misura diretta a freddo 1.310 ms (`evidenza-interna` C21, con Claude Code 2.1.311). | — |
| Codex CLI 0.164.0-alpha.11.1 (verificata) | **Confermata, con avvertenza** | `~/.local/bin/codex --version` → «codex-cli 0.164.0-alpha.11.1». Su GitHub (`openai/codex/releases`, 27/10) l'ultima pre-release è **0.166.0-alpha.2** (pubblicata oggi 11:54 UTC): il binario dentro ChatGPT.app è un ramo alpha che avanza quasi ogni giorno. La versione «verificata» cambierà spesso: `verifiedVersions` per Codex deve accettare un intervallo (o la sola `minimumVersion` ≥ 0.131.0 per CVE-2026-19591 [42]), non una stringa esatta, altrimenti lo stato `.unverified` sarà la norma. | media |
| Ollama 0.40.11 (runner MLX anche su 16 GB) | **Confermata** | `ollama --version` → 0.40.11; GitHub `ollama/ollama/releases` (27/10): v0.40.11 del 24/10 è **l'ultima stabile** (v0.40.12-rc0 di oggi è pre-release). Runner MLX su M1 16 GB: log locale `~/.ollama/logs/server.log` («starting mlx runner subprocess», ricerca [9], evidenza C23). | — |
| Vision `RecognizeTextRequest` | **Confermata** | `Vision.swiftmodule/arm64e-apple-macos.swiftinterface` nell'SDK installato: `@available(macOS 15.0, …) public struct RecognizeTextRequest`; livelli `.fast`/`.accurate` (`RecognitionLevel`). Coincide con la ricerca [22]. | — |
| Hardware M1, 16 GB | **Confermata** | Evidenza interna C6/C23 e log Ollama. | — |

## 2. AD-6 — Sessione lunga, tre livelli, Haiku 5.5 istantaneo

| Affermazione | Esito | Fonte / correzione | Gravità |
| --- | --- | --- | --- |
| `claude -p --input-format stream-json` come processo riusato tra richieste | **Confermata** | `cli-reference` (27/10): `--input-format` «options: text, stream-json»; `headless`: `--input-format stream-json` è la modalità con prompt in coda; ricerca [95] (streaming input mode «preferred», MCP e contesto persistenti). Il codice attuale (`ClaudeCLI.swift:184`) già usa `--input-format stream-json` per il processo pronto. | — |
| `--max-turns` per turno in sessione lunga | **Confermata** | `cli-reference`: «With `--input-format stream-json`, a message still queued when the limit ends a turn stays queued and starts a new turn with its own limit». Ogni richiesta ha il proprio tetto: coerente con AD-6. | — |
| Riavvio dopo N richieste / inattività / timeout (cane da guardia) | **Confermata come necessità** | Ricerca [119] (issue 53584: processo lungo stream-json si blocca senza timeout, chiuso «not planned»); [116] regressioni headless in 2.1.x. | — |
| «Si avvia solo su una versione verificata (`ClaudeCLI.verifiedVersions`)» | **Confermata, ma la minima è troppo bassa** | Il CHANGELOG 2.1.299 contiene «Fixed queued prompts sent as content blocks over `--input-format stream-json`»: la Sessione lunga dipende proprio dai prompt in coda. **Correzione:** la `minimumVersion` per la Sessione lunga deve essere **≥ 2.1.299**, non 2.1.293 (che vale per Haiku 5.5 con processo per richiesta). Due minime distinte: una per il modello, una per la modalità. | media |
| Haiku 5.5 con effort `low` | **Confermata** | `model-config`: Haiku 5.5 supporta `low/medium/high/xhigh/max`, default `medium`; `cli-reference` `--effort low…`. Ricerca [94]: su 5.5 il thinking non si disattiva, `low` lo riduce. | — |
| Haiku 5.5 «adatto a comandi a un passo» | **Non confermata** (assunzione dichiarata) | Ricerca [85]: OSWorld 2.1 72,4 % vs 83,9 % di Sonnet 5.5; nessun benchmark di affidabilità su strumenti MCP. Il PRD lo marca [ASSUMPTION] e rimanda al Banco (FR-43). Coerente: resta da misurare, non da asserire. | bassa |
| Cache del prompt separata per livello | **Confermata** | Ricerca [83] (cambiare modello/effort invalida il prefisso), misura diretta [7]. | — |
| Codex un processo per richiesta, nessun `.instant` | **Confermata** | Evidenza C22 (`codex exec` 2,6–3,3 s solo per la risposta del servizio); ricerca [88][97] su `app-server` rinviato. | — |

## 3. AD-14 — Modalità non «bare», rilevamento della versione

| Affermazione | Esito | Fonte / correzione | Gravità |
| --- | --- | --- | --- |
| `--bare` non usa il login dell'abbonamento e diventerà il default di `-p` | **Confermata** | `headless` (27/10): «Set `ANTHROPIC_API_KEY` … because bare mode doesn't use your subscription login»; «In bare mode, Claude Code never reads OAuth credentials or the system keychain»; nota: «`--bare` … will become the default for `-p` in a future release». | — |
| «`ClaudeCLI` passa sempre in modo esplicito la modalità non “bare” **quando la CLI la espone**» | **Confermata la condizione, errata l'attesa implicita** | Oggi **non esiste** un flag `--no-bare` né alcuna opzione che forzi la modalità con login: `cli-reference` elenca solo `--bare` («Sets `CLAUDE_CODE_SIMPLE`») e `--safe-mode` (che è un'altra cosa: autenticazione normale, personalizzazioni spente); il CHANGELOG 2.1.299–2.1.311 e una ricerca web non mostrano nulla di simile. **Correzione:** l'unica leva esistente è l'ambiente: `--bare` è equivalente a `CLAUDE_CODE_SIMPLE=1`. `ClaudeCLI.spawn` deve **rimuovere `CLAUDE_CODE_SIMPLE`** dall'ambiente del figlio (oggi `ClaudeCLI.swift:206` toglie solo `ANTHROPIC_API_KEY`, `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`); l'AD deve nominarlo. Quando Anthropic cambierà il default, quasi certamente sarà `CLAUDE_CODE_SIMPLE=0` o un flag nuovo: il rilevamento resta necessario. | **alta** |
| Rilevare un avvio «bare» come errore di avvio | **Confermata come fattibile** | `headless`: in caso di autenticazione mancante «Claude Code prints the failure as the result on stdout»; l'evento `system/init` porta un array `capabilities` per rilevare il comportamento «instead of comparing version strings». Suggerimento: usare `system/init` (modello, `mcp_servers`, `capabilities`) come prova di avvio sano, oltre alla versione. | — |
| Stato `.unverified(version)` con processo per richiesta | **Confermata** (coerente con [116]) | — | — |

## 4. AD-16 — Token, `--mcp-config`, `Origin`/`Host`, revisione MCP

| Affermazione | Esito | Fonte / correzione | Gravità |
| --- | --- | --- | --- |
| Token oggi negli argomenti (`--mcp-config <json>`) | **Confermata** | `ClaudeEngine.swift:68` passa `access.mcpConfigJSON` come stringa; `MCPServer.swift:25-31` vi include `Authorization: Bearer <token>`. Ricerca [52][53] (CWE-214, issue Claude Code). | — |
| «passa via stdin dove la CLI lo permette» (per Claude) | **Errata** | `cli-reference`: `--mcp-config` «Load MCP servers from JSON **files or strings**». Nessuna lettura da stdin né `-`; e con la Sessione lunga stdin è già il canale dei prompt `stream-json`. **Correzione:** per Claude l'unica via senza argv è il **file temporaneo 0600** (confermato: CHANGELOG 2.1.309 «the MCP config file passed with `--mcp-config`»), con il token scritto nel file oppure referenziato da ambiente. Togliere «o passata via stdin» dall'AD per Claude; per Codex resta `bearer_token_env_var` (`CodexCLI.swift:111`, già in uso). | **alta** |
| Token «letto dall'ambiente» dentro il file `--mcp-config` | **Non confermata** | L'espansione `${VAR}` nei campi `headers`/`url` è documentata per `.mcp.json` di progetto; non ho verificato (budget web esaurito) che valga anche per i file passati con `--mcp-config`. Se non vale, il token va scritto in chiaro nel file 0600, che è comunque accettabile (stesso utente, cancellato alla chiusura). Da provare nello spike della Storia. | media |
| `--tools ""`, `--strict-mcp-config`, `--setting-sources ""` | **Confermate** | `cli-reference` (27/10): `--tools ""` disabilita i built-in e «doesn't affect MCP tools»; `--strict-mcp-config` «Only use MCP servers from `--mcp-config`»; `--setting-sources` lista di sorgenti. Già nel codice (`ClaudeCLI.swift:191-195`). | — |
| Attesa dei server MCP fino a `MCP_TIMEOUT` (30 s) | **Confermata** | `cli-reference`/`headless` (27/10); ricerca [87]. | — |
| `MCPServer` rifiuta `Origin` presente e non consentita (403) | **Confermata la regola della spec; non confermato l'effetto su Claude Code** | Spec Streamable HTTP: Origin **MUST** essere validato (ricerca [44]). Non è noto se il client HTTP di Claude Code o di Codex **invii** un'intestazione `Origin` (per esempio `http://localhost`). Se lo fa, la regola «nessuna origine consentita» spegne lo stesso Agente. **Correzione:** prima di rifiutare, **registrare** `Origin`/`Host` per una sessione con entrambi i Motori (lo stesso log di revisione già previsto), poi fissare l'allowlist; in via cautelativa accettare `Origin` assente **oppure** uguale a `http://127.0.0.1:<porta>`/`http://localhost:<porta>`, e rifiutare il resto. | media |
| `Host` diverso da `127.0.0.1:<porta>` → 403 | **Confermata come buona pratica** | Spec [44] (bind SHOULD 127.0.0.1) e CVE di DNS rebinding [46][114]. Attenzione al caso `localhost:<porta>` se un client lo usasse: stessa misura di log sopra. | bassa |
| «registra la revisione di protocollo negoziata da ogni client» | **Confermata, ma da precisare** | `modelcontextprotocol.io/specification/versioning` (27/10): revisione **corrente 2026-07-28**; le revisioni ≤ 2025-11-25 negoziano con `initialize`; la 2026-07-28 **non ha `initialize`** e dichiara la versione per richiesta in `_meta["io.modelcontextprotocol/protocolVersion"]` e nell'intestazione `MCP-Protocol-Version`. Il server attuale (`MCPServer.swift:84-88`) accetta 2024-11-05…2025-11-25 solo in `initialize`. **Precisazione:** il log deve leggere sia il `protocolVersion` di `initialize` sia l'intestazione `MCP-Protocol-Version`, altrimenti un client 2026-07-28 risulta «non negoziato» e fallisce su `initialize` assente. Coerente con il Deferred «Revisione MCP 2026-07-28». | media |
| Codex: `--ignore-user-config`, `--ignore-rules`, `--sandbox read-only`, `--disable …`, `--ephemeral`, `--strict-config`, `bearer_token_env_var` | **Confermate per uso reale** | Già in `CodexCLI.swift` e usate nel Banco Codex 23/25 [2]; evidenza C22 mostra `codex exec - --json --ephemeral`. Non riverificate sulla documentazione OpenAI oggi (budget). | bassa |
| Residuo `~/.codex/AGENTS.md` letto comunque | **Confermata** | Ricerca §1 e §5 (osservazione sul codice e sul comportamento, [6]). | — |

## 5. AD-18 — Banco di prova e fasi

Nessuna affermazione tecnica legata a versioni: strumenti interni (`Tests/bench`, TSV, `BenchPhase`). Le misure citate come base (25/25 Claude, 23/25 Codex, mediana 7,0 s, primo strumento 2,6 s, code 4–10 s) sono **confermate** dai TSV del 27/10 e dall'evidenza interna C2/C3. L'obbligo «somma delle fasi = totale entro 0,2 s» è una scelta di progetto, non una verità esterna. — Nessuna riserva.

## 6. AD-19 — Scansione AX, Electron, Vision

| Affermazione | Esito | Fonte / correzione | Gravità |
| --- | --- | --- | --- |
| `AXVisibleChildren` / `AXVisibleRows` | **Confermate** | SDK installato, `HIServices/AXAttributeConstants.h`: `kAXVisibleChildrenAttribute` (4 occorrenze), `kAXVisibleRowsAttribute` (2). Pratica confermata da ricerca [27][28]. Il codice non le usa ancora (nessuna occorrenza in `Sources/`): è lavoro nuovo, come dichiarato. | — |
| `AXManualAccessibility` sull'elemento applicazione per Electron/Chromium; `AXEnhancedUserInterface` riservato a VoiceOver | **Confermata** | Electron docs (ricerca [26]); già usato in `Accessibility.swift:77`. Non è una costante pubblica dell'SDK (stringa privata di Chromium/Electron): va tenuta come stringa, com'è oggi. | — |
| `AXLoadingProgress` < 1 prolunga l'attesa | **Non confermata come API pubblica** | Nessuna costante `kAXLoadingProgress` negli header dell'SDK: è un attributo esposto da WebKit/Chromium sulle `AXWebArea`. Funziona come stringa, ma va trattato come opzionale (assente in app native) e **non** come garanzia. | bassa |
| `RecognizeTextRequest`, modalità accurata con ripiego alla veloce, timeout 10 s, riscaldamento | **Confermata** | SDK: `@available(macOS 15.0)`, `RecognitionLevel`; ricerca [22][23][80] (26,9 s alla prima chiamata → riscaldamento; pattern timeout 10 s + ripiego fast). | — |
| Tempi OCR (0,07/0,13 s a caldo) | **Non confermata** (fonte bassa) | Ricerca [23] è un'issue GitHub su macOS 27, confidenza low; [24] misura su M3 Max. Lo Spine non promette numeri: nessuna correzione, ma il Banco deve misurare su M1. | bassa |

## 7. AD-21 — Conferme nell'esecutore

Nessuna affermazione dipendente da versioni esterne. I riferimenti impliciti (classificatori aggirabili: ricerca [110][111][112]; conferma per singola azione come in Claude Code computer use [35] e Operator [37]) sono **confermati** dall'appendice. L'uso di `AXIdentifier` e delle azioni di accessibilità per riconoscere i pulsanti è API pubblica stabile. — Nessuna riserva.

## 8. AD-22 — Livelli di accesso e campi sicuri

| Affermazione | Esito | Fonte / correzione | Gravità |
| --- | --- | --- | --- |
| «campo sicuro se il **ruolo** è `AXSecureTextField` o il sottoruolo lo è» | **Errata nella nomenclatura, innocua nell'effetto** | Nell'SDK esiste **solo** `kAXSecureTextFieldSubrole` (`AXRoleConstants.h`): un `NSSecureTextField` espone ruolo `AXTextField` e sottoruolo `AXSecureTextField`; non esiste `kAXSecureTextFieldRole`. Il codice attuale (`Accessibility.swift:322`, `AgentTools.swift:780`) confronta correttamente il sottoruolo. **Correzione:** riformulare «se il sottoruolo è `AXSecureTextField` (app native **e** pagine web, ricerca [48]); se la lettura del sottoruolo fallisce, un campo a riga singola è trattato come sicuro». Il doppio controllo ruolo/sottoruolo può restare come difesa, ma non va presentato come due casi distinti del sistema. | bassa |
| Pagine web: ruolo `AXTextField` + sottoruolo `AXSecureTextField` | **Confermata** | Ricerca [48] (desktop-tools PR 118, medium) e coerente con l'SDK. | — |
| Inserimento sicuro della tastiera (Secure Keyboard Entry) blocca i tasti sintetici | **Confermata** | Ricerca [49]. | — |
| Livelli per app come in Claude Code computer use (terminale escluso, view/click/full) | **Confermata** | Ricerca [35][56]. | — |
| Siti bancari e di trading in `.none` | **Confermata come allineamento con Anthropic** | Ricerca [36] (Help Center: trading bloccato, banking sconsigliato). | — |

## 9. AD-23 — Frasi spurie

Nessuna dipendenza esterna. La motivazione (frasi di 7–12 caratteri arrivate all'Agente, classificatore oltre 1,5 s a freddo) è **confermata** da `MacTalkAct.log` del 27/10 (evidenza C10). Il timeout di 1,0 s del classificatore (AD-2) contro 1,5 s misurati nel log è una tensione già nota al PRD, non un errore di versione. — Nessuna riserva.

## 10. Freschezza e scadenze

- La ricerca fissa il primo ricontrollo al **28/10/2026** e la scadenza delle affermazioni di classe «versione» (`--bare`, toolset, Ollama, mlx-swift-lm) al **1/11/2026**; il PRD §10 la riporta. Lo Spine **non** la riporta: aggiungere una riga in Deferred o nelle Convenzioni («rileggere `--bare`, `--input-format`, minime dei modelli prima dell'epic velocità e comunque entro il 1/11»). Gravità bassa.
- Oggi (27/10) tutto ciò che ho ricontrollato è ancora valido: Claude Code 2.1.311 è l'ultima release, Ollama 0.40.11 l'ultima stabile, revisione MCP corrente 2026-07-28 come nella ricerca, `--bare` ancora opt-in.

## 11. Elenco delle correzioni richieste (in ordine di priorità)

1. **AD-16 (alta):** eliminare «o passata via stdin» per Claude; `--mcp-config` accetta solo file o stringhe. Canale corretto: file temporaneo 0600 (token nel file o, se l'espansione `${VAR}` è confermata, dall'ambiente).
2. **AD-14 (alta):** sostituire «passa in modo esplicito la modalità non bare quando la CLI la espone» con «rimuove `CLAUDE_CODE_SIMPLE` dall'ambiente del figlio e non passa `--bare`; quando la CLI esporrà un'opzione esplicita la userà; rileva l'avvio sano da `system/init`». Aggiornare l'elenco di `ClaudeCLI.swift:206`.
3. **AD-16 (media):** `Origin`: misurare prima di rifiutare; allowlist = assente oppure `http://127.0.0.1:<porta>`/`http://localhost:<porta>`. Il log deve catturare sia `initialize.protocolVersion` sia l'intestazione `MCP-Protocol-Version`.
4. **AD-6 / Stack (media):** due minime distinte: 2.1.293 per Haiku 5.5, **≥ 2.1.299** per la Sessione lunga (fix dei prompt in coda su `stream-json`).
5. **Stack (media):** Codex «versione verificata» come intervallo/minima (≥ 0.131.0), non stringa esatta: l'alpha dentro ChatGPT.app avanza quasi ogni giorno (0.166.0-alpha.2 oggi).
6. **AD-22 (bassa):** «ruolo `AXSecureTextField`» → «sottoruolo `AXSecureTextField`»; non esiste un ruolo con quel nome.
7. **AD-19 (bassa):** `AXLoadingProgress` e `AXManualAccessibility` sono attributi privati di WebKit/Chromium/Electron: dichiararli opzionali.
8. **Stack (bassa):** annotare che `claude-sonnet-5-5` è confermato dall'uso (Banco 27/10), non dalla documentazione, che non ne scrive l'ID.
9. **Spine (bassa):** riportare la scadenza del 1/11/2026 per le affermazioni di classe «versione».

## 12. Riepilogo numerico

| Esito | Numero |
| --- | --- |
| Confermate | 24 |
| Non confermate | 6 |
| Errate (con correzione) | 3 |
| **Totale affermazioni esaminate** | **33** |

| Gravità | Numero |
| --- | --- |
| Critica | 0 |
| Alta | 2 |
| Media | 5 |
| Bassa | 6 |
