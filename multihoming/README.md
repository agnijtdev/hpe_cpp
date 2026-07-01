# Multihoming

## Based On
> *"The Multiple Benefits of a Secure Transport for BGP"*
> Thomas Wirtgen, Nicolas Rybowski, Cristel Pelsser, Olivier Bonaventure
> ACM CoNEXT 2024 — Section 5.1 (Resilient IPv6 Multihoming)

---

## Roles

| Container | AS Number | Role | Description |
|---|---|---|---|
| `bgpost_as1` | AS 65001 | Provider (Backup Path) | Transit ISP, carries backup traffic when AS2↔AS3 link fails |
| `bgpost_as2` | AS 65002 | Provider (Main Path) | Primary ISP, AS3's normal internet connection goes through here |
| `bgpost_as3` | AS 65003 | Stub (Customer) | Multihomed customer network, connects to both providers |

---

## Topology Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                    BGPoST Topology 1 — Multihoming                  │
│         AS1 = Provider (backup)   AS2 = Provider (main)             │
│         AS3 = Stub (multihomed customer)                            │
└─────────────────────────────────────────────────────────────────────┘

         ┌──────────────────┐                ┌──────────────────┐
         │      AS1         │                │      AS2         │
         │  (65001)         │                │  (65002)         │
         │  Provider        │◄───BGP/TLS────►│  Provider       │
         │  Backup Path     │  172.30.12.x   │  Main Path       │
         │                  │                │                  │
         │  172.30.12.2     │                │  172.30.12.3     │
         │  172.30.13.2     │                │  172.30.23.2     │
         └────────┬─────────┘                └────────┬─────────┘
                  │                                   │
                  │ BGP/TLS (backup link)             │ BGP/TLS (main link)
                  │ 172.30.13.x                       │ 172.30.23.x
                  │ (idle normally)                   │ (default route)
                  │                                   │
         ┌────────┴───────────────────────────────────┴──────────┐
         │                        AS3                            │
         │                      (65003)                          │
         │                   Stub Network                        │
         │                                                       │
         │   eth0: 172.30.23.3  ──► main link  to AS2            |
         │   eth1: 172.30.13.3  ──► backup link to AS1           │
         └───────────────────────────────────────────────────────┘


NORMAL STATE — main link AS3 ↔ AS2 is UP
─────────────────────────────────────────
  AS3 ──eth0──► AS2   (direct, default route, BGP Established)
  AS3  eth1     AS1   (connected but idle, no active tunnel)

FAILURE STATE — AS3 eth0 goes DOWN
────────────────────────────────────
  AS3 ──eth0──✗ AS2   (link dead, BGP session held via Graceful Restart)
  AS3 ──eth1──► AS1 ──► AS2   (GRE backup tunnel activated automatically)

  GRE tunnel (gre-backup):
  - - - - - - - - - - - - - - - - - - - - - - - - -
  local:  172.30.23.3  (AS3)
  remote: 172.30.23.2  (AS2)
  routed: via 172.30.13.2 (AS1) on eth1
  - - - - - - - - - - - - - - - - - - - - - - - - -

NETWORKS & IPs SUMMARY
───────────────────────
  net_as1_as2  172.30.12.0/24   AS1(172.30.12.2) ↔ AS2(172.30.12.3)
  net_as1_as3  172.30.13.0/24   AS1(172.30.13.2) ↔ AS3(172.30.13.3)
  net_as2_as3  172.30.23.0/24   AS2(172.30.23.2) ↔ AS3(172.30.23.3)

BGP SESSIONS (all over TLS, mutual X.509 certificates)
────────────────────────────────────────────────────────
  AS1 ↔ AS2   172.30.12.2 ↔ 172.30.12.3   always up
  AS1 ↔ AS3   172.30.13.2 ↔ 172.30.13.3   always up
  AS2 ↔ AS3   172.30.23.2 ↔ 172.30.23.3   main link (failover target)

---

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Docker | ≥ 24.x | Container runtime |
| Docker Compose | ≥ 2.x | Multi-container orchestration |
| OpenSSL | ≥ 3.x | Certificate generation |
| Python 3 | ≥ 3.10 | tunnel_manager.py inside container |

Install on Ubuntu:
```bash
sudo apt update && sudo apt install -y docker.io docker-compose-v2 openssl python3
sudo usermod -aG docker $USER   # log out and back in after this
```

---

## Project Directory Structure

```
bgpost-lab/
├── certs/
│   ├── gen_certs.sh             # generates all X.509 certs with embedded JSON
│   ├── distribute_certs.sh      # copies certs into each container build context
│   ├── ca/                      # root Certificate Authority
│   ├── as1/                     # AS1 router cert
│   ├── as2/                     # AS2 router cert
│   └── as3/                     # AS3 router cert + bgpost_config.json
│
└── topology1-multihoming/
    ├── docker-compose.yml        # network + container definitions
    ├── as1/
    │   ├── Dockerfile
    │   ├── bird.conf             # BIRD BGP over TLS config
    │   ├── entrypoint.sh
    │   └── certs/               # filled by distribute_certs.sh
    ├── as2/
    │   ├── Dockerfile
    │   ├── bird.conf
    │   ├── entrypoint.sh
    │   └── certs/
    └── as3/
        ├── Dockerfile
        ├── bird.conf
        ├── entrypoint.sh
        ├── tunnel_manager.py     # cert-driven GRE tunnel automation
        └── certs/                # contains bgpost_config.json
```

---

## Step 0 — Build the BGPoTLS BIRD Image (One Time Only)

```bash
git clone https://github.com/IPNetworkingLab/BGPoTLS.git
cd BGPoTLS
sudo docker build -t bird-tls:latest .
cd ..
```

This builds the modified BIRD routing daemon that supports `transport tls;` in BGP protocol blocks. This step takes 5-10 minutes on first run.

---

## Step 1 — Generate Certificates

```bash
cd ~/bgpost-lab/certs
sudo bash gen_certs.sh
sudo bash distribute_certs.sh
```

`gen_certs.sh` creates:
- A root CA that signs all router certificates
- Per-router X.509 certificates for AS1, AS2, AS3
- For AS3 specifically, a certificate with BGPoST tunnel configuration embedded in a custom OID extension field, and a `bgpost_config.json` file beside it

`distribute_certs.sh` copies each router's certificate into its respective Docker build context so containers can mount them.

---

## Step 2 — Start the Containers

```bash
cd ~/bgpost-lab/topology1-multihoming
sudo docker compose up --build -d
```

Wait 15 seconds for BIRD to start and BGP sessions to establish:
```bash
sleep 15
sudo docker ps | grep bgpost
```

Expected output — all three containers must show `Up`:
```
bgpost_as3   ...   Up X seconds
bgpost_as2   ...   Up X seconds
bgpost_as1   ...   Up X seconds
```

If any container shows `Restarting`, check its logs:
```bash
sudo docker logs bgpost_as1 2>&1 | tail -20
```

---

## Step 3 — Verify BGP Sessions Are Established

Check all three routers have active BGP sessions over TLS:

```bash
sudo docker exec bgpost_as1 birdcl show protocols
sudo docker exec bgpost_as2 birdcl show protocols
sudo docker exec bgpost_as3 birdcl show protocols
```

Expected output for AS3 (stub):
```
Name       Proto   Table   State   Since         Info
device1    Device  ---     up      ...
direct1    Direct  ---     up      ...
kernel1    Kernel  master4 up      ...
bgp_as2    BGP     ---     up      ...   Established
static1    Static  master4 up      ...
```

`bgp_as2` must show `Established` — this is the main BGP session over TLS between AS3 (stub) and AS2 (main provider).

---

## Step 4 — Check Normal State (Before Failure)

### Routing table on AS3 (stub)
```bash
sudo docker exec bgpost_as3 ip route
```

Expected — default route goes via AS2 directly:
```
default via 172.30.23.2 dev eth0
172.30.23.0/24 dev eth0 proto kernel scope link src 172.30.23.3
172.30.13.0/24 dev eth1 proto kernel scope link src 172.30.13.3
```

### Confirm no backup tunnel exists yet
```bash
sudo docker exec bgpost_as3 ip link show gre-backup 2>&1
```


### Ping from AS1 (backup provider) to AS3 (stub)
```bash
sudo docker exec bgpost_as1 ping -c 4 172.30.13.3
```

Expected — 0% packet loss:
```
4 packets transmitted, 4 received, 0% packet loss
```

### Ping from AS2 (main provider) to AS3 (stub)
```bash
sudo docker exec bgpost_as2 ping -c 4 172.30.23.3
```

Expected — 0% packet loss via direct link.

### Tunnel manager log — should show no failures
```bash
sudo docker exec bgpost_as3 tail -10 /var/log/tunnel_manager.log
```

Expected — only startup messages, no WARNING lines.

---

## Step 5 — Trigger the Failover (Simulate Link Failure)

Bring down AS3's main interface (eth0 — the direct link to AS2):
```bash
sudo docker exec bgpost_as3 ip link set eth0 down
```

Wait for tunnel_manager.py to detect the failure (3 probes × 5 seconds = 15 seconds):
```bash
sleep 20
```

---

## Step 6 — Observe the Failover Results

### Tunnel manager decision log
```bash
sudo docker exec bgpost_as3 tail -25 /var/log/tunnel_manager.log
```

Expected output:
```
[WARNING] tunnel_manager: Main link probe FAILED (1/3)
[WARNING] tunnel_manager: Main link probe FAILED (2/3)
[WARNING] tunnel_manager: Main link probe FAILED (3/3)
[INFO]    tunnel_manager: ═══ LINK FAILURE DETECTED — Activating backup GRE tunnel ═══
[INFO]    tunnel_manager:   Tunnel type : GRE
[INFO]    tunnel_manager:   Local addr  : 172.30.23.3
[INFO]    tunnel_manager:   Remote addr : 172.30.23.2
[INFO]    tunnel_manager:   Backup via  : 172.30.13.2 (AS1)
[INFO]    tunnel_manager:   Added static route: 172.30.23.2/32 via 172.30.13.2 dev eth1
[INFO]    tunnel_manager:   Adding route 10.3.0.0/16 via gre-backup (tunnel)
[INFO]    tunnel_manager:   Migrating BIRD BGP session → tunnel interface
[INFO]    tunnel_manager:   BIRD protocol 'bgp_as2' disabled (GR hold active)
[INFO]    tunnel_manager: ✓ Backup tunnel ACTIVE — traffic continues through AS1
```

### GRE tunnel interface is now active
```bash
sudo docker exec bgpost_as3 ip link show gre-backup
```

Expected:
```
9: gre-backup@NONE: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1476 ...
    link/gre 172.30.23.3 peer 172.30.23.2
```

### AS3 routing table after failover
```bash
sudo docker exec bgpost_as3 ip route
```

Expected — route to AS2 now goes via AS1 (eth1), not the dead eth0:
```
default via 172.30.13.1 dev eth1
172.30.23.2 via 172.30.13.2 dev eth1          ← host route via AS1
10.3.0.0/16 dev gre-backup scope link          ← tunnel route
172.30.13.0/24 dev eth1 proto kernel ...
```

### Connectivity test through the tunnel
```bash
sudo docker exec bgpost_as3 ping -c 4 172.30.23.2
```

Expected — 0% packet loss even though direct link is down:
```
64 bytes from 172.30.23.2: icmp_seq=1 ttl=63 time=0.134 ms
64 bytes from 172.30.23.2: icmp_seq=2 ttl=63 time=0.138 ms
4 packets transmitted, 4 received, 0% packet loss
```

Traffic path: **AS3 → eth1 → AS1 → AS2** (encapsulated in GRE)

### AS2 (main provider) to AS3 — expected to FAIL
```bash
sudo docker exec bgpost_as2 ping -c 4 172.30.23.3
```

Expected — this fails, which is correct. AS2's direct link to AS3 is genuinely broken. AS2 has no other path to AS3's address. This is the correct and expected behavior — AS2 is the failed provider.

### AS1 (backup provider) to AS3 — expected to SUCCEED
```bash
sudo docker exec bgpost_as1 ping -c 4 172.30.13.3
```

Expected — 0% packet loss. AS1's link to AS3 was never affected, proving AS3 remains reachable via its backup provider even when the main provider link fails.

### BGP session state during failover
```bash
sudo docker exec bgpost_as3 birdcl show protocols
```

Expected:
```
bgp_as2    BGP   ---   down   ...   (Graceful Restart hold active)
```

BGP session is held in Graceful Restart mode, preserving routes in the routing table while the tunnel carries data plane traffic.

---

## Step 7 — Restore the Main Link (Recovery)

Bring AS3's eth0 back up:
```bash
sudo docker exec bgpost_as3 ip link set eth0 up
```

Wait for tunnel_manager.py to detect recovery (3 successful probes × 5 seconds):
```bash
sleep 20
```

---

## Step 8 — Verify Recovery

### Tunnel manager recovery log
```bash
sudo docker exec bgpost_as3 tail -15 /var/log/tunnel_manager.log
```

Expected:
```
[INFO] tunnel_manager: Main link RECOVERED (1/3)
[INFO] tunnel_manager: Main link RECOVERED (2/3)
[INFO] tunnel_manager: Main link RECOVERED (3/3)
[INFO] tunnel_manager: ═══ MAIN LINK RECOVERED — Tearing down backup tunnel ═══
[INFO] tunnel_manager: ✓ Backup tunnel REMOVED — traffic restored via main link
```

### Confirm tunnel is gone
```bash
sudo docker exec bgpost_as3 ip link show gre-backup 2>&1
```

Expected:
```
Device "gre-backup" does not exist.
```

### Routing table restored to normal
```bash
sudo docker exec bgpost_as3 ip route
```

Expected — default route back via AS2 directly:
```
default via 172.30.23.2 dev eth0 proto bird
172.30.23.0/24 dev eth0 proto kernel scope link src 172.30.23.3
```

### BGP session re-established
```bash
sudo docker exec bgpost_as3 birdcl show protocols
```

Expected:
```
bgp_as2    BGP   ---   up   ...   Established
```

### Direct ping from AS2 to AS3 works again
```bash
sudo docker exec bgpost_as2 ping -c 4 172.30.23.3
```

Expected — 0% packet loss on direct link.

---

## Stopping the Lab

```bash
cd ~/bgpost-lab/topology1-multihoming
sudo docker compose down --remove-orphans
```

---


## What This Demonstrates

| Paper Claim | What You Observed |
|---|---|
| BGP sessions secured with TLS mutual auth | `transport tls` + X.509 certs in BIRD, `Established` state confirmed |
| X.509 certs carry router configuration | `bgpost_config.json` embedded in cert drives all tunnel parameters |
| Automatic GRE backup tunnel on link failure | `gre-backup` interface appeared automatically, 0 operator commands needed |
| Traffic rerouted via second provider | Ping AS3→AS2 succeeded via AS1 even with direct link down |
| BGP Graceful Restart preserves routes | `bgp_as2` held in GR mode, no route flap during tunnel transition |
| Automatic tunnel teardown on recovery | `gre-backup` deleted automatically after 3 successful probes |
| BGP session restored after recovery | `bgp_as2` returned to `Established` over TLS |
