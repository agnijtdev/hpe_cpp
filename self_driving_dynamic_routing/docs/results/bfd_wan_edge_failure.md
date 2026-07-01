# BFD WAN Edge Failure Detection

## Objective

The objective of this experiment was to validate fast failure detection on the WAN edge using BFD.

The tested failure was the WAN edge link between `hpe-r2` and `hpe-r9`. This link carries eBGP between the enterprise edge router and the upstream ISP router. BFD was attached to the BGP session so that link/session failure could be detected quickly.

## Test Setup

| Item                | Value     |
| ------------------- | --------- |
| Failed router       | hpe-r2    |
| Failed interface    | eth1      |
| Failed peer         | hpe-r9    |
| BFD peer IP         | 10.0.29.3 |
| Traffic source      | hpe-h1    |
| Traffic destination | hpe-h3    |
| Destination IP      | 10.0.93.2 |

## BFD Timer Configuration Observed

The BFD session used the following observed timing values:

| Field        |         Value |
| ------------ | ------------: |
| BFD interval | 0.100 seconds |
| BFD timeout  | 0.500 seconds |

## Measurement Result

| Metric                        | Result |
| ----------------------------- | -----: |
| BFD detection time            |  61 ms |
| BGP reaction time             |  61 ms |
| Estimated packets transmitted |    293 |
| Packets received              |    293 |
| Lost packets                  |      0 |
| Packet loss                   |  0.00% |
| Explicit unreachable packets  |      0 |

## Path Before Failure

Before the failure, `hpe-r2` reached the external host network through the direct WAN edge link to `hpe-r9`.

```text
10.0.93.2 via 10.0.29.3 dev eth1
```

This means the original forwarding path was:

```text
hpe-r2 -> hpe-r9
```

## Path During Failure

After the `hpe-r2` to `hpe-r9` link was brought down, BFD detected the failure and BGP removed the failed direct route. During the failure, `hpe-r2` changed its route to the external network through `hpe-r1`.

```text
10.0.93.2 via 10.0.12.2 dev eth2
```

At the same time, `hpe-r1` still had reachability to the ISP router through its own WAN edge link:

```text
10.0.93.2 via 10.0.19.3 dev eth0
```

Therefore, the alternate forwarding path became:

```text
hpe-r2 -> hpe-r1 -> hpe-r9
```

## Traffic Behaviour During Failure

During the failure window, traffic from `hpe-h1` to `hpe-h3` remained successful.

```text
10 packets transmitted, 10 received, 0% packet loss
```

The longer timestamped ping monitor also showed:

```text
293 packets transmitted, 293 received, 0 lost, 0.00% packet loss
```

## Restore Behaviour

After the failed link was restored, BFD became Up again on both sides. The BGP session between `hpe-r2` and `hpe-r9` also returned to Established state after a short reconnection period.

The final restore confirmation showed:

* Direct `hpe-r2` to `hpe-r9` ping worked with 0% packet loss.
* Direct `hpe-r9` to `hpe-r2` ping worked with 0% packet loss.
* BFD session was Up.
* BGP session was Established.
* Final `hpe-h1` to `hpe-h3` ping worked with 0% packet loss.

## Evidence Files

| Evidence                    | File                                                             |
| --------------------------- | ---------------------------------------------------------------- |
| Main BFD failure output     | evidence/bfd/bfd_edge_failure_20260623_145246.txt                |
| Alternate path verification | evidence/bfd/bfd_alternate_path_verification_20260623_145536.txt |
| Restore confirmation        | evidence/bfd/bfd_restore_confirmation_20260623_150004.txt        |
| CSV result                  | results/bfd/bfd_edge_failure.csv                                 |

## Conclusion

The BFD WAN edge failure experiment successfully demonstrated fast failure detection and automatic routing recovery.

BFD detected the `hpe-r2` to `hpe-r9` WAN edge failure in 61 ms. BGP reacted in the same 61 ms window. After the failed direct path was removed, traffic shifted to the alternate path through `hpe-r1` and continued toward `hpe-r9`.

The traffic test showed 0.00% packet loss during the failure window. After link restoration, BFD and BGP recovered cleanly. This confirms that BFD can provide sub-second WAN failure detection and help maintain reachability through alternate paths.
