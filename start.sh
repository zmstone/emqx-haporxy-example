#!/bin/bash

set -euo pipefail

THIS_DIR="$(pwd)"
cat certs/server.pem certs/server.key > certs/server-bundle.pem

docker rm -f 'n1.test.net' 2>/dev/null || true
docker rm -f 'n2.test.net' 2>/dev/null || true
docker rm -f 'proxy.test.net' 2>/dev/null || true
docker network rm 'test.net' 2>/dev/null || true

docker network create 'test.net'

docker run -d \
    --name n1.test.net \
    --net test.net \
    -p 18083:18083 \
    -e EMQX_NODE_NAME=emqx@n1.test.net \
    -e EMQX_LISTENER__TCP__EXTERNAL__PROXY_PROTOCOL=on \
    -e EMQX_listener__tcp__external__peer_cert_as_username=cn \
    -e EMQX_LOG__LEVEL=debug \
    emqx/emqx:4.3.6

docker run -d \
    --name n2.test.net \
    --net test.net \
    -p 18084:18083 \
    -e EMQX_NODE_NAME=emqx@n2.test.net \
    -e EMQX_LISTENER__TCP__EXTERNAL__PROXY_PROTOCOL=on \
    -e EMQX_listener__tcp__external__peer_cert_as_username=cn \
    -e EMQX_LOG__LEVEL=debug \
    emqx/emqx:4.3.6

cat<<EOF > haproxy.cfg
global
    log stdout format raw daemon debug
    nbproc 1
    nbthread 2
    cpu-map auto:1/1-2 0-1
    # Enable the HAProxy Runtime API
    # e.g. echo "show table emqx_tcp_back" | sudo socat stdio tcp4-connect:172.100.239.4:9999
    stats socket :9999 level admin expose-fd listeners
defaults
    log global
    mode tcp
    option tcplog
    maxconn 1024000
    timeout connect 30000
    timeout client 600s
    timeout server 600s
frontend emqx_tcp
   mode tcp
   option tcplog
   bind *:1883
   # 'verify required' must be set, otherwise the client may not send its certificate
   bind *:8883 ssl crt /certs/server-bundle.pem ca-file /certs/ca.pem verify required
   default_backend emqx_tcp_back
backend emqx_tcp_back
    mode tcp
    # Create a stick table for session persistence
    stick-table type string len 32 size 100k expire 30m
    # Use ClientID / client_identifier as persistence key
    stick on req.payload(0,0),mqtt_field_value(connect,client_identifier)
    # send proxy-protocol v2 headers
    server emqx1 n1.test.net:1883 check-send-proxy send-proxy-v2-ssl-cn
    server emqx2 n2.test.net:1883 check-send-proxy send-proxy-v2-ssl-cn
EOF

docker run -d \
    --net test.net \
    --name proxy.test.net \
    -p 1883:1883 \
    -p 8883:8883 \
    -p 9999:9999 \
    -v ${THIS_DIR}/certs:/certs \
    -v ${THIS_DIR}/haproxy.cfg:/haproxy.cfg \
    haproxy:2.4 haproxy -f /haproxy.cfg

wait (){
  container="$1"
  while ! docker exec "$container" emqx_ctl status >/dev/null 2>&1; do
    echo -n '.'
    sleep 1
  done
}

wait 'n1.test.net'
wait 'n2.test.net'

docker exec -it n2.test.net emqx_ctl cluster join emqx@n1.test.net

# start a subscriber client to test TLS
# docker run -v $(pwd)/certs:/certs --rm -it --net host eclipse-mosquitto mosquitto_sub -h localhost -p 8883 -t 't/xyz' --cert /certs/client.pem --key /certs/client.key --cafile /certs/ca.pem -i client1
