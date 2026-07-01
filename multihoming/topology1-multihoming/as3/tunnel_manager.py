#!/usr/bin/env python3
"""
tunnel_manager.py  —  BGPoST IPv6 Multihoming Backup Tunnel Manager
====================================================================
Implements the mechanism described in Section 5.1 of:
  "The Multiple Benefits of a Secure Transport for BGP"
  Wirtgen et al., ACM CoNEXT 2024

What this script does
---------------------
1. Reads the BGPoST configuration JSON that was embedded inside the AS3
   X.509 certificate (written to /certs/bgpost_config.json at cert-gen time).
2. Parses tunnel parameters (type, local/remote IPv6 addresses, BFD settings).
3. Watches the main BGP uplink interface (eth0, toward AS2) using a
   lightweight BFD-style keepalive loop.
4. When the main link goes DOWN:
     a. Creates a GRE6 (IPv6-over-IPv6 GRE) tunnel interface via iproute2.
     b. Adds the IPv6 route for AS3's PA prefix through the tunnel.
     c. Signals BIRD to migrate the BGP session over the tunnel (birdc cmd).
5. When the main link comes back UP:
     a. Tears down the tunnel.
     b. Migrates BGP session back to the main link.

Usage (runs as PID 1 alongside BIRD inside the AS3 container):
    python3 /usr/local/bin/tunnel_manager.py \
        --cert-config /certs/bgpost_config.json \
        --main-iface  eth0 \
        --backup-iface eth1 \
        --log-level   INFO
"""

import argparse
import json
import logging
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

# ── Logging ──────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] tunnel_manager: %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("/var/log/tunnel_manager.log"),
    ],
)
log = logging.getLogger(__name__)

# ── Constants ─────────────────────────────────────────────────────────────────
TUNNEL_IFACE   = "gre-backup"   # name of the GRE tunnel interface
BIRDC_SOCKET   = "/run/bird/bird.ctl"
BIRD_PROTOCOL  = "bgp_as2"      # BIRD protocol name for the AS2 eBGP session
KEEPALIVE_INT  = 5              # seconds between reachability probes
PROBE_TIMEOUT  = 3              # seconds to wait for each probe
PROBE_FAILURES = 3              # consecutive failures before declaring link down
RECOVERY_PROBES = 3             # consecutive successes before declaring link up


# ── Helpers ───────────────────────────────────────────────────────────────────

def run(cmd: list[str], check: bool = True, capture: bool = False) -> subprocess.CompletedProcess:
    """Run a system command, log it, raise on failure."""
    log.debug("RUN: %s", " ".join(cmd))
    result = subprocess.run(
        cmd,
        check=check,
        capture_output=capture,
        text=True,
    )
    if capture and result.stdout:
        log.debug("OUT: %s", result.stdout.strip())
    return result


def birdc(command: str) -> Optional[str]:
    """Send a command to the BIRD daemon via birdc and return its output."""
    try:
        result = run(["birdc", command], capture=True)
        return result.stdout
    except subprocess.CalledProcessError as e:
        log.warning("birdc command failed: %s", e)
        return None


def iface_is_up(iface: str) -> bool:
    """Check if a network interface has LOWER_UP flag (carrier)."""
    try:
        r = run(["ip", "link", "show", iface], capture=True, check=False)
        return "LOWER_UP" in r.stdout
    except Exception:
        return False


def icmp_reachable(target_ip: str, iface: str, timeout: int = PROBE_TIMEOUT) -> bool:
    try:
        r = subprocess.run(
            ["ping", "-c", "1", "-W", str(timeout), "-I", iface, target_ip],
            capture_output=True,
            text=True,
            timeout=timeout + 1
        )
        return r.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


# ── Certificate config parser ─────────────────────────────────────────────────

class BGPoSTConfig:
    """
    Represents the router configuration embedded in the BGPoST X.509 certificate.
    In a full implementation this would be extracted from the cert's custom OID
    (1.3.6.1.4.1.99999.1) via python-cryptography. For simplicity we read the
    JSON file that gen_certs.sh wrote alongside the certificate.
    """

    def __init__(self, json_path: str):
        path = Path(json_path)
        if not path.exists():
            raise FileNotFoundError(f"BGPoST config not found: {json_path}")

        with open(path) as f:
            raw = json.load(f)

        log.info("Loaded BGPoST config from certificate: %s", json_path)
        log.info("Config: %s", json.dumps(raw, indent=2))

        self.prefixes: list[str]   = raw.get("prefixes", [])
        self.as_number: int        = raw.get("as_number", 0)
        tunnel_cfg                 = raw.get("tunnel", {})
        self.tunnel_type: str      = tunnel_cfg.get("type", "GRE")
        self.local_addr: str       = tunnel_cfg.get("local_addr", "")
        self.remote_addr: str      = tunnel_cfg.get("remote_addr", "")
        self.backup_via: str       = tunnel_cfg.get("backup_via", "")
        self.keepalive_interval: int = tunnel_cfg.get("keepalive_interval", KEEPALIVE_INT)
        self.use_bfd: bool         = tunnel_cfg.get("bfd", False)


# ── Tunnel lifecycle ──────────────────────────────────────────────────────────

class TunnelManager:
    """
    Manages a GRE6 backup tunnel between AS3 and AS2 (routed via AS1).

    State machine:
        MAIN_UP  →  (link failure detected)  →  TUNNEL_UP
        TUNNEL_UP →  (link recovery detected) →  MAIN_UP
    """

    def __init__(self, config: BGPoSTConfig, main_iface: str, backup_iface: str):
        self.cfg          = config
        self.main_iface   = main_iface
        self.backup_iface = backup_iface
        self.tunnel_active = False
        self._failure_count   = 0
        self._recovery_count  = 0
        self._running         = True

        signal.signal(signal.SIGTERM, self._handle_signal)
        signal.signal(signal.SIGINT,  self._handle_signal)

    def _handle_signal(self, signum, frame):
        log.info("Received signal %d, shutting down cleanly...", signum)
        self._running = False
        if self.tunnel_active:
            self._tear_down_tunnel()

    # ── Tunnel operations ─────────────────────────────────────────────────────

    def _bring_up_tunnel(self):
        """
        Creates a GRE6 tunnel interface and updates routing.
        Equivalent to the operator manually running:
          ip tunnel add gre-backup mode ip6gre ...
        but driven automatically by the certificate config.
        """
        log.info("═══ LINK FAILURE DETECTED — Activating backup GRE tunnel ═══")
        log.info("  Tunnel type : %s", self.cfg.tunnel_type)
        log.info("  Local addr  : %s", self.cfg.local_addr)
        log.info("  Remote addr : %s", self.cfg.remote_addr)
        log.info("  Backup via  : %s (AS1)", self.cfg.backup_via)

        try:
            # 1. Create GRE6 tunnel interface
# 0. Add a static host route so the kernel knows HOW to reach
            #    AS2's tunnel endpoint now that the direct link (eth0) is
            #    down. The route goes via AS1's address on the backup
            #    interface (eth1) -- this makes GRE encapsulation deliverable.
            run(["ip", "route", "add", f"{self.cfg.remote_addr}/32",
                 "via", self.cfg.backup_via, "dev", self.backup_iface],
                check=False)
            log.info("  Added static route: %s/32 via %s dev %s",
                      self.cfg.remote_addr, self.cfg.backup_via, self.backup_iface)

            # 1. Create GRE tunnel interface
            run(["ip","tunnel", "add", TUNNEL_IFACE,
                 "mode", "gre",
                 "local",  self.cfg.local_addr,
                  "remote", self.cfg.remote_addr])
            # 2. Bring tunnel interface up
            run(["ip", "link", "set", TUNNEL_IFACE, "up"])

            # 3. Assign a link-local address to the tunnel (needed for routing)
            run(["ip", "addr", "add",
                 "10.255.255.1/30", "dev", TUNNEL_IFACE],check=False)

            # 4. Add route for AS3's PA prefix through the tunnel
            for prefix in self.cfg.prefixes:
                log.info("  Adding route %s via %s (tunnel)", prefix, TUNNEL_IFACE)
                run(["ip","route", "add", prefix,
                     "dev", TUNNEL_IFACE], check=False)

            # 5. Tell BIRD to use the backup path
            self._migrate_bird_to_tunnel()

            self.tunnel_active   = True
            self._failure_count  = 0
            log.info("✓ Backup tunnel ACTIVE — traffic continues through AS1")

        except subprocess.CalledProcessError as e:
            log.error("Failed to bring up tunnel: %s", e)

    def _tear_down_tunnel(self):
        """Remove the GRE6 tunnel and restore main-link routing."""
        log.info("═══ MAIN LINK RECOVERED — Tearing down backup tunnel ═══")
        try:
            # 1. Restore BIRD to main link first (graceful restart)
            self._migrate_bird_to_main()

            # 2. Remove routes added for tunnel
            for prefix in self.cfg.prefixes:
                run(["ip","route", "del", prefix,
                     "dev", TUNNEL_IFACE], check=False)

            # 3. Delete tunnel interface
            run(["ip","tunnel", "del", TUNNEL_IFACE], check=False)

            # 4. Remove the static route via AS1 (no longer needed)
            run(["ip", "route", "del", f"{self.cfg.remote_addr}/32",
                 "via", self.cfg.backup_via, "dev", self.backup_iface],
                check=False)

            self.tunnel_active    = False
            self._recovery_count  = 0
            log.info("✓ Backup tunnel REMOVED — traffic restored via main link")

        except subprocess.CalledProcessError as e:
            log.error("Failed to tear down tunnel: %s", e)

    def _migrate_bird_to_tunnel(self):
        """
        Instruct BIRD to disable the direct eBGP session (main link) and
        enable the session over the tunnel interface.
        BIRD graceful-restart is used so no BGP Withdraws are sent.
        """
        log.info("  Migrating BIRD BGP session → tunnel interface")
        birdc(f"disable {BIRD_PROTOCOL}")
        # Give BIRD a moment to process
        time.sleep(0.5)
        # In a production setup you would switch BIRD's neighbour address
        # to the tunnel endpoint and do a graceful restart. For the PoC we
        # simply disable the protocol so routes are preserved (GR hold timer)
        # and the tunnel carries the data plane.
        log.info("  BIRD protocol '%s' disabled (GR hold active)", BIRD_PROTOCOL)

    def _migrate_bird_to_main(self):
        """Re-enable the direct eBGP session after main link recovery."""
        log.info("  Migrating BIRD BGP session → main interface")
        birdc(f"enable {BIRD_PROTOCOL}")
        log.info("  BIRD protocol '%s' re-enabled", BIRD_PROTOCOL)

    # ── Monitoring loop ───────────────────────────────────────────────────────

    def _probe_main_link(self) -> bool:
        """
        Returns True if the main link to AS2 is considered UP.
        Uses both interface carrier state and an ICMPv6 reachability probe.
        """
        if not iface_is_up(self.main_iface):
            log.debug("Interface %s has no carrier", self.main_iface)
            return False
        reachable = icmp_reachable(self.cfg.remote_addr, self.main_iface)
        if not reachable:
            log.debug("ICMPv6 probe to %s via %s failed",
                      self.cfg.remote_addr, self.main_iface)
        return reachable

    def run(self):
        """Main monitoring loop — probe the link and manage the tunnel state."""
        log.info("Tunnel Manager starting up")
        log.info("  Main interface   : %s", self.main_iface)
        log.info("  Backup interface : %s", self.backup_iface)
        log.info("  Probe interval   : %ds", self.cfg.keepalive_interval)
        log.info("  Failure threshold: %d consecutive failures", PROBE_FAILURES)

        while self._running:
            link_up = self._probe_main_link()

            if not self.tunnel_active:
                # ── Normal state: main link should be up ──────────────────────
                if link_up:
                    self._failure_count = 0
                else:
                    self._failure_count += 1
                    log.warning("Main link probe FAILED (%d/%d)",
                                self._failure_count, PROBE_FAILURES)
                    if self._failure_count >= PROBE_FAILURES:
                        self._bring_up_tunnel()
            else:
                # ── Tunnel state: watch for main link recovery ─────────────────
                if link_up:
                    self._recovery_count += 1
                    log.info("Main link RECOVERED (%d/%d)",
                             self._recovery_count, RECOVERY_PROBES)
                    if self._recovery_count >= RECOVERY_PROBES:
                        self._tear_down_tunnel()
                else:
                    self._recovery_count = 0
                    log.debug("Tunnel active, main link still DOWN")

            time.sleep(self.cfg.keepalive_interval)

        log.info("Tunnel Manager stopped.")


# ── Entry point ────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="BGPoST GRE Tunnel Manager — driven by X.509 certificate config"
    )
    parser.add_argument("--cert-config", default="/certs/bgpost_config.json",
                        help="Path to the BGPoST JSON config extracted from the cert")
    parser.add_argument("--main-iface",   default="eth0",
                        help="Main uplink interface toward AS2")
    parser.add_argument("--backup-iface", default="eth1",
                        help="Secondary interface toward AS1 (used for tunnel routing)")
    parser.add_argument("--log-level", default="INFO",
                        choices=["DEBUG", "INFO", "WARNING", "ERROR"])
    args = parser.parse_args()

    logging.getLogger().setLevel(getattr(logging, args.log_level))

    try:
        config = BGPoSTConfig(args.cert_config)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        log.critical("Cannot load BGPoST config: %s", e)
        sys.exit(1)

    manager = TunnelManager(config, args.main_iface, args.backup_iface)
    manager.run()


if __name__ == "__main__":
    main()