#!/usr/bin/env bash
# =============================================================================
# observe.sh — BGPoST Lab Output & Observation Tool
# =============================================================================
# This script is your window into the lab. It runs pre-defined observation
# sequences so you can SEE the BGPoST mechanisms working.
#
# Usage:
#   bash scripts/observe.sh topo1          # IPv6 Multihoming demo
#   bash scripts/observe.sh topo2          # Anycast scaling demo
#   bash scripts/observe.sh topo1 failover # Trigger link failure
#   bash scripts/observe.sh topo2 kill-a   # Kill replica A NSD
#   bash scripts/observe.sh status         # Show container health
#   bash scripts/observe.sh logs <name>    # Tail a container log
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

banner()  { echo -e "\n${BOLD}${CYAN}══════════ $* ══════════${NC}"; }
step()    { echo -e "\n${GREEN}▶ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠  $*${NC}"; }
info()    { echo -e "   ${CYAN}$*${NC}"; }
hr()      { echo -e "${CYAN}──────────────────────────────────────────────────${NC}"; }

# ── Container names ────────────────────────────────────────────────────────────
AS1="bgpost_as1"
AS2="bgpost_as2"
AS3="bgpost_as3"
RA="bgpost_router_a"
RB="bgpost_router_b"
REPA="bgpost_replica_a"
REPB="bgpost_replica_b"
CLIENT="bgpost_client"

# ── Helpers ────────────────────────────────────────────────────────────────────

require_container() {
  if ! docker ps --format '{{.Names}}' | grep -q "^$1$"; then
    warn "Container $1 is not running. Start it first:"
    case "$1" in
      bgpost_as*) echo "  cd topology1-multihoming && docker compose up -d" ;;
      *)          echo "  cd topology2-anycast && docker compose up -d" ;;
    esac
    exit 1
  fi
}

birdc_show() {
  local container="$1"; shift
  docker exec "$container" birdc "$@" 2>/dev/null || echo "(birdc not available)"
}

# ── Status overview ────────────────────────────────────────────────────────────

cmd_status() {
  banner "BGPoST Lab Container Status"
  echo ""
  printf "  %-25s %-12s %-20s\n" "CONTAINER" "STATUS" "IP(s)"
  hr
  for name in $AS1 $AS2 $AS3 $RA $RB $REPA $REPB $CLIENT; do
    status=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "not found")
    ips=$(docker inspect --format='{{range .NetworkSettings.Networks}}{{.GlobalIPv6Address}} {{end}}' \
          "$name" 2>/dev/null | tr -s ' ' | head -c 45 || echo "")
    color="$GREEN"
    [[ "$status" != "running" ]] && color="$RED"
    printf "  ${color}%-25s${NC} %-12s %-20s\n" "$name" "$status" "$ips"
  done
  echo ""
}

# ── Topology 1 observation ─────────────────────────────────────────────────────

cmd_topo1() {
  banner "Topology 1: IPv6 Multihoming Backup Tunnel"

  for c in $AS1 $AS2 $AS3; do require_container "$c"; done

  step "BGP Session Status (AS3 perspective)"
  info "Checking BIRD protocols on AS3..."
  birdc_show $AS3 "show protocols all bgp_as2"
  birdc_show $AS3 "show protocols all bgp_as2_tunnel"

  step "Routing Table on AS3"
  docker exec $AS3 ip -6 route show 2>/dev/null || true

  step "TLS Certificates on AS3 (BGPoST config embedded in cert)"
  docker exec $AS3 cat /certs/bgpost_config.json 2>/dev/null \
    | python3 -m json.tool 2>/dev/null || echo "(cert config not yet deployed)"

  step "Tunnel Manager Live Log (last 20 lines)"
  docker exec $AS3 tail -20 /var/log/tunnel_manager.log 2>/dev/null \
    || echo "(log not yet available)"

  step "Network Interfaces on AS3"
  docker exec $AS3 ip -6 addr show 2>/dev/null || true

  echo ""
  echo -e "${YELLOW}To trigger the failover, run:${NC}"
  echo "  bash scripts/observe.sh topo1 failover"
}

# ── Topology 1 failover trigger ────────────────────────────────────────────────

cmd_topo1_failover() {
  banner "Topology 1: Simulating Link Failure (AS3 ↔ AS2 main link)"

  for c in $AS1 $AS2 $AS3; do require_container "$c"; done

  step "BEFORE FAILURE: BGP session state"
  birdc_show $AS3 "show protocols bgp_as2"

  step "BEFORE FAILURE: Routing table"
  docker exec $AS3 ip -6 route 2>/dev/null

  step "BEFORE FAILURE: Interfaces"
  docker exec $AS3 ip link show 2>/dev/null

  step "Simulating link failure (taking down eth0 on AS3)..."
  warn "This will cause the main link to drop. tunnel_manager.py will detect"
  warn "this via ICMPv6 probes and bring up the GRE backup tunnel."
  echo ""

  docker exec $AS3 ip link set eth0 down 2>/dev/null || \
    warn "Could not take down eth0 (may need --privileged). Try manual: docker exec -it bgpost_as3 ip link set eth0 down"

  step "Waiting 20 seconds for tunnel_manager.py to detect failure and act..."
  for i in $(seq 20 -1 1); do
    printf "\r  Countdown: %2ds  " "$i"
    sleep 1
  done
  echo ""

  step "AFTER FAILURE: BGP session state"
  birdc_show $AS3 "show protocols all"

  step "AFTER FAILURE: GRE tunnel interface"
  docker exec $AS3 ip link show gre-backup 2>/dev/null \
    && echo -e "${GREEN}✓ GRE backup tunnel is UP${NC}" \
    || echo -e "${RED}✗ GRE tunnel not yet created${NC}"

  step "AFTER FAILURE: Routing table (should route via gre-backup)"
  docker exec $AS3 ip -6 route 2>/dev/null

  step "Tunnel Manager log (what happened)"
  docker exec $AS3 tail -30 /var/log/tunnel_manager.log 2>/dev/null

  step "Connectivity test through tunnel"
  docker exec $AS3 ping6 -c 3 2001:db8:12::1 2>/dev/null \
    && echo -e "${GREEN}✓ Reachable via backup tunnel through AS1${NC}" \
    || echo -e "${RED}✗ Not reachable (tunnel may still be coming up)${NC}"

  echo ""
  step "To restore the main link:"
  echo "  docker exec bgpost_as3 ip link set eth0 up"
}

# ── Topology 2 observation ─────────────────────────────────────────────────────

cmd_topo2() {
  banner "Topology 2: Anycast Service Scaling"

  for c in $RA $RB $REPA $REPB; do require_container "$c"; done

  step "BGP Routes for Anycast Prefix on Router A"
  info "Checking if 2001:db8:ff::/48 is in the routing table..."
  birdc_show $RA "show route 2001:db8:ff::/48"

  step "BGP Routes on Router B"
  birdc_show $RB "show route 2001:db8:ff::/48"

  step "Health Monitor Log — Replica A (last 20 lines)"
  docker exec $REPA tail -20 /var/log/health_monitor.log 2>/dev/null \
    || echo "(log not yet available)"

  step "Health Monitor Log — Replica B (last 20 lines)"
  docker exec $REPB tail -20 /var/log/health_monitor.log 2>/dev/null \
    || echo "(log not yet available)"

  step "BGPoST Certificate Config — Replica A"
  docker exec $REPA cat /certs/bgpost_config.json 2>/dev/null \
    | python3 -m json.tool 2>/dev/null || echo "(cert not yet deployed)"

  step "NSD DNS Server Status — Replica A"
  docker exec $REPA nsd-checkconf /etc/nsd/nsd.conf 2>/dev/null \
    && echo "NSD config OK" || echo "(NSD not yet running)"

  step "DNS Test from Client (20 queries to anycast address)"
  require_container $CLIENT
  docker exec $CLIENT bash /test_dns.sh 20 example.com 2>/dev/null || true

  echo ""
  echo -e "${YELLOW}To kill Replica A's DNS and watch BGP withdraw:${NC}"
  echo "  bash scripts/observe.sh topo2 kill-a"
}

# ── Topology 2 replica kill ────────────────────────────────────────────────────

cmd_topo2_kill_a() {
  banner "Topology 2: Kill Replica A DNS → Watch BGP Withdraw"

  for c in $REPA $RA $CLIENT; do require_container "$c"; done

  step "BEFORE: Anycast route on Router A"
  birdc_show $RA "show route 2001:db8:ff::/48"

  step "BEFORE: Health monitor state"
  docker exec $REPA tail -5 /var/log/health_monitor.log 2>/dev/null

  step "Killing NSD on Replica A..."
  docker exec $REPA pkill nsd 2>/dev/null || warn "Could not kill NSD (already dead?)"
  echo "NSD killed. health_monitor.py will detect failure in ~30 seconds."

  step "Watching health monitor log in real-time (Ctrl+C to stop)..."
  echo -e "${YELLOW}Watch for 'WITHDRAWING anycast prefix' message:${NC}"
  docker logs -f --tail=0 $REPA &
  LOG_PID=$!
  sleep 35
  kill $LOG_PID 2>/dev/null || true

  step "AFTER: Anycast route on Router A (should be gone)"
  birdc_show $RA "show route 2001:db8:ff::/48"

  step "AFTER: Route should still exist on Router B (Replica B healthy)"
  birdc_show $RB "show route 2001:db8:ff::/48"

  step "DNS test — traffic should now go ONLY to Replica B"
  docker exec $CLIENT bash /test_dns.sh 10 example.com 2>/dev/null || true

  step "To restart NSD on Replica A (observe re-advertisement):"
  echo "  docker exec bgpost_replica_a nsd -c /etc/nsd/nsd.conf"
}

# ── Live log tailing ────────────────────────────────────────────────────────────

cmd_logs() {
  local target="${1:-}"
  case "$target" in
    as1|as2|as3) docker logs -f "bgpost_$target" ;;
    router-a)    docker logs -f "$RA" ;;
    router-b)    docker logs -f "$RB" ;;
    replica-a)   docker logs -f "$REPA" ;;
    replica-b)   docker logs -f "$REPB" ;;
    client)      docker logs -f "$CLIENT" ;;
    tunnel)      docker exec $AS3 tail -f /var/log/tunnel_manager.log ;;
    health-a)    docker exec $REPA tail -f /var/log/health_monitor.log ;;
    health-b)    docker exec $REPB tail -f /var/log/health_monitor.log ;;
    *)
      echo "Available log targets:"
      echo "  as1, as2, as3, router-a, router-b, replica-a, replica-b"
      echo "  client, tunnel, health-a, health-b"
      ;;
  esac
}

# ── Main dispatcher ─────────────────────────────────────────────────────────────

CMD="${1:-help}"
shift || true

case "$CMD" in
  status)          cmd_status ;;
  topo1)
    case "${1:-}" in
      failover)    cmd_topo1_failover ;;
      *)           cmd_topo1 ;;
    esac
    ;;
  topo2)
    case "${1:-}" in
      kill-a)      cmd_topo2_kill_a ;;
      *)           cmd_topo2 ;;
    esac
    ;;
  logs)            cmd_logs "${1:-}" ;;
  help|*)
    banner "BGPoST Lab — Observation Tool"
    echo ""
    echo "  Usage: bash scripts/observe.sh <command>"
    echo ""
    echo "  Commands:"
    echo "    status              Show all container status"
    echo "    topo1               Observe Topology 1 (multihoming tunnel)"
    echo "    topo1 failover      Trigger main link failure → watch GRE tunnel come up"
    echo "    topo2               Observe Topology 2 (anycast scaling)"
    echo "    topo2 kill-a        Kill Replica A NSD → watch BGP withdraw"
    echo "    logs <target>       Tail container or service log"
    echo ""
    echo "  Log targets for 'logs': as1 as2 as3 router-a router-b"
    echo "                           replica-a replica-b tunnel health-a health-b"
    echo ""
    ;;
esac