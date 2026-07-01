# OSPF Core Link Failure Recovery

## Objective

The objective of this experiment was to validate OSPF fast recovery when an internal core link fails.

The tested failure was the core OSPF link between `hpe-r3` and `hpe-r2`. The goal was to observe whether OSPF could detect the failure, remove the failed path, install an alternate path, and restore forwarding quickly.

## Test Setup

| Item                       | Value                                           |
| -------------------------- | ----------------------------------------------- |
| Failed router              | hpe-r3                                          |
| Failed core peer           | hpe-r2                                          |
| Old next-hop               | 10.0.23.2                                       |
| New next-hop               | 10.0.13.2                                       |
| Test type                  | OSPF core link failure                          |
| Primary measurement method | Linux kernel route monitor                      |
| Supporting methods         | `ip route get` sampling and BIRD route sampling |
| Traffic measurement        | Timestamped ICMP ping                           |

## Why Multiple Measurement Methods Were Used

OSPF convergence is not only a control-plane event. A route may change inside BIRD first, but traffic is forwarded by the Linux kernel routing table.

Because of this, three different methods were used:

| Method                     | Purpose                                                         |
| -------------------------- | --------------------------------------------------------------- |
| Linux kernel route monitor | Measures when the actual forwarding route changed in the kernel |
| `ip route get` sampling    | Confirms when the router’s forwarding decision changed          |
| BIRD route-table sampling  | Confirms when BIRD selected the alternate route                 |
| Timestamped ping           | Measures traffic impact and packet loss                         |

The kernel route monitor result was treated as the primary convergence time because it reflects when the data-plane forwarding route changed.

## Measurement Result

| Metric                                   |    Result |
| ---------------------------------------- | --------: |
| Old next-hop                             | 10.0.23.2 |
| New next-hop                             | 10.0.13.2 |
| Kernel route monitor convergence time    |    628 ms |
| `ip route get` sample convergence time   |    631 ms |
| BIRD route-table sample convergence time |    648 ms |
| Estimated transmitted packets            |       350 |
| Received packets                         |       338 |
| Failed/lost packets                      |        12 |
| Estimated packet loss                    |     3.43% |
| Explicit unreachable packets             |         1 |

## Path Change

Before the failure, the route used the old next-hop:

```text
10.0.23.2
```

After the core link failure, OSPF selected the alternate next-hop:

```text
10.0.13.2
```

This means OSPF successfully removed the failed path and installed an alternate route.

## Convergence Analysis

The three convergence measurements were very close:

```text
Kernel route monitor: 628 ms
ip route get sampling: 631 ms
BIRD route sampling: 648 ms
```

This consistency shows that the result is reliable. The kernel forwarding table changed first at around 628 ms, and the supporting measurements confirmed the same route transition within a very small time gap.

## Traffic Impact

The ping log did not contain a normal final ping summary, so packet loss was estimated using ICMP sequence numbers.

The parsed result was:

```text
Estimated transmitted packets: 350
Received packets: 338
Failed/lost packets: 12
Estimated packet loss percent: 3.43%
Explicit unreachable packets seen: 1
```

This shows that traffic experienced a short disruption during OSPF reconvergence, but connectivity recovered automatically after the alternate path was installed.

## Post-Test Recovery Validation

After the failure experiment, OSPF was verified on all internal routers.

```text
hpe-r1: OSPF Running
hpe-r2: OSPF Running
hpe-r3: OSPF Running
hpe-r4: OSPF Running
hpe-r5: OSPF Running
hpe-r6: OSPF Running
hpe-r7: OSPF Running
hpe-r8: OSPF Running
```

Final end-to-end pings also succeeded:

```text
hpe-h1 -> hpe-h2: 0% packet loss
hpe-h1 -> hpe-h3: 0% packet loss
hpe-h3 -> hpe-h1: 0% packet loss
```

## Evidence Files

| Evidence                  | File                                                                         |
| ------------------------- | ---------------------------------------------------------------------------- |
| Final OSPF result CSV     | results/ospf/ospf_core_link_failure.csv                                      |
| Kernel monitor result CSV | results/ospf/ospf_kernel_monitor_result_20260623_151142.csv                  |
| Main evidence summary     | evidence/ospf_kernel_monitor/kernel_monitor_ospf_failure_20260623_151142.txt |
| Kernel route monitor log  | evidence/ospf_kernel_monitor/kernel_route_monitor_20260623_151142.log        |
| Route-get samples         | evidence/ospf_kernel_monitor/route_get_samples_20260623_151142.log           |
| BIRD route samples        | evidence/ospf_kernel_monitor/bird_route_samples_20260623_151142.log          |
| Ping log                  | evidence/ospf_kernel_monitor/ping_timestamped_20260623_151142.log            |

## Conclusion

The OSPF core link failure experiment successfully demonstrated automatic intra-domain recovery.

When the `hpe-r3` to `hpe-r2` core link failed, OSPF removed the old path through `10.0.23.2` and installed the alternate path through `10.0.13.2`.

The primary convergence time measured using the Linux kernel route monitor was 628 ms. Supporting measurements using `ip route get` and BIRD route-table sampling showed 631 ms and 648 ms respectively. Since all three values were close, the convergence measurement is consistent and reliable.

The traffic test showed an estimated packet loss of 3.43% during the short convergence window. After reconvergence, OSPF was Running on all internal routers and end-to-end connectivity returned to 0% packet loss.
