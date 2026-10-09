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

## Notes

- Reset everything: `docker compose down -v`
- Stronger isolation: install [gVisor](https://gvisor.dev) and uncomment
  `runtime: runsc` in `compose.yaml`.
- Don't keep SSH keys or tokens in the workspace. If pi needs to push, use a
  deploy key scoped to one repo.
