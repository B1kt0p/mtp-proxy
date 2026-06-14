#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Установка telemt MTProxy + SYN limiter через nftables
#
# Обязательные параметры:
#   --domain  FakeTLS-домен
#   --dir     абсолютный путь к каталогу проекта
#   --port    внешний TCP-порт VPS
#   --name    уникальное имя экземпляра/контейнера
#
# Пример:
#
# /opt/auto_teleproxy/install-telemt.sh \
#   --domain apple.com \
#   --dir /opt/telemt3 \
#   --port 10443 \
#   --name telemt3
# ============================================================

DOMAIN=""
PROJECT_DIR=""
EXTERNAL_PORT=""
INSTANCE_NAME=""

CONTAINER_PORT="443"

DEFAULT_RATE="1/second"
DEFAULT_BURST="1"
DEFAULT_METER_TIMEOUT="60s"

SUCCESS=0
CREATED_PROJECT=0
CREATED_CONTAINER=0
CREATED_SERVICE_FILE=0
CREATED_NFT=0

usage() {
    cat <<'EOF'
Использование:

  install-telemt.sh \
    --domain apple.com \
    --dir /opt/telemt3 \
    --port 10443 \
    --name telemt3

Обязательные параметры:

  --domain    FakeTLS-домен
  --dir       Абсолютный путь к каталогу проекта
  --port      Внешний TCP-порт VPS
  --name      Уникальное имя экземпляра и Docker-контейнера
EOF
}

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    printf '\nОШИБКА: %s\n' "$*" >&2
    exit 1
}

rollback() {
    local rc=$?

    trap - EXIT

    if [[ "$SUCCESS" -eq 1 ]]; then
        exit 0
    fi

    set +e

    printf '\nУстановка завершилась с ошибкой, код: %s\n' "$rc" >&2

    if [[ -n "${INSTANCE_NAME:-}" ]] &&
       command -v docker >/dev/null 2>&1 &&
       docker inspect "$INSTANCE_NAME" >/dev/null 2>&1; then

        printf '\nПоследние логи контейнера:\n' >&2
        docker logs "$INSTANCE_NAME" --tail=100 2>&1 || true
    fi

    if [[ "$CREATED_SERVICE_FILE" -eq 1 &&
          -n "${SERVICE_NAME:-}" ]]; then

        systemctl disable --now "$SERVICE_NAME" \
            >/dev/null 2>&1 || true

        rm -f "${SERVICE_FILE:-}"

        systemctl daemon-reload \
            >/dev/null 2>&1 || true

        systemctl reset-failed \
            >/dev/null 2>&1 || true
    fi

    if [[ "$CREATED_NFT" -eq 1 &&
          -n "${NFT_TABLE:-}" ]] &&
       command -v nft >/dev/null 2>&1; then

        nft delete table inet "$NFT_TABLE" \
            >/dev/null 2>&1 || true
    fi

    if [[ "$CREATED_CONTAINER" -eq 1 &&
          -n "${PROJECT_DIR:-}" &&
          -f "${PROJECT_DIR}/docker-compose.yml" ]] &&
       command -v docker >/dev/null 2>&1; then

        (
            cd "$PROJECT_DIR" || exit 0
            docker compose down --remove-orphans \
                >/dev/null 2>&1 || true
        )
    fi

    rm -f "${LIMIT_SCRIPT:-}" "${WATCH_SCRIPT:-}"

    if [[ "$CREATED_PROJECT" -eq 1 &&
          -n "${PROJECT_DIR:-}" ]]; then

        rm -rf "$PROJECT_DIR"
    fi

    exit "$rc"
}

trap rollback EXIT

# ============================================================
# Обработка параметров
# ============================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)
            [[ $# -ge 2 ]] ||
                die "После --domain отсутствует значение"

            DOMAIN="$2"
            shift 2
            ;;

        --dir)
            [[ $# -ge 2 ]] ||
                die "После --dir отсутствует значение"

            PROJECT_DIR="$2"
            shift 2
            ;;

        --port)
            [[ $# -ge 2 ]] ||
                die "После --port отсутствует значение"

            EXTERNAL_PORT="$2"
            shift 2
            ;;

        --name)
            [[ $# -ge 2 ]] ||
                die "После --name отсутствует значение"

            INSTANCE_NAME="$2"
            shift 2
            ;;

        -h|--help)
            usage
            SUCCESS=1
            trap - EXIT
            exit 0
            ;;

        *)
            die "Неизвестный параметр: $1"
            ;;
    esac
done

# ============================================================
# Проверка обязательных параметров
# ============================================================

[[ -n "$DOMAIN" ]] ||
    die "Не указан обязательный параметр --domain"

[[ -n "$PROJECT_DIR" ]] ||
    die "Не указан обязательный параметр --dir"

[[ -n "$EXTERNAL_PORT" ]] ||
    die "Не указан обязательный параметр --port"

[[ -n "$INSTANCE_NAME" ]] ||
    die "Не указан обязательный параметр --name"

[[ "$EUID" -eq 0 ]] ||
    die "Скрипт необходимо запускать от root"

[[ "$PROJECT_DIR" = /* ]] ||
    die "--dir должен быть абсолютным путём"

[[ "$EXTERNAL_PORT" =~ ^[0-9]+$ ]] ||
    die "--port должен быть целым числом"

(( EXTERNAL_PORT >= 1 && EXTERNAL_PORT <= 65535 )) ||
    die "--port должен находиться в диапазоне 1–65535"

[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] ||
    die "Некорректный FakeTLS-домен: $DOMAIN"

[[ "$INSTANCE_NAME" =~ ^[A-Za-z][A-Za-z0-9_.-]*$ ]] ||
    die "Имя должно начинаться с буквы и может содержать буквы, цифры, точки, дефисы и подчёркивания"

# ============================================================
# Имена файлов и ресурсов
# ============================================================

NFT_PREFIX="$(
    printf '%s' "$INSTANCE_NAME" |
    sed 's/[^A-Za-z0-9_]/_/g'
)"

NFT_TABLE="${NFT_PREFIX}_limit"
NFT_METER="${NFT_PREFIX}_in_syn_per_client"

CONFIG_DIR="${PROJECT_DIR}/config"
DATA_DIR="${PROJECT_DIR}/data"

COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
CONNECTION_FILE="${PROJECT_DIR}/connection.txt"

LIMIT_SCRIPT="/usr/local/sbin/${INSTANCE_NAME}-in-syn-limit.sh"
WATCH_SCRIPT="/usr/local/sbin/${INSTANCE_NAME}-in-syn-watch.sh"

SERVICE_NAME="${INSTANCE_NAME}-in-syn-watch.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

# ============================================================
# Установка пакетов
# ============================================================

log "Установка необходимых пакетов"

command -v apt-get >/dev/null 2>&1 ||
    die "Скрипт рассчитан на Debian/Ubuntu с apt"

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    openssl \
    nftables \
    tcpdump \
    iproute2 \
    coreutils

# ============================================================
# Проверка Docker
# ============================================================

log "Проверка Docker"

if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
fi

systemctl enable --now docker

if ! docker compose version >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y docker-compose-plugin
fi

docker compose version >/dev/null 2>&1 ||
    die "Docker Compose Plugin не установлен"

# ============================================================
# Проверка конфликтов
# ============================================================

log "Проверка конфликтов"

[[ ! -e "$PROJECT_DIR" ]] ||
    die "Каталог уже существует: $PROJECT_DIR"

if docker inspect "$INSTANCE_NAME" >/dev/null 2>&1; then
    die "Docker-контейнер '$INSTANCE_NAME' уже существует"
fi

if systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
    die "Systemd-сервис '$SERVICE_NAME' уже существует"
fi

if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
    die "Таблица nftables '$NFT_TABLE' уже существует"
fi

[[ ! -e "$LIMIT_SCRIPT" ]] ||
    die "Скрипт уже существует: $LIMIT_SCRIPT"

[[ ! -e "$WATCH_SCRIPT" ]] ||
    die "Watcher уже существует: $WATCH_SCRIPT"

if ss -H -ltn 2>/dev/null |
   awk '{print $4}' |
   grep -Eq "(^|:)${EXTERNAL_PORT}$"; then

    die "TCP-порт ${EXTERNAL_PORT} уже занят"
fi

# ============================================================
# Создание каталогов
# ============================================================

log "Создание структуры проекта"

mkdir -p "$CONFIG_DIR"
mkdir -p "$DATA_DIR"

CREATED_PROJECT=1

chmod 755 "$PROJECT_DIR"
chmod 755 "$CONFIG_DIR"

# telemt пишет runtime-файлы в рабочий каталог.
chmod 777 "$DATA_DIR"

# ============================================================
# Определение публичного IPv4
# ============================================================

log "Определение публичного IPv4"

PUBLIC_IP="$(
    curl -4fsS \
        --max-time 10 \
        https://api.ipify.org ||
    true
)"

[[ -n "$PUBLIC_IP" ]] ||
    die "Не удалось определить публичный IPv4 сервера"

echo "Публичный IPv4: $PUBLIC_IP"

# ============================================================
# Генерация секрета
# ============================================================

USER_SECRET="$(openssl rand -hex 16)"

[[ "$USER_SECRET" =~ ^[0-9a-f]{32}$ ]] ||
    die "Не удалось сгенерировать secret"

# ============================================================
# Создание конфигурации telemt
# ============================================================

log "Создание конфигурации telemt"

cat > "$CONFIG_FILE" <<EOF
[general]
use_middle_proxy = true
log_level = "normal"
tg_connect = 30

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "${PUBLIC_IP}"
public_port = ${EXTERNAL_PORT}

[server]
port = ${CONTAINER_PORT}

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "${DOMAIN}"
mask = true
tls_emulation = true
tls_front_dir = "/var/lib/telemt/tlsfront"

[access.users]
main = "${USER_SECRET}"

[timeouts]
client_handshake = 120
client_keepalive = 90
EOF

chmod 644 "$CONFIG_FILE"

# ============================================================
# Создание Docker Compose
# ============================================================

log "Создание Docker Compose"

cat > "$COMPOSE_FILE" <<EOF
services:
  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: ${INSTANCE_NAME}
    restart: unless-stopped

    ports:
      - "${EXTERNAL_PORT}:${CONTAINER_PORT}/tcp"

    volumes:
      - ./config/config.toml:/etc/telemt/config.toml:ro
      - ./data:/var/lib/telemt:rw

    working_dir: /var/lib/telemt

    command:
      - "/etc/telemt/config.toml"

    cap_drop:
      - ALL

    cap_add:
      - NET_BIND_SERVICE

    security_opt:
      - no-new-privileges:true

    ulimits:
      nofile:
        soft: 65536
        hard: 65536
EOF

chmod 644 "$COMPOSE_FILE"

# ============================================================
# Создание скрипта SYN limiter
# ============================================================

log "Создание скрипта SYN limiter"

cat > "$LIMIT_SCRIPT" <<EOF
#!/bin/sh
set -eu

CONTAINER="${INSTANCE_NAME}"
TABLE="${NFT_TABLE}"
CHAIN="forward"
PORT="${CONTAINER_PORT}"

RATE="\${RATE:-${DEFAULT_RATE}}"
BURST="\${BURST:-${DEFAULT_BURST}}"
METER_TIMEOUT="\${METER_TIMEOUT:-${DEFAULT_METER_TIMEOUT}}"

IP=""

for i in \$(seq 1 60); do
    RUNNING="\$(
        docker inspect \
            -f '{{.State.Running}}' \
            "\$CONTAINER" \
            2>/dev/null ||
        true
    )"

    if [ "\$RUNNING" = "true" ]; then
        IP="\$(
            docker inspect \
                -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\\n"}}{{end}}' \
                "\$CONTAINER" \
                2>/dev/null |
            awk 'NF {print; exit}'
        )"

        [ -n "\$IP" ] && break
    fi

    sleep 1
done

if [ -z "\$IP" ]; then
    echo "Не удалось определить IP контейнера: \$CONTAINER" >&2
    exit 1
fi

nft delete table inet "\$TABLE" 2>/dev/null || true

nft add table inet "\$TABLE"

nft "add chain inet \$TABLE \$CHAIN { type filter hook forward priority 0; policy accept; }"

nft "add rule inet \$TABLE \$CHAIN ip daddr \$IP tcp dport \$PORT tcp flags & (syn | ack) == syn meter ${NFT_METER} { ip saddr timeout \$METER_TIMEOUT limit rate over \$RATE burst \$BURST packets } counter drop comment \\"${NFT_METER}_\${RATE}_burst_\${BURST}\\""

echo "SYN limiter применён:"
echo "container=\$CONTAINER"
echo "ip=\$IP"
echo "port=\$PORT"
echo "rate=\$RATE"
echo "burst=\$BURST"
echo "meter_timeout=\$METER_TIMEOUT"

nft list chain inet "\$TABLE" "\$CHAIN"
EOF

chmod 700 "$LIMIT_SCRIPT"

# ============================================================
# Создание watcher
# ============================================================

log "Создание watcher контейнера"

cat > "$WATCH_SCRIPT" <<EOF
#!/bin/sh
set -u

CONTAINER="${INSTANCE_NAME}"
TABLE="${NFT_TABLE}"
CHAIN="forward"
INTERVAL="\${INTERVAL:-5}"
LAST_IP=""

rule_matches_ip() {
    CHECK_IP="\$1"

    nft list chain inet "\$TABLE" "\$CHAIN" 2>/dev/null |
        grep -Fq "ip daddr \$CHECK_IP"
}

CURRENT_IP="\$(
    docker inspect \
        -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\\n"}}{{end}}' \
        "\$CONTAINER" \
        2>/dev/null |
    awk 'NF {print; exit}'
)"

# Если установщик уже создал правильное правило,
# watcher не будет сразу удалять и пересоздавать таблицу.
if [ -n "\$CURRENT_IP" ] &&
   rule_matches_ip "\$CURRENT_IP"; then

    LAST_IP="\$CURRENT_IP"
    echo "Existing nftables rule found for IP: \$LAST_IP"
fi

echo "Watching Docker container: \$CONTAINER"

while true; do
    RUNNING="\$(
        docker inspect \
            -f '{{.State.Running}}' \
            "\$CONTAINER" \
            2>/dev/null ||
        true
    )"

    if [ "\$RUNNING" = "true" ]; then
        IP="\$(
            docker inspect \
                -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\\n"}}{{end}}' \
                "\$CONTAINER" \
                2>/dev/null |
            awk 'NF {print; exit}'
        )"

        NEED_REFRESH=0

        if [ -n "\$IP" ]; then
            if [ "\$IP" != "\$LAST_IP" ]; then
                NEED_REFRESH=1
            elif ! rule_matches_ip "\$IP"; then
                NEED_REFRESH=1
            fi
        fi

        if [ "\$NEED_REFRESH" -eq 1 ]; then
            echo "Refreshing nftables rule: \${LAST_IP:-none} -> \$IP"

            if "${LIMIT_SCRIPT}"; then
                LAST_IP="\$IP"
            else
                echo "Не удалось применить nftables для \$CONTAINER" >&2
            fi
        fi
    else
        if [ -n "\$LAST_IP" ]; then
            echo "Container \$CONTAINER is not running"
            LAST_IP=""
        fi
    fi

    sleep "\$INTERVAL"
done
EOF

chmod 700 "$WATCH_SCRIPT"

# ============================================================
# Создание systemd-сервиса
# ============================================================

log "Создание systemd-сервиса"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Watch ${INSTANCE_NAME} and refresh nftables SYN limiter
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WATCH_SCRIPT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$SERVICE_FILE"

CREATED_SERVICE_FILE=1

# ============================================================
# Запуск контейнера
# ============================================================

log "Запуск telemt"

cd "$PROJECT_DIR"

docker compose pull

CREATED_CONTAINER=1
docker compose up -d

# ============================================================
# Ожидание запуска контейнера
# ============================================================

log "Ожидание запуска контейнера"

CONTAINER_READY=0

for i in $(seq 1 60); do
    STATUS="$(
        docker inspect \
            -f '{{.State.Status}}' \
            "$INSTANCE_NAME" \
            2>/dev/null ||
        true
    )"

    HEALTH="$(
        docker inspect \
            -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "$INSTANCE_NAME" \
            2>/dev/null ||
        true
    )"

    RESTARTING="$(
        docker inspect \
            -f '{{.State.Restarting}}' \
            "$INSTANCE_NAME" \
            2>/dev/null ||
        true
    )"

    printf 'Попытка %s/60: status=%s health=%s restarting=%s\n' \
        "$i" \
        "$STATUS" \
        "$HEALTH" \
        "$RESTARTING"

    if [[ "$STATUS" == "running" ]] &&
       [[ "$HEALTH" == "healthy" ||
          "$HEALTH" == "none" ]]; then

        CONTAINER_READY=1
        break
    fi

    if [[ "$STATUS" == "exited" ||
          "$STATUS" == "dead" ||
          "$RESTARTING" == "true" ]]; then

        docker logs "$INSTANCE_NAME" --tail=100 || true
        die "Ошибка запуска контейнера $INSTANCE_NAME"
    fi

    sleep 2
done

[[ "$CONTAINER_READY" -eq 1 ]] ||
    die "Контейнер не перешёл в рабочее состояние за 120 секунд"

# ============================================================
# Применение SYN limiter
# ============================================================

log "Применение SYN limiter"

CREATED_NFT=1

"$LIMIT_SCRIPT"

# ============================================================
# Запуск watcher
# ============================================================

log "Запуск watcher"

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

# ============================================================
# Открытие порта в UFW
# ============================================================

if command -v ufw >/dev/null 2>&1 &&
   ufw status 2>/dev/null |
   grep -q '^Status: active'; then

    log "Открытие ${EXTERNAL_PORT}/tcp в UFW"

    ufw allow "${EXTERNAL_PORT}/tcp"
fi

# ============================================================
# Создание Telegram-ссылок
# ============================================================

log "Создание Telegram-ссылок"

DOMAIN_HEX="$(
    printf '%s' "$DOMAIN" |
    od -An -tx1 |
    tr -d ' \n'
)"

HTTPS_LINK="https://t.me/proxy?server=${PUBLIC_IP}&port=${EXTERNAL_PORT}&secret=ee${USER_SECRET}${DOMAIN_HEX}"

TG_LINK="tg://proxy?server=${PUBLIC_IP}&port=${EXTERNAL_PORT}&secret=ee${USER_SECRET}${DOMAIN_HEX}"

cat > "$CONNECTION_FILE" <<EOF
Instance: ${INSTANCE_NAME}
Project directory: ${PROJECT_DIR}
Public IP: ${PUBLIC_IP}
External port: ${EXTERNAL_PORT}
Container port: ${CONTAINER_PORT}
FakeTLS domain: ${DOMAIN}
User secret: ${USER_SECRET}

HTTPS link:
${HTTPS_LINK}

Telegram link:
${TG_LINK}
EOF

chmod 600 "$CONNECTION_FILE"

# ============================================================
# Ожидание готовности nftables
# ============================================================

NFT_READY=0
NFT_OUTPUT=""

for i in $(seq 1 10); do
    if NFT_OUTPUT="$(
        nft list chain inet "$NFT_TABLE" forward 2>/dev/null
    )"; then

        NFT_READY=1
        break
    fi

    sleep 1
done

[[ "$NFT_READY" -eq 1 ]] ||
    die "Правило nftables не найдено после запуска watcher"

# ============================================================
# Успешное завершение
# ============================================================

SUCCESS=1
trap - EXIT

# ============================================================
# Цветной вывод
# ============================================================

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    GREEN=$'\033[1;32m'
    CYAN=$'\033[1;36m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[1;34m'
    MAGENTA=$'\033[1;35m'
    WHITE=$'\033[1;37m'
    RESET=$'\033[0m'
else
    GREEN=""
    CYAN=""
    YELLOW=""
    BLUE=""
    MAGENTA=""
    WHITE=""
    RESET=""
fi

printf '\n%s============================================%s\n' \
    "$GREEN" "$RESET"

printf '%s  Установка успешно завершена%s\n' \
    "$GREEN" "$RESET"

printf '%s============================================%s\n' \
    "$GREEN" "$RESET"

printf '\n%sКонтейнер:%s\n' \
    "$CYAN" "$RESET"

docker ps --filter "name=^/${INSTANCE_NAME}$"

printf '\n%sNFTables limiter:%s\n' \
    "$CYAN" "$RESET"

printf '%s\n' "$NFT_OUTPUT"

printf '\n%sSystemd-сервис:%s\n' \
    "$CYAN" "$RESET"

systemctl status "$SERVICE_NAME" --no-pager || true

printf '\n%sHTTPS-ссылка:%s\n' \
    "$MAGENTA" "$RESET"

printf '%s%s%s\n' \
    "$GREEN" "$HTTPS_LINK" "$RESET"

printf '\n%sTelegram-ссылка:%s\n' \
    "$MAGENTA" "$RESET"

printf '%s%s%s\n' \
    "$GREEN" "$TG_LINK" "$RESET"

printf '\n%sДанные подключения сохранены в:%s\n' \
    "$YELLOW" "$RESET"

printf '%s%s%s\n' \
    "$WHITE" "$CONNECTION_FILE" "$RESET"

printf '\n%sПолезные команды:%s\n\n' \
    "$YELLOW" "$RESET"

printf '%sdocker logs %s --tail=100%s\n' \
    "$BLUE" "$INSTANCE_NAME" "$RESET"

printf '%sdocker logs -f %s%s\n' \
    "$BLUE" "$INSTANCE_NAME" "$RESET"

printf '%snft list chain inet %s forward%s\n' \
    "$BLUE" "$NFT_TABLE" "$RESET"

printf '%ssystemctl status %s --no-pager%s\n' \
    "$BLUE" "$SERVICE_NAME" "$RESET"

printf '%sjournalctl -u %s -n 50 --no-pager%s\n' \
    "$BLUE" "$SERVICE_NAME" "$RESET"

printf "%swatch -n 1 'nft list chain inet %s forward'%s\n" \
    "$BLUE" "$NFT_TABLE" "$RESET"

printf '\n'

