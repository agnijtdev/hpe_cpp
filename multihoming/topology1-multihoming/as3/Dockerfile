FROM bird-tls:latest

RUN apk add --no-cache \
    iproute2 iputils tcpdump python3 py3-pip \
    kmod

COPY bird.conf          /etc/bird/bird.conf
COPY tunnel_manager.py  /usr/local/bin/tunnel_manager.py
RUN  chmod +x /usr/local/bin/tunnel_manager.py

# Entrypoint: start BIRD in background, then run tunnel_manager.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN mkdir -p /run/bird /var/log

# NET_ADMIN capability is required to create tunnel interfaces (ip tunnel add)
# This is granted in docker-compose.yml via cap_add

ENTRYPOINT ["/entrypoint.sh"]
