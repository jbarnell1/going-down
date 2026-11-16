#!/bin/sh
# Starts the server container, reachable only from this machine itself (127.0.0.1:4450).
# The passphrase is read from ~/going-down.env, a file only you can read, holding one line:
#   GD_JOIN_SECRET=the passphrase for the night
# To change the passphrase: edit that file, then run this script again.
set -eu
ENVFILE="${GD_ENV_FILE:-$HOME/going-down.env}"
[ -f "$ENVFILE" ] || { echo "No $ENVFILE: create it first (see the top of this script)."; exit 1; }
# Its own small network with no route out: the server answers players and can start no connection
# to the home network or the internet.
docker network inspect gd-net >/dev/null 2>&1 || docker network create --driver bridge \
  -o com.docker.network.bridge.enable_ip_masquerade=false \
  -o com.docker.network.bridge.enable_icc=false gd-net >/dev/null
docker rm -f going-down >/dev/null 2>&1 || true
docker run -d --name going-down --network gd-net \
  --read-only --tmpfs /tmp:size=1m,mode=1777 --cap-drop ALL --security-opt no-new-privileges \
  --memory 256m --pids-limit 64 --cpus 2 \
  -p 127.0.0.1:4450:4450 --env-file "$ENVFILE" going-down-server >/dev/null
sleep 2
docker logs going-down 2>&1 | tail -3
