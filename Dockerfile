FROM debian:bookworm-slim

ENV STEAMCMDDIR=/opt/steamcmd \
    DST_DIR=/opt/dst \
    KLEI_ROOT=/home/steam/.klei \
    CONF_DIR=DoNotStarveTogether \
    CLUSTER_NAME=MyDediServer \
    UPDATE_ON_START=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl tar gosu tini \
      lib32gcc-s1 lib32stdc++6 \
      libcurl3-gnutls \
    && rm -rf /var/lib/apt/lists/*
    
# опционально, чтобы не было предупреждения про locale:
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8


RUN useradd -m -s /bin/bash steam && mkdir -p "$STEAMCMDDIR" "$DST_DIR" "$KLEI_ROOT" \
    && chown -R steam:steam /opt /home/steam

RUN curl -fsSL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
    | tar -xz -C "$STEAMCMDDIR"

VOLUME ["/home/steam/.klei/DoNotStarveTogether", "/opt/dst"]

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 10999/udp 11000/udp
ENTRYPOINT ["/usr/bin/tini","-g","--","/entrypoint.sh"]
