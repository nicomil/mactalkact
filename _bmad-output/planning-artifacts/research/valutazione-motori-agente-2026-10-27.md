---
title: Valutazione dei motori per l'Agente — Codex, modello Apple, Ollama e MLX
type: research-technical
created: 2026-10-27
author: Claude per Nico
sources:
  - Sources/MacTalkAct/AgentRunner.swift, ClaudeCLI.swift, MCPServer.swift, LLMPlanner.swift, Coordinator.swift
  - codex-cli 0.164.0-alpha.11.1 installato (`codex exec --help`, `codex features list`, `codex login status`)
  - Ollama 0.40.11 e LM Studio (`lms`) installati; Mac Apple M1 con 16 GB di memoria unificata
  - OpenAI, documentazione Codex: MCP (https://developers.openai.com/codex/mcp) e modalità non interattiva (https://learn.chatgpt.com/docs/non-interactive-mode)
  - Apple, WWDC26: guida macOS 27 (https://developer.apple.com/wwdc26/guides/macos/), sessioni 241 e 339 (https://developer.apple.com/videos/play/wwdc2026/339)
  - Confronti di terzi su server locali per Apple Silicon (rapidmlx.com/compare, insiderllm.com, betterclaw.io, stochasticsandbox.com), da considerare indicativi
---

# Valutazione dei motori per l'Agente

## In sintesi

1. **Codex si integra quasi come Claude.** `codex exec` è un comando non interattivo con uscita JSONL, usa il login ChatGPT già presente sul Mac e accetta server MCP via HTTP con token bearer letto da una variabile d'ambiente. Può quindi usare **lo stesso server MCP interno** di MacTalkAct senza modifiche. Il lavoro vero è spegnere gli strumenti propri di Codex (shell, computer use, browser, plugin) e leggere il suo messaggio di limite.
2. **Il cambio più importante per il modello locale viene da Apple.** In macOS 27 il framework FoundationModels accetta qualsiasi modello che implementa il protocollo `LanguageModel`: il modello Apple, un modello MLX caricato dentro l'app (`MLXLanguageModel` del pacchetto `mlx-swift-lm`) o un provider scritto da noi. Lo stesso `LanguageModelSession`, con gli stessi `Tool` e la stessa generazione vincolata, funziona con tutti. Conviene quindi costruire **un solo Agente locale** su FoundationModels e cambiare solo il modello sotto.
3. **Il vincolo è la memoria: 16 GB su M1.** Con Edge, Jupyter e l'app aperti restano realisticamente 6–8 GB per un modello. Sono adatti modelli da 4 a 9 miliardi di parametri in 4 bit (circa 3–7 GB). Il collo di bottiglia per un agente non è la velocità di scrittura ma la lettura del prompt: con le istruzioni, gli strumenti e la fotografia dello schermo il primo passo può costare molti secondi. Il prompt dell'Agente locale deve essere molto più corto di quello per Claude.
4. **Raccomandazione:** modello Apple come Agente locale predefinito (sempre presente, nessuna installazione); come Modello locale esteso un **provider compatibile OpenAI** verso un server sul Mac, che copre in un colpo Ollama, LM Studio, `mlx_lm.server` e Rapid-MLX. Ollama è il primo candidato perché è già installato e dalla serie 0.4x usa MLX su Apple Silicon. L'MLX caricato dentro l'app è l'alternativa da provare in uno spike, non la prima scelta. Il modello va scelto con un banco di prova, non con le classifiche online.

## 1. Codex come secondo motore cloud

### 1.1 Cosa offre la CLI installata

| Bisogno di MacTalkAct | Come si ottiene con `codex exec` |
| --- | --- |
| Esecuzione senza interfaccia | `codex exec -` legge la richiesta da stdin; `--json` scrive eventi JSONL (`thread.started`, `turn.started`, `item.*`, `turn.completed`, `turn.failed`, `error`) |
| Login con l'abbonamento | riusa `~/.codex/auth.json` (oggi «Logged in using ChatGPT»); nessuna chiave API |
| Strumenti di MacTalkAct | `-c mcp_servers.mactalk.url="http://127.0.0.1:<porta>/mcp"` e `-c mcp_servers.mactalk.bearer_token_env_var="MACTALK_MCP_TOKEN"`; con `required = true` Codex esce con errore se il server non risponde |
| Niente configurazione dell'utente | `--ignore-user-config`: non carica `~/.codex/config.toml`, dove oggi ci sono Figma, Stitch, `node_repl` con computer use e un hook `notify` (l'autenticazione resta valida) |
| Niente strumenti propri | `--disable shell_tool --disable unified_exec --disable computer_use --disable browser_use --disable apps --disable plugins --disable image_generation` (nomi verificati con `codex features list`), più `--sandbox read-only` come seconda barriera |
| Nessuna traccia su disco | `--ephemeral`; `--skip-git-repo-check` perché la cartella di lavoro è `~/Library/Application Support/MacTalkAct` |
| Modello e sforzo | `-m <modello>` e `-c model_reasoning_effort="low"|"medium"|"high"`; `--output-schema` se serve una risposta strutturata |
| Ultima risposta | evento finale del turno nel JSONL, oppure `-o <file>` |

**Dove si trova il binario.** Il comando `codex` nel PATH del terminale è uno shim di cmux. Il binario vero è `~/.local/bin/codex`, collegamento a `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex`. La ricerca del binario deve saltare gli shim e conoscere anche il percorso dentro ChatGPT.app.

### 1.2 Limiti d'uso

Codex ha un limite su una finestra mobile di 5 ore e uno settimanale. Il messaggio riportato dagli utenti è «You've hit your usage limit», seguito da «Try again at <data e ora>» oppure «try again in <durata>». Il limite settimanale può riprendere giorni dopo, quindi l'analisi deve leggere anche la data, non solo l'ora come fa oggi `AgentRunner.resetDate`. Ci sono segnalazioni di limiti mostrati per errore con quota disponibile: un messaggio di limite non leggibile deve mettere in pausa per 30 minuti, come per Claude.

### 1.3 Da verificare con uno spike (Storia 4.1)

- **Processo pronto in anticipo.** Con Claude l'app tiene un processo avviato e in attesa su stdin (~2 s risparmiati). Va misurato se `codex exec -` fa autenticazione e connessione MCP prima di ricevere la richiesta. In caso contrario l'alternativa è `codex app-server` (sperimentale): un processo che resta vivo e apre un thread per richiesta.
- **Nessuno strumento nascosto.** Con le opzioni sopra, il primo evento deve elencare solo gli strumenti `mactalk`. Vanno controllati in particolare la ricerca web, `view_image` e `sleep_tool`.
- **Modelli.** Il modello dell'utente oggi è `gpt-6-astra` con sforzo alto. I modelli per il livello rapido e profondo si scelgono dopo aver misurato 10 richieste tipiche, come per Claude nella Storia 2.2.
- **Testo dei messaggi di limite e di login scaduto,** da raccogliere dal JSONL reale.

## 2. Il modello locale

### 2.1 Che cosa è cambiato con macOS 27

- **Protocollo `LanguageModel`.** Un `LanguageModelSession` può usare il modello Apple sul dispositivo, un modello MLX (`import MLXFoundationModels; LanguageModelSession(model: MLXLanguageModel(modelID: "mlx-community/…"))`) o un provider che dichiara le sue capacità (`.toolCalling`, `.guidedGeneration`, `.reasoning`) e implementa un `LanguageModelExecutor`. Strumenti (`Tool`) e generazione vincolata (`@Generable`) restano gli stessi.
- **Modello Apple rinnovato** sul dispositivo e un **nuovo modello Apple su Private Cloud Compute**, gratuito per gli sviluppatori sotto i 2 milioni di download ma con un entitlement da richiedere e un limite giornaliero per utente. Per un'app firmata localmente non è chiaro se l'entitlement si possa ottenere: resta tra le cose rinviate.
- **Profili dinamici:** la stessa sessione può cambiare modello, strumenti e istruzioni. Utile per passare dal modello Apple al Modello locale esteso senza riscrivere il ciclo dell'Agente.

### 2.2 Server locali su Apple Silicon

| Opzione | Pro | Contro |
| --- | --- | --- |
| **Ollama** (0.40.11 installato, già in esecuzione) | Già presente; API compatibile OpenAI con tool calling; `keep_alive` per scaricare il modello dalla memoria; secondo più fonti usa MLX su Apple Silicon per le architetture supportate | Una richiesta alla volta per modello (per noi va bene); il vantaggio MLX dipende dal modello e va misurato |
| **LM Studio** (`lms` installato) | Motore MLX maturo, spesso il più veloce nei confronti 2026; API compatibile OpenAI | App con interfaccia da tenere aperta o servizio da configurare |
| **`mlx_lm.server`** | Ufficiale Apple MLX, leggero | «Server di esempio»: va tarato (cache KV a 8 bit) per tempi accettabili; non installato |
| **Rapid-MLX** | Server MLX pensato per il tool calling degli agenti, compatibile OpenAI e Anthropic | Progetto giovane, una sola fonte sui benefici |
| **MLX dentro l'app** (`mlx-swift-lm`) | Nessun server; si integra direttamente in FoundationModels | Il modello occupa memoria nel processo dell'app; build più pesante; gestione dei download dei pesi |

Un **provider compatibile OpenAI** (`/v1/chat/completions` con `tools`) copre le prime quattro righe con un solo codice. È la scelta con il miglior rapporto tra lavoro e opzioni.

### 2.3 Modelli candidati per 16 GB

| Modello (4 bit) | Memoria circa | Note dalle fonti |
| --- | --- | --- |
| Modello Apple sul dispositivo | di sistema | Sempre presente, ~0,6 s per una classificazione; finestra di contesto piccola, va verificata quella di macOS 27 |
| Qwen 3.5 4B | ~3 GB | Indicato come scelta sicura per 16 GB |
| Qwen 3.5 9B | ~6,6 GB | Il miglior compromesso secondo più guide, al limite della memoria con il browser aperto |
| Gemma 4 E4B | ~3–4 GB | Alternativa citata per 16 GB |

Sono indicazioni da classifiche online con numeri incoerenti tra loro. La scelta va fatta con il banco di prova dell'Agente (Storia 5.1) misurando: compiti riusciti, passi, tempo al primo strumento, memoria occupata.

### 2.4 Perché il prompt dell'Agente locale deve cambiare

Il messaggio che oggi riceve Claude contiene un prompt di sistema lungo, la definizione di tutti gli strumenti, la fotografia dello schermo, la memoria e il blocco `<recent>`. Un modello da 4–9 miliardi su M1 legge qualche centinaio di token al secondo: alcune migliaia di token significano diversi secondi prima di ogni primo passo. Per l'Agente locale servono:

- istruzioni brevi in italiano, centrate su un compito di pochi passi;
- un sottoinsieme di strumenti (osservare con ricerca, cliccare, scrivere, sostituire testo, tasti, aprire app o URL, scorrere, conferma);
- `observe` che restituisce solo gli elementi più pertinenti alla richiesta;
- un tetto basso di passi (8) e una resa onesta quando il compito è troppo lungo;
- riuso della cache tra un passo e l'altro, che FoundationModels gestisce quando la trascrizione cresce solo in coda.

## 3. Raccomandazioni per i piani

1. **Epic 4:** introdurre un protocollo comune per i Motori, aggiungere Codex, una catena di riserva Claude ↔ Codex → locale e un Agente locale di base con il modello Apple.
2. **Epic 5:** prima un banco di prova che misura l'Agente, poi uno spike sui modelli locali su questo Mac, poi il provider compatibile OpenAI, l'ottimizzazione dell'Agente locale e la rimozione delle ultime dipendenze dal cloud (pulizia della dettatura, macro).
3. **Rinviato:** modello Apple su Private Cloud Compute (entitlement), MLX dentro l'app (dopo lo spike), adapter addestrato per il classificatore.

## 4. Esito dello spike su Codex (Storia 4.1, 27/10)

Prove fatte con `MacTalkAct --mcp-serve` (solo il server degli strumenti, nuovo comando di debug) e `codex exec` 0.164.0-alpha.11.1, login ChatGPT.

### 4.1 Opzioni che servono davvero

| Opzione | Esito |
| --- | --- |
| `mcp_servers.mactalk.default_tools_approval_mode="approve"` | **Indispensabile.** Senza, ogni strumento MCP fallisce con «MCP tool call requires approval, but approval policy is never». |
| `model_instructions_file=<file>` | **Indispensabile.** Sostituisce le istruzioni di base di Codex (pensate per programmare) con il prompt dell'Agente: i token in ingresso scendono da ~47.000 a ~21.000 e spariscono riferimenti a skill personali. |
| `web_search="disabled"` | Necessaria: senza, il modello ha `web__run`. |
| `--disable multi_agent` | Toglie gli strumenti per creare sotto-agenti. |
| `--disable code_mode_host` | **Da non usare.** Tutti i modelli disponibili sono `code_mode_only`: senza host Codex non può chiamare nessuno strumento. |
| `--disable shell_tool unified_exec computer_use browser_use apps plugins image_generation skill_search tool_suggest view_image sleep_tool goals` | Accettate; tengono fuori shell, computer use e browser. |
| `--sandbox read-only` | Resta come seconda barriera: `apply_patch` rimane elencato ma non può scrivere (approvazione «never»). |
| `project_doc_max_bytes=0`, `include_permissions_instructions=false`, `include_apps_instructions=false`, `include_environment_context=false` | Accettate, meno testo inutile. |
| `--strict-config` | Utile: una chiave sconosciuta fa fallire l'avvio (per esempio `skills.enabled` non esiste). |
| `~/.codex/AGENTS.md` | Viene letto comunque (33 byte nel Mac di Nico). Non si può escludere senza un `CODEX_HOME` separato, che rischierebbe di invalidare il login dell'utente al rinnovo del token: lo si accetta e il prompt dell'Agente chiede di ignorare istruzioni di stile. |

Strumenti che restano visibili al modello oltre a `mactalk`: `apply_patch` (bloccato dalla sandbox), `clock__curr_time`, risorse MCP, gli strumenti interni del code mode. Nessuno può agire sullo schermo o sui file.

### 4.2 Tempi (5 prove, `gpt-6-luna`, sforzo basso, richiesta «osserva e dimmi l'app»)

| Avvio | Primo strumento | Risposta finale |
| --- | --- | --- |
| A freddo | 3,4–4,3 s | 4,3–5,6 s |
| Processo pronto da 6–8 s | 2,7–3,6 s | 3,6–4,0 s |

Il processo pronto fa risparmiare solo qualche decimo: `codex exec` non avvia la sessione prima di ricevere tutta la richiesta. **Decisione:** un processo per richiesta, senza processo di riserva; `codex app-server` non serve. NFR-9 (primo strumento ≤ 4 s) è rispettato con il modello rapido.

### 4.3 Modelli

Con `--ignore-user-config` il modello predefinito è `gpt-6.1-sol`. Elenco disponibile per l'account: `gpt-6.1-sol` («workhorse»), `gpt-6-astra` (frontiera), `gpt-6.1-terra`, `gpt-6-luna` («veloce ed economico»), modelli 5.6. **Predefiniti scelti:** rapido `gpt-6-luna` con sforzo `low`; profondo `gpt-6.1-sol` con sforzo `medium`. La verifica su 10 compiti tipici è rimandata al Banco di prova (Storia 5.1), che li misura per tutti i Motori nello stesso modo.

### 4.4 Messaggi

- **Login mancante o scaduto:** eventi `error` «Reconnecting… n/5 (unexpected status 401 Unauthorized …)» e poi `turn.failed` con lo stesso testo, dopo circa 20 s di tentativi. Per non aspettare, lo stato «accesso da fare» si ricava da `codex login status` (uscita 1, «Not logged in») al ricontrollo dei Motori.
- **Limite d'uso:** nel binario compaiono «You've hit your usage limit. … or try again at <ora>» con i formati `%-I:%M %p` e `%b %-d, %Y %-I:%M %p`, e «try again in <durata>». Esempi in `Tests/fixtures/codex/`.
- **Risposta finale:** l'ultimo `item.completed` di tipo `agent_message` prima di `turn.completed`.

## 5. Banco di prova e motore locale (Storie 5.1 e 5.4, 27/10)

### 5.1 Il Banco

20 compiti (15 brevi, 5 medi) su 6 pagine HTML locali in `Tests/bench/pages/` (posta, tabella con caselle, notebook, modulo, elenco di 150 articoli, sito con menu). Ogni pagina scrive il proprio stato nel titolo della finestra; `--agent-bench` apre la pagina in Safari, esegue la richiesta col motore indicato, rilegge il titolo con l'Accessibilità e confronta. Le conferme vengono approvate dal banco, le domande restano senza risposta.

### 5.2 Modello Apple: dal 5% all'80%

Registro delle prove (ogni riga è il Banco completo; «primo» è il tempo fino alla prima azione con effetti):

| Versione | Riusciti | Primo (mediana) | Tempo (mediana) | Cosa è cambiato |
| --- | --- | --- | --- | --- |
| Strumenti liberi (tool calling di FoundationModels) | 1/20 (5%) | 4,0 s | 12,0 s | Base: clicca id mai visti, apre app sbagliate (Mail, una ricerca Google), dichiara riusciti compiti non fatti |
| Passi guidati (un'azione per volta, generazione vincolata) | 4/5 su un sottoinsieme | 4,5 s | 6,7 s | Azioni giuste, ma il modello non dice mai «fatto» e ripete (ha scritto un nome 8 volte): scartata |
| Piano intero in una chiamata, elementi indicati per testo | 8/20 (40%) | 5,6 s | 6,5 s | L'app risolve il testo in id; nessuna ripetizione |
| + filtro della barra del browser, clic prima di scrivere, verifica del campo | 10/20 | 6,7 s | 8,1 s | |
| + ricerca nella pagina di numeri e nomi fuori schermo, menu a tendina, ripresa del passo dopo un clic | 14/20 (70%) | 6,6 s | 7,4 s | Un errore grave: ha eliminato la mail sbagliata copiando un esempio del prompt |
| + esempi con nomi inventati, scarto dei clic non pertinenti, conferma che cita la richiesta | 15/20 (75%) | 6,8 s | 8,8 s | Nel notebook ha inserito testo in mezzo a una cella |
| + regola «niente scrittura su testi esistenti», solo elementi della pagina, riepilogo onesto, ruoli corretti | **16/20 (80%)** | **5,6 s** | **6,5 s** | Versione adottata |

Le quattro richieste che non riesce restano sicure: le modifiche di testo nel notebook vengono rifiutate («Col modello locale non modifico testi già scritti: chiedilo a Claude o a Codex») invece di sporcare la cella; «spunta le 18:30 per tutti quelli che hanno già le 21:30» richiede un ragionamento che il modello piccolo non fa; lo scorrimento in fondo a una pagina lunga è a volte instabile.

**Decisioni.** Il motore locale lavora in modalità **piano** (`LocalEngine.Mode.plan`): una chiamata produce tutti i passi con generazione vincolata, l'app li esegue risolvendo ogni elemento per testo solo dentro la pagina web, scarta i clic che non c'entrano con la richiesta e quelli rischiosi non chiesti (inviare, eliminare), mette per ultimi quelli rischiosi, chiede conferma citando la richiesta, non scrive mai su testi già presenti quando la richiesta è una modifica, e alla fine dice che cosa ha fatto davvero («Ho cliccato «Prezzi»»). Le modalità «passi» e «strumenti» restano per confronto (`--local-mode`).

**Miglioramenti utili anche ai motori cloud.** `observe` ora segna lo stato delle caselle (`checked`/`unchecked`) e gli elementi interni alla pagina web (`(page)`); la ricerca con `query` trova anche elementi fuori schermo e il clic con il mouse li porta prima in vista; `type_text` verifica che il campo mostri il testo scritto.

## 6. Esito dello spike sui modelli locali (Storia 5.2, 27/10)

Stesso Banco, stesso motore locale in modalità piano, modello servito da **Ollama 0.40.11** tramite il provider compatibile OpenAI (`--agent-bench --engine local --model …`). Mac: M1, 16 GB, Safari aperto.

| Modello | Riusciti | Brevi | Medi | Prima azione (mediana / 90°) | Tempo (mediana / 90°) | Memoria (`ollama ps`) |
| --- | --- | --- | --- | --- | --- | --- |
| **Apple sul dispositivo** | **16/20 (80%)** | 12/15 | 4/5 | 5,6 s / 8,8 s | **6,5 s** / 9,5 s | di sistema |
| qwen3.5:4b | 13/20 (65%) | 11/15 | 2/5 | 11,3 s / 35,9 s | 12,9 s / 39,4 s | 9,4 GB |
| **qwen3.5:9b** | **18/20 (90%)** | 13/15 | 5/5 | 18,9 s / 44,5 s | 20,2 s / 47,2 s | 10 GB |
| gemma4:e4b | 9/20 (45%) | 7/15 | 2/5 | 9,0 s / 65,6 s | 15,8 s / 94,8 s | 10 GB |

**Osservazioni.**

- **Ollama usa già MLX.** Il log del server dice «starting mlx runner subprocess» per tutti e tre i modelli e `ollama ps` riporta `RUNNER mlx`, `100% GPU`. Il confronto con LM Studio (anch'esso MLX) non avrebbe cambiato il quadro e non è stato fatto; il provider funziona con entrambi perché usa la stessa API.
- **Il ragionamento va spento.** I modelli Qwen 3.5 «pensano» prima di rispondere: con 800 token di limite la risposta arrivava vuota dopo 55 s. Con `reasoning_effort: "none"` lo stesso piano costa 57 token. Il provider lo manda sempre (e riprova senza se un server lo rifiuta).
- **Memoria.** Ollama riserva il contesto massimo (131.072 token): 9–10 GB anche per il modello da 4 miliardi. Su 16 GB con il browser aperto è al limite. Con `OLLAMA_CONTEXT_LENGTH=8192` all'avvio di Ollama la memoria scende di molto: l'agente non usa più di qualche migliaio di token.
- **gemma4:e4b** produce spesso JSON non valido con lo schema imposto ed è il più lento: scartato.
- **MLX dentro l'app** (`mlx-swift-lm`, prodotto `MLXFoundationModels`): il pacchetto esiste e si integra con `LanguageModelSession`, ma la compilazione del pacchetto esterno non è stata autorizzata in questa sessione. Visto che Ollama gira già su MLX, il guadagno atteso è solo l'assenza del server, a fronte di gigabyte di pesi nel processo dell'app: resta rinviato.

**Decisioni.**

1. **Predefinito: modello Apple.** È il più veloce (6,5 s a compito), non occupa memoria propria e supera la soglia di SM-6 (70%).
2. **Modello locale esteso consigliato: `qwen3.5:9b` su Ollama.** Supera la soglia di SM-6 (85%) con il 90%, ma costa circa 20 s a compito e 10 GB: conviene quando la precisione conta più del tempo e il Mac ha memoria libera. **NFR-9 non è rispettato** per il modello esteso su M1 (prima azione 18,9 s contro 5 s): il limite viene dalla lettura del prompt su M1, non dal codice. Su Mac con più memoria e chip più recenti il quadro migliora.
3. `qwen3.5:4b` non conviene: più lento e meno preciso del modello Apple.

## 7. Confronto tra motori sul Banco (27/10)

| Motore | Riusciti | Brevi | Medi | Prima azione (mediana) | Tempo (mediana / 90°) |
| --- | --- | --- | --- | --- | --- |
| Claude (Sonnet 5.5 rapido, Opus 5.5 per i medi) | 18/20 (90%) | 13/15 | 5/5 | 4,7 s | 9,4 s / 23,5 s |
| Codex | vedi sotto | | | | |
| Locale, modello Apple | 16/20 (80%) | 12/15 | 4/5 | 5,6 s | 6,5 s / 9,5 s |
| Locale, qwen3.5:9b su Ollama | 18/20 (90%) | 13/15 | 5/5 | 18,9 s | 20,2 s / 47,2 s |

Claude riesce dove il locale rinuncia (modifiche nel notebook, «tutti quelli che hanno già…») e ha mancato i due clic sul menu del sito (ha detto di non aver verificato). Il modello Apple, guidato dal piano, è **più rapido di Claude** sui compiti brevi perché non c'è rete né avvio di processi.
