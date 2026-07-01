# =============================================================================
# client-node/Dockerfile
# Lightweight container used purely to send DNS queries / pings toward the
# anycast address 192.0.2.1 and observe failover behaviour.
# =============================================================================
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    dnsutils \
    iputils-ping \
    iproute2 \
    curl \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root
ENTRYPOINT ["/bin/bash"]
CMD ["-c", "sleep infinity"]