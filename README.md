# XLADA — развёртывание

Файлы для запуска панели XLADA на сервере. Исходный код — в соседних
репозиториях организации: [backend](https://github.com/xray-panel/backend),
[frontend](https://github.com/xray-panel/frontend),
[node](https://github.com/xray-panel/node),
[subscription-page](https://github.com/xray-panel/subscription-page).

Здесь только то, что нужно на сервере: compose-файлы, конфиги обратного
прокси, образцы окружения и скрипт переезда.

## Новая установка

```bash
git clone https://github.com/xray-panel/deploy.git /opt/xlada
cd /opt/xlada

# окружение
cp panel.env.sample .env
chmod 600 .env
# заполните .env: APP_SECRET, POSTGRES_PASSWORD, METRICS_PASS, домены
# APP_SECRET сгенерируйте: openssl rand -hex 32

docker compose up -d
```

Панель поднимется на `127.0.0.1:3000`. Наружу её отдаёт nginx:

```bash
cp nginx/panel.conf /etc/nginx/sites-available/xlada-panel
ln -sf /etc/nginx/sites-available/xlada-panel /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
certbot --nginx -d panel.example.com
```

Первый вход: откройте панель и зарегистрируйте суперадмина. Пароль —
минимум 24 символа, заглавные и строчные буквы, цифры.

## Переезд с Remnawave с сохранением пользователей

```bash
cd /opt/remnawave          # каталог старой установки
# положите рядом migrate-to-xlada.sh и docker-compose.migrate-from-remnawave.yml
bash migrate-to-xlada.sh
```

Скрипт сохранит дамп базы и `.env` в `backups/<дата>/`, проверит, что
дамп целый, остановит старый стек и поднимет XLADA на той же базе.
Том с данными не затрагивается.

Подробности и то, чего делать нельзя, — в
[MIGRATE-FROM-REMNAWAVE.md](MIGRATE-FROM-REMNAWAVE.md).

## Переход на PostgreSQL 18

XLADA работает на `postgres:18.4`, а старая установка Remnawave — на 17.6.
Каталог данных между мажорными версиями несовместим: в образах 18+ он переехал
в `/var/lib/postgresql/18/docker`, поэтому том, смонтированный в
`/var/lib/postgresql`, с данными 17 не запустится:

```
Error: in 18+, these Docker images are configured to store database data in a
       format which is compatible with "pg_ctlcluster" ...
Counter to that, there appears to be PostgreSQL data in: /var/lib/postgresql
```

Переходить на 18 нужно отдельным шагом. Порядок, при котором старый том не
изменяется вообще (откат — две строки в compose), описан в
[PG18-UPGRADE.md](PG18-UPGRADE.md).

## Страница подписки (необязательно)

Тот, что видит конечный пользователь. Нужен API-токен из панели:
Настройки → API Tokens.

```bash
cp subpage.env.sample .env.subpage
chmod 600 .env.subpage
# укажите REMNAWAVE_PANEL_URL и REMNAWAVE_API_TOKEN

docker compose up -d xpanel-subpage
cp nginx/subpage.conf /etc/nginx/sites-available/xlada-subpage
ln -sf /etc/nginx/sites-available/xlada-subpage /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
certbot --nginx -d sub.example.com
```

## Обновление версии

Версия задаётся переменной `XLADA_VERSION` в `.env` и совпадает у всех
компонентов:

```bash
# в .env: XLADA_VERSION=1.2.0
docker compose pull
docker compose up -d
```

## Как выпускается новая версия

Версия одна на все компоненты и совпадает у образов, тегов и `package.json`.
Порядок для сопровождающего:

```bash
# 1. поднять версию во всех четырёх репозиториях разом
scripts/set-version.sh 1.2.0

# 2. закоммитить и запушить ВСЕ ЧЕТЫРЕ
for r in backend frontend node subscription-page; do
    git -C apps/$r add -A && git -C apps/$r commit -m "Версия 1.2.0"
    git -C apps/$r push origin HEAD
done

# 3. теги — только там, где есть образ и релиз
for r in backend node subscription-page; do
    git -C apps/$r tag -a v1.2.0 -m "XLADA $r 1.2.0"
    git -C apps/$r push origin v1.2.0
done

# 4. обновить compose-файлы и MIGRATE-FROM-REMNAWAVE.md этого репозитория:
#    версию по умолчанию в них подставляет set-version.sh в основном
#    репозитории, поэтому файлы просто копируются оттуда и пушутся
```

Тег `v*` запускает сборку: образы под amd64 и arm64 публикуются в GHCR, и
создаётся релиз на GitHub. Панель собирается около 11 минут, нода — около 6.

**Фронтенду тег не ставится.** Отдельного образа и релиза у него нет: его
сборка уезжает внутрь образа панели, публиковать нечего. Но запушить его
обязательно — иначе версия в `package.json` на GitHub останется прежней.
Эта ошибка уже случалась, поэтому шаг 2 явно перечисляет все четыре
репозитория.

## Что важно не делать

- **`docker compose down -v`** — флаг `-v` удаляет тома вместе с базой.
- **Менять `APP_SECRET`** после первого запуска — от него зависят хеши
  паролей и зашифрованные секреты, вход перестанет работать.
- **Менять имена томов и сервисов** — при обновлении compose создаст
  новые пустые тома, а данные останутся в старых.

## Лицензия

AGPL-3.0-only. XLADA — производная работа от
[Remnawave](https://github.com/remnawave); атрибуция в файлах `NOTICE`
соответствующих репозиториев.
