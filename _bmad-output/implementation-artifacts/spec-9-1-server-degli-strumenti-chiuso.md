---
title: 'Storia 9.1 — Server degli strumenti chiuso'
type: 'feature'
created: '2026-10-27'
status: 'in-review'
baseline_commit: '14547f2f368d7d7aeaa940c61565eb0531935085'
route: 'dispatch'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Il token del server degli strumenti stava negli argomenti di `claude` (`--mcp-config` con il JSON intero), quindi era leggibile con `ps` da ogni processo dell'utente. Il server non controllava né `Origin` né `Host`, quindi una pagina web su localhost, o un attacco di DNS rebinding, poteva tentare di raggiungerlo.

**Approach:** Per Claude, `--mcp-config` punta a un file 0600 nella cartella dell'app che contiene solo il riferimento `${MACTALK_MCP_TOKEN}`. La CLI lo espande dal suo ambiente, dove l'app mette il token. Per Codex resta `bearer_token_env_var`. Il server registra `MCP-Protocol-Version` e la revisione negoziata, e rifiuta con 403 le richieste con un `Origin` diverso dal server stesso o con un `Host` diverso da `127.0.0.1:<porta>` o `localhost:<porta>`.

## Boundaries & Constraints

**Always:** il token non compare mai negli argomenti di un processo né su disco; il file di configurazione viene cancellato alla chiusura; le CLI, che non mandano `Origin`, continuano a funzionare.

**Never:** nessun cambiamento agli strumenti né all'autenticazione bearer.

</frozen-after-approval>

## Code Map

- `Sources/MacTalkAct/MCPServer.swift` -- file di configurazione, `allowed(origin:host:port:)`, log del protocollo.
- `Sources/MacTalkAct/ClaudeCLI.swift`, `ClaudeEngine.swift` -- `Config.env` con il token, `--mcp-config` col percorso.
- `Sources/MacTalkAct/AgentEngine.swift`, `AgentRunner.swift` -- `mcpConfigPath`, cancellazione alla chiusura.
- `Sources/MacTalkAct/DebugCLI.swift` -- test.

## Tasks & Acceptance

**Execution:**
- [x] server, motori, test.

**Acceptance Criteria:**
- Given un compito con Claude, when parte, then la CLI si collega leggendo il token dall'ambiente e negli argomenti c'è solo il percorso del file.
- Given `--fallback-test`, when gira, then una richiesta con `Origin` estraneo o con `Host` sbagliato riceve 403 e il file è 0600 senza il token.

## Implementation Notes

- Spec approvata in autonomia (Nico: «committa e procedi»).
- La CLI `claude` 2.1.311 espande `${MACTALK_MCP_TOKEN}` nelle intestazioni: il ripiego «token nel file, cancellato dopo la connessione» non è servito.
- `Host` accetta anche `localhost:<porta>` oltre a `127.0.0.1:<porta>`: un attacco di DNS rebinding manda comunque un altro nome e viene rifiutato.
- Le richieste vengono rifiutate subito, senza la fase di sola registrazione: le CLI non mandano `Origin`, e il Banco con Claude e Codex funziona.
- `~/.codex/AGENTS.md` di Nico esiste ed è vuoto, e non è stato toccato. Codex col Banco (2 compiti) risponde in italiano con i soli strumenti di MacTalkAct. La prova con istruzioni di stile richiede un `CODEX_HOME` separato con il login: rinviata.

## Spec Change Log

## Review Triage Log
