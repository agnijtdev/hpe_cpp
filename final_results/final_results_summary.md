# Final Experimental Results Summary

## 1. Baseline Validation

Final validation showed successful host-to-host connectivity with 0% packet loss across all tested host pairs.

## 2. OSPF Core Link Failure

Valid runs: 23

| Metric | Average | Median | Min | Max |
|---|---:|---:|---:|---:|
| bfd_detect_ms | 79.96 | 68.00 | 25.00 | 182.00 |
| route_get_new_ms | 85.32 | 80.50 | 32.00 | 143.00 |
| bird_new_route_ms | 634.95 | 651.50 | 241.00 | 1023.00 |
| traffic_outage_ms | 678.50 | 697.00 | 209.00 | 1034.00 |
| ping_loss_percent | 4.26 | 4.49 | 0.00 | 6.75 |

Interpretation: OSPF convergence was measured at multiple layers. Local forwarding changed faster than full BIRD route-table observation and end-to-end traffic recovery.

## 3. BFD WAN Edge Failure

Valid runs: 8

| Metric | Average | Median | Min | Max |
|---|---:|---:|---:|---:|
| bfd_detect_ms | 84.38 | 85.00 | 38.00 | 121.00 |
| bgp_non_established_ms | 64.75 | 74.50 | 0.00 | 124.00 |
| route_get_changed_ms | 66.50 | 78.50 | 1.00 | 128.00 |
| bird_route_changed_ms | 79.88 | 87.00 | 18.00 | 124.00 |
| traffic_outage_ms | 24.50 | 24.50 | 23.00 | 26.00 |
| traffic_loss_percent | 0.03 | 0.00 | 0.00 | 0.13 |

Interpretation: BFD-driven WAN edge failover achieved fast route switching with near-zero packet loss.

## 4. OSPF ECMP Direct Interface-Down Failure

No-BFD runs: 6
With-BFD runs: 6

| Metric | No BFD Avg | With BFD Avg |
|---|---:|---:|
| route_get_switch_ms | 77.17 | 75.50 |
| bird_route_survivor_only_ms | 573.33 | 517.83 |
| kernel_event_ms | 575.33 | 524.50 |
| traffic_loss_percent | 0.00 | 0.00 |

Interpretation: In direct interface-down failure, both modes maintained 0% packet loss because the kernel immediately reported the link-down event.

## 5. OSPF ECMP Silent Blackhole Failure

No-BFD runs: 4
With-BFD runs: 4

| Metric | No BFD Avg | With BFD Avg | Improvement |
|---|---:|---:|---:|
| route_get_switch_ms | 17439.75 | 1283.50 | 92.64% |
| bird_route_survivor_only_ms | 17443.50 | 1276.50 | 92.68% |
| traffic_outage_ms | 14252.25 | 1142.75 | 91.98% |
| traffic_loss_percent | 45.75 | 3.53 | 92.29% |

Interpretation: Silent failure is where BFD showed its strongest value. Without BFD, traffic kept using the failed ECMP branch for much longer. With BFD, the failed branch was removed quickly, reducing outage and packet loss by about 92%.

## Final Conclusion

The project demonstrates a self-healing routing network using OSPF, BGP, BFD and ECMP. Direct link failures were handled through fast kernel/netlink and routing updates, while silent blackhole-style failures clearly showed the importance of BFD. The strongest result is the silent ECMP failure experiment, where BFD reduced route switching delay, traffic outage and packet loss by roughly 92%.
