#!/usr/bin/env bash
set -u

ROUTERS="hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9"
HOSTS="hpe-h1 hpe-h2 hpe-h3"

TS=$(date +%Y%m%d_%H%M%S)

SNAP_DIR="configs/baseline/${TS}"
LATEST_DIR="configs/baseline/latest"
EVIDENCE_DIR="evidence/config_snapshot"
OUT="${EVIDENCE_DIR}/config_snapshot_${TS}.txt"

mkdir -p "$SNAP_DIR"
mkdir -p "$LATEST_DIR"
mkdir -p "$EVIDENCE_DIR"

{
  echo "Configuration Snapshot"
  echo "Date: $(date)"
  echo "Snapshot directory: $SNAP_DIR"
  echo

  echo "============================================================"
  echo "1. Saving BIRD configs from routers"
  echo "============================================================"

  for r in $ROUTERS; do
    echo
    echo "---- $r ----"

    mkdir -p "$SNAP_DIR/$r"
    mkdir -p "$LATEST_DIR/$r"

    docker cp "$r:/etc/bird/bird.conf" "$SNAP_DIR/$r/bird.conf" 2>/dev/null \
      && echo "Saved $SNAP_DIR/$r/bird.conf" \
      || echo "Failed to save BIRD config from $r"

    cp "$SNAP_DIR/$r/bird.conf" "$LATEST_DIR/$r/bird.conf" 2>/dev/null || true

    echo
    echo "BIRD config checksum:"
    sha256sum "$SNAP_DIR/$r/bird.conf" 2>/dev/null || true
  done

  echo
  echo "============================================================"
  echo "2. Saving router runtime state"
  echo "============================================================"

  for r in $ROUTERS; do
    echo
    echo "---- $r runtime state ----"

    docker exec "$r" sh -lc "
      echo '### hostname'
      hostname

      echo
      echo '### ip addr'
      ip -br addr

      echo
      echo '### ip route'
      ip route

      echo
      echo '### bird protocols'
      birdc show protocols

      echo
      echo '### bird routes'
      birdc show route
    " > "$SNAP_DIR/$r/runtime_state.txt" 2>&1 || true

    cp "$SNAP_DIR/$r/runtime_state.txt" "$LATEST_DIR/$r/runtime_state.txt" 2>/dev/null || true

    echo "Saved $SNAP_DIR/$r/runtime_state.txt"
  done

  echo
  echo "============================================================"
  echo "3. Saving host runtime state"
  echo "============================================================"

  for h in $HOSTS; do
    echo
    echo "---- $h runtime state ----"

    mkdir -p "$SNAP_DIR/$h"
    mkdir -p "$LATEST_DIR/$h"

    docker exec "$h" sh -lc "
      echo '### hostname'
      hostname

      echo
      echo '### ip addr'
      ip -br addr

      echo
      echo '### ip route'
      ip route
    " > "$SNAP_DIR/$h/runtime_state.txt" 2>&1 || true

    cp "$SNAP_DIR/$h/runtime_state.txt" "$LATEST_DIR/$h/runtime_state.txt" 2>/dev/null || true

    echo "Saved $SNAP_DIR/$h/runtime_state.txt"
  done

  echo
  echo "============================================================"
  echo "4. Creating snapshot manifest"
  echo "============================================================"

  MANIFEST="$SNAP_DIR/MANIFEST.txt"

  {
    echo "Configuration Snapshot Manifest"
    echo "Date: $(date)"
    echo
    echo "Routers:"
    for r in $ROUTERS; do
      echo "- $r: bird.conf + runtime_state.txt"
    done
    echo
    echo "Hosts:"
    for h in $HOSTS; do
      echo "- $h: runtime_state.txt"
    done
    echo
    echo "Purpose:"
    echo "This snapshot stores the working baseline configuration and runtime state before further tuning or experiments."
  } > "$MANIFEST"

  cp "$MANIFEST" "$LATEST_DIR/MANIFEST.txt" 2>/dev/null || true

  cat "$MANIFEST"

  echo
  echo "============================================================"
  echo "5. Snapshot file list"
  echo "============================================================"

  find "$SNAP_DIR" -type f | sort

  echo
  echo "Saved snapshot evidence to $OUT"

} | tee "$OUT"
