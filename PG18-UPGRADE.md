# Переход PostgreSQL 17 → 18 (без потери данных)

Инструкция для установки, где база была создана на `postgres:17.6` (том
смонтирован в `/var/lib/postgresql/data`) и которую нужно поднять на
`postgres:18.4`.

Актуально для переезда с Remnawave на XLADA: официальный compose Remnawave
использует `postgres:17.6`, а `deploy/docker-compose.yml` XLADA — `postgres:18.4`.

---

## 1. Почему контейнер падает в цикле

В образах `postgres:18+` каталог данных переехал:

| Версия | `PGDATA` | Куда монтировать том |
|---|---|---|
| 17 и ниже | `/var/lib/postgresql/data` | `/var/lib/postgresql/data` |
| **18 и выше** | `/var/lib/postgresql/18/docker` | **`/var/lib/postgresql`** |

Если старый том (в котором `PG_VERSION` лежит **в корне**) смонтировать в
`/var/lib/postgresql`, entrypoint образа 18 отказывается инициализировать
кластер:

```
Counter to that, there appears to be PostgreSQL data in:
  /var/lib/postgresql
```

Это защита от «обновили образ, но не обновили данные». Она срабатывает не на
«непустой каталог», а на наличие файла `PG_VERSION` в одном из мест:

```
/var/lib/postgresql
/var/lib/postgresql/data
/var/lib/postgresql/*/docker
```

Отсюда два неочевидных следствия:

* **Просто переложить кластер 17 в `/var/lib/postgresql/17/docker` внутри того
  же тома — не поможет.** Шаблон `*/docker` поймает его снова. Такая раскладка
  годится только для ручного `pg_upgrade`, который запускается до старта
  сервера.
* Если `/var/lib/postgresql/data` остаётся отдельной точкой монтирования, образ
  18 тоже ругается — уже как на «unused mount/volume».

Исходник: [`18/docker-entrypoint.sh`](https://raw.githubusercontent.com/docker-library/postgres/master/18/bookworm/docker-entrypoint.sh),
функции `docker_setup_env()` / `docker_error_old_databases()`,
[PR #1259](https://github.com/docker-library/postgres/pull/1259).

---

## 2. Выбранный способ: новый том + restore дампа

| Вариант | Риск | Откат |
|---|---|---|
| `pg_upgrade --link` | локали/ICU/glibc, бинари 17 в образе 18, `--link` необратим при сбое | сложный |
| initdb 18 в том же томе | файловые операции внутри единственного тома | обратный `mv` |
| **новый том для 18, старый не трогаем** | **минимальный** | **2 строки в compose** |

Дополнительный довод против `pg_upgrade`: в PostgreSQL 18 сменился провайдер
сравнения строк по умолчанию, а образы 17 и 18 собраны на разных версиях
glibc. Ошибка совместимости коллаций проявляется не сразу, а позже — «молча
неправильной» сортировкой и ненайденными строками. Логический дамп этой
проблемы не имеет: кластер 18 создаётся заново, нативно для своего образа.

При базе в десятки-сотни мегабайт `pg_dump` + restore занимает секунды, поэтому
`pg_upgrade` не даёт ничего, кроме риска.

**Старый том при этом не изменяется ни на байт** — он и есть путь отката.

---

## 3. Процедура

> Запрещено на всём протяжении: `docker compose down -v`,
> `docker volume rm`, `docker volume prune`, `docker system prune --volumes`.
> Останавливать стек только через `docker compose stop` или `down` **без** `-v`.

Все команды выполняются в каталоге установки — `/opt/remnawave` у стандартной
установки Remnawave; подставьте свой, если он другой.

### Шаг 0. Инвентаризация (только чтение)

```bash
cd /opt/remnawave

docker compose ps -a
docker compose config --volumes
docker volume ls | grep -i -E 'db|postgres'

# фактическое имя тома и точка монтирования
docker inspect remnawave-db \
  --format '{{range .Mounts}}{{.Type}} {{.Name}} -> {{.Destination}}{{"\n"}}{{end}}'
```

Имя тома ожидается `remnawave-db-data` (в compose Remnawave он объявлен с
явным `name:`, поэтому префикс проекта не добавляется). Если у вас имя с
префиксом (`remnawave_remnawave-db-data`) — подставляйте своё везде ниже.

Проверить, что в томе действительно кластер 17:

```bash
docker run --rm -v remnawave-db-data:/v postgres:17.6 cat /v/PG_VERSION
# ожидаем: 17
```

Проверить дамп:

```bash
ls -lh backups/pg18-upgrade/
head -n 3 backups/pg18-upgrade/database-pg17.sql
# дамп целый, если маркер завершения найден ровно один раз:
grep -c 'PostgreSQL database dump complete' backups/pg18-upgrade/database-pg17.sql
# ожидаем: 1
```

### Шаг 1. Вернуться на 17.6 и снять свежий дамп

Возвращаем в `docker-compose.yml` сервис `remnawave-db`: `image: postgres:17.6`
и монтирование `remnawave-db-data:/var/lib/postgresql/data`
(готовый файл — `backups/pg18-upgrade/docker-compose.yml.backup`).

```bash
cd /opt/remnawave
cp -a docker-compose.yml backups/pg18-upgrade/docker-compose.yml.pg18-broken
cp -a backups/pg18-upgrade/docker-compose.yml.backup docker-compose.yml

docker compose config --quiet && echo "COMPOSE OK"
docker compose stop
docker compose up -d remnawave-db          # только база, backend не поднимаем
docker compose logs --tail=20 remnawave-db
```

> Неудачная попытка запуска 18 могла оставить внутри старого тома пустой
> каталог `18/docker`. Для PostgreSQL 17 это безвредный мусор, ничего делать не
> нужно; удалить его можно после успешного перехода.

Проверить, что база жива и данные на месте:

```bash
docker compose exec remnawave-db sh -c 'echo "user=$POSTGRES_USER db=$POSTGRES_DB"'
docker compose exec remnawave-db sh -c 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
docker compose exec remnawave-db sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from users;"'
# ожидаем: 4821
```

Снять свежий дамп (backend к этому моменту уже остановлен, записей нет):

```bash
docker compose exec -T remnawave-db sh -c \
  'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
     --clean --if-exists --no-owner --no-privileges' \
  > backups/pg18-upgrade/database-pg17-fresh.sql

ls -lh backups/pg18-upgrade/database-pg17-fresh.sql
head -n 3 backups/pg18-upgrade/database-pg17-fresh.sql
grep -c 'PostgreSQL database dump complete' backups/pg18-upgrade/database-pg17-fresh.sql
# ожидаем: 1
grep -c '^CREATE TABLE' backups/pg18-upgrade/database-pg17-fresh.sql
# запомните это число, чтобы сверить после restore
```

### Шаг 2. Репетиция на одноразовом контейнере 18 (необязательно, но полезно)

Проверяем сразу и дамп, и поведение образа 18 — до того, как что-то менять в
рабочем compose.

```bash
docker volume create pg18-verify-tmp

docker run -d --name pg18-verify \
  -e POSTGRES_USER=verify -e POSTGRES_PASSWORD=verify -e POSTGRES_DB=verify \
  -v pg18-verify-tmp:/var/lib/postgresql \
  postgres:18.4

docker logs --tail=20 pg18-verify      # "PostgreSQL init process complete"

docker exec -i pg18-verify sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 --single-transaction' \
  < /opt/remnawave/backups/pg18-upgrade/database-pg17-fresh.sql
echo "restore exit=$?"                 # ожидаем 0

docker exec pg18-verify sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from users;"'
# ожидаем: 4821

docker rm -f pg18-verify
docker volume rm pg18-verify-tmp
```

Если restore здесь проходит и счётчик совпал — на боевом томе будет так же.

### Шаг 3. Новый том для 18

Правки в `docker-compose.yml` (сервис `remnawave-db`):

```yaml
  remnawave-db:
    image: postgres:18.4                     # было: postgres:17.6
    volumes:
      # ВАЖНО: путь /var/lib/postgresql, БЕЗ /data.
      # Новый том: старый remnawave-db-data остаётся нетронутым.
      - remnawave-db-pg18-data:/var/lib/postgresql
```

И в верхнеуровневой секции `volumes:` добавить новый том, старый — оставить
объявленным:

```yaml
volumes:
  remnawave-db-pg18-data:
    name: remnawave-db-pg18-data
    driver: local
  remnawave-db-data:            # старый том, не монтируется, НЕ удалять
    name: remnawave-db-data
    driver: local
```

Проверить, что compose собрался правильно:

```bash
cd /opt/remnawave
docker compose config --quiet && echo "COMPOSE OK"
docker compose config --format json | python3 -c "
import json,sys
c = json.load(sys.stdin)
db = c['services']['remnawave-db']
print('image :', db['image'])
for v in db.get('volumes', []):
    print('mount :', v.get('source'), '->', v.get('target'))
print('volumes:', sorted(c.get('volumes', {}).keys()))
"
# ожидаем: image postgres:18.4; mount remnawave-db-pg18-data -> /var/lib/postgresql
```

Запустить только базу:

```bash
docker compose up -d remnawave-db
docker compose logs --tail=30 remnawave-db
# ожидаем: "PostgreSQL init process complete; ready for start up."

docker compose exec remnawave-db sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "show server_version;"'
# ожидаем: 18.4

docker compose exec remnawave-db sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from pg_tables;"'
# ожидаем: 0 — кластер пустой
```

Если снова появилась ошибка «in 18+ …» — значит смонтирован не тот том или
остался путь `/var/lib/postgresql/data`. Вернитесь к правке compose.

### Шаг 4. Залить данные

```bash
docker compose exec -T remnawave-db sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 --single-transaction' \
  < /opt/remnawave/backups/pg18-upgrade/database-pg17-fresh.sql
echo "restore exit=$?"        # ожидаем 0

docker compose exec remnawave-db sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from users;"'
# ожидаем: 4821
```

### Шаг 5. Поднять весь стек

```bash
docker compose up -d
docker compose ps
docker compose logs --tail=80 remnawave
```

Далее — панель в браузере: список пользователей, вход под админом, одна
тестовая подписка.

---

## 4. Откат

Старый том не менялся, поэтому откат сводится к возврату compose:

```bash
cd /opt/remnawave
docker compose stop
cp -a backups/pg18-upgrade/docker-compose.yml.pg17-restored docker-compose.yml
docker compose up -d
docker compose exec remnawave-db sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from users;"'
# ожидаем: 4821
```

(`docker-compose.yml.pg17-restored` — это копия, снятая перед правками Шага 3;
если её нет, верните вручную `postgres:17.6` и `/var/lib/postgresql/data`.)

---

## 5. Зачистка (не раньше, чем через неделю стабильной работы)

```bash
docker ps -a --filter volume=remnawave-db-data     # ничего не должно быть
docker volume rm remnawave-db-data
```

Дампы в `backups/pg18-upgrade/` хранить до следующего штатного бэкапа.

---

## 6. Частые ошибки

| Ошибка | Симптом | Как не допустить |
|---|---|---|
| `down -v` / `volume prune` | том 17 удалён безвозвратно | только `stop` / `down` без `-v` |
| Неверное имя тома | стек поднялся на пустом томе, «данные пропали» | имя из `docker inspect`, а не по памяти |
| Монтирование нового тома в `.../data` | тот же цикл падений | ровно `/var/lib/postgresql` |
| Перекладывание кластера 17 в `17/docker` | цикл падений сохраняется (шаблон `*/docker`) | отдельный том |
| Backend поднят во время restore | `relation ... already exists`, дубли | backend поднимать только после проверки счётчика |
| `POSTGRES_USER`/`POSTGRES_DB` изменились | `password authentication failed`, пустая база | новые значения взять из того же `.env` |
| Восстановление без `ON_ERROR_STOP` | restore «прошёл», но данные неполные | `-v ON_ERROR_STOP=1 --single-transaction` |

Расширения в дампе не нужны: миграции XLADA не создают `CREATE EXTENSION`,
`gen_random_uuid()` входит в ядро PostgreSQL начиная с 13.

---

## 7. Приложение: проверено эмпирически

Все утверждения выше проверены на локальном Docker (образ `postgres:18.4`,
Debian 18.4-1.pgdg13+1) на одноразовых томах:

| Проверка | Результат |
|---|---|
| Том, в корне которого лежит `PG_VERSION`, смонтирован в `/var/lib/postgresql` | контейнер падает, exit 1, в ошибке `/var/lib/postgresql` — **воспроизводит исходную проблему** |
| Тот же том, кластер переложен в `17/docker` | **контейнер снова падает**, в ошибке `/var/lib/postgresql/17/docker` — «очевидный» фикс не работает |
| Пустой новый том, смонтированный в `/var/lib/postgresql` | initdb проходит: `PGDATA=/var/lib/postgresql/18/docker`, `PG_VERSION=18`, сервер `18.4` |
| `pg_dump --clean --if-exists --no-owner --no-privileges` + `psql -v ON_ERROR_STOP=1 --single-transaction` | restore exit 0, 0 ошибок, 4821 строка до и после |

Последний пункт подтверждает и идемпотентность: дамп с `--clean --if-exists`
успешно накатывается повторно, поэтому неудачный restore можно просто повторить.

