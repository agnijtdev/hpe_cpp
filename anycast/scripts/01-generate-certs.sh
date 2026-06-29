#!/bin/bash
# =============================================================================
# scripts/01-generate-certs.sh
# -----------------------------------------------------------------------------
# Generates a simulated BGPoST PKI:
#   - One local Certificate Authority (CA) -- "operators host their own CA"
#     per Section 4 ("Provisioning BGPoST certificates for ASes") of the paper.
#   - A server certificate for provider-router.
#   - Client certificates for replica-a and replica-b (mutual TLS / mTLS).
#
# SIMULATING THE "EMBEDDED CONFIGURATION" IDEA FROM THE PAPER:
# -----------------------------------------------------------------------------
# The paper proposes embedding a JSON router-configuration blob inside a
# custom X.509v3 extension (see Listing 1 / Section 4 of the paper). This is
# a *research prototype* feature requiring a patched X.509 parser inside
# BIRD -- it is NOT a documented, stable feature of the public BGPoTLS repo.
#
# We simulate the *idea* safely and transparently:
#   1) We embed a JSON config blob as a custom X.509v3 extension
#      (OID 1.2.3.4.5.6.7.8.1, arbitrary/unregistered -- lab use only).
#   2) BIRD does NOT read this extension. Real session config (local/neighbor
#      IP, ASN, filters) lives in bird.conf as plain BIRD syntax, which is
#      what the public repo actually supports.
#   3) scripts/02-extract-cert-profile.sh shows you how to pull that JSON
#      back OUT of a live certificate with openssl, demonstrating the
#      "automated configuration extraction" workflow conceptually, without
#      pretending BIRD acts on it automatically.
#
# Output: ./certs/{ca.crt, ca.key, provider.{crt,key}, replica-a.{crt,key},
#                   replica-b.{crt,key}}
# =============================================================================
set -euo pipefail

CERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/certs"
mkdir -p "${CERT_DIR}"
cd "${CERT_DIR}"

DAYS=3650

echo "=== [1/4] Generating Certificate Authority (CA) ==="
openssl genpkey -algorithm ED25519 -out ca.key
openssl req -x509 -new -key ca.key -days ${DAYS} -out ca.crt \
    -subj "/C=BE/ST=Lab/L=Lab/O=BGPoST-Lab-CA/CN=BGPoST Lab Root CA"
echo "    -> ca.crt / ca.key created."
echo

# -----------------------------------------------------------------------------
# Helper: build an openssl extension file for a given node, embedding:
#   - subjectAltName (DNS SNI value used in bird.conf 'tls local/peer sni')
#   - a custom OID extension carrying a JSON "router configuration" blob,
#     simulating the BGPoST certificate concept from the paper (Listing 1).
# -----------------------------------------------------------------------------
make_ext_file() {
    local name="$1"        # e.g. replica-a
    local sni="$2"         # e.g. replica-a.bgpost.lab
    local json_config="$3" # JSON blob to embed (simulated only)
    local ext_file="${name}.ext.cnf"

    # Custom OID 1.2.3.4.5.6.7.8.1 is an arbitrary, UNREGISTERED OID used
    # for lab/simulation purposes only. Do not reuse in production.
    cat > "${ext_file}" <<EOF
subjectAltName = DNS:${sni}
1.2.3.4.5.6.7.8.1 = ASN1:UTF8String:${json_config}
EOF
    echo "${ext_file}"
}

echo "=== [2/4] Generating provider-router server certificate ==="
PROVIDER_JSON='{"role":"provider","as":65000,"accepts_prefixes":["192.0.2.1/32"]}'
openssl genpkey -algorithm ED25519 -out provider.key
openssl req -new -key provider.key -out provider.csr \
    -subj "/C=BE/ST=Lab/L=Lab/O=BGPoST-Lab/CN=provider.bgpost.lab"
EXT_FILE=$(make_ext_file "provider" "provider.bgpost.lab" "${PROVIDER_JSON}")
openssl x509 -req -in provider.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out provider.crt -days ${DAYS} -extfile "${EXT_FILE}"
rm -f provider.csr
echo "    -> provider.crt / provider.key created."
echo

echo "=== [3/4] Generating anycast-replica-a client certificate ==="
REPLICA_A_JSON='{"role":"client","as":65010,"prefixes":["192.0.2.1/32"],"qos_mbps":100}'
openssl genpkey -algorithm ED25519 -out replica-a.key
openssl req -new -key replica-a.key -out replica-a.csr \
    -subj "/C=BE/ST=Lab/L=Lab/O=BGPoST-Lab/CN=replica-a.bgpost.lab"
EXT_FILE=$(make_ext_file "replica-a" "replica-a.bgpost.lab" "${REPLICA_A_JSON}")
openssl x509 -req -in replica-a.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out replica-a.crt -days ${DAYS} -extfile "${EXT_FILE}"
rm -f replica-a.csr
echo "    -> replica-a.crt / replica-a.key created."
echo

echo "=== [4/4] Generating anycast-replica-b client certificate ==="
REPLICA_B_JSON='{"role":"client","as":65011,"prefixes":["192.0.2.1/32"],"qos_mbps":100}'
openssl genpkey -algorithm ED25519 -out replica-b.key
openssl req -new -key replica-b.key -out replica-b.csr \
    -subj "/C=BE/ST=Lab/L=Lab/O=BGPoST-Lab/CN=replica-b.bgpost.lab"
EXT_FILE=$(make_ext_file "replica-b" "replica-b.bgpost.lab" "${REPLICA_B_JSON}")
openssl x509 -req -in replica-b.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out replica-b.crt -days ${DAYS} -extfile "${EXT_FILE}"
rm -f replica-b.csr
echo "    -> replica-b.crt / replica-b.key created."
echo

chmod 644 ./*.crt
chmod 600 ./*.key
rm -f ./*.ext.cnf ./*.srl

echo "=== Done. Certificates are in: ${CERT_DIR} ==="
ls -l "${CERT_DIR}"