# Screenshot Checklist

## Baseline

- Docker containers running.
- OSPF neighbours Full.
- BGP sessions Established.
- hpe-h1 to hpe-h2 ping success.
- hpe-h1 to hpe-h3 ping success.
- hpe-h3 to hpe-h1 ping success.

## BFD

- BFD sessions Up.
- Failure test showing detection time.
- CSV/result file showing 57 ms.

## OSPF

- Before failure route via 10.0.23.2.
- After failure route via 10.0.13.2.
- Kernel monitor result showing 489 ms.
- Packet loss estimate.

## BGP GR/LLGR

Pending.

## ECMP

Pending.
