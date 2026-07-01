# Lab Topology

## Purpose

This topology emulates a smaller version of an enterprise network using the BIRD routing stack.

The design includes:

- OSPF Area 0 as the campus/core area.
- ABRs connecting the core to non-backbone areas.
- An NSSA area for branch/guest/DMZ-like routing.
- A stub area for a smaller branch.
- eBGP connectivity to an external ISP/upstream router.
- iBGP between enterprise WAN edge routers.
- BFD on WAN edge BGP sessions.
- GR/LLGR configured on BGP sessions.

## Router Roles

| Node | Role |
|---|---|
| hpe-r1 | Enterprise WAN edge router, OSPF Area 0, eBGP to ISP, iBGP to hpe-r2 |
| hpe-r2 | Enterprise WAN edge router, OSPF Area 0, eBGP to ISP, iBGP to hpe-r1 |
| hpe-r3 | Area Border Router between Area 0 and NSSA Area 10 |
| hpe-r4 | Area Border Router between Area 0 and Stub Area 20 |
| hpe-r5 | Internal router in NSSA Area 10 |
| hpe-r6 | NSSA branch router and gateway for hpe-h1 |
| hpe-r7 | Internal router in Stub Area 20 |
| hpe-r8 | Stub branch router and gateway for hpe-h2 |
| hpe-r9 | External ISP/upstream router in AS65002 |

## Host Networks

| Host | IP Address | Gateway Router |
|---|---|---|
| hpe-h1 | 10.0.61.2/24 | hpe-r6 |
| hpe-h2 | 10.0.82.2/24 | hpe-r8 |
| hpe-h3 | 10.0.93.2/24 | hpe-r9 |

## OSPF Design

OSPF is used as the internal routing protocol.

- Area 0 contains the enterprise core.
- Area 10 is used as an NSSA-style branch/guest area.
- Area 20 is used as a stub-style branch area.
- hpe-r3 and hpe-r4 act as ABRs.

## BGP Design

BGP is used for WAN and inter-domain reachability.

- hpe-r1 and hpe-r2 connect to hpe-r9 using eBGP.
- hpe-r1 and hpe-r2 exchange internal routes using iBGP.
- GR and LLGR are configured for BGP state preservation experiments.

## BFD Design

BFD is enabled on WAN-edge BGP sessions to provide fast failure detection.

## Conclusion

This topology gives a realistic small-scale enterprise routing lab. It includes core routing, ABRs, NSSA/stub areas, WAN eBGP, iBGP, BFD, and BGP recovery mechanisms.