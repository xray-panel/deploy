#!/usr/bin/env bash
# Переезд с Remnawave на XLADA с сохранением базы.
#
# Запускать НА СЕРВЕРЕ СТАРОЙ УСТАНОВКИ, от root, из каталога с
# docker-compose.yml и .env (обычно /opt/remnawave):
#
#   cd /opt/remnawave
#   bash migrate-to-xlada.sh
#
# Что делает по шагам:
#   1. складывает резервные копии в /opt/remnawave/backups/<дата-время>/
#      (дамп базы, .env, compose-файл, список томов и образов);
#   2. проверяет, что дамп не пустой, и останавливается, если он пуст;
#   3. останавливает старый стек — БЕЗ флага -v, чтобы не удалить тома;
#   4. поднимает XLADA на той же базе;
#   5. показывает журнал применения миграций.
#
# Ничего не удаляет. Том с базой не трогает.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

MIGRATE_COMPOSE="docker-compose.migrate-from-remnawave.yml"
STAMP="$(date +%F_%H-%M-%S)"
BACKUP_DIR="$ROOT/backups/$STAMP"

say() { printf '\n=== %s ===\n' "$1"; }

# ── проверки до начала ──────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
    echo "ОШИБКА: нет файла .env в $ROOT" >&2
    exit 1
fi

if [[ ! -f "$MIGRATE_COMPOSE" ]]; then
    echo "ОШИБКА: нет файла $MIGRATE_COMPOSE в $ROOT" >&2
    echo "Скопируйте его из репозитория XLADA в deploy/." >&2
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx remnawave-db; then
    echo "ОШИБКА: контейнер remnawave-db не запущен." >&2
    echo "Сначала поднимите старый стек, чтобы было что сохранять." >&2
    exit 1
fi

# Имена пользователя и базы берём из работающего контейнера: в оболочке эти
# переменные не заданы, они лежат в .env, и подстановка "$POSTGRES_USER"
# дала бы пустое значение.
DB_USER="$(docker exec remnawave-db printenv POSTGRES_USER)"
DB_NAME="$(docker exec remnawave-db printenv POSTGRES_DB)"

if [[ -z "$DB_USER" || -z "$DB_NAME" ]]; then
    echo "ОШИБКА: не удалось определить POSTGRES_USER/POSTGRES_DB из контейнера." >&2
    exit 1
fi

say "Параметры"
echo "каталог установки: $ROOT"
echo "база:              $DB_NAME"
echo "пользователь:      $DB_USER"
echo "резервные копии:   $BACKUP_DIR"

# ── шаг 1: резервные копии ──────────────────────────────────────────────────
say "1/5 Резервные копии"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

echo "дамп базы..."
docker exec remnawave-db pg_dump -U "$DB_USER" -d "$DB_NAME" > "$BACKUP_DIR/database.sql"

# Дамп без завершающей строки означает, что pg_dump оборвался.
if [[ ! -s "$BACKUP_DIR/database.sql" ]] || ! grep -q 'PostgreSQL database dump complete' "$BACKUP_DIR/database.sql"; then
    echo "ОШИБКА: дамп пустой или неполный. Останавливаюсь, ничего не меняю." >&2
    echo "Файл: $BACKUP_DIR/database.sql" >&2
    exit 1
fi

SIZE="$(du -h "$BACKUP_DIR/database.sql" | cut -f1)"
USERS="$(docker exec remnawave-db psql -U "$DB_USER" -d "$DB_NAME" -tAc 'SELECT count(*) FROM users;' 2>/dev/null || echo '?')"
echo "дамп готов: $SIZE, пользователей в базе: $USERS"

cp -a .env "$BACKUP_DIR/env.backup"
cp -a docker-compose.yml "$BACKUP_DIR/docker-compose.yml.backup" 2>/dev/null || true
docker volume ls > "$BACKUP_DIR/volumes.txt"
docker images > "$BACKUP_DIR/images.txt"
echo "рядом сохранены: .env, docker-compose.yml, список томов и образов"

# ── шаг 2: подтверждение ────────────────────────────────────────────────────
say "2/5 Подтверждение"
echo "Сейчас старый стек будет остановлен, а на его базе поднимется XLADA."
echo "Том с данными не затрагивается. Откат: вернуть прежний compose и образ."
read -r -p "Продолжить? Введите yes: " ANSWER
if [[ "$ANSWER" != "yes" ]]; then
    echo "Отменено. Резервные копии остались в $BACKUP_DIR"
    exit 0
fi

# ── шаг 3: остановка ────────────────────────────────────────────────────────
say "3/5 Остановка старого стека"
# ВНИМАНИЕ: без -v. Флаг -v удаляет тома вместе с базой.
docker compose down

# ── шаг 4: запуск XLADA ─────────────────────────────────────────────────────
say "4/5 Запуск XLADA на той же базе"
docker compose -f "$MIGRATE_COMPOSE" up -d

# ── шаг 5: миграции ─────────────────────────────────────────────────────────
say "5/5 Применение миграций (30 секунд журнала)"
sleep 20
docker logs --tail 60 remnawave 2>&1 | grep -iE 'migrat|seed|started|error' | tail -20 || true

say "Готово"
cat <<EOF
Резервные копии: $BACKUP_DIR

Проверьте, что пользователи на месте:
  docker exec remnawave-db psql -U $DB_USER -d $DB_NAME -tAc 'SELECT count(*) FROM users;'
  (до переезда было: $USERS)

Панель:
  curl -s -o /dev/null -w '%{http_code}\\n' https://<ваш-домен>/api/auth/status

Если что-то не так, откат:
  docker compose -f "$MIGRATE_COMPOSE" down
  docker compose up -d
  # при необходимости восстановить базу:
  # docker exec -i remnawave-db psql -U $DB_USER -d $DB_NAME < $BACKUP_DIR/database.sql
EOF
