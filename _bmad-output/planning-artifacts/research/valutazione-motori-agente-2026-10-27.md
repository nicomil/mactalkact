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
