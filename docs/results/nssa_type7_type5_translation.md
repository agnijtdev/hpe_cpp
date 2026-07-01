# OSPF NSSA Type-7 to Type-5 Translation

## Objective

The objective of this experiment was to validate OSPF NSSA behaviour, specifically Type-7 to Type-5 external route translation and external route containment.

The experiment checked whether an external route originated inside an NSSA area is first carried as a Type-7 LSA inside the NSSA, and then translated into a Type-5 LSA by the Area Border Router, or ABR, for the backbone area.

## NSSA Area in the Topology

In this topology, Area 10 is configured as an NSSA area.

The relevant routers are:

| Router   | Role                                                               |
| -------- | ------------------------------------------------------------------ |
| `hpe-r3` | ABR between Area 0 and Area 10                                     |
| `hpe-r5` | Internal NSSA router                                               |
| `hpe-r6` | Internal NSSA router and origin router for the test external route |

Area 10 is configured as NSSA on `hpe-r3`, `hpe-r5`, and `hpe-r6`.

## Why NSSA is Important

In normal OSPF, external routes are flooded as Type-5 LSAs.

However, an NSSA does not directly flood Type-5 LSAs inside the NSSA area. Instead, external routes originated inside the NSSA are carried as Type-7 LSAs. The ABR then translates the Type-7 LSA into a Type-5 LSA for the rest of the OSPF domain.

This keeps external route flooding controlled and prevents external LSAs from entering areas where they should not be directly flooded.

## Test External Route

A controlled static blackhole route was added on `hpe-r6`.

```text
172.16.66.0/24
```

This was added as a BIRD static route:

```text
172.16.66.0/24 blackhole
```

This route was then exported into OSPF from `hpe-r6`, which is inside NSSA Area 10.

The route was intentionally configured as a blackhole route because the experiment only needed a clean routing advertisement, not real host connectivity.

## Route Visibility Result

The route visibility CSV showed the following result:

| Router   | Route present | Route type  |
| -------- | ------------- | ----------- |
| `hpe-r6` | Yes           | Static      |
| `hpe-r5` | Yes           | OSPF-E2     |
| `hpe-r3` | Yes           | OSPF-E2     |
| `hpe-r1` | Yes           | OSPF-E2     |
| `hpe-r2` | Yes           | OSPF-E2     |
| `hpe-r4` | Yes           | OSPF-E2     |
| `hpe-r8` | No            | Not present |

This confirms that the test route was originated by `hpe-r6`, propagated through Area 10, translated by the ABR, and made visible to the backbone routers.

## Type-7 Evidence Inside NSSA

The Type-7 LSADB output showed the test route inside the NSSA area.

On `hpe-r6`:

```text
0007  172.16.66.255   6.6.6.6
```

On `hpe-r5`:

```text
0007  172.16.66.255   6.6.6.6
```

On `hpe-r3`:

```text
0007  172.16.66.255   6.6.6.6
```

This proves that the external route originated by `hpe-r6` was carried inside Area 10 as a Type-7 LSA.

## Type-5 Evidence Outside NSSA

The Type-5 LSADB output showed the translated route outside the NSSA.

On `hpe-r3`:

```text
0005  172.16.66.255   3.3.3.3
```

On `hpe-r1`:

```text
0005  172.16.66.255   3.3.3.3
```

On `hpe-r2`:

```text
0005  172.16.66.255   3.3.3.3
```

On `hpe-r4`:

```text
0005  172.16.66.255   3.3.3.3
```

This proves that ABR `hpe-r3`, whose router ID is `3.3.3.3`, translated the NSSA Type-7 LSA into a Type-5 LSA for the backbone area.

## Stub Area Containment

Router `hpe-r8` is inside the stub area, Area 20.

When the route was checked on `hpe-r8`, BIRD reported:

```text
Network not found
```

This means `hpe-r8` did not receive the external OSPF route as a direct OSPF external route.

However, the Linux kernel still had a forwarding path using the default route:

```text
172.16.66.1 via 10.0.78.2 dev eth0
```

This is the expected containment behaviour. The external route itself was not flooded into the stub area, but the stub router could still forward traffic using the default route.

## Evidence Files

| Evidence                       | File                                                           |
| ------------------------------ | -------------------------------------------------------------- |
| NSSA static external route CSV | `results/nssa/nssa_static_external_route.csv`                  |
| Final NSSA translation CSV     | `results/nssa/nssa_type7_type5_translation.csv`                |
| Full experiment output         | `evidence/nssa/nssa_static_external_route_20260623_162347.txt` |
| Final evidence folder          | `evidence/nssa/final/`                                         |
| Before configuration           | `configs/nssa_static_before/hpe-r6_bird_20260623_162347.conf`  |
| After configuration            | `configs/nssa_static_after/hpe-r6_bird_20260623_162347.conf`   |

## Conclusion

The NSSA experiment successfully demonstrated Type-7 to Type-5 translation and external route containment.

A static blackhole route, `172.16.66.0/24`, was originated inside NSSA Area 10 from `hpe-r6`. Inside the NSSA, the route appeared as a Type-7 LSA originated by router ID `6.6.6.6`. At the ABR, `hpe-r3`, the Type-7 LSA was translated into a Type-5 LSA originated by router ID `3.3.3.3`.

Backbone routers such as `hpe-r1`, `hpe-r2`, and `hpe-r4` received the translated Type-5 LSA. The stub-area router `hpe-r8` did not receive the external route directly, showing that external route flooding was contained.

This confirms that NSSA behaviour worked correctly in the lab topology.
