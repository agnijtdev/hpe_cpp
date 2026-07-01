#!/usr/bin/env bash
# =============================================================================
# gen_certs.sh — Generate CA + per-router X.509 certificates for BGPoST lab
#
# Each certificate embeds a custom JSON block in a SubjectAltName extension
# (OID 1.3.6.1.4.1.99999.1) that carries router configuration data, exactly
# as proposed in Section 4 of the BGPoST paper.
#
# Cert layout:
#   ca/           — Root CA (self-signed)
#   as1/          — Provider AS1 router cert
#   as2/          — Provider AS2 router cert
#   as3/          — Stub AS3 router cert  (contains tunnel config JSON)
#   replica-a/    — Anycast replica A cert (contains anycast prefix JSON)
#   replica-b/    — Anycast replica B cert
# =============================================================================
set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")" && pwd)"
CA_DIR="$CERT_DIR/ca"
DAYS=3650
KEY_SIZE=4096

# Colour helpers
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[CERT]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

mkdir -p "$CA_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# 1. Root Certificate Authority
# ─────────────────────────────────────────────────────────────────────────────
info "Generating Root CA..."
openssl genrsa -out "$CA_DIR/ca.key" $KEY_SIZE 2>/dev/null
openssl req -new -x509 -days $DAYS \
  -key "$CA_DIR/ca.key" \
  -out "$CA_DIR/ca.crt" \
  -subj "/C=BE/ST=Wallonia/L=Louvain/O=BGPoST-Lab-CA/CN=bgpost-lab-ca" \
  -extensions v3_ca \
  -addext "basicConstraints=critical,CA:TRUE"
info "CA certificate: $CA_DIR/ca.crt"

# ─────────────────────────────────────────────────────────────────────────────
# Helper: generate a router cert with an optional JSON config block
#   $1 = output directory name (relative to CERT_DIR)
#   $2 = Common Name
#   $3 = IP SAN (e.g. "2001:db8:1::1")
#   $4 = JSON config string (empty string = no custom extension)
# ─────────────────────────────────────────────────────────────────────────────
gen_router_cert() {
  local name="$1"
  local cn="$2"
  local ip_san="$3"
  local json_config="$4"
  local out="$CERT_DIR/$name"

  mkdir -p "$out"
  info "Generating cert for $cn ($name)..."

  # Generate private key
  openssl genrsa -out "$out/router.key" $KEY_SIZE 2>/dev/null

  # Build OpenSSL extensions config
  local ext_file="$out/ext.cnf"
  cat > "$ext_file" <<EXTEOF
[req]
distinguished_name = req_distinguished_name
req_extensions     = v3_req
prompt             = no

[req_distinguished_name]
C  = BE
ST = Wallonia
O  = BGPoST-Lab
CN = $cn

[v3_req]
subjectAltName = @alt_names
keyUsage       = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth, serverAuth

[alt_names]
DNS.1 = $cn
IP.1  = $ip_san
EXTEOF

  # If JSON config is provided, add it as a custom critical extension
  # OID 1.3.6.1.4.1.99999.1 is a private-enterprise OID used for the lab
  if [[ -n "$json_config" ]]; then
    cat >> "$ext_file" <<JSONEXT

[v3_req_extra]
# BGPoST Router Configuration Section (paper Section 4 / Listing 1)
1.3.6.1.4.1.99999.1 = ASN1:UTF8String:$json_config
JSONEXT
    # Append to v3_req section
    echo "1.3.6.1.4.1.99999.1 = ASN1:UTF8String:$json_config" >> "$ext_file"
    # Store JSON separately for easy parsing by Python scripts
    echo "$json_config" > "$out/bgpost_config.json"
    info "  Embedded BGPoST config JSON → $out/bgpost_config.json"
  fi

  # Generate CSR
  openssl req -new \
    -key "$out/router.key" \
    -out "$out/router.csr" \
    -config "$ext_file" 2>/dev/null

  # Sign with CA
  openssl x509 -req \
    -in "$out/router.csr" \
    -CA "$CA_DIR/ca.crt" \
    -CAkey "$CA_DIR/ca.key" \
    -CAcreateserial \
    -out "$out/router.crt" \
    -days $DAYS \
    -extfile "$ext_file" \
    -extensions v3_req 2>/dev/null

  # Copy CA cert for convenience
  cp "$CA_DIR/ca.crt" "$out/ca.crt"

  # Verify
  openssl verify -CAfile "$CA_DIR/ca.crt" "$out/router.crt" >/dev/null
  info "  ✓ $out/router.crt verified against CA"
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Topology 1 — IPv6 Multihoming routers
#    AS3's certificate embeds the GRE tunnel configuration that will be parsed
#    by tunnel_manager.py to automatically bring up the backup tunnel.
# ─────────────────────────────────────────────────────────────────────────────

gen_router_cert "as1" "as1.bgpost.lab" "172.30.12.2" ""

gen_router_cert "as2" "as2.bgpost.lab" "172.30.12.3" ""

AS3_JSON='{
"prefixes":["10.3.0.0/16"],
"tunnel":{
"type":"GRE",
"local_addr":"172.30.23.3",
"remote_addr":"172.30.23.2",
"backup_via":"172.30.13.2",
"keepalive_interval":5,
"bfd":true
},
"as_number":65003
}'
gen_router_cert "as3" "as3.bgpost.lab" "172.30.23.3" "$AS3_JSON"
# ─────────────────────────────────────────────────────────────────────────────
# 3. Topology 2 — Anycast service replicas
#    Each replica cert embeds the anycast prefix it should advertise when
#    healthy, as described in paper Section 5 / Appendix A.2.
# ─────────────────────────────────────────────────────────────────────────────

REPLICA_A_JSON='{"anycast_prefix":"2001:db8:ff::/48","service":"dns","health_check":{"port":53,"protocol":"udp","query":"example.com","interval":10},"as_number":65101}'
gen_router_cert "replica-a" "replica-a.bgpost.lab" "2001:db8:a::1" "$REPLICA_A_JSON"

REPLICA_B_JSON='{"anycast_prefix":"2001:db8:ff::/48","service":"dns","health_check":{"port":53,"protocol":"udp","query":"example.com","interval":10},"as_number":65102}'
gen_router_cert "replica-b" "replica-b.bgpost.lab" "2001:db8:b::1" "$REPLICA_B_JSON"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Print summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
info "Certificate generation complete. Summary:"
echo "═══════════════════════════════════════════════════════"
for d in "$CERT_DIR"/*/; do
  name=$(basename "$d")
  if [[ -f "$d/router.crt" ]]; then
    expiry=$(openssl x509 -noout -enddate -in "$d/router.crt" | cut -d= -f2)
    echo "  $name → router.crt  (expires: $expiry)"
    if [[ -f "$d/bgpost_config.json" ]]; then
      echo "    └─ BGPoST config: $(cat "$d/bgpost_config.json" | python3 -m json.tool --compact 2>/dev/null || cat "$d/bgpost_config.json")"
    fi
  fi
done
echo "═══════════════════════════════════════════════════════"
echo ""
warn "IMPORTANT: Copy cert directories into the respective container build contexts:"
echo "  cp -r as1  ../topology1-multihoming/as1/certs"
echo "  cp -r as2  ../topology1-multihoming/as2/certs"
echo "  cp -r as3  ../topology1-multihoming/as3/certs"
echo "  cp -r replica-a ../topology2-anycast/replica-a/certs"
echo "  cp -r replica-b ../topology2-anycast/replica-b/certs"
echo ""
echo "Or run:  bash $CERT_DIR/distribute_certs.sh"