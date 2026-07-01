import sys
from pathlib import Path


PREFIX = "100.100.1.0/24"


def router_id(i: int) -> str:
    return f"{i}.{i}.{i}.{i}"


def asn(i: int) -> int:
    return 65000 + i


def link_subnet_octet(link_id: int) -> int:
    return 10 + link_id


def left_ip(link_id: int) -> str:
    return f"172.33.{link_subnet_octet(link_id)}.11"


def right_ip(link_id: int) -> str:
    return f"172.33.{link_subnet_octet(link_id)}.12"


def ip_for_router_on_link(router: int, link_id: int) -> str:
    """
    Link i connects r{i} and r{i+1}.
    Left router gets .11, right router gets .12.
    """
    if router == link_id:
        return left_ip(link_id)
    if router == link_id + 1:
        return right_ip(link_id)
    raise ValueError(f"Router r{router} is not on link {link_id}")


def bgp_block(local_router: int, peer_router: int) -> str:
    if peer_router == local_router + 1:
        link_id = local_router
        passive_line = ""
    elif peer_router == local_router - 1:
        link_id = peer_router
        passive_line = "    passive on;\n"
    else:
        raise ValueError("Only adjacent routers are supported")

    local_ip = ip_for_router_on_link(local_router, link_id)
    peer_ip = ip_for_router_on_link(peer_router, link_id)

    return f"""
protocol bgp to_r{peer_router} {{
    description "TLS BGP session to r{peer_router}";
    local {local_ip} as {asn(local_router)};
    neighbor {peer_ip} as {asn(peer_router)};
    hold time 240;

    transport tls;
    strict bind on;
{passive_line}
    tls certificate "/etc/bird/certs/r{local_router}.cert.pem";
    tls root ca "/etc/bird/certs/ca.cert.pem";
    tls pkey "/etc/bird/certs/r{local_router}.key";
    tls peer sni "r{peer_router}.rtr";
    tls local sni "r{local_router}.rtr";

    ipv4 {{
        import all;
        export all;
    }};
}}
"""


def build_config(router: int, total: int) -> str:
    parts = []

    parts.append("log stderr all;\n")
    parts.append(f"router id {router_id(router)};\n")

    parts.append("""
protocol device {
}

protocol direct {
    ipv4;
}
""")

    if router == 1:
        parts.append(f"""
protocol static static_routes {{
    ipv4;
    route {PREFIX} blackhole;
}}
""")

    if router > 1:
        parts.append(bgp_block(router, router - 1))

    if router < total:
        parts.append(bgp_block(router, router + 1))

    return "\n".join(parts)


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 scripts/generate_tls_line_configs.py <number_of_routers>")
        print("Example: python3 scripts/generate_tls_line_configs.py 10")
        sys.exit(1)

    total = int(sys.argv[1])

    if total < 2:
        print("ERROR: number_of_routers must be at least 2")
        sys.exit(1)

    out_dir = Path(f"generated_configs/tls_line_{total}")
    out_dir.mkdir(parents=True, exist_ok=True)

    topology_lines = []
    topology_lines.append(f"TLS line topology with {total} routers")
    topology_lines.append("")
    topology_lines.append("Path:")
    topology_lines.append(" -- ".join([f"r{i}" for i in range(1, total + 1)]))
    topology_lines.append("")
    topology_lines.append("Links:")

    for link_id in range(1, total):
        topology_lines.append(
            f"r{link_id}({left_ip(link_id)}) <--> "
            f"r{link_id + 1}({right_ip(link_id)}) "
            f"on 172.33.{link_subnet_octet(link_id)}.0/24"
        )

    (out_dir / "topology.txt").write_text("\n".join(topology_lines) + "\n")

    for router in range(1, total + 1):
        r_dir = out_dir / f"r{router}"
        r_dir.mkdir(parents=True, exist_ok=True)
        (r_dir / "bird.conf").write_text(build_config(router, total))

    print(f"Generated TLS configs for {total} routers in {out_dir}")


if __name__ == "__main__":
    main()
