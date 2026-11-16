# The Going Down dedicated server, for a Linux box. Build context: godot/export/server (the folder
# `npm run godot:export -- server` writes). See godot/server/README.md for the exact commands.
#
#   docker build -t going-down-server -f godot/server/Dockerfile godot/export/server
#   docker run -d --name going-down --read-only --tmpfs /tmp:size=1m --cap-drop ALL \
#     --security-opt no-new-privileges -p 127.0.0.1:4450:4450 --env-file /path/outside/repo/going-down.env going-down-server
FROM debian:bookworm-slim

# Nothing to install: the headless engine needs only the C library the base image has.
RUN useradd --system --uid 10001 --home-dir /nonexistent --shell /usr/sbin/nologin gd \
 && mkdir -p /srv/going-down

COPY --chown=root:root --chmod=0555 GoingDownServer.x86_64 /srv/going-down/GoingDownServer.x86_64

# The engine looks for a user data folder at start; point it at /tmp (a tmpfs at run time). The
# server itself writes nothing: no log files (it logs to standard output), no saves.
ENV XDG_DATA_HOME=/tmp XDG_CONFIG_HOME=/tmp XDG_CACHE_HOME=/tmp HOME=/tmp

USER gd
WORKDIR /srv/going-down
EXPOSE 4450

# Healthy while the port accepts TCP connections (bash's /dev/tcp: no extra tools in the image).
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/4450"]

# The passphrase comes from the environment at run time (GD_JOIN_SECRET), never from the image.
ENTRYPOINT ["/srv/going-down/GoingDownServer.x86_64", "--headless", "--", "server", "port=4450"]
