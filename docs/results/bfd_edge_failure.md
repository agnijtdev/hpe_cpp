# BFD Edge Failure Test Result

## Test Objective

The objective of this test was to validate fast failure detection on the WAN edge BGP link between `hpe-r2` and `hpe-r9`.

## Test Setup

- Failed link: `hpe-r2 eth4` toward `hpe-r9`
- BFD peer: `10.0.29.3`
- Routing protocol protected by BFD: eBGP
- Alternate WAN path: `hpe-r1` to `hpe-r9`

## Before Failure

Before the failure, the BFD session between `hpe-r2` and `hpe-r9` was Up. The BGP session was Established. End-to-end traffic from `hpe-h1` to `hpe-h3` was also working with 0% packet loss.

## Failure Action

The interface `eth4` on `hpe-r2` was brought down to simulate a WAN edge link failure.

## Observed Behaviour

The BGP session between `hpe-r2` and `hpe-r9` moved to Idle with the error `Neighbor lost`. The approximate detection time measured by the script was 57 ms.

During the failure, traffic from `hpe-h1` to `hpe-h3` continued successfully with 0% packet loss. This happened because the network still had an alternate WAN path through `hpe-r1`.

## After Restore

After the interface was brought back up, the BFD session came back Up and the BGP session between `hpe-r2` and `hpe-r9` returned to Established state.

## Result

The test successfully demonstrated fast WAN-edge failure detection and automatic failover through the alternate path.

| Metric | Result |
|---|---|
| BFD before failure | Up |
| BGP before failure | Established |
| Detection time | 57 ms |
| Traffic during failure | 0% packet loss |
| BFD after restore | Up |
| BGP after restore | Established |
