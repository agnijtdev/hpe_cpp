#!/usr/bin/env bash
# distribute_certs.sh — Copy generated certs into each container's build context
set -euo pipefail
CERT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$CERT_DIR")"

copy_cert() {
  local src="$CERT_DIR/$1"
  local dst="$2"
  mkdir -p "$dst"
  cp -r "$src/." "$dst/"
  echo "[DIST] $1 → $dst"
}

copy_cert "as1"      "$ROOT/topology1-multihoming/as1/certs"
copy_cert "as2"      "$ROOT/topology1-multihoming/as2/certs"
copy_cert "as3"      "$ROOT/topology1-multihoming/as3/certs"
copy_cert "replica-a" "$ROOT/topology2-anycast/replica-a/certs"
copy_cert "replica-b" "$ROOT/topology2-anycast/replica-b/certs"
# Routers also need the CA to verify peer certs
for router in router-a router-b; do
  mkdir -p "$ROOT/topology2-anycast/$router/certs"
  cp "$CERT_DIR/ca/ca.crt" "$ROOT/topology2-anycast/$router/certs/"
done

echo "Done. All certs distributed."