#!/usr/bin/env bash
# Optional host firewall for the sandbox network (run as root, after `docker compose up` / first run
# has created the br-pi bridge). Result:
#   - container -> internet:       allowed
#   - container -> your LAN/VPN:   blocked
#   - container -> host:           only port 8080 (llama.cpp)
#   - LAN -> host:8080:            blocked (safe to run llama-server on 0.0.0.0)
# Not persistent across reboots — add to your firewall config if you want it permanent.
# Safe to re-run: each rule is removed (all copies) and re-inserted, so the order is always as listed.
set -euo pipefail

BR=br-pi
PORT=8080

# put CHAIN RULE... : remove every existing copy, then insert at the top.
# Rules are therefore listed below in REVERSE of their final order (last call = first rule).
put() {
  local chain=$1; shift
  while iptables -C "$chain" "$@" 2>/dev/null; do iptables -D "$chain" "$@"; done
  iptables -I "$chain" "$@"
}

# 1) Forwarded traffic: block container -> private networks, keep replies to established flows.
for net in 100.64.0.0/10 169.254.0.0/16 192.168.0.0/16 172.16.0.0/12 10.0.0.0/8; do
  put DOCKER-USER -i "$BR" -d "$net" -j DROP
done
put DOCKER-USER -i "$BR" -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN

# 2) Traffic to the host itself. Final order:
#      lo -> PORT                ACCEPT
#      br-pi established         ACCEPT
#      br-pi -> PORT             ACCEPT
#      br-pi anything else       DROP
#      anyone else -> PORT       DROP   (LAN can't reach llama.cpp)
put INPUT -p tcp --dport "$PORT" -j DROP
put INPUT -i "$BR" -j DROP
put INPUT -i "$BR" -p tcp --dport "$PORT" -j ACCEPT
put INPUT -i "$BR" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
put INPUT -i lo -p tcp --dport "$PORT" -j ACCEPT

# 3) nftables inet filter (the system ruleset in /etc/nftables.conf). On Arch,
#    `iptables` above is iptables-nft and lands in the `ip filter` table, which is
#    SEPARATE from `inet filter`. If that chain has `policy drop` (it does by
#    default) and allows only lo/icmp/ssh/established, it rejects br-pi -> host:PORT
#    before the rules above ever matter — that's why the container got an instant
#    "connection refused". Allow br-pi -> PORT there too. Established replies are
#    already covered by the chain's existing ct-state accept.
TAG="pi-sandbox-llama"
if command -v nft >/dev/null 2>&1 && nft list chain inet filter input >/dev/null 2>&1; then
  # Drop any previous copy of our rule, then insert fresh at the top (idempotent).
  while handle=$(nft -a list chain inet filter input 2>/dev/null \
                   | awk -v t="$TAG" '$0 ~ t {print $NF; exit}'); [ -n "${handle:-}" ]; do
    nft delete rule inet filter input handle "$handle"
  done
  nft insert rule inet filter input iifname "$BR" tcp dport "$PORT" accept comment \"$TAG\"
  echo "nft: allowed $BR -> host:$PORT in 'inet filter input'."
else
  echo "nft: no 'inet filter input' chain (or nft absent) — skipped; iptables rules above may suffice."
fi

echo "Firewall rules for $BR applied."
