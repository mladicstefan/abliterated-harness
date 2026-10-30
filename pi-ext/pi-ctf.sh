#!/usr/bin/env bash
# Launch pi with native MCP + skills, with MCP tools loaded on demand.
#
# pi (>=1.4) has a built-in MCP client, a `tool_search` tool (BM25 over tool
# metadata) and progressive-disclosure skills, so this harness no longer loads
# the old third-party pi-mcp-bridge / pi-skills extensions. Instead:
#   - MCP servers come from the agent-dir mcp.json (materialized below from
#     $PI_MCP_SRC, default /opt/pi/mcp.json). With exposure "deferred" their
#     tools stay OUT of the model's tool list; the prompt carries only a
#     compact `mcp_servers` index and the model pulls schemas via `tool_search`.
#   - skills in /opt/pi/skills are listed name+description only; the model
#     reads a SKILL.md body on demand with the `read` tool.
#
# Deferral is controlled by PI_DEFER (on|off|auto, default on):
#   on   : honor exposure as written in mcp.json (deferred/codemode).
#   off  : force every server to exposure=direct -> all MCP schemas declared
#          up front. This is the pre-1.4 eager behaviour (deferral disabled).
#   auto : estimate total MCP tool-definition size and defer only when it
#          exceeds PI_DEFER_THRESHOLD_PCT % (default 15) of the model context
#          window (chars/4 ~= tokens). See pi-ext/defer-estimate.mjs.
# Point at a different server set with PI_MCP_SRC=/workspace/my.mcp.json.
set -euo pipefail

PI_PKG="${PI_PKG:-@earendil-works/pi-coding-agent}"
AGENT_DIR="${PI_AGENT_DIR:-$HOME/.pi/agent}"
MCP_SRC="${PI_MCP_SRC:-/opt/pi/mcp.json}"
MCP_EFF="$AGENT_DIR/mcp.json"
SKILLS_DIR="${PI_SKILLS_DIR:-/opt/pi/skills}"
PI_DEFER="${PI_DEFER:-on}"
PI_DEFER_THRESHOLD_PCT="${PI_DEFER_THRESHOLD_PCT:-15}"

# Keep pi current on every launch. pi's built-in `pi update --self` refuses on
# the read-only global install, so we install the latest into the writable
# ~/.local prefix (a volume, first on PATH) which shadows the baked copy and
# persists across restarts. Best-effort: never block startup if offline.
# Disable with PI_CTF_NO_UPDATE=1; override the package with PI_PKG.
if [ "${PI_CTF_NO_UPDATE:-0}" != "1" ]; then
  if npm install -g --no-fund --no-audit "${PI_PKG}@latest" >/dev/null 2>&1; then
    hash -r   # re-resolve PATH so the freshly installed ~/.local/bin/pi is used
    echo "pi-ctf: pi up to date -> $(pi --version 2>/dev/null)" >&2
  else
    echo "pi-ctf: update skipped (offline/failed); using $(pi --version 2>/dev/null)" >&2
  fi
fi

# --- Materialize the effective mcp.json into the agent dir -----------------
# pi reads mcp.json from the agent dir automatically (no env var needed). We
# derive it from the read-only source so PI_DEFER can rewrite exposure without
# touching the canonical file.
mkdir -p "$AGENT_DIR"
if [ ! -f "$MCP_SRC" ]; then
  echo "pi-ctf: no MCP source at $MCP_SRC; starting with no MCP servers" >&2
  MCP_SRC=""
fi

# Strip the human-only `_comment` and (for `direct`) force every server's
# exposure, so pi reads a clean native config.
strip_comment() { jq 'del(._comment)' "$1"; }
force_direct()  { jq 'del(._comment) | .mcpServers |= with_entries(.value.exposure = "direct")' "$1"; }

# PI_DEFER=auto: probe MCP tool-def size and echo "defer" or "direct".
resolve_auto() {
  local pct
  pct="$(PI_MCP_SRC="$MCP_SRC" PI_MODELS="$AGENT_DIR/models.json" \
         node "${PI_DEFER_ESTIMATE:-/opt/pi/defer-estimate.mjs}" --pct 2>/dev/null || echo 100)"
  # integer-compare the floor of pct against the threshold
  if [ "${pct%%.*}" -ge "$PI_DEFER_THRESHOLD_PCT" ] 2>/dev/null; then
    echo "pi-ctf: defer=auto -> deferring (MCP ~${pct}% >= ${PI_DEFER_THRESHOLD_PCT}% of ctx)" >&2
    echo defer
  else
    echo "pi-ctf: defer=auto -> direct (MCP ~${pct}% < ${PI_DEFER_THRESHOLD_PCT}% of ctx)" >&2
    echo direct
  fi
}

# Resolve the effective mode ("defer" or "direct") once, so the materialized
# config and the pi args agree even in auto mode.
case "$PI_DEFER" in
  off) mode=direct;;
  on)  mode=defer;;
  auto) mode=defer;;  # refined below once we can probe the servers
  *) echo "pi-ctf: unknown PI_DEFER='$PI_DEFER' (use on|off|auto); defaulting to on" >&2; PI_DEFER=on; mode=defer;;
esac
if [ -n "$MCP_SRC" ]; then
  [ "$PI_DEFER" = auto ] && mode="$(resolve_auto)"
  rm -f "$MCP_EFF" 2>/dev/null || true
  if [ "$mode" = direct ]; then
    force_direct "$MCP_SRC" > "$MCP_EFF"
  else
    strip_comment "$MCP_SRC" > "$MCP_EFF"
  fi
  # read-only so a session can't silently repoint its own servers; the next
  # launch rebuilds it from source anyway.
  chmod 0444 "$MCP_EFF" 2>/dev/null || true
elif [ "$PI_DEFER" = auto ]; then
  mode=direct   # no servers to probe
fi

# --- Assemble pi args ------------------------------------------------------
args=()
# Activate the deferred-discovery tool so the model can pull MCP schemas on
# demand, but only when we actually deferred something. (codemode stays a
# loaded-but-inactive builtin; turn it on per run with `--tools +codemode`,
# or give a server exposure=codemode in mcp.json.)
[ "$mode" = defer ] && args+=(--tools +tool_search)
[ -d "$SKILLS_DIR" ] && args+=(--skill "$SKILLS_DIR")

exec pi "${args[@]}" "$@"
