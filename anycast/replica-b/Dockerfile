# =============================================================================
# replica-b/Dockerfile
# Extends bird-tls:latest (Alpine-based) with NSD so this container can act
# as one anycast replica: BIRD advertises 192.0.2.1/32, NSD answers DNS.
# =============================================================================
FROM bird-tls:latest

RUN apk add --no-cache \
    nsd \
    python3 \
    py3-pip \
    iproute2 \
    bash

RUN mkdir -p /etc/nsd /var/lib/nsd /var/log/nsd /etc/nsd/zones /var/log/bird

COPY nsd.conf /etc/nsd/nsd.conf
COPY zones/bgpost.lab.zone /etc/nsd/zones/bgpost.lab.zone
COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.py /usr/local/bin/healthcheck.py

RUN chmod +x /entrypoint.sh /usr/local/bin/healthcheck.py

EXPOSE 53/udp 53/tcp 179/tcp

ENTRYPOINT ["/entrypoint.sh"]