#!/usr/bin/env bash
set -euo pipefail

echo "============================================================"
echo "ENABLE BIRD GOLD LOGGING"
echo "============================================================"

for r in hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9; do
    echo
    echo "Configuring BIRD log file on $r"

    docker exec "$r" sh -lc '
        set -e

        CONF="/etc/bird/bird.conf"
        LOG="/tmp/bird-gold.log"

        cp "$CONF" "/tmp/bird.conf.before_gold_log"

        if ! grep -q "/tmp/bird-gold.log" "$CONF"; then
            {
                echo "log \"/tmp/bird-gold.log\" all;"
                cat "$CONF"
            } > /tmp/bird.conf.with_gold_log

            cp /tmp/bird.conf.with_gold_log "$CONF"
        fi

        : > "$LOG"

        bird -p -c "$CONF" >/dev/null
        birdc configure >/dev/null
    '

    echo "[OK] $r logging enabled at /tmp/bird-gold.log"
done

echo
echo "Done."
