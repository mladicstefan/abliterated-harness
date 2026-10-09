#!/usr/bin/env bash
set -euo pipefail

url="${LLAMA_BASE_URL:-http://host.docker.internal:8080/v1}"

if curl -fsS --max-time 3 "${url}/models" >/dev/null 2>&1; then
  echo "✓ llama.cpp reachable at ${url}" >&2
else
  echo "⚠ Cannot reach ${url}" >&2
  echo "  llama-server must listen on 0.0.0.0 or 172.30.0.1 (not 127.0.0.1). See README." >&2
fi

exec "$@"
