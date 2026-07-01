# Configuration Snapshot

## Objective

The objective of this deliverable was to save a clean baseline snapshot of the working lab configuration.

This snapshot was taken after baseline validation confirmed that containers were running, OSPF neighbours were Full, BGP sessions were Established, BFD sessions were Up, and end-to-end host connectivity worked with 0% packet loss.

## Files Captured

The snapshot includes:

- BIRD configuration from each router.
- Runtime state from each router.
- Runtime state from each host.
- A manifest describing the snapshot contents.

## Snapshot Location

The timestamped snapshot is stored at:

`configs/baseline/20260623_142648/`

The latest baseline snapshot is also available at:

`configs/baseline/latest/`

## Why This Matters

The project proposal requires configurations before and after tuning. This snapshot acts as the baseline configuration state before additional experiments such as BFD tuning, OSPF healing, ECMP failover, and BGP GR/LLGR testing.

## Conclusion

The baseline configuration snapshot was successfully created. It provides a reproducible reference point for comparing future tuned configurations and experiment results.
