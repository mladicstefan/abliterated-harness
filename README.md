# Pi sandbox (Docker, Debian 13)

Pi coding agent in an isolated container, talking to llama.cpp on your host at `:8080`, with internet access.

## 1. Make llama-server reachable from the container

Inside a container `localhost` is the container itself, so llama-server must not listen only on `127.0.0.1`.
Add `--host 0.0.0.0` to your llama-server command (then run `firewall.sh` so the LAN can't reach it).
Optional but nicer: add `--alias qwen3.8-27b` and use that short name as `id` in `config/models.json`.

Your current `-c 32768` is tight for an agent; the model trains on 262k, so raise it if VRAM allows
and update `contextWindow` in `config/models.json` to match.

## 2. Build & run

```bash
cp .env.example .env
sed -i "s/^HOST_UID=.*/HOST_UID=$(id -u)/; s/^HOST_GID=.*/HOST_GID=$(id -g)/" .env
chmod +x pi entrypoint.sh firewall.sh

docker compose build
./pi                          # pi in ./workspace
WORKSPACE=~/code/myproj ./pi  # pi in another project
./pi bash                     # shell in the sandbox
sudo ./firewall.sh            # once, after the first run created the br-pi bridge
```

Inside pi, pick the model with `/model` (provider `llama-cpp`).

Quick connectivity test: `./pi curl -s http://host.docker.internal:8080/v1/models | jq .data[0].id`

## What's isolated

| | |
|---|---|
| Filesystem | Only `$WORKSPACE` is mounted. Root fs is read-only; `$HOME` is a named volume. |
| User | Non-root, UID = yours, `cap_drop: ALL`, `no-new-privileges` |
| Network | Own bridge `br-pi`; internet yes, host only `:8080`, LAN blocked (with `firewall.sh`) |
| Resources | 8 GB RAM, 4 CPUs, 1024 PIDs — edit in `compose.yaml` |
| Docker socket | Never mounted (that would be root on your host) |

Agent can still `npm i -g`, `pip install` (go into `~/.local` in the volume) and use venvs.
Upgrade pi: `docker compose build --no-cache --build-arg PI_VERSION=latest` or pin a version in `.env`.
Reset everything: `docker compose down -v`.

## Going further

- **gVisor**: install `runsc`, uncomment `runtime: runsc` — syscalls go through a user-space kernel.
- **Rootless Docker**: run the daemon itself unprivileged; a container breakout then lands as your user, not root.
- **Secrets**: don't put SSH keys/tokens in the workspace. If pi needs git push, use a deploy key scoped to one repo.
