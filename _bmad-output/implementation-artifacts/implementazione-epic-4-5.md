---
title: Implementazione Epic 4 e 5 — Mai senza Agente, Bravo anche da solo
date: 2026-10-27
epics: [epic-4, epic-5]
---

# Implementazione Epic 4 e 5

## Epic 4 — Mai senza Agente

| Storia | Realizzazione |
| --- | --- |
| 4.1 Spike Codex | Nuovo comando `--mcp-serve` (solo il server degli strumenti). Opzioni verificate su `codex exec` 0.164: servono `default_tools_approval_mode="approve"` sul server MCP (altrimenti ogni strumento viene rifiutato) e `model_instructions_file` (istruzioni dell'agente al posto di quelle di Codex, token in ingresso da ~47.000 a ~21.000); `code_mode_host` deve restare acceso. Il processo pronto in anticipo fa risparmiare solo qualche decimo: **un processo per richiesta**. Modelli: rapido `gpt-6-luna` (prima azione ~3,5 s), profondo `gpt-6.1-sol`. Esito completo nella ricerca, §4. |
| 4.2 Protocollo dei motori | `AgentEngine.swift`: protocollo `AgentEngine`, `EngineID`, `AgentLevel`, `AgentRequest`, `AgentEngineError` (con `allowsFallback`), `EnginePause`, `LimitMessage` (messaggi di limite di Claude e Codex: «resets 7pm», «try again at 5:40 PM», «try again at Nov 3rd, 2026 9:15 AM», «try again in 2 hours»). `ClaudeEngine.swift` contiene la logica che era in `AgentRunner` (processi pronti, livelli, pausa). `AgentRunner` compone il messaggio e possiede strumenti, server e lucchetto. |
| 4.3 Codex | `CodexCLI.swift` (ricerca del binario saltando gli shim di altre app, opzioni dello spike, token MCP solo nell'ambiente, lettura del JSONL con `CodexEventParser`, abbandono anticipato su limite, login mancante o rete assente) e `CodexEngine.swift` (stato «accesso da fare» da `codex login status`, pausa per limite). |
| 4.4 Locale di base | `LocalEngine.swift`: `LanguageModelSession` con adattatori `Tool` costruiti da `AgentTools.definitions`, prompt corto, 8 passi. Superata dalla modalità piano della Storia 5.4. |
| 4.5 Scelta e catena | `EngineSelector.select` (funzione pura): scelto → altro cloud → locale; con «Locale» scelto nessun passaggio al cloud (NFR-10). Avvisi una volta per passaggio, «Codex è tornato» al ritorno. Sottomenu «Motore dell'agente» nella barra (motori con stato, catena, ricontrollo). |
| 4.6 Limite a metà | `AgentTools.effectfulCalls`; `AgentRunner.run` ripete sul motore successivo solo con zero azioni con effetti, altrimenti `RunError.stoppedMidway` («Claude si è fermato a metà: ho fatto 1 passo, controlla. La prossima richiesta userà Codex.»). |
| 4.7 Impostazioni e stato | Sezione «Agente» rinominata «Motori»: motore scelto, catena, schede Claude, Codex, Locale, limiti comuni. Stato e diagnostica: una riga per motore con stato e ultimo errore, «Ricontrolla i motori». README aggiornato. |

## Epic 5 — Bravo anche da solo

| Storia | Realizzazione |
| --- | --- |
| 5.1 Banco di prova | `Tests/bench/agente.tsv` (20 compiti) e 6 pagine in `Tests/bench/pages/` che scrivono il proprio stato nel titolo; `--agent-bench [--engine] [--only] [--model] [--local-mode]` apre le pagine in Safari, esegue, verifica e salva la tabella in `~/Library/Logs/`. |
| 5.2 Spike modelli locali | qwen3.5:4b, qwen3.5:9b, gemma4:e4b su Ollama (motore MLX verificato nel log). Consigliato `qwen3.5:9b` (90%, ~20 s, ~10 GB); predefinito resta il modello Apple. MLX dentro l'app: compilazione del pacchetto esterno non autorizzata in sessione, rinviato. Esito nella ricerca, §6. |
| 5.3 Modello locale esteso | `OpenAICompatibleModel.swift`: `ServerLanguageModel` + `ServerModelExecutor` (protocollo `LanguageModel` di macOS 27) verso `/v1/chat/completions`, con strumenti, schema JSON per la generazione vincolata, `reasoning_effort: none`, `keep_alive` per Ollama; solo `localhost` senza conferma. Impostazioni: indirizzo, elenco dei modelli dal server, permanenza in memoria, «Prova». Se il server non risponde, modello Apple con avviso. |
| 5.4 Locale ottimizzato | `LocalStepAgent.swift`, modalità **piano**: dal 5% all'80% col modello Apple (registro delle prove nella ricerca, §5). Regole di sicurezza: solo elementi della pagina, scarto dei clic non pertinenti e di quelli rischiosi non chiesti, rischiosi per ultimi, conferma che cita la richiesta, nessuna scrittura su testi esistenti per le modifiche, riepilogo onesto di ciò che è stato fatto. Avviso «Col modello locale potrebbe non riuscire» per i compiti lunghi. |
| 5.5 Niente cloud dove non serve | `LocalText.swift`: ripulitura della dettatura col modello Apple (1–3 s) quando il motore in uso non è Claude. Le macro mandano i passi liberi al motore in uso, compreso quello locale. README: «Senza abbonamenti: il motore locale». |

## Miglioramenti trasversali emersi dal Banco

- `observe` mostra lo stato delle caselle (`(checked)`/`(unchecked)`) e segna gli elementi della pagina web (`(page)`).
- `observe` con `query` trova anche elementi fuori schermo; il clic col mouse li porta prima in vista.
- `type_text` con un id verifica che il campo mostri il testo scritto.

## Verifica

| Verifica | Risultato |
| --- | --- |
| `--selftest` | tutto ok: selettore su tutte le combinazioni, messaggi di limite reali e simulati, JSONL di Codex, argomenti senza token, schema del passo, analisi degli elementi |
| `--fallback-test` | ok: con zero azioni la richiesta passa a Codex, con un'azione si ferma senza ripetere |
| `--route-test` | 116/116, 0 scritture indebite |
| Codex reale | limite d'uso reale ricevuto e letto correttamente («try again at 5:07 AM» → pausa fino alle 05:07) |
| Banco | Claude 18/20, modello Apple 16/20, qwen3.5:9b 18/20 (tabella nella ricerca, §7) |

## Scostamenti

- **Codex senza processo pronto**: lo spike ha mostrato che non serve (AD-13 invariata, decisione nella ricerca).
- **Motore locale a piano** invece del ciclo con gli strumenti nativi previsto da AD-17: gli strumenti nativi restano disponibili (`--local-mode tools`), ma col modello Apple riuscivano 1 compito su 20.
- **NFR-9 non rispettato per il modello esteso su M1** (prima azione ~19 s contro 5 s): limite dell'hardware, documentato.
- **Confronto con LM Studio non fatto**: Ollama usa già MLX e il provider è lo stesso.
- Con «Locale» scelto la catena di riserva non passa al cloud (privacy): scelta presa durante la Storia 4.5 e descritta nel README.
