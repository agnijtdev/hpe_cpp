#!/bin/bash
# =============================================================================
# scripts/02-extract-cert-profile.sh
# -----------------------------------------------------------------------------
# Demonstrates the "automated configuration extraction" concept from the
# paper (Section 4 / Listing 1): pulling the embedded JSON router-config
# blob back out of an X.509 certificate using plain openssl.
#
# This is illustrative only -- BIRD itself does not parse this extension
# (see the note at the top of 01-generate-certs.sh). Run this manually to
# see the data is genuinely embedded in the certificate, the way the paper
# describes a "Provider Certificate Generator" portal would do automatically.
#
# Usage: ./02-extract-cert-profile.sh <cert-name>
#   e.g. ./02-extract-cert-profile.sh replica-a
# =============================================================================
set -euo pipefail

CERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/certs"
CERT_NAME="${1:-replica-a}"
CERT_FILE="${CERT_DIR}/${CERT_NAME}.crt"

if [ ! -f "${CERT_FILE}" ]; then
    echo "ERROR: ${CERT_FILE} not found. Run 01-generate-certs.sh first."
    exit 1
fi

echo "=== Full certificate text (note the SAN and custom OID extension) ==="
openssl x509 -in "${CERT_FILE}" -noout -text | sed -n '/X509v3 extensions/,/Signature Algorithm/p'
echo

echo "=== Extracting the embedded JSON config blob (OID 1.2.3.4.5.6.7.8.1) ==="
# The extension's value is printed on the line immediately following the
# "1.2.3.4.5.6.7.8.1:" header line. OpenSSL prefixes UTF8String DER output
# with stray bytes (e.g. ".;") before the printable text -- strip those.
RAW_EXT=$(openssl x509 -in "${CERT_FILE}" -noout -text \
    | awk '/1\.2\.3\.4\.5\.6\.7\.8\.1:/{getline; print; exit}' \
    | sed -E 's/^[[:space:]]*//; s/^[^{]*(\{)/\1/')
echo "Raw extension value:"
echo "    ${RAW_EXT}"
echo
echo "In a real BGPoST deployment, the provider's router would parse this"
echo "JSON at session-establishment time and apply it automatically (e.g."
echo "install an import filter restricting accepted prefixes to those"
echo "listed). In this lab, that filter logic instead lives explicitly in"
echo "bird.conf -- this script just proves the certificate genuinely"
echo "carries the configuration payload end-to-end."