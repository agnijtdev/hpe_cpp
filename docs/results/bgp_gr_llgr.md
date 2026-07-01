# BGP Graceful Restart / LLGR and Route Withdrawal Behaviour

## Objective

The objective of this experiment was to test BGP control-plane restart behaviour and route withdrawal behaviour.

This experiment has two parts:

1. BGP Graceful Restart / LLGR forwarding continuity test
2. BGP route withdrawal test

The main difference is important.

In the Graceful Restart test, the BGP session was restarted, but the route was expected to be retained temporarily so that forwarding could continue.

In the withdrawal test, the route itself was intentionally removed from BGP export. In that case, forwarding should eventually fail because the route is no longer valid.

## BGP GR / LLGR Configuration Verification

Before running the test, the BGP configuration was checked on the BGP routers.

The following BGP options were already configured:

```text
graceful restart yes;
long lived graceful restart yes;
```

The protocol details also showed:

```text
Long-lived graceful restart
LL stale time: 3600
Restart time: 120
BGP state: Established
```

The BGP sessions were established before testing.

| Router   | BGP Peer | State       |
| -------- | -------- | ----------- |
| `hpe-r1` | `hpe-r9` | Established |
| `hpe-r1` | `hpe-r2` | Established |
| `hpe-r2` | `hpe-r9` | Established |
| `hpe-r9` | `hpe-r1` | Established |
| `hpe-r9` | `hpe-r2` | Established |

## Part 1: BGP Graceful Restart Forwarding Test

### Why Isolation Was Needed

A simple BGP restart test is not enough to prove Graceful Restart.

If `hpe-r1 -> hpe-r9` BGP fails, traffic might simply move through another path:

```text
hpe-r1 -> hpe-r2 -> hpe-r9
```

That would prove BGP failover, not Graceful Restart.

So the final test used a stricter method.

### Isolation Method

The final Graceful Restart proof used a blackhole guard and disabled the alternate path.

The setup was:

```text
Traffic: hpe-h1 -> hpe-h3
Source host: 10.0.61.2
Destination host: 10.0.93.2
Target prefix: 10.0.93.0/24
Expected BGP next-hop: 10.0.19.3
```

A blackhole guard route was added on `hpe-r1`:

```text
blackhole 10.0.93.0/24 metric 9999
```

At the same time, the valid BGP route still existed:

```text
10.0.93.0/24 via 10.0.19.3 dev eth0 proto bird metric 32
```

The Linux route lookup still preferred the real BGP route:

```text
10.0.93.2 via 10.0.19.3 dev eth0
```

Then the alternate `hpe-r1 -> hpe-r2` path was disabled:

```text
hpe-r1 eth1 DOWN
hpe-r1 protocol r2 disabled/down
```

This means the test had no usable alternate path through `hpe-r2`.

### BGP Restart Action

The BGP session from `hpe-r9` toward `hpe-r1` was restarted:

```text
docker exec hpe-r9 birdc restart r1
```

During the test, the BGP session on `hpe-r1` temporarily became non-established:

```text
BGP non-established seen ms: 114
State: Active
Received: Administrative reset
```

This proves that a real BGP control-plane restart happened.

### GR Forwarding Result

The final CSV result was:

| Measurement                         | Result |
| ----------------------------------- | -----: |
| Blackhole guard enabled             |    yes |
| `hpe-r1 -> hpe-r2` link down        |    yes |
| Old next-hop after restart          |    yes |
| Alternate next-hop after restart    |     no |
| Blackhole/unreachable after restart |     no |
| BGP non-established seen            | 114 ms |
| Ping transmitted                    |    200 |
| Ping received                       |    200 |
| Ping lost                           |      0 |
| Packet loss                         |     0% |

The important lines were:

```text
Old next-hop seen after restart: yes
Alternate next-hop seen after restart: no
Blackhole/unreachable seen after restart: no
Ping transmitted: 200
Ping received: 200
Ping lost: 0
Ping loss percent: 0
```

### GR Interpretation

This confirms that forwarding continued during the BGP restart.

The result is strong because:

1. The `hpe-r1 -> hpe-r2` alternate path was disabled.
2. A blackhole guard was installed for `10.0.93.0/24`.
3. The traffic did not fall into the blackhole route.
4. The route lookup continued to use the old direct next-hop `10.0.19.3`.
5. No ping packets were lost.

So the traffic continuity was not caused by alternate routing or static/default fallback. It was caused by the forwarding plane continuing to use the retained route during the BGP restart.

One honest observation is that the sampled BIRD route output did not show a visible “stale” or “LLGR stale” label. Therefore, the conclusion should not say that BIRD visibly marked the route as stale. The correct conclusion is that forwarding continuity was observed during BGP restart under GR/LLGR-enabled configuration.

## Part 2: BGP Route Withdrawal Test

### Purpose

The withdrawal test proves the opposite behaviour.

In this test, the BGP session stayed up, but the prefix `10.0.93.0/24` was intentionally withdrawn from export toward `hpe-r1`.

The purpose was to show that Graceful Restart protects forwarding during restart, but it does not keep forwarding alive when the route is truly withdrawn.

### Withdrawal Isolation Setup

The same isolation idea was used:

```text
blackhole guard enabled
hpe-r1 -> hpe-r2 alternate path disabled
```

Before withdrawal, `hpe-r1` still had the valid BGP route:

```text
10.0.93.0/24 via 10.0.19.3 dev eth0 proto bird metric 32
blackhole 10.0.93.0/24 metric 9999
```

Route lookup still preferred the real BGP route:

```text
10.0.93.2 via 10.0.19.3 dev eth0
```

The alternate path was disabled:

```text
hpe-r1 eth1 DOWN
```

A baseline ping before withdrawal succeeded:

```text
5 packets transmitted
5 received
0% packet loss
```

### Withdrawal Action

The `hpe-r9` BGP export policy toward `hpe-r1` was changed to reject the host-side prefix:

```text
10.0.93.0/24
```

The modified configuration was applied using:

```text
docker exec hpe-r9 birdc configure
```

### Withdrawal Result

The final CSV result was:

| Measurement                                  |           Result |
| -------------------------------------------- | ---------------: |
| Blackhole guard enabled                      |              yes |
| `hpe-r1 -> hpe-r2` path disabled             |              yes |
| Withdrawn prefix                             |   `10.0.93.0/24` |
| BGP session non-established after withdrawal |               no |
| Alternate next-hop after withdrawal          |               no |
| BIRD route missing time                      |           134 ms |
| Ping transmitted                             |              220 |
| Ping received                                |               11 |
| Ping lost                                    |              209 |
| Packet loss                                  |              95% |
| Final ping after withdrawal                  | 100% packet loss |

The important lines were:

```text
BGP non-established seen after withdrawal: no
BIRD route missing ms: 134
BIRD route missing line: Network not found
Ping transmitted: 220
Ping received: 11
Ping lost: 209
Ping loss percent: 95
```

Final ping after withdrawal:

```text
5 packets transmitted
0 received
100% packet loss
```

### Withdrawal Interpretation

This proves that the route was actually withdrawn while the BGP session stayed up.

The session did not go down:

```text
BGP non-established seen after withdrawal: no
```

But the route disappeared from BIRD:

```text
Network not found
```

After the route disappeared, traffic failed.

This is the expected behaviour. Graceful Restart helps during a control-plane restart, but it should not keep forwarding traffic forever for a route that has been intentionally withdrawn.

## Comparison: GR Restart vs Route Withdrawal

| Test                  | BGP Session Behaviour             | Route Behaviour                       | Traffic Result                             |
| --------------------- | --------------------------------- | ------------------------------------- | ------------------------------------------ |
| GR forwarding test    | Session temporarily became Active | Forwarding continued via old next-hop | 0% packet loss                             |
| Route withdrawal test | Session stayed established        | Route became `Network not found`      | 95% loss during test, 100% final ping loss |

## Evidence Files

| Evidence                    | File                                                                  |
| --------------------------- | --------------------------------------------------------------------- |
| GR forwarding CSV           | `results/bgp_gr_llgr/bgp_gr_forwarding_blackhole_guard.csv`           |
| GR forwarding main evidence | `evidence/bgp_gr_llgr/bgp_gr_blackhole_guard_20260623_170932.txt`     |
| GR ping log                 | `evidence/bgp_gr_llgr/ping_blackhole_guard_20260623_170932.log`       |
| GR route-get log            | `evidence/bgp_gr_llgr/route_get_blackhole_guard_20260623_170932.log`  |
| GR BIRD route log           | `evidence/bgp_gr_llgr/bird_route_blackhole_guard_20260623_170932.log` |
| GR BGP state log            | `evidence/bgp_gr_llgr/bgp_state_blackhole_guard_20260623_170932.log`  |
| Withdrawal CSV              | `results/bgp_gr_llgr/bgp_route_withdrawal_final.csv`                  |
| Withdrawal main evidence    | `evidence/bgp_gr_llgr/bgp_route_withdrawal_20260623_172052.txt`       |
| Withdrawal ping log         | `evidence/bgp_gr_llgr/ping_route_withdrawal_20260623_172052.log`      |
| Withdrawal route-get log    | `evidence/bgp_gr_llgr/route_get_withdrawal_20260623_172052.log`       |
| Withdrawal BIRD route log   | `evidence/bgp_gr_llgr/bird_route_withdrawal_20260623_172052.log`      |
| Withdrawal BGP state log    | `evidence/bgp_gr_llgr/bgp_state_withdrawal_20260623_172052.log`       |

## Screenshots

| Screenshot                                                            | Description                                  |
| --------------------------------------------------------------------- | -------------------------------------------- |
| `screenshots/bgp_gr_llgr/01_bgp_gr_blackhole_guard_csv.png`           | Final GR forwarding CSV                      |
| `screenshots/bgp_gr_llgr/02_blackhole_guard_real_route_preferred.png` | Blackhole guard and real BGP route preferred |
| `screenshots/bgp_gr_llgr/03_alternate_path_disabled.png`              | Alternate path disabled                      |
| `screenshots/bgp_gr_llgr/04_bgp_restart_observed.png`                 | BGP restart observed                         |
| `screenshots/bgp_gr_llgr/05_forwarding_continued_no_fallback.png`     | Forwarding continued without fallback        |
| `screenshots/bgp_gr_llgr/06_bgp_withdrawal_csv.png`                   | Withdrawal CSV                               |
| `screenshots/bgp_gr_llgr/07_withdrawal_isolation_setup.png`           | Withdrawal isolation setup                   |
| `screenshots/bgp_gr_llgr/08_route_withdrawn_bgp_still_up.png`         | Route withdrawn while BGP stayed up          |
| `screenshots/bgp_gr_llgr/09_withdrawal_packet_loss.png`               | Packet loss after withdrawal                 |

## Conclusion

The BGP Graceful Restart / LLGR experiment showed that forwarding continued during a BGP control-plane restart. During the restart, the BGP session temporarily moved into a non-established state, but traffic continued through the old direct next-hop `10.0.19.3` with 0% packet loss.

The test was isolated using a blackhole guard and by disabling the alternate `hpe-r1 -> hpe-r2` path. Therefore, the result was not caused by alternate routing or default-route fallback.

The route withdrawal test showed the opposite behaviour. When `10.0.93.0/24` was intentionally withdrawn from BGP export, the BGP session stayed up, but the route disappeared from BIRD within 134 ms. Traffic then failed, with 95% packet loss during the test and 100% packet loss in the final ping.

Together, these two tests show the difference between Graceful Restart route retention and true route withdrawal.
