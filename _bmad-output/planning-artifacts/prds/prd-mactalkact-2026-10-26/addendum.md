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
