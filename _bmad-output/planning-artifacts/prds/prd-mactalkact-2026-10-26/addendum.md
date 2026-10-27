# Addendum al PRD — dettagli tecnici e alternative scartate

Materiale utile all'architettura e alle storie che non appartiene ai requisiti.

## Alternative valutate per il Router

| Alternativa | Esito | Motivo |
| --- | --- | --- |
| Allungare la lista `Grammar.actionVerbs` | Scartata | La lingua parlata ha troppe forme («rimetti», «cambiala», «fai che…»); ogni aggiunta lascia scoperte altre frasi e non risolve la Chiacchiera. |
| Classificare con Claude (Haiku o Sonnet) via CLI | Scartata | Avvio e risposta della CLI richiedono circa 2 s, consumano la subscription e smettono di funzionare al limite. |
| Classificatore on-device (FoundationModels) | Scelta | Verificato il 26/10: 6/6 corrette, 0,55–0,63 s a modello caldo, offline, gratuito. |
| Chiedere sempre conferma prima di scrivere | Scartata | Rallenta la dettatura, che è l'uso più frequente; la conferma resta solo per i casi incerti (FR-4). |

## Dettagli dell'esperimento on-device

- API: `SystemLanguageModel.default`, `LanguageModelSession(instructions:)`, `respond(to:generating:)` con un tipo `@Generable` e `@Guide(.anyOf([...]))` per vincolare l'uscita.
- Un `enum` `@Generable` ha fallito con «Unexpected value " dettatura"»: usare una struct con un campo `String` vincolato da `.anyOf`.
- Prima chiamata dopo l'avvio del processo: circa 2 s; conviene chiamare `prewarm()` all'avvio e dopo ogni risposta.
- Codice di prova in `scratchpad/fm/fm.swift` e `scratchpad/fm/act.swift` (non nel progetto).

## Idee per lo strumento di modifica negli editor web (FR-16)

1. Clic nel campo, `get_text` per leggere la riga dal testo visibile (screenshot o AX della pagina), poi selezione con Home / Shift+End sulla riga giusta e digitazione del nuovo testo.
2. In alternativa, Cmd+A dentro la cella (in Jupyter seleziona solo la cella) e riscrittura dell'intero contenuto, quando la cella è corta.
3. Verifica finale con screenshot o lettura del testo della pagina.

## Strumento in blocco (FR-15)

Firma proposta: `click_many(ids: [Int], method: "auto|mouse")` → per ogni id: etichetta, esito, stato dopo l'azione (`AXValue` per caselle e interruttori). Dopo uno scorrimento gli id cambiano: lo strumento rifiuta id di un registro scaduto.

## Alternative valutate per i Motori (27/10)

Dettagli e fonti in `research/valutazione-motori-agente-2026-10-27.md`.

| Alternativa | Esito | Motivo |
| --- | --- | --- |
| Codex tramite chiave API OpenAI | Scartata | Costi a consumo e una chiave da custodire; il login ChatGPT è già sul Mac e copre l'uso personale. |
| Codex con la configurazione personale dell'utente | Scartata | Porterebbe server MCP esterni, computer use e hook nell'Agente; si usa `--ignore-user-config` e si passa tutto con `-c`. |
| Ripetere sempre la richiesta sul Motore di riserva | Scartata | Se l'Agente ha già cliccato o scritto, ripetere può fare due volte la stessa azione (inviare due mail). Si ripete solo prima di ogni Azione con effetti. |
| Agente locale con il ciclo dell'Agente cloud (stesso prompt e tutti gli strumenti) | Scartata | Su M1 la lettura di migliaia di token di prompt costa secondi a ogni passo; il Motore locale ha prompt corto e meno strumenti. |
| Un client diverso per ogni server locale (Ollama, LM Studio, MLX) | Scartata | Tutti espongono `/v1/chat/completions` con `tools`: un solo provider compatibile OpenAI li copre. |
| MLX caricato dentro l'app (`MLXLanguageModel`) | Rinviata | Elegante con FoundationModels su macOS 27, ma mette gigabyte di pesi nel processo dell'app; si valuta nello spike della Storia 5.2. |
| Modello Apple su Private Cloud Compute | Rinviata | Richiede un entitlement che un'app firmata localmente forse non può ottenere. |

## Opzioni di avvio di Codex (bozza da confermare nella Storia 4.1)

```text
codex exec - --json --ephemeral --skip-git-repo-check --ignore-user-config --ignore-rules \
  --sandbox read-only -m <modello> -c model_reasoning_effort="low" \
  --disable shell_tool --disable unified_exec --disable computer_use --disable browser_use \
  --disable apps --disable plugins --disable image_generation \
  -c mcp_servers.mactalk.url="http://127.0.0.1:<porta>/mcp" \
  -c mcp_servers.mactalk.bearer_token_env_var="MACTALK_MCP_TOKEN" \
  -c mcp_servers.mactalk.required=true \
  -c developer_instructions="<prompt di sistema dell'Agente>"
```

Il token del server MCP passa solo nell'ambiente del processo figlio. La chiave usata per le istruzioni di sistema (`developer_instructions` o equivalente) va verificata sulla versione installata.

## Candidati valutati per precisione e velocità dell'Agente (27/10, sera)

Dettagli, fonti e matrice pesata in `research/technical-agente-precisione-velocita-e-strumenti-2026-10-27/research.md` (§6). Vincoli: abbonamenti senza chiave API obbligatoria; ai Motori solo gli strumenti dell'app; dati locali sul Mac; macOS 27 su M1 16 GB. Pesi: precisione 35 %, velocità 30 %, sicurezza 25 %, lavoro 10 %.

| Alternativa | Esito | Motivo |
| --- | --- | --- |
| API Anthropic diretta, Agent SDK, Responses API OpenAI con computer use | Scartate | Richiedono una chiave API (per l'SDK Anthropic lo dice esplicitamente); il modello computer-use di OpenAI è stato dismesso il 23 luglio 2026. |
| Server MCP `computer-use` di Claude Code / computer use di OpenAI | Scartati | Non disponibili fuori dalla sessione interattiva (`-p` escluso) e non documentati per client terzi. |
| Modalità `--bare` di `claude -p` | Scartata | Avvio più rapido ma senza il login dell'abbonamento; diventerà il default: FR-45 lo sorveglia. |
| Ping periodico per tenere calda la cache del prompt | Scartato | È «uso continuo in background», che Anthropic limita; la Sessione lunga rinnova la cache solo mentre l'utente lavora. |
| Codex `app-server` | Rinviato | Thread caldi per 30 minuti, ma nessun modo documentato di escludere shell e file; «mai permesso per servizi commerciali o ospitati». |
| Azioni dirette via Apple Events (Mail, Calendar, Safari, Finder, Chromium) | Solo spike (FR-49) | Dizionari vivi su macOS 27, ma su Tahoe timeout di 2 minuti per Mail e Finder appeso su «empty trash», Messaggi rotto, consensi Automation fragili, JavaScript via Apple Events disattivato da Chromium. |
| Controllo del browser via porta di debug (CDP) o estensione Playwright | Scartato | Porta aperta a ogni processo locale; token che salta le conferme; solo Chrome/Edge. |
| Modello di grounding locale da 4 miliardi (Eyes-4B, Qwen-UI-Agent-4B) | Rinviato | 50,9 % su ScreenSpot-Pro a bassa risoluzione in MLX 4-bit; nessuna latenza misurata su M1. |
| MLX in-process (`MLXFoundationModels`, mlx-swift-lm 3.32.3) | Rinviato a spike | Nessuna porta aperta e tool calling multi-round, ma pesi nel processo dell'app e nessuna misura su M1; Ollama 0.40 usa già MLX anche su 16 GB. |
| Classificatore semantico delle azioni come difesa principale | Ridotto a secondo strato (FR-55) | Un classificatore per azione è stato aggirato nel 60–80 % dei tentativi; i giudici LLM mancano un terzo dei comportamenti non sicuri. |

## Note tecniche per la Sessione lunga (FR-42)

- `claude -p --input-format stream-json --output-format stream-json` con più messaggi utente nello stesso processo (modalità «streaming input», quella preferita dall'SDK); `--no-session-persistence` resta; nessun `/clear` in `-p`: il riavvio è l'unico modo di azzerare il contesto.
- Attesa del server MCP all'avvio: regolare `CLAUDE_CODE_MCP_STARTUP_WAIT_MS`; la lista degli strumenti in cache evita l'attesa dai processi successivi.
- Cache del prompt: prefisso `tools → system → messages`, TTL 5 minuti rinnovato a ogni uso; cambiare modello o effort invalida la cache, quindi ogni livello ha la propria sessione.
- Blocchi noti del processo lungo (issue 53584, «not planned»): timeout per turno e riavvio.

## Note tecniche per lo spike sulle azioni dirette (FR-49)

Cinque verbi con tempo massimo 3 s: `open location` in Safari e nei browser Chromium, `make new event` in Calendario, `reveal` nel Finder, ricerca in una casella di Mail, `send` di una bozza con conferma. Niente `do shell script`, niente `execute javascript`. Registrare: tempo, errore (-1712, -1743, -600), consenso Automation richiesto, versione dell'app bersaglio.

## Residuo di isolamento di Codex (FR-50)

`~/.codex/AGENTS.md` viene letto anche con `--ignore-user-config --ignore-rules`. Rimedi da provare nella storia: `CODEX_HOME` dedicato al processo figlio (rischio: invalidare il login al rinnovo del token) oppure una directory di lavoro vuota con le regole disattivate; in ogni caso la suite di sicurezza verifica che un file di prova non cambi il comportamento.

## Modello Apple con immagini (candidato K-b, prova in FR-47)

macOS 27 accetta immagini nei prompt del modello on-device (contesto 8192 token) e i tool Vision `OCRTool` e `BarcodeReaderTool`; il modello descrive e legge, non localizza elementi. Esito della prova su 5 compiti del Banco da registrare nella ricerca; nessun requisito finché non c'è un numero.
