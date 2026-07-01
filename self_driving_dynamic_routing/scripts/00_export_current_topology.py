#!/usr/bin/env python3
import json
import subprocess
import sys
from pathlib import Path

containers = [
    "hpe-r1", "hpe-r2", "hpe-r3", "hpe-r4", "hpe-r5", "hpe-r6", "hpe-r7", "hpe-r8", "hpe-r9",
    "hpe-h1", "hpe-h2", "hpe-h3"
]

def run(cmd):
    return subprocess.check_output(cmd, text=True)

def sh_quote(s):
    return "'" + s.replace("'", "'\"'\"'") + "'"

out_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("scripts/00_create_topology.sh")

info = json.loads(run(["docker", "inspect"] + containers))

container_networks = {}
all_networks = set()

for item in info:
    name = item["Name"].lstrip("/")
    nets = item["NetworkSettings"]["Networks"]
    container_networks[name] = []
    for net_name, net_data in nets.items():
        ip = net_data.get("IPAddress")
        if ip:
            container_networks[name].append((net_name, ip))
            if net_name.startswith("net_"):
                all_networks.add(net_name)

net_info = json.loads(run(["docker", "network", "inspect"] + sorted(all_networks)))

network_subnets = {}
for net in net_info:
    name = net["Name"]
    ipam = net.get("IPAM", {}).get("Config", [])
    subnet = None
    for cfg in ipam:
        if cfg.get("Subnet"):
            subnet = cfg["Subnet"]
            break
    if subnet:
        network_subnets[name] = subnet

# Find host default gateways: host has one net, gateway is router IP in same net
host_gateways = {}
for host in ["hpe-h1", "hpe-h2", "hpe-h3"]:
    if not container_networks.get(host):
        continue
    host_net = container_networks[host][0][0]
    gw = None
    for cname, nets in container_networks.items():
        if cname.startswith("hpe-r"):
            for n, ip in nets:
                if n == host_net:
                    gw = ip
                    break
        if gw:
            break
    if gw:
        host_gateways[host] = gw

lines = []
lines.append("#!/usr/bin/env bash")
lines.append("set -euo pipefail")
lines.append("")
lines.append('IMAGE="${IMAGE:-hpe-bird-lab}"')
lines.append("")
lines.append('echo "Building Docker image..."')
lines.append('docker build -t "$IMAGE" bird-lab')
lines.append("")
lines.append('echo "Removing old containers if present..."')
for c in containers:
    lines.append(f"docker rm -f {sh_quote(c)} >/dev/null 2>&1 || true")
lines.append("")
lines.append('echo "Removing old lab networks if present..."')
for n in sorted(all_networks):
    lines.append(f"docker network rm {sh_quote(n)} >/dev/null 2>&1 || true")
lines.append("")
lines.append('echo "Creating lab networks..."')
for n in sorted(all_networks):
    subnet = network_subnets.get(n)
    if subnet:
        lines.append(f"docker network create --driver bridge --subnet {sh_quote(subnet)} {sh_quote(n)} >/dev/null")
    else:
        lines.append(f"docker network create --driver bridge {sh_quote(n)} >/dev/null")
lines.append("")
lines.append('echo "Creating containers..."')
for c in containers:
    lines.append(f'docker run -dit --privileged --name {sh_quote(c)} --network none "$IMAGE" bash >/dev/null')
lines.append("")
lines.append('echo "Connecting containers to networks with fixed IPs..."')
for c in containers:
    for n, ip in container_networks.get(c, []):
        if n.startswith("net_"):
            lines.append(f"docker network connect --ip {sh_quote(ip)} {sh_quote(n)} {sh_quote(c)}")
lines.append("")
lines.append('echo "Enabling IP forwarding on routers..."')
for r in [c for c in containers if c.startswith("hpe-r")]:
    lines.append(f"docker exec {sh_quote(r)} sysctl -w net.ipv4.ip_forward=1 >/dev/null")
lines.append("")
lines.append('echo "Installing BIRD configs and starting BIRD..."')
for i in range(1, 10):
    r = f"hpe-r{i}"
    lines.append(f"docker exec {sh_quote(r)} mkdir -p /etc/bird /run/bird")
    lines.append(f"docker cp configs/r{i}.conf {sh_quote(r)}:/etc/bird/bird.conf")
    lines.append(f"docker exec {sh_quote(r)} sh -lc 'rm -f /run/bird/bird.ctl; bird -c /etc/bird/bird.conf'")
lines.append("")
lines.append('echo "Setting host default routes..."')
for h, gw in host_gateways.items():
    lines.append(f"docker exec {sh_quote(h)} ip route replace default via {sh_quote(gw)}")
lines.append("")
lines.append('echo "Waiting for routing protocols to converge..."')
lines.append("sleep 10")
lines.append("")
lines.append('echo "Fixing interface names / runtime forwarding if helper scripts exist..."')
lines.append("if [ -f scripts/fix_bird_interfaces_after_reboot.py ]; then python3 scripts/fix_bird_interfaces_after_reboot.py || true; fi")
lines.append("if [ -f scripts/fix_runtime_forwarding.sh ]; then bash scripts/fix_runtime_forwarding.sh || true; fi")
lines.append("")
lines.append('echo "Validating lab..."')
lines.append("if [ -f scripts/02_validate_baseline.sh ]; then bash scripts/02_validate_baseline.sh || true; fi")
lines.append("")
lines.append('echo "Topology created. Run scripts/12_final_project_validation.sh to confirm final health."')

out_path.write_text("\n".join(lines) + "\n")
out_path.chmod(0o755)
print(f"Generated {out_path}")
