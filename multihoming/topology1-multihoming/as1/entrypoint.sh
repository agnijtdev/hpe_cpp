#!/bin/sh
sleep 3
exec /usr/sbin/bird -f -c /etc/bird/bird.conf
