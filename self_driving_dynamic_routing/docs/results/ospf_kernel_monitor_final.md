# Accurate OSPF Core Link Failure Measurement

## Objective

This test measured OSPF self-healing after a core link failure between hpe-r3 and hpe-r2.

The goal was to measure how quickly the Linux forwarding route changed after the failure.

## Failure Tested

- Failed link: hpe-r3 to hpe-r2
- Failed interface: hpe-r3 eth0
- Old next-hop: 10.0.23.2
- Alternate next-hop: 10.0.13.2
- Traffic path tested: hpe-h1 to hpe-h3

## Measurement Method

Three measurements were collected:

1. Kernel route monitor using ip monitor route
2. High-frequency route sampling using ip route get
3. BIRD route-table sampling using birdc show route

The primary convergence value was taken from the kernel route monitor because it records when the Linux forwarding route actually changes.

Timestamped ICMP traffic was also used to estimate packet loss during the failure window.

## Result

| Metric | Result |
|---|---:|
| Kernel route monitor switch time | 489 ms |
| Route-get sample confirmation | 508 ms |
| BIRD route-table confirmation | 508 ms |
| Estimated ICMP packets transmitted | 349 |
| ICMP packets received | 339 |
| Failed/lost packets | 10 |
| Estimated packet loss | 2.87% |
| Explicit unreachable packets observed | 1 |

## Route Change Observed

Before failure, hpe-r3 forwarded traffic toward hpe-h3 through hpe-r2:

    10.0.93.2 via 10.0.23.2 dev eth0

After failure, the route changed to the alternate path through hpe-r1:

    default via 10.0.13.2 dev eth3

## Conclusion

The accurate measurement shows that OSPF recovered from the core link failure in approximately 489 ms at the kernel forwarding level.

The route-get and BIRD route-table measurements confirmed the route change at approximately 508 ms.

Real traffic experienced a short disruption, with an estimated packet loss of 2.87% during the failure window.

This demonstrates fast automatic route recovery using OSPF in the BIRD routing stack.
