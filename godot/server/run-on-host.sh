#!/bin/sh
# Starts the server container, reachable only from this machine itself (127.0.0.1:4450).
# The passphrase is read from ~/going-down.env, a file only you can read, holding one line:
#   GD_JOIN_SECRET=the passphrase for the night
# To change the passphrase: edit that file, then run this script again.
# Live settings (the host's F8 panel): if the folder ~/going-down-settings exists (create it once and give it to
# the container's user: mkdir ~/going-down-settings && sudo chown 10001 ~/going-down-settings), it is mounted at
# /settings and the server keeps the host's changes in /settings/settings.json (with .log, .tmp and .bad beside
# it). Without the folder the changes last until the container stops. Nothing else is writable.
set -eu
ENVFILE="${GD_ENV_FILE:-$HOME/going-down.env}"
SETTINGS_DIR="${GD_SETTINGS_DIR:-$HOME/going-down-settings}"
SETTINGS_ARGS=""
[ -d "$SETTINGS_DIR" ] && SETTINGS_ARGS="-v $SETTINGS_DIR:/settings -e GD_SETTINGS_FILE=/settings/settings.json"
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
  -p 127.0.0.1:4450:4450 --env-file "$ENVFILE" $SETTINGS_ARGS going-down-server flare=1 lamp=1 >/dev/null
sleep 2
docker logs going-down 2>&1 | tail -3
