FROM bird-tls:latest

RUN apk add --no-cache bash iproute2
RUN mkdir -p /var/log/bird

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 179/tcp

ENTRYPOINT ["/entrypoint.sh"]