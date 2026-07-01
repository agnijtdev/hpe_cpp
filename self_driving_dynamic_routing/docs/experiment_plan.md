# Experiment Plan

## Experiment 1: Baseline Validation

Check that all containers, OSPF neighbours, BGP sessions, routes, and host pings are healthy.

## Experiment 2: BFD WAN Edge Failure

Fail the hpe-r2 to hpe-r9 WAN link and measure BFD detection time.

Expected result:
Fast detection below 300 ms.

Measured result:
57 ms.

## Experiment 3: OSPF Core Link Failure

Fail the hpe-r3 to hpe-r2 core link and measure route convergence.

Expected result:
Route should move from hpe-r2 to hpe-r1.

Measured result:
489 ms using kernel route monitor.

## Experiment 4: BGP GR/LLGR Restart

Restart BGP control plane and observe forwarding/recovery behaviour.

Status:
Pending.

## Experiment 5: ECMP Failover

Observe failover or rehash to surviving next-hop.

Status:
Pending.

## Experiment 6: iBGP Route Reflector Extension

Add an extra internal router so route reflector behaviour is meaningful.

Status:
Pending.
