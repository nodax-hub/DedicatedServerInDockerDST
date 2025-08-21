#!/usr/bin/env bash
set -euo pipefail

# ---------- ENV с дефолтами ----------
STEAMCMDDIR="${STEAMCMDDIR:-/opt/steamcmd}"
DST_DIR="${DST_DIR:-/opt/dst}"
KLEI_ROOT="${KLEI_ROOT:-/home/steam/.klei}"
CONF_DIR="${CONF_DIR:-DoNotStarveTogether}"
CLUSTER_NAME="${CLUSTER_NAME:-MyDediServer}"

# пользовательские настройки (из .env)
CLUSTER_TOKEN="${CLUSTER_TOKEN:-}"                # ОБЯЗАТЕЛЬНО заполнить
SERVER_NAME="${SERVER_NAME:-DST Docker Server}"
SERVER_DESC="${SERVER_DESC:-Dedicated server in Docker}"
SERVER_PASSWORD="${SERVER_PASSWORD:-}"            # пусто = без пароля
GAME_MODE="${GAME_MODE:-survival}"               # survival / endless / wilderness
MAX_PLAYERS="${MAX_PLAYERS:-6}"
PVP="${PVP:-false}"
PAUSE_WHEN_EMPTY="${PAUSE_WHEN_EMPTY:-true}"
OFFLINE_CLUSTER="${OFFLINE_CLUSTER:-false}"      # true = не публиковать в лобби
ENABLE_CAVES="${ENABLE_CAVES:-1}"                # 1 = запускать Caves
MASTER_PORT="${MASTER_PORT:-10999}"
CAVES_PORT="${CAVES_PORT:-11000}"
SHARD_MASTER_PORT="${SHARD_MASTER_PORT:-10888}"  # внутренний порт межшард. связи
CLUSTER_KEY_ENV="${CLUSTER_KEY:-}"               # можно задать свой ключ шардов

mkdir -p "$KLEI_ROOT/$CONF_DIR" "$DST_DIR" && chown -R steam:steam /home/steam /opt

# ---------- Установка/обновление сервера ----------
if [ "${UPDATE_ON_START:-1}" = "1" ]; then
  gosu steam bash -lc "$STEAMCMDDIR/steamcmd.sh +force_install_dir $DST_DIR +login anonymous +app_update 343050 +quit"
fi

BIN="$DST_DIR/bin64/dontstarve_dedicated_server_nullrenderer_x64"
if [ ! -x "$BIN" ]; then
  echo "Не найден бинарник: $BIN" >&2
  exit 1
fi

CLUSTER_DIR="$KLEI_ROOT/$CONF_DIR/$CLUSTER_NAME"
MASTER_DIR="$CLUSTER_DIR/Master"
CAVES_DIR="$CLUSTER_DIR/Caves"

# ---------- Первичная генерация конфига (если нет) ----------
if [ ! -d "$CLUSTER_DIR" ]; then
  echo "Инициализация кластера в $CLUSTER_DIR"
  mkdir -p "$MASTER_DIR"
  [ "${ENABLE_CAVES}" = "1" ] && mkdir -p "$CAVES_DIR"

  # cluster_key: либо из ENV, либо случайный
  if [ -n "$CLUSTER_KEY_ENV" ]; then
    CLUSTER_KEY="$CLUSTER_KEY_ENV"
  else
    CLUSTER_KEY="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
  fi

  # cluster.ini
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

  # токен (обязателен для онлайн-кластера)
  if [ -n "$CLUSTER_TOKEN" ]; then
    echo -n "$CLUSTER_TOKEN" > "$CLUSTER_DIR/cluster_token.txt"
  fi

  # Master/server.ini
  cat > "$MASTER_DIR/server.ini" <<EOF
[NETWORK]
server_port = ${MASTER_PORT}

[SHARD]
is_master = true
name = Master
id = 1

[STEAM]
# можно задать при необходимости:
# master_server_port = 27017
# authentication_port = 8766
EOF

  # Master/leveldataoverride.lua (дефолтный пресет surface)
  cat > "$MASTER_DIR/leveldataoverride.lua" <<'EOF'
return {
  override_enabled = true,
  preset = "SURVIVAL_TOGETHER"
}
EOF

  if [ "${ENABLE_CAVES}" = "1" ]; then
    # Caves/server.ini
    cat > "$CAVES_DIR/server.ini" <<EOF
[NETWORK]
server_port = ${CAVES_PORT}

[SHARD]
is_master = false
name = Caves
id = 2
master_ip = 127.0.0.1
master_port = ${SHARD_MASTER_PORT}
EOF

    # Caves/leveldataoverride.lua (дефолтный пресет caves)
    cat > "$CAVES_DIR/leveldataoverride.lua" <<'EOF'
return {
  override_enabled = true,
  preset = "DST_CAVE"
}
EOF
  fi

  chown -R steam:steam "$CLUSTER_DIR"
else
  echo "Найден существующий кластер: $CLUSTER_DIR — оставляю как есть"
fi

# ---------- Запуск шард ----------
RUN_SHARED=( "$BIN" -console \
  -persistent_storage_root "$KLEI_ROOT" \
  -conf_dir "$CONF_DIR" \
  -cluster "$CLUSTER_NAME" \
  -monitor_parent_process $$ )

term() { kill -TERM 0 2>/dev/null || true; wait || true; }
trap term INT TERM

# Master
gosu steam bash -lc "cd $DST_DIR/bin64 && ${RUN_SHARED[*]} -shard Master -port ${MASTER_PORT} | sed 's/^/[Master] /'" &
PID1=$!

# Caves (если каталог есть)
if [ -d "$CAVES_DIR" ]; then
  gosu steam bash -lc "cd $DST_DIR/bin64 && ${RUN_SHARED[*]} -shard Caves -port ${CAVES_PORT} | sed 's/^/[Caves]  /'" &
fi

wait -n
term
