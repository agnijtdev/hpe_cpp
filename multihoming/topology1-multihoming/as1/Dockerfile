FROM bird-tls:latest
RUN apk add --no-cache iproute2 iputils tcpdump python3
COPY bird.conf /etc/bird/bird.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && mkdir -p /run/bird
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/entrypoint.sh"]
