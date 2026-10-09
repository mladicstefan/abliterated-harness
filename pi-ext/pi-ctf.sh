#!/usr/bin/env bash
# Launch pi with the MCP bridge + skills wired in (this pi has no built-in MCP client).
#   - clawos pi-mcp-bridge  -> exposes .mcp.json servers as tools  mcp__<server>__<tool>
#   - @spences10/pi-skills  -> skill manager extension
#   - /opt/pi/skills        -> baked skills (@howaboua + any you drop in)
# Override the server set by exporting CLAWD_PI_MCP_CONFIGS to your own JSON file list, e.g.
#   CLAWD_PI_MCP_CONFIGS='["/workspace/my.mcp.json"]' pi-ctf
set -euo pipefail

BRIDGE=/opt/pi/vendor/node_modules/@clawos-dev/pi-mcp-bridge/extension.cjs
SKILLMGR=/opt/pi/vendor/node_modules/@spences10/pi-skills/dist/index.js

# Keep pi current on every launch. pi's built-in `pi update --self` refuses on
# the read-only global install, so we install the latest into the writable
# ~/.local prefix (a volume, first on PATH) which shadows the baked copy and
# persists across restarts. Best-effort: never block startup if offline.
# Disable with PI_CTF_NO_UPDATE=1; override the package with PI_PKG.
PI_PKG="${PI_PKG:-@earendil-works/pi-coding-agent}"
if [ "${PI_CTF_NO_UPDATE:-0}" != "1" ]; then
  if npm install -g --no-fund --no-audit "${PI_PKG}@latest" >/dev/null 2>&1; then
    hash -r   # re-resolve PATH so the freshly installed ~/.local/bin/pi is used
    echo "pi-ctf: pi up to date -> $(pi --version 2>/dev/null)" >&2
  else
    echo "pi-ctf: update skipped (offline/failed); using $(pi --version 2>/dev/null)" >&2
  fi
fi

export CLAWD_PI_MCP_CONFIGS="${CLAWD_PI_MCP_CONFIGS:-[\"/opt/pi/mcp.json\"]}"

args=()
[ -f "$BRIDGE" ]   && args+=(-e "$BRIDGE")
[ -f "$SKILLMGR" ] && args+=(-e "$SKILLMGR")
[ -d /opt/pi/skills ] && args+=(--skill /opt/pi/skills)

exec pi "${args[@]}" "$@"
