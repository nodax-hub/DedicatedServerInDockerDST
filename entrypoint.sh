#!/usr/bin/env bash
set -euo pipefail

# ---------- ENV ----------
STEAMCMDDIR="${STEAMCMDDIR:-/opt/steamcmd}"
DST_DIR="${DST_DIR:-/opt/dst}"
KLEI_ROOT="${KLEI_ROOT:-/home/steam/.klei}"
CONF_DIR="${CONF_DIR:-DoNotStarveTogether}"
CLUSTER_NAME="${CLUSTER_NAME:-MyDediServer}"

CLUSTER_TOKEN="${CLUSTER_TOKEN:-}"
SERVER_NAME="${SERVER_NAME:-DST Docker Server}"
SERVER_DESC="${SERVER_DESC:-Dedicated server in Docker}"
SERVER_PASSWORD="${SERVER_PASSWORD:-}"
GAME_MODE="${GAME_MODE:-survival}"
MAX_PLAYERS="${MAX_PLAYERS:-6}"
PVP="${PVP:-false}"
PAUSE_WHEN_EMPTY="${PAUSE_WHEN_EMPTY:-true}"
OFFLINE_CLUSTER="${OFFLINE_CLUSTER:-false}"

ENABLE_CAVES="${ENABLE_CAVES:-1}"
MASTER_PORT="${MASTER_PORT:-10999}"
CAVES_PORT="${CAVES_PORT:-11000}"
SHARD_MASTER_PORT="${SHARD_MASTER_PORT:-10888}"
CLUSTER_KEY_ENV="${CLUSTER_KEY:-}"

# Развести steam-порты по шардам (чтобы не кололись 27016):
MASTER_STEAM_PORT="${MASTER_STEAM_PORT:-27016}"
MASTER_AUTH_PORT="${MASTER_AUTH_PORT:-8766}"
CAVES_STEAM_PORT="${CAVES_STEAM_PORT:-27018}"
CAVES_AUTH_PORT="${CAVES_AUTH_PORT:-8768}"

mkdir -p "$KLEI_ROOT/$CONF_DIR" "$DST_DIR" && chown -R steam:steam /home/steam /opt

# ---------- Установка/обновление ----------
if [ "${UPDATE_ON_START:-1}" = "1" ]; then
  gosu steam bash -lc "$STEAMCMDDIR/steamcmd.sh +force_install_dir $DST_DIR +login anonymous +app_update 343050 +quit"
fi

BIN="$DST_DIR/bin64/dontstarve_dedicated_server_nullrenderer_x64"
[ -x "$BIN" ] || { echo "Не найден бинарник: $BIN" >&2; exit 1; }

CLUSTER_DIR="$KLEI_ROOT/$CONF_DIR/$CLUSTER_NAME"
MASTER_DIR="$CLUSTER_DIR/Master"
CAVES_DIR="$CLUSTER_DIR/Caves"

# ---------- Первичная генерация ----------
if [ ! -d "$CLUSTER_DIR" ]; then
  echo "Инициализация кластера в $CLUSTER_DIR"
  mkdir -p "$MASTER_DIR"
  [ "$ENABLE_CAVES" = "1" ] && mkdir -p "$CAVES_DIR"

  if [ -n "$CLUSTER_KEY_ENV" ]; then CLUSTER_KEY="$CLUSTER_KEY_ENV"; else CLUSTER_KEY="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"; fi

  cat > "$CLUSTER_DIR/cluster.ini" <<EOF
[NETWORK]
cluster_name = ${SERVER_NAME}
cluster_description = ${SERVER_DESC}
cluster_password = ${SERVER_PASSWORD}
offline_cluster = ${OFFLINE_CLUSTER}

[GAMEPLAY]
game_mode = ${GAME_MODE}
max_players = ${MAX_PLAYERS}
pvp = ${PVP}
pause_when_empty = ${PAUSE_WHEN_EMPTY}

[MISC]
console_enabled = true

[SHARD]
sharding = true
cluster_key = ${CLUSTER_KEY}
EOF

  [ -n "$CLUSTER_TOKEN" ] && printf "%s" "$CLUSTER_TOKEN" > "$CLUSTER_DIR/cluster_token.txt"

  cat > "$MASTER_DIR/server.ini" <<EOF
[NETWORK]
server_port = ${MASTER_PORT}

[SHARD]
is_master = true
name = Master
id = 1

[STEAM]
master_server_port = ${MASTER_STEAM_PORT}
authentication_port = ${MASTER_AUTH_PORT}
EOF

  cat > "$MASTER_DIR/leveldataoverride.lua" <<'EOF'
return { override_enabled = true, preset = "SURVIVAL_TOGETHER" }
EOF

  if [ "$ENABLE_CAVES" = "1" ]; then
    cat > "$CAVES_DIR/server.ini" <<EOF
[NETWORK]
server_port = ${CAVES_PORT}

[SHARD]
is_master = false
name = Caves
id = 2
master_ip = 127.0.0.1
master_port = ${SHARD_MASTER_PORT}

[STEAM]
master_server_port = ${CAVES_STEAM_PORT}
authentication_port = ${CAVES_AUTH_PORT}
EOF

    cat > "$CAVES_DIR/leveldataoverride.lua" <<'EOF'
return { override_enabled = true, preset = "DST_CAVE" }
EOF
  fi

  chown -R steam:steam "$CLUSTER_DIR"
else
  echo "Найден существующий кластер: $CLUSTER_DIR — оставляю как есть"
fi

# ---------- Запуск ----------
term() { kill -TERM 0 2>/dev/null || true; }
trap term INT TERM

run_shared=( "$BIN" \
  -persistent_storage_root "$KLEI_ROOT" \
  -conf_dir "$CONF_DIR" \
  -cluster "$CLUSTER_NAME" )

# Master
gosu steam bash -lc "cd $DST_DIR/bin64; exec \"${run_shared[@]}\" -shard Master -port ${MASTER_PORT} -steam_master_server_port ${MASTER_STEAM_PORT} -steam_authentication_port ${MASTER_AUTH_PORT}" &
PID_MASTER=$!

# Caves (если есть)
if [ -d "$CAVES_DIR" ]; then
  gosu steam bash -lc "cd $DST_DIR/bin64; exec \"${run_shared[@]}\" -shard Caves -port ${CAVES_PORT} -steam_master_server_port ${CAVES_STEAM_PORT} -steam_authentication_port ${CAVES_AUTH_PORT}" &
  PID_CAVES=$!
fi

# ждём любой из процессов; при завершении — аккуратно гасим второй
if [ -n "${PID_CAVES:-}" ]; then
  wait -n "$PID_MASTER" "$PID_CAVES" || true
else
  wait "$PID_MASTER" || true
fi
term
wait || true
