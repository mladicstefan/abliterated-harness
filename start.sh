#!/usr/bin/env bash
# Start the sandbox (detached), apply the host firewall, check llama.cpp, then attach to pi.
#   ./start.sh
# Detach without stopping pi: Ctrl-P Ctrl-Q.  Re-attach: ./start.sh again.  Stop: docker compose down
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
export HOST_UID="$(id -u)" HOST_GID="$(id -g)"

LLAMA_PORT=8080

# 1) Kernel: bridge networking needs veth. Fails after a kernel upgrade without reboot.
if ! modprobe -n -q veth 2>/dev/null && ! lsmod | grep -q '^veth'; then
  echo "✗ veth module unavailable for running kernel $(uname -r) (kernel upgraded without reboot?)." >&2
  echo "  Reboot, or restore modules from the pacman cache and run: sudo depmod $(uname -r) && sudo modprobe veth" >&2
  exit 1
fi

# 2) llama-server must be up on the host
if ! curl -fsS --max-time 3 "http://127.0.0.1:${LLAMA_PORT}/v1/models" >/dev/null; then
  echo "⚠ llama-server not answering on :${LLAMA_PORT} — start it with --host 0.0.0.0" >&2
fi

# 3) Build image if missing. Compose builds via bake, which needs --allow for `network: host`.
if ! docker image inspect pi-sandbox:latest >/dev/null 2>&1; then
  docker buildx bake -f compose.yaml --allow=network.host pi
fi

# 4) Start (no-op if already running)
docker compose up -d pi

# 5) Firewall: rules are idempotent but not persistent, so apply every start (needs the br-pi bridge)
sudo ./firewall.sh

# 6) Can the container reach llama.cpp?
if docker compose exec -T pi curl -fsS --max-time 3 "http://host.docker.internal:${LLAMA_PORT}/v1/models" >/dev/null 2>&1; then
  echo "✓ llama.cpp reachable from the sandbox"
else
  echo "⚠ sandbox cannot reach host.docker.internal:${LLAMA_PORT} — pi will start but can't talk to the model" >&2
fi

# 7) Attach to pi
echo "Attaching — detach with Ctrl-P Ctrl-Q (Ctrl-C stops pi). Press Ctrl-L if the screen is blank."
exec docker attach "$(docker compose ps -q pi)"
