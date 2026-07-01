#!/usr/bin/env python3

from pathlib import Path
import subprocess
import re
import shutil
import sys
from datetime import datetime

# Desired OSPF interface order for each router.
# The order matches the existing bird.conf OSPF interface blocks.
# We detect the current interface name by IP address.
desired_ips = {
    "hpe-r1": ["10.0.12.2", "10.0.13.2", "10.0.14.2"],
    "hpe-r2": ["10.0.12.3", "10.0.23.2", "10.0.24.2"],
    "hpe-r3": ["10.0.13.3", "10.0.23.3", "10.0.34.2", "10.0.35.2"],
    "hpe-r4": ["10.0.14.3", "10.0.24.3", "10.0.34.3", "10.0.47.2"],
    "hpe-r5": ["10.0.35.3", "10.0.56.2"],
    "hpe-r6": ["10.0.56.3", "10.0.61.3"],
    "hpe-r7": ["10.0.47.3", "10.0.78.2"],
    "hpe-r8": ["10.0.78.3", "10.0.82.3"],
}

def run(cmd, check=True, capture=True):
    result = subprocess.run(
        cmd,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )
    if check and result.returncode != 0:
        print(f"\nCommand failed: {' '.join(cmd)}")
        if capture:
            print(result.stdout)
        sys.exit(1)
    return result.stdout if capture else ""

def iface_for_ip(router, ip):
    out = run(["docker", "exec", router, "ip", "-o", "-4", "addr", "show"])
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 4:
            iface = parts[1].split("@")[0]
            addr = parts[3]
            if addr == f"{ip}/24":
                return iface
    raise RuntimeError(f"Could not find IP {ip}/24 inside {router}")

timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
backup_dir = Path(f"configs/tuned_backup_before_iface_fix_{timestamp}")
backup_dir.mkdir(parents=True, exist_ok=True)

print("Fixing BIRD OSPF interface names after reboot...\n")

for router, ips in desired_ips.items():
    print(f"===== {router} =====")

    detected_ifaces = []
    for ip in ips:
        iface = iface_for_ip(router, ip)
        detected_ifaces.append(iface)
        print(f"  {ip} -> {iface}")

    tuned_path = Path("configs/tuned") / router / "bird.conf"
    current_path = Path("configs/current") / router / "bird.conf"

    if tuned_path.exists():
        source_path = tuned_path
    elif current_path.exists():
        source_path = current_path
    else:
        # Last fallback: copy from running container
        source_path = tuned_path
        source_path.parent.mkdir(parents=True, exist_ok=True)
        run(["docker", "cp", f"{router}:/etc/bird/bird.conf", str(source_path)])

    backup_path = backup_dir / f"{router}.bird.conf"
    shutil.copy2(source_path, backup_path)

    text = source_path.read_text()
    lines = text.splitlines()

    iface_index = 0
    new_lines = []

    for line in lines:
        # Replace only OSPF-style non-loopback interface lines.
        # Example: interface "eth2" {
        if re.search(r'interface\s+"eth[0-9]+"', line):
            if iface_index >= len(detected_ifaces):
                print(f"  ERROR: More interface lines than expected in {source_path}")
                sys.exit(1)

            new_iface = detected_ifaces[iface_index]
            line = re.sub(r'interface\s+"eth[0-9]+"', f'interface "{new_iface}"', line)
            iface_index += 1

        new_lines.append(line)

    if iface_index != len(detected_ifaces):
        print(f"  ERROR: Expected to replace {len(detected_ifaces)} interface lines, replaced {iface_index}")
        print(f"  Check config file: {source_path}")
        sys.exit(1)

    tuned_path.parent.mkdir(parents=True, exist_ok=True)
    tuned_path.write_text("\n".join(new_lines) + "\n")

    # Validate inside container before applying.
    run(["docker", "cp", str(tuned_path), f"{router}:/tmp/bird.conf.ifacefix"])
    validation = run(["docker", "exec", router, "bird", "-p", "-c", "/tmp/bird.conf.ifacefix"])

    if "Configuration OK" not in validation:
        print(validation)

    # Apply.
    run(["docker", "cp", str(tuned_path), f"{router}:/etc/bird/bird.conf"])
    run(["docker", "exec", router, "birdc", "configure"])

    print(f"  Applied fixed config to {router}\n")

print(f"Backups saved in: {backup_dir}")
print("Interface fix completed.")
