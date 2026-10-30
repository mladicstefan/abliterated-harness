# Pi sandbox

Runs the Pi coding agent in an isolated Docker container that talks to a
llama.cpp server on your host. The container gets internet, but can only reach
your host on port 8080 and can't touch the rest of your LAN.

## 1. Run llama-server

Point it at your model and bind it so the container can reach it:

```bash
llama-server -m your-model.gguf --host 0.0.0.0 -c 32768
```

`--host 0.0.0.0` matters: inside the container `localhost` is the container,
not your host. `start.sh` applies a firewall so the rest of your LAN still
can't reach the server.

If your model name differs, update `id` and `contextWindow` in
`config/models.json` to match.

## 2. Start

```bash
./start.sh
```

That builds the image if needed, starts the container, applies the firewall
(asks for sudo), checks the model is reachable, and drops you into pi.

- Detach without stopping: `Ctrl-P Ctrl-Q`
- Re-attach: `./start.sh` again
- Stop: `docker compose down`
- Work on another project: `WORKSPACE=~/code/myproj ./start.sh`

Inside pi, pick the model with `/model` (provider `llama-cpp`).

## What's isolated

| | |
|---|---|
| Filesystem | Only `$WORKSPACE` is mounted. Root fs is read-only; `$HOME` is a named volume. |
| User | Non-root, UID = yours, `cap_drop: ALL`, `no-new-privileges` |
| Network | Own bridge `br-pi`; internet yes, host only `:8080`, LAN blocked |
| Resources | 8 GB RAM, 4 CPUs, 1024 PIDs — edit in `compose.yaml` |
| Docker socket | Never mounted |

The agent can still `npm i -g`, `pip install --user`, and use venvs — those land
in `~/.local` on the persistent volume.

## MCP tools & context

With many MCP servers wired in (the pentest layer alone is three), declaring
every tool to the model each turn burns a large, fixed slice of a small local
context window. pi (>=1.4) avoids this natively, and this harness leans on it
instead of the old eager bridge:

- MCP servers are declared in `pi-ext/mcp.json` (standard `mcpServers` shape,
  plus pi's `exposure` / `description` / `toolExposure`). At launch `pi-ctf`
  writes the effective config to the agent dir (`~/.pi/agent/mcp.json`); pi
  reads it there automatically.
- By default servers use `"exposure": "deferred"`: their tool schemas stay
  **out** of the model's tool list. The system prompt carries only a compact
  `mcp_servers` index (one line per server: name + `description`), and the
  model pulls the full schemas on demand with the built-in `tool_search` tool
  (BM25 over tool metadata). Loaded tools are recorded in the transcript, so
  they survive compaction, resume and fork.
- Core file/shell/edit tools are always loaded. To always-load a specific MCP
  server or tool, give it `"exposure": "direct"`, or pin individual tools with
  `"toolExposure": { "scan_*": "direct" }`.
- Skills (`/opt/pi/skills`) are listed name + description only; the model reads
  a `SKILL.md` body with the `read` tool when it activates one.

Control deferral with env vars (set before `./start.sh` or `./pi`):

| Var | Default | Meaning |
|---|---|---|
| `PI_DEFER` | `on` | `on` honor `exposure`; `off` force everything `direct` (pre-1.4 eager behaviour, deferral disabled); `auto` defer only when MCP tool defs exceed the threshold |
| `PI_DEFER_THRESHOLD_PCT` | `15` | `auto` only: defer when estimated MCP tool-def size (chars/4 ≈ tokens) exceeds this % of the model `contextWindow` |
| `PI_MCP_SRC` | `/opt/pi/mcp.json` | source config to materialize (e.g. `/workspace/my.mcp.json`) |

Example: `PI_DEFER=off ./pi` restores the old behaviour where all MCP tools are
declared up front. Code mode (`createCodemodeExtension`) ships in pi and stays
available (`--tools +codemode`, or `"exposure": "codemode"`), but is off by
default.

## Notes

- Reset everything: `docker compose down -v`
- Stronger isolation: install [gVisor](https://gvisor.dev) and uncomment
  `runtime: runsc` in `compose.yaml`.
- Don't keep SSH keys or tokens in the workspace. If pi needs to push, use a
  deploy key scoped to one repo.
