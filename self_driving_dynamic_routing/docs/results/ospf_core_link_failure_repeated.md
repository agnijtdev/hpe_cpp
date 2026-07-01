# OSPF Core Link Failure Repeated Test Result

## Objective

This test validates OSPF self-healing when the core link between hpe-r3 and hpe-r2 fails.

## Failure Tested

- Failed link: hpe-r3 to hpe-r2
- Original next-hop: 10.0.23.2
- Alternate next-hop after failure: 10.0.13.2
- Traffic tested: hpe-h1 to hpe-h3

## Run Results

| Run | Route switch time | Total samples | Successful samples | Failed samples | Packet loss |
|---|---:|---:|---:|---:|---:|
| Run 1 | 625 ms | 64 | 62 | 2 | 3.12% |
| Run 2 | 972 ms | 60 | 57 | 3 | 5.00% |
| Run 3 | 521 ms | 62 | 61 | 1 | 1.61% |

## Summary

Across three OSPF core-link failure tests:

| Metric | Result |
|---|---:|
| Average route switch time | 706 ms |
| Total ping samples | 186 |
| Total failed samples | 6 |
| Overall packet loss during failure windows | 3.23% |
| Traffic after convergence | 0% packet loss |

## Observation

Before failure, hpe-r3 used hpe-r2 as the default route toward the WAN.

When the hpe-r3 to hpe-r2 link failed, OSPF removed the failed path and selected the alternate path through hpe-r1.

The default route changed from 10.0.23.2 to 10.0.13.2.

After convergence, traffic from hpe-h1 to hpe-h3 worked again with 0% packet loss.

## Conclusion

The repeated test shows that OSPF automatically heals the network after a core link failure. Across three runs, the average route switch time was about 706 ms, which is below 1 second.

This supports the project goal of demonstrating fast automatic route recovery using the BIRD routing stack.
