# OSPF ECMP Failover

## Objective

The objective of this experiment was to validate OSPF Equal-Cost Multi-Path, or ECMP, failover.

The experiment checked whether a router with two equal-cost OSPF next-hops could continue forwarding traffic when one ECMP branch failed. The experiment also compared native OSPF ECMP behaviour with BFD-assisted OSPF ECMP behaviour.

## ECMP Route Under Test

The ECMP route was observed on `hpe-r3`.

```text id="r3f5gv"
10.0.24.0/24
via 10.0.23.2 on eth3 weight 1
via 10.0.34.3 on eth0 weight 1
```

The same route was also installed in the Linux kernel as a multipath route.

```text id="k53l77"
10.0.24.0/24 proto bird metric 32
nexthop via 10.0.23.2 dev eth3 weight 1
nexthop via 10.0.34.3 dev eth0 weight 1
```

This proves that `hpe-r3` had two equal-cost OSPF forwarding branches:

```text id="l2rr87"
hpe-r3 -> hpe-r2
hpe-r3 -> hpe-r4
```

The failed ECMP next-hop was:

```text id="dmk5r1"
10.0.23.2
```

The surviving ECMP next-hop was:

```text id="w5wstb"
10.0.34.3
```

## Measurement Methods

Multiple measurement methods were used because ECMP failover has both control-plane and data-plane behaviour.

| Method                     | Purpose                                                                  |
| -------------------------- | ------------------------------------------------------------------------ |
| Linux kernel route monitor | Detects when the kernel forwarding route changed                         |
| Kernel route sampling      | Confirms when the failed ECMP next-hop was removed from the kernel route |
| `ip route get` sampling    | Shows the selected forwarding next-hop for the test destination          |
| BIRD route-table sampling  | Confirms when BIRD removed the failed next-hop                           |
| ICMP ping                  | Measures packet loss during the failover window                          |

The kernel route monitor and kernel route sampling were treated as the main forwarding-plane measurements.

## OSPF-BFD Activation

Initially, ECMP failover was measured using native OSPF behaviour. Then BFD was enabled on OSPF interfaces.

After enabling BFD, `hpe-r3` showed active BFD sessions to both ECMP neighbours:

```text id="ehtnfc"
10.0.23.2 eth3 Up
10.0.34.3 eth0 Up
```

This confirms that BFD was active on the OSPF ECMP core links.

## Comparison Result

| Test                         | OSPF-BFD | Ping interval | Kernel monitor | Kernel route sample | Route-get sample | BIRD route sample |  Tx |  Rx | Lost |   Loss |
| ---------------------------- | -------- | ------------: | -------------: | ------------------: | ---------------: | ----------------: | --: | --: | ---: | -----: |
| Native OSPF ECMP without BFD | No       |         0.02s |         840 ms |              820 ms |            94 ms |            819 ms | 500 | 420 |   80 | 16.00% |
| OSPF ECMP with BFD, stress   | Yes      |         0.02s |         292 ms |              305 ms |            49 ms |            304 ms | 500 | 463 |   37 |  7.40% |
| OSPF ECMP with BFD, normal   | Yes      |            1s |         517 ms |              542 ms |            63 ms |            540 ms |  20 |  19 |    1 |  5.00% |

## Interpretation

The native OSPF ECMP baseline showed that the failed ECMP next-hop was removed, but convergence took longer.

After enabling BFD on OSPF interfaces, the ECMP failover improved significantly in the high-rate stress test.

```text id="s1xho2"
Kernel monitor time improved from 840 ms to 292 ms.
BIRD route-table update improved from 819 ms to 304 ms.
Packet loss reduced from 16.00% to 7.40%.
```

This shows that BFD helped OSPF detect the failed ECMP branch faster and remove the failed next-hop more quickly.

## Normal-Rate Traffic Result

The normal-rate ping test used one ICMP packet per second.

```text id="hsckqf"
20 packets transmitted
19 received
1 packet lost
5.00% packet loss
```

Although the percentage appears as 5%, this represents only one lost packet during the failover window. This is a practical way to describe normal-rate traffic impact.

## Stress-Traffic Result

The high-rate stress test used one packet every 0.02 seconds, or around 50 packets per second.

In the BFD-assisted stress test:

```text id="w445gc"
500 packets transmitted
463 received
37 packets lost
7.40% packet loss
```

At 50 packets per second, 37 lost packets corresponds to a short disruption window. This stress test made the failover window more visible.

## Route Behaviour

Before failure, both ECMP next-hops were present:

```text id="k6haj8"
nexthop via 10.0.23.2 dev eth3 weight 1
nexthop via 10.0.34.3 dev eth0 weight 1
```

After the failure of the `10.0.23.2` branch, the kernel route changed to the surviving next-hop:

```text id="p4f5nu"
10.0.24.0/24 via 10.0.34.3 dev eth0 proto bird metric 32
```

This proves that the failed ECMP branch was removed and forwarding continued through the surviving branch.

## Evidence Files

| Evidence                      | File                                            |
| ----------------------------- | ----------------------------------------------- |
| ECMP comparison CSV           | results/ospf/ospf_ecmp_comparison.csv           |
| Native OSPF ECMP baseline CSV | results/ospf/ospf_ecmp_native_without_bfd.csv   |
| BFD stress CSV                | results/ospf/ospf_ecmp_with_bfd_stress.csv      |
| BFD normal CSV                | results/ospf/ospf_ecmp_with_bfd_normal.csv      |
| OSPF-BFD confirmation         | evidence/ospf_bfd/ospf_bfd_sessions_confirmed_* |
| Final ECMP evidence folder    | evidence/ospf_ecmp/final/                       |

## Conclusion

The OSPF ECMP failover experiment successfully demonstrated equal-cost multipath routing and failover.

Before failure, `hpe-r3` had two equal-cost next-hops toward `10.0.24.0/24`: `10.0.23.2` and `10.0.34.3`. When the `10.0.23.2` branch failed, OSPF removed the failed next-hop and continued forwarding using the surviving next-hop `10.0.34.3`.

The native OSPF ECMP baseline converged in 840 ms by kernel route monitor measurement. After BFD was enabled on OSPF interfaces, the stress-test convergence improved to 292 ms, and packet loss reduced from 16.00% to 7.40%.

Under normal-rate traffic, only one packet was lost during ECMP failover. This confirms that OSPF ECMP failover worked correctly, and BFD-assisted OSPF improved failure detection and reduced traffic disruption.
