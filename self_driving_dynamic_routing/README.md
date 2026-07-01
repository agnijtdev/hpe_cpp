# Self-Driving Dynamic Routing Using OSPF & BGP in the BIRD Routing Stack

This project implements a self-healing enterprise-style routing lab using BIRD, OSPF, BGP, BFD, Graceful Restart, and related routing recovery mechanisms.

## Main Goals

- Detect network failures quickly.
- Automatically select alternate paths.
- Reduce packet loss during failures.
- Demonstrate OSPF and BGP working together.
- Measure convergence time and packet loss.

## Current Lab Routers

| Node | Role |
|---|---|
| hpe-r1 | WAN edge / OSPF core |
| hpe-r2 | WAN edge / OSPF core |
| hpe-r3 | ABR for NSSA area |
| hpe-r4 | ABR for stub area |
| hpe-r5 | NSSA internal router |
| hpe-r6 | NSSA branch router, hpe-h1 gateway |
| hpe-r7 | Stub area internal router |
| hpe-r8 | Stub branch router, hpe-h2 gateway |
| hpe-r9 | ISP/upstream router, hpe-h3 gateway |


