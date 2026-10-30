# syntax=docker/dockerfile:1.7
# Pi coding agent sandbox — Debian 13 (trixie), non-root, Node 24 LTS.

ARG NODE_VERSION=24

# Pull the official Node binaries from the (Debian-based) node image,
# so the runtime image stays plain Debian without the extra "node" user.
FROM node:${NODE_VERSION}-trixie-slim AS node

FROM kalilinux/kali-rolling
ARG PI_VERSION=latest
ARG HOST_UID=1000
ARG HOST_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TERM=xterm-256color

# Base tooling a coding agent actually uses (git, rg, fd, jq, python, compilers).
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git openssh-client gnupg \
      jq ripgrep fd-find tree less nano file procps \
      unzip zip xz-utils bzip2 \
      python3 python3-pip python3-venv \
      build-essential pkg-config \
      tini tzdata \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd

# Node.js + npm
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && node --version && npm --version

# Pi itself, baked into the image (rebuild with --build-arg PI_VERSION=x.y.z to pin/upgrade).
# The package was renamed from @mariozechner/pi-coding-agent (frozen at 0.73.1) to
# @earendil-works/pi-coding-agent; pi-ctf keeps it current at runtime.
RUN --mount=type=cache,target=/root/.npm \
    npm install -g "@earendil-works/pi-coding-agent@${PI_VERSION}" \
 && command -v pi && pi --version

# ---------------------------------------------------------------------------
# Web-CTF / pentest layer. Everything lands in /opt (outside the pi-home
# volume) so it survives at runtime. pi (>=1.4) has a built-in MCP client, so
# servers are reached natively from the agent-dir mcp.json (materialized by
# /usr/local/bin/pi-ctf from /opt/pi/mcp.json); their tools are loaded on
# demand via pi's `tool_search`. No third-party MCP bridge is used.
#
# NOTE: the git repos below are third-party and unpinned (cloned at build
# time). They execute real tooling. Review them; build only in the sandbox.
# ---------------------------------------------------------------------------

# Pentest CLIs the servers/skills shell out to. Kali has most; split so a
# rename in kali-rolling can't fail the whole build (extended set best-effort).
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
 && apt-get install -y --no-install-recommends \
      nmap nikto sqlmap ffuf nuclei gobuster dirb whatweb wfuzz \
      seclists wordlists dnsutils pipx \
 && for p in subfinder httpx-toolkit katana dalfox amass; do \
      apt-get install -y --no-install-recommends "$p" || echo "WARN: optional pkg $p unavailable"; \
    done

# keel-pentest (scoped MCP control plane) in its own venv -> /usr/local/bin/keel-pentest
RUN python3 -m venv /opt/keel \
 && /opt/keel/bin/pip install --no-cache-dir keel-pentest \
 && ln -s /opt/keel/bin/keel-pentest /usr/local/bin/keel-pentest \
 && keel-pentest --help >/dev/null 2>&1 || echo "WARN: keel-pentest smoke test non-zero"

# Node-based MCP servers, built from source. Each is its own best-effort RUN:
# a failed clone/build just leaves that server absent (the bridge reports it
# down at runtime) instead of failing the image. tsc comes from the repo's
# devDependencies (mcp-pentest) or is pinned here (cyber unified server).

# adriyansyah-mf/mcp-pentest -> dist/index.js  (build: tsc). Upstream has a
# type error in parameter-extraction.ts; tsc still emits JS (no noEmitOnError),
# so we keep the emitted output and gate on the file existing, not tsc's exit.
RUN git clone --depth 1 https://github.com/adriyansyah-mf/mcp-pentest /opt/pi/vendor/mcp-pentest \
 && ( cd /opt/pi/vendor/mcp-pentest && npm install --no-audit --no-fund && (npm run build || true) ) \
 && test -f /opt/pi/vendor/mcp-pentest/dist/index.js && echo "mcp-pentest OK" \
 || echo "WARN: mcp-pentest unavailable (remove its entry from /opt/pi/mcp.json)"

# hackersatyamrastogi/pentesting-cyber-mcp -> build only the self-contained
# `unified` server with tsc, skipping the turbo/pnpm monorepo orchestration.
RUN git clone --depth 1 https://github.com/hackersatyamrastogi/pentesting-cyber-mcp /opt/pi/vendor/pentesting-cyber-mcp \
 && ( cd /opt/pi/vendor/pentesting-cyber-mcp/servers/unified \
      && npm install --no-audit --no-fund \
      && npm install -D --no-audit --no-fund typescript@5 \
      && npx tsc -p tsconfig.json \
      && chmod +x build/index.js ) \
 && test -f /opt/pi/vendor/pentesting-cyber-mcp/servers/unified/build/index.js && echo "cyber unified OK" \
 || echo "WARN: cyber unified unavailable (remove its entry from /opt/pi/mcp.json)"

# Skills, vendored into /opt/pi. pi loads these natively with `--skill`
# (progressive disclosure: name+description in the prompt, SKILL.md read on
# demand) — no third-party skill-manager extension needed.
RUN npm install --prefix /opt/pi/vendor \
      @howaboua/pi-skill-harness-and-agent-engineering \
 && mkdir -p /opt/pi/skills \
 && cp -r /opt/pi/vendor/node_modules/@howaboua/pi-skill-harness-and-agent-engineering/skills/. /opt/pi/skills/

COPY --chmod=0755 pi-ext/pi-ctf.sh /usr/local/bin/pi-ctf
COPY pi-ext/mcp.json /opt/pi/mcp.json
COPY pi-ext/defer-estimate.mjs /opt/pi/defer-estimate.mjs

# Non-root user whose UID/GID match yours on the host -> no root-owned files in your projects
RUN groupadd -g "${HOST_GID}" pi \
 && useradd -m -u "${HOST_UID}" -g "${HOST_GID}" -s /bin/bash pi \
 && mkdir -p /workspace /home/pi/.pi/agent /home/pi/.local/bin \
 && chown -R pi:pi /workspace /home/pi

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

# Let the agent install its own npm/pip packages into $HOME (a volume) — no root needed
ENV NPM_CONFIG_PREFIX=/home/pi/.local \
    PIP_USER=1 \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    PATH=/home/pi/.local/bin:${PATH}

USER pi
WORKDIR /workspace

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["pi-ctf"]
