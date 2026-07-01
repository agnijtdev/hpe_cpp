# OSPF Area Healing Across ABRs

## Objective

The objective of this experiment was to validate OSPF area healing across ABRs.

The experiment tested whether traffic between two different OSPF areas could recover when the direct ABR-to-ABR/core link failed.

The traffic tested was:

```text
hpe-h1 -> hpe-h2
10.0.61.2 -> 10.0.82.2
```

In the topology:

| Host / Router | Area / Role                    |
| ------------- | ------------------------------ |
| `hpe-h1`      | Host behind Area 10            |
| `hpe-r6`      | Area 10 router                 |
| `hpe-r3`      | ABR between Area 10 and Area 0 |
| `hpe-r4`      | ABR between Area 20 and Area 0 |
| `hpe-r8`      | Area 20 router                 |
| `hpe-h2`      | Host behind Area 20            |

So this experiment checks traffic from Area 10 to Area 20.

## Link Failed

The failed link was the direct core/ABR link between `hpe-r3` and `hpe-r4`.

The failed interface was:

```text
hpe-r3 eth0
```

Before the failure, `hpe-r3` reached the Area 20 host network through `hpe-r4`.

```text
10.0.82.0/24
via 10.0.34.3 on eth0
```

The old direct next-hop was:

```text
10.0.34.3
```

## Baseline Route Before Failure

Before the failure, the route from `hpe-r3` toward `10.0.82.0/24` was:

```text
10.0.82.0/24 unicast [ospf1] IA
via 10.0.34.3 on eth0
```

The Linux kernel forwarding decision also used the same next-hop:

```text
10.0.82.2 via 10.0.34.3 dev eth0
```

This proves that before failure, Area 10 to Area 20 traffic used the direct `hpe-r3 -> hpe-r4` path.

## Healing Behaviour After Failure

After `hpe-r3 eth0` was brought down, OSPF recalculated an alternate path.

The route-get sampler first showed the new forwarding path as:

```text
10.0.82.2 via 10.0.23.2 dev eth3
```

The Linux kernel route later showed two alternate next-hops:

```text
10.0.82.0/24 proto bird metric 32
nexthop via 10.0.13.2 dev eth2 weight 1
nexthop via 10.0.23.2 dev eth3 weight 1
```

The BIRD route table also showed the healed route:

```text
10.0.82.0/24 unicast [ospf1] IA
via 10.0.13.2 on eth2 weight 1
via 10.0.23.2 on eth3 weight 1
```

This proves that after the direct ABR link failed, traffic healed through alternate backbone paths via `hpe-r1` and `hpe-r2`.

## Measurement Results

| Measurement              |   Result |
| ------------------------ | -------: |
| Route-get switch time    |    80 ms |
| Kernel route switch time |   931 ms |
| BIRD route switch time   |   962 ms |
| Ping packets transmitted |      150 |
| Ping packets received    |      136 |
| Ping packets lost        |       14 |
| Packet loss              | 9.33333% |

The missing ICMP sequence numbers were:

```text
11 12 13 14 15 16 17 18 19 20 21 22 23 24
```

The ping interval used during the test was 0.1 seconds. This means the 14 lost packets represent a short disruption window of around 1.4 seconds during OSPF area healing.

## Final Restored Health

After the failed link was restored, connectivity was checked again.

```text
5 packets transmitted
5 received
0% packet loss
```

This confirms that the network returned to a healthy state after the link was restored.

## Interpretation

The experiment shows three important things.

First, the direct ABR path between `hpe-r3` and `hpe-r4` was being used before the failure.

Second, when that direct link failed, OSPF did not leave Area 10 to Area 20 traffic broken. It recalculated alternate Area 0 backbone paths through `hpe-r1` and `hpe-r2`.

Third, after the link was restored, normal connectivity returned with 0% packet loss.

The route-get result changed quickly, within 80 ms. The full kernel and BIRD route-table convergence took around 1 second. During this convergence window, 14 out of 150 high-frequency ping packets were lost.

## Evidence Files

| Evidence               | File                                                                   |
| ---------------------- | ---------------------------------------------------------------------- |
| Area healing CSV       | `results/area_healing/ospf_area_healing_r3_r4_failure.csv`             |
| Full experiment output | `evidence/area_healing/area_healing_r3_r4_failure_20260623_163945.txt` |
| Ping log               | `evidence/area_healing/ping_h1_to_h2_20260623_163945.log`              |
| Route-get samples      | `evidence/area_healing/route_get_samples_20260623_163945.log`          |
| Kernel route samples   | `evidence/area_healing/kernel_route_samples_20260623_163945.log`       |
| BIRD route samples     | `evidence/area_healing/bird_route_samples_20260623_163945.log`         |
| Final evidence folder  | `evidence/area_healing/final/`                                         |

## Conclusion

The OSPF area healing experiment successfully demonstrated inter-area recovery across ABRs.

Before failure, traffic from Area 10 toward Area 20 used the direct path from `hpe-r3` to `hpe-r4` through next-hop `10.0.34.3`. After the `hpe-r3 eth0` link failed, OSPF recalculated the path and installed alternate next-hops through `10.0.13.2` and `10.0.23.2`.

The route-get sampler detected a forwarding change in 80 ms, while the full kernel and BIRD route-table updates completed in around 1 second. During the transition, 14 packets were lost in a high-frequency ping test, but after restoration the final health check showed 0% packet loss.

This confirms that OSPF area healing worked correctly across ABRs in the lab topology.
