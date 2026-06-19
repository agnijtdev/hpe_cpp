import sys
from pathlib import Path

BASE_PREFIX = "100.100.1.0/24"
BASE_AS = 65000
BASE_NET_A = 172
BASE_NET_B = 31


def link_subnet_octet(link_id: int) -> int:
    """
    Link 1 uses 172.31.11.0/24
    Link 2 uses 172.31.12.0/24
    Link 3 uses 172.31.13.0/24
    """
    return 10 + link_id


def left_ip(link_id: int) -> str:
    """
    IP address of the left router on a link.
    Example: link 1 between r1-r2:
    r1 gets 172.31.11.11
    """
    return f"{BASE_NET_A}.{BASE_NET_B}.{link_subnet_octet(link_id)}.11"


def right_ip(link_id: int) -> str:
    """
    IP address of the right router on a link.
    Example: link 1 between r1-r2:
    r2 gets 172.31.11.12
    """
    return f"{BASE_NET_A}.{BASE_NET_B}.{link_subnet_octet(link_id)}.12"


def router_id(router_num: int) -> str:
    """
    BIRD router ID.
    This does not need to be an interface IP.
    It just needs to be unique.
    """
    return f"{router_num}.{router_num}.{router_num}.{router_num}"


def asn(router_num: int) -> int:
    """
    Private AS number for each lab router.
    r1 = AS65001, r2 = AS65002, etc.
    """
    return BASE_AS + router_num


def generate_bird_config(router_num: int, total_routers: int) -> str:
    lines = []

    lines.append("log stderr all;")
    lines.append("")
    lines.append(f"router id {router_id(router_num)};")
    lines.append("")
    lines.append("protocol device {")
    lines.append("}")
    lines.append("")
    lines.append("protocol direct {")
    lines.append("    ipv4;")
    lines.append("}")
    lines.append("")

    if router_num == 1:
        lines.append("protocol static static_routes {")
        lines.append("    ipv4;")
        lines.append(f"    route {BASE_PREFIX} blackhole;")
        lines.append("}")
        lines.append("")

    # BGP session to left neighbor
    if router_num > 1:
        link_id = router_num - 1
        local_ip = right_ip(link_id)
        neighbor_ip = left_ip(link_id)
        neighbor_num = router_num - 1

        lines.append(f"protocol bgp to_r{neighbor_num} {{")
        lines.append(f"    local as {asn(router_num)};")
        lines.append(f"    neighbor {neighbor_ip} as {asn(neighbor_num)};")
        lines.append(f"    source address {local_ip};")
        lines.append("")
        lines.append("    ipv4 {")
        lines.append("        import all;")
        lines.append("        export all;")
        lines.append("    };")
        lines.append("}")
        lines.append("")

    # BGP session to right neighbor
    if router_num < total_routers:
        link_id = router_num
        local_ip = left_ip(link_id)
        neighbor_ip = right_ip(link_id)
        neighbor_num = router_num + 1

        lines.append(f"protocol bgp to_r{neighbor_num} {{")
        lines.append(f"    local as {asn(router_num)};")
        lines.append(f"    neighbor {neighbor_ip} as {asn(neighbor_num)};")
        lines.append(f"    source address {local_ip};")
        lines.append("")
        lines.append("    ipv4 {")
        lines.append("        import all;")
        lines.append("        export all;")
        lines.append("    };")
        lines.append("}")
        lines.append("")

    return "\n".join(lines)


def generate_topology_file(output_dir: Path, total_routers: int):
    lines = []
    lines.append(f"Line topology with {total_routers} routers")
    lines.append("")
    lines.append("Routers:")
    for i in range(1, total_routers + 1):
        lines.append(f"  r{i}: AS{asn(i)}, router-id {router_id(i)}")

    lines.append("")
    lines.append("Links:")
    for link_id in range(1, total_routers):
        lines.append(
            f"  r{link_id} <--> r{link_id + 1}: "
            f"{BASE_NET_A}.{BASE_NET_B}.{link_subnet_octet(link_id)}.0/24 "
            f"(r{link_id}={left_ip(link_id)}, r{link_id + 1}={right_ip(link_id)})"
        )

    lines.append("")
    lines.append(f"Originated test prefix on r1: {BASE_PREFIX}")

    (output_dir / "topology.txt").write_text("\n".join(lines) + "\n")


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 scripts/generate_line_configs.py <number_of_routers>")
        sys.exit(1)

    total_routers = int(sys.argv[1])

    if total_routers < 2:
        print("ERROR: number_of_routers must be at least 2")
        sys.exit(1)

    output_dir = Path(f"generated_configs/tcp_line_{total_routers}")
    output_dir.mkdir(parents=True, exist_ok=True)

    for router_num in range(1, total_routers + 1):
        router_dir = output_dir / f"r{router_num}"
        router_dir.mkdir(parents=True, exist_ok=True)

        config = generate_bird_config(router_num, total_routers)
        (router_dir / "bird.conf").write_text(config)

    generate_topology_file(output_dir, total_routers)

    print(f"Generated configs for {total_routers} routers in {output_dir}")


if __name__ == "__main__":
    main()
