#!/usr/bin/env bash
set -euo pipefail

# ===== Локаль (убирает WARNING про setlocale) =====
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# ===== ENV с дефолтами (можно задавать через .env) =====
STEAMCMDDIR="${STEAMCMDDIR:-/opt/steamcmd}"
DST_DIR="${DST_DIR:-/opt/dst}"
KLEI_ROOT="${KLEI_ROOT:-/home/steam/.klei}"
CONF_DIR="${CONF_DIR:-DoNotStarveTogether}"
CLUSTER_NAME="${CLUSTER_NAME:-MyDediServer}"

# Кластер/геймплей
CLUSTER_TOKEN="${CLUSTER_TOKEN:-}"            # если оставить пустым и OFFLINE_CLUSTER=false — онлайн листинга не будет
SERVER_NAME="${SERVER_NAME:-DST Docker Server}"
SERVER_DESC="${SERVER_DESC:-Dedicated server in Docker}"
SERVER_PASSWORD="${SERVER_PASSWORD:-}"
GAME_MODE="${GAME_MODE:-survival}"           # survival/endless/wilderness
MAX_PLAYERS="${MAX_PLAYERS:-6}"
PVP="${PVP:-false}"
PAUSE_WHEN_EMPTY="${PAUSE_WHEN_EMPTY:-true}"
OFFLINE_CLUSTER="${OFFLINE_CLUSTER:-false}"  # true = не публиковать в лобби (работает без токена)
CLUSTER_KEY_ENV="${CLUSTER_KEY:-}"           # можно зафиксировать свой ключ шардов

# Шарды/порты
ENABLE_CAVES="${ENABLE_CAVES:-1}"
MASTER_PORT="${MASTER_PORT:-10999}"
CAVES_PORT="${CAVES_PORT:-11000}"
SHARD_MASTER_PORT="${SHARD_MASTER_PORT:-10888}"  # внутренняя связь шардов (Master слушает, Caves подключается)

# Steam-порты (разведены для исключения коллизий)
MASTER_STEAM_PORT="${MASTER_STEAM_PORT:-27016}"
MASTER_AUTH_PORT="${MASTER_AUTH_PORT:-8766}"
CAVES_STEAM_PORT="${CAVES_STEAM_PORT:-27018}"
CAVES_AUTH_PORT="${CAVES_AUTH_PORT:-8768}"

UPDATE_ON_START="${UPDATE_ON_START:-1}"

# ===== Подготовка =====
mkdir -p "$KLEI_ROOT/$CONF_DIR" "$DST_DIR"
chown -R steam:steam /home/steam /opt || true

# ===== Установка/обновление сервера =====
if [ "$UPDATE_ON_START" = "1" ]; then
  gosu steam "$STEAMCMDDIR/steamcmd.sh" \
    +force_install_dir "$DST_DIR" \
    +login anonymous \
    +app_update 343050 \
    +quit
fi

BIN="$DST_DIR/bin64/dontstarve_dedicated_server_nullrenderer_x64"
if [ ! -x "$BIN" ]; then
  echo "Не найден бинарник: $BIN" >&2
  exit 1
fi

CLUSTER_DIR="$KLEI_ROOT/$CONF_DIR/$CLUSTER_NAME"
MASTER_DIR="$CLUSTER_DIR/Master"
CAVES_DIR="$CLUSTER_DIR/Caves"

# ===== Первичная генерация (только если кластера ещё нет) =====
if [ ! -d "$CLUSTER_DIR" ]; then
  echo "Инициализация кластера в $CLUSTER_DIR"
  mkdir -p "$MASTER_DIR"
  [ "$ENABLE_CAVES" = "1" ] && mkdir -p "$CAVES_DIR"

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

  # Токен (если задан)
  if [ -n "$CLUSTER_TOKEN" ]; then
    printf "%s" "$CLUSTER_TOKEN" > "$CLUSTER_DIR/cluster_token.txt"
  fi

  # Master/server.ini
  cat > "$MASTER_DIR/server.ini" <<EOF
[NETWORK]
server_port = ${MASTER_PORT}

[SHARD]
is_master = true
name = Master
id = 1
master_port = ${SHARD_MASTER_PORT}

[STEAM]
master_server_port = ${MASTER_STEAM_PORT}
authentication_port = ${MASTER_AUTH_PORT}
EOF

  # Master/leveldataoverride.lua
  cat > "$MASTER_DIR/leveldataoverride.lua" <<'EOF'
return { override_enabled = true, preset = "SURVIVAL_TOGETHER" }
EOF

  # Caves (если включены)
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
  # если кластер уже есть — не перезаписываем, только минимальная подготовка
  echo "Найден существующий кластер: $CLUSTER_DIR — оставляю как есть"
  # если токен задан env и файла ещё нет — создадим
  if [ -n "$CLUSTER_TOKEN" ] && [ ! -s "$CLUSTER_DIR/cluster_token.txt" ]; then
    printf "%s" "$CLUSTER_TOKEN" > "$CLUSTER_DIR/cluster_token.txt"
    chown steam:steam "$CLUSTER_DIR/cluster_token.txt"
  fi
fi

# Пустые списки (чтобы убрать варнинги — не критично)
: > "$CLUSTER_DIR/blocklist.txt"  || true
: > "$CLUSTER_DIR/adminlist.txt"   || true
: > "$CLUSTER_DIR/whitelist.txt"   || true
chown steam:steam "$CLUSTER_DIR"/{blocklist.txt,adminlist.txt,whitelist.txt} || true

# ===== Рабочая директория bin64 (это критично для ../data и UGC путей) =====
cd "$DST_DIR/bin64"

# Каталоги UGC модов для обеих шард (исключает V_RemoveDotSlashes)
mkdir -p "$DST_DIR/ugc_mods/$CLUSTER_NAME/Master"
[ -d "$CAVES_DIR" ] && mkdir -p "$DST_DIR/ugc_mods/$CLUSTER_NAME/Caves"

# ===== Запуск =====
term() { kill -TERM 0 2>/dev/null || true; }
trap term INT TERM

RUN_SHARED_BASE=( "./dontstarve_dedicated_server_nullrenderer_x64"
  -persistent_storage_root "$KLEI_ROOT"
  -conf_dir "$CONF_DIR"
  -cluster "$CLUSTER_NAME"
)

# Master
RUN_MASTER=( "${RUN_SHARED_BASE[@]}"
  -shard Master
  -port "$MASTER_PORT"
  -steam_master_server_port "$MASTER_STEAM_PORT"
  -steam_authentication_port "$MASTER_AUTH_PORT"
)
gosu steam "${RUN_MASTER[@]}" &
PID_MASTER=$!

# Caves (если каталог есть)
if [ -d "$CAVES_DIR" ]; then
  RUN_CAVES=( "${RUN_SHARED_BASE[@]}"
    -shard Caves
    -port "$CAVES_PORT"
    -steam_master_server_port "$CAVES_STEAM_PORT"
    -steam_authentication_port "$CAVES_AUTH_PORT"
  )
  gosu steam "${RUN_CAVES[@]}" &
  PID_CAVES=$!
fi

# Ожидание процессов; корректное завершение второго при падении первого
if [ -n "${PID_CAVES:-}" ]; then
  wait -n "$PID_MASTER" "$PID_CAVES" || true
else
  wait "$PID_MASTER" || true
fi

term
wait || true
