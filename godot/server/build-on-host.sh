#!/bin/sh
# Builds the "going-down-server" image on a Linux machine with Docker, from the folder that holds
# GoingDownServer.x86_64 (from `npm run godot:export -- server`), Dockerfile.scratch and this script.
set -eu
cd "$(dirname "$0")"
BIN=GoingDownServer.x86_64
[ -f "$BIN" ] || { echo "Put $BIN beside this script first."; exit 1; }
rm -rf ctx
mkdir -p ctx/lib ctx/lib64
cp "$BIN" ctx/
# Every library the server file is linked against, as this machine resolves them.
ldd "$BIN" | awk '$2 == "=>" && $3 ~ /^\// { print $3 }' | while read -r f; do cp -L "$f" ctx/lib/; done
cp -L /lib64/ld-linux-x86-64.so.2 ctx/lib64/
cp Dockerfile.scratch ctx/Dockerfile
docker build -q -t going-down-server ctx
rm -rf ctx
echo "built going-down-server"
