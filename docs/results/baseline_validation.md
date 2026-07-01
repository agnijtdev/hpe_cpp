# Baseline Validation

## Objective

The objective of this baseline validation was to confirm that the routing lab was healthy before running failure experiments.

A stable baseline is important because convergence and failover results are meaningful only when the network starts from a known working state.

## What Was Validated

The baseline validation checked the following:

- All HPE router and host containers were running.
- BIRD was running on all routers.
- OSPF was running.
- OSPF neighbours were in Full state.
- BGP sessions were Established.
- BFD sessions on the WAN edge were Up.
- End-to-end host connectivity worked with 0% packet loss.

## Baseline Connectivity Results

| Test | Source | Destination | Packet Loss |
|---|---|---|---:|
| h1_to_h2 | hpe-h1 | 10.0.82.2 | 0% |
| h2_to_h1 | hpe-h2 | 10.0.61.2 | 0% |
| h1_to_h3 | hpe-h1 | 10.0.93.2 | 0% |
| h2_to_h3 | hpe-h2 | 10.0.93.2 | 0% |
| h3_to_h1 | hpe-h3 | 10.0.61.2 | 0% |
| h3_to_h2 | hpe-h3 | 10.0.82.2 | 0% |

## Conclusion

The baseline validation confirmed that the lab was stable before failure testing.

OSPF was running with Full neighbour adjacencies, BGP sessions were Established, BFD sessions were Up on the WAN edge, and all host-to-host connectivity tests completed with 0% packet loss.

This baseline is the reference state for later BFD, OSPF, ECMP, and BGP GR/LLGR experiments.
