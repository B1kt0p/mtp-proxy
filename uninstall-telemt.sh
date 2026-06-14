#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Полное удаление экземпляра telemt
#
# Обязательные параметры:
#   --name   имя Docker-контейнера/экземпляра
#   --dir    абсолютный путь к каталогу проекта
#
# Пример:
#   ./uninstall-telemt.sh \
#     --name telemt4 \
#     --dir /opt/telemt4
#
# Для удаления без подтверждения:
#   ./uninstall-telemt.sh \
#     --name telemt4 \
#     --dir /opt/telemt4 \
#     --yes
# ============================================================

INSTANCE_NAME=""
PROJECT_DIR=""
ASSUME_YES=0

usage() {
    cat <<'EOF'
Использование:

  uninstall-telemt.sh \
    --name NAME \
    --dir DIRECTORY

Обязательные параметры:

  --name    Имя экземпляра и Docker-контейнера
  --dir     Абсолютный путь к каталогу проекта

Дополнительные параметры:

  --yes     Не запрашивать подтверждение
  -h        Показать справку

Пример:

  /opt/auto_teleproxy/uninstall-telemt.sh \
    --name telemt4 \
    --dir /opt/telemt4
EOF
}

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    printf '\nОШИБКА: %s\n' "$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            [[ $# -ge 2 ]] ||
                die "После --name отсутствует значение"

            INSTANCE_NAME="$2"
            shift 2
            ;;

        --dir)
            [[ $# -ge 2 ]] ||
                die "После --dir отсутствует значение"

            PROJECT_DIR="$2"
            shift 2
            ;;

        --yes|-y)
            ASSUME_YES=1
            shift
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        *)
            die "Неизвестный параметр: $1"
            ;;
    esac
done

# ============================================================
# Проверка параметров
# ============================================================

[[ -n "$INSTANCE_NAME" ]] ||
    die "Не указан обязательный параметр --name"

[[ -n "$PROJECT_DIR" ]] ||
    die "Не указан обязательный параметр --dir"

[[ "$EUID" -eq 0 ]] ||
    die "Скрипт необходимо запускать от root"

[[ "$PROJECT_DIR" = /* ]] ||
    die "--dir должен быть абсолютным путём"

[[ "$INSTANCE_NAME" =~ ^[A-Za-z][A-Za-z0-9_.-]*$ ]] ||
    die "Некорректное имя экземпляра: $INSTANCE_NAME"

PROJECT_DIR="$(readlink -m "$PROJECT_DIR")"

# Защита от случайного удаления системных каталогов.
case "$PROJECT_DIR" in
    /|/opt|/etc|/usr|/var|/root|/home)
        die "Отказ от удаления опасного каталога: $PROJECT_DIR"
        ;;
esac

NFT_PREFIX="$(
    printf '%s' "$INSTANCE_NAME" |
    sed 's/[^A-Za-z0-9_]/_/g'
)"

NFT_TABLE="${NFT_PREFIX}_limit"

SERVICE_NAME="${INSTANCE_NAME}-in-syn-watch.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

LIMIT_SCRIPT="/usr/local/sbin/${INSTANCE_NAME}-in-syn-limit.sh"
WATCH_SCRIPT="/usr/local/sbin/${INSTANCE_NAME}-in-syn-watch.sh"

COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"

# ============================================================
# Подтверждение
# ============================================================

if [[ "$ASSUME_YES" -ne 1 ]]; then
    echo
    echo "Будет полностью удалён экземпляр:"
    echo
    echo "  Имя:       $INSTANCE_NAME"
    echo "  Каталог:   $PROJECT_DIR"
    echo "  Сервис:    $SERVICE_NAME"
    echo "  NFT table: $NFT_TABLE"
    echo

    read -r -p "Продолжить удаление? [y/N]: " ANSWER

    case "$ANSWER" in
        y|Y|yes|YES|д|Д|да|ДА)
            ;;
        *)
            echo "Удаление отменено."
            exit 0
            ;;
    esac
fi

# ============================================================
# Сохраняем данные Docker до удаления контейнера
# ============================================================

COMPOSE_PROJECT=""
DOCKER_NETWORKS=()

if command -v docker >/dev/null 2>&1 &&
   docker inspect "$INSTANCE_NAME" >/dev/null 2>&1; then

    COMPOSE_PROJECT="$(
        docker inspect \
            -f '{{index .Config.Labels "com.docker.compose.project"}}' \
            "$INSTANCE_NAME" \
            2>/dev/null ||
        true
    )"

    mapfile -t DOCKER_NETWORKS < <(
        docker inspect \
            -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{"\n"}}{{end}}' \
            "$INSTANCE_NAME" \
            2>/dev/null |
        awk 'NF'
    )
fi

# ============================================================
# Остановка watcher
# ============================================================

log "Остановка systemd-сервиса"

systemctl disable --now "$SERVICE_NAME" \
    2>/dev/null || true

rm -f "$SERVICE_FILE"

# ============================================================
# Удаление nftables
# ============================================================

log "Удаление таблицы nftables"

if command -v nft >/dev/null 2>&1; then
    nft delete table inet "$NFT_TABLE" \
        2>/dev/null || true
fi

# ============================================================
# Остановка Docker Compose
# ============================================================

log "Остановка Docker Compose"

if [[ -f "$COMPOSE_FILE" ]] &&
   command -v docker >/dev/null 2>&1; then

    (
        cd "$PROJECT_DIR"

        docker compose down --remove-orphans \
            2>/dev/null || true
    )
fi

# На случай, если compose down не удалил контейнер.
if command -v docker >/dev/null 2>&1; then
    docker rm -f "$INSTANCE_NAME" \
        2>/dev/null || true
fi

# ============================================================
# Удаление оставшихся Docker-сетей проекта
# ============================================================

log "Удаление оставшихся Docker-сетей"

if command -v docker >/dev/null 2>&1; then
    for NETWORK in "${DOCKER_NETWORKS[@]:-}"; do
        [[ -n "$NETWORK" ]] || continue

        NETWORK_PROJECT="$(
            docker network inspect \
                -f '{{index .Labels "com.docker.compose.project"}}' \
                "$NETWORK" \
                2>/dev/null ||
            true
        )"

        # Удаляем только сеть этого Compose-проекта.
        if [[ -n "$COMPOSE_PROJECT" &&
              "$NETWORK_PROJECT" == "$COMPOSE_PROJECT" ]]; then

            docker network rm "$NETWORK" \
                2>/dev/null || true
        fi
    done

    # Запасной вариант для стандартного имени сети.
    PROJECT_BASENAME="$(basename "$PROJECT_DIR")"

    docker network rm "${PROJECT_BASENAME}_default" \
        2>/dev/null || true
fi

# ============================================================
# Удаление служебных скриптов
# ============================================================

log "Удаление limiter и watcher"

rm -f "$LIMIT_SCRIPT"
rm -f "$WATCH_SCRIPT"

# ============================================================
# Обновление systemd
# ============================================================

log "Обновление systemd"

systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

# ============================================================
# Удаление каталога проекта
# ============================================================

log "Удаление каталога проекта"

rm -rf -- "$PROJECT_DIR"

# ============================================================
# Проверка удаления
# ============================================================

ERRORS=0

if command -v docker >/dev/null 2>&1 &&
   docker inspect "$INSTANCE_NAME" >/dev/null 2>&1; then

    echo "Контейнер всё ещё существует: $INSTANCE_NAME" >&2
    ERRORS=$((ERRORS + 1))
fi

if systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
    echo "Systemd-сервис всё ещё существует: $SERVICE_NAME" >&2
    ERRORS=$((ERRORS + 1))
fi

if command -v nft >/dev/null 2>&1 &&
   nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then

    echo "Таблица nftables всё ещё существует: $NFT_TABLE" >&2
    ERRORS=$((ERRORS + 1))
fi

if [[ -e "$PROJECT_DIR" ]]; then
    echo "Каталог проекта всё ещё существует: $PROJECT_DIR" >&2
    ERRORS=$((ERRORS + 1))
fi

if [[ "$ERRORS" -ne 0 ]]; then
    die "Удаление завершено не полностью"
fi

# ============================================================
# Итог
# ============================================================

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    GREEN=$'\033[1;32m'
    CYAN=$'\033[1;36m'
    RESET=$'\033[0m'
else
    GREEN=""
    CYAN=""
    RESET=""
fi

printf '\n%s============================================%s\n' \
    "$GREEN" "$RESET"

printf '%s  Экземпляр успешно удалён%s\n' \
    "$GREEN" "$RESET"

printf '%s============================================%s\n' \
    "$GREEN" "$RESET"

printf '\n%sИмя:%s %s\n' \
    "$CYAN" "$RESET" "$INSTANCE_NAME"

printf '%sКаталог:%s %s\n' \
    "$CYAN" "$RESET" "$PROJECT_DIR"

printf '%sSystemd:%s %s\n' \
    "$CYAN" "$RESET" "$SERVICE_NAME"

printf '%sNFTables:%s %s\n\n' \
    "$CYAN" "$RESET" "$NFT_TABLE"

