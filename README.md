# Self-Driving Dynamic Routing and BGP over Secure Transport

A Docker-based virtual routing lab built on the **BIRD 2.0.8** routing stack that
demonstrates self-healing dynamic routing (OSPF + BGP + BFD + ECMP + Graceful
Restart/LLGR) and secure BGP transport (TLS / QUIC).

**Project ID:** CPP3-77 — College of Engineering, Trivandrum, APJ Abdul Kalam
Technological University
**Mentor:** Muthiah Sivappirakasam, Principal Engineer, Hewlett Packard Enterprise
**Team:** Agnij T Dev, Angel Roy, Devanarayanan H, Gopika Sreekumar, Rohan A Jacob

---

## Overview

The project has two parts:

1. **Self-Driving Dynamic Routing** — a 9-router / 3-host enterprise topology
   (Docker containers running BIRD) that self-detects and recovers from link,
   interface, and control-plane failures using OSPF, BGP, BFD, and ECMP.
2. **BGP over Secure Transport (BGPoST)** — a fork of BIRD extended to run BGP
   over TLS and QUIC, tested for propagation delay, multi-homing failover, and
   anycast DNS failover.

## Topology (Part I)

- **Core/backbone:** `hpe-r1`, `hpe-r2` (WAN edge), `hpe-r3`, `hpe-r4` (ABRs)
- **Area 10 (NSSA):** `hpe-r5`, `hpe-r6` → host `hpe-h1`
- **Area 20 (Stub):** `hpe-r7`, `hpe-r8` → host `hpe-h2`
- **External AS:** `hpe-r9` (ISP, AS65002) → host `hpe-h3`
- Enterprise AS: 65001

Protocols: OSPF (Area 0 backbone, NSSA Area 10, Stub Area 20), eBGP at the WAN
edge, BFD (single-hop + multihop), ECMP, Graceful Restart, and LLGR.

## Key Results (Part I)

| Test | Result |
|---|---|
| BFD WAN edge detection | 72 ms avg (target < 300 ms) |
| OSPF core link recovery | 85 ms kernel switch / 635 ms full convergence |
| OSPF ECMP failover (direct) | ~75 ms, 0% packet loss |
| OSPF ECMP silent blackhole (no BFD → with BFD) | 17,989 ms → 1,264 ms |
| Multihop BFD detection | 511–571 ms avg, 15/15 runs < 1 s |
| OSPF area healing (ABR, silent blackhole) | 18.7 s → 1.3 s with BFD |
| NSSA Type-7 → Type-5 translation | Verified; external routes contained in stub area |
| BGP Graceful Restart | 0% packet loss during restart |
| BGP LLGR stale-route timer | Stale at ~5 s, withdrawn at ~15 s (matches config) |
| BGP peer flap recovery | Alternate path in 93 ms, full recovery in 1,754 ms |

Every experiment above was repeated across multiple runs (14–30 depending on
the test) to avoid relying on a single result; averages, medians, and standard
deviations are recorded for each.

## BGP over Secure Transport (Part II)

Extends BIRD with `transport tls;` and `transport quic;` config options
(mutual X.509 authentication, TLS-AO, certificate-embedded JSON config).

- **Prefix propagation:** compared TCP, TLS, QUIC, TLS-AO Static, TLS-AO
  Dynamic across a 10-router chain (13,104 observed prefixes) — TLS/TLS-AO
  stayed close to plain TCP; QUIC showed a slightly higher but acceptable delay.
- **Multi-homing over BGPoTLS:** automatic GRE-tunnel failover to a backup
  provider, driven by certificate-embedded config and a health-check script,
  with BGP Graceful Restart preserving forwarding state.
- **Anycast DNS over BGPoTLS:** two replicas advertise a shared anycast IP;
  a health-check script withdraws the BGP route on DNS failure, achieving
  failover in under 4 seconds with no client-side change.

## Tech Stack

| Category | Tools |
|---|---|
| Virtualization | Docker |
| OS | Ubuntu Linux |
| Routing | BIRD 2.0.8 (OSPF, BGP, BFD) |
| Secure transport | TLS 1.3, QUIC (picotls / picoquic), mutual X.509 |
| Failure injection | `ip link`, `tc netem` |
| Traffic testing | `ping`, `tcpdump` |
| Automation / analysis | Bash, Python |

## Repository Layout (suggested)

```
anycast/       
bgpost_lab/       
multihoming/    
self_driving_dynamic_routing/        
report/         # project report
```

