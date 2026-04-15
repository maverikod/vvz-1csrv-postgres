# vvz-1csrv-postgres

Стек в одном контейнере: **Postgres Pro STD 16** и **1С:Предприятие 8.3** (ragent, рабочие процессы). Управление через **Docker Compose**; на хосте без Docker — unit-файлы в `install/linux/systemd/`.

---

## Каталоги на хосте по умолчанию

Пути задаются переменными **`PGSQL1C_ETC`**, **`PGSQL1C_LOG`**, **`PGSQL1C_VAR`** (в `docker compose` и в `/etc/default/*` для systemd).

| Назначение | Переменная | Путь по умолчанию | Содержимое |
|------------|------------|-------------------|------------|
| Настройки PostgreSQL | `PGSQL1C_ETC` | **`/etc/pgsql1c`** | Каталог **`conf.d/`** монтируется в `.../data/conf.d` кластера (файлы `*.conf`, в т.ч. параметры для 1С) |
| Логи | `PGSQL1C_LOG` | **`/var/log/pgsql1c`** | Лог postmaster (`postgres.log` и др. внутри этого дерева), логи 1С при привязке к `/var/log/1cv8` в контейнере |
| Данные (базы и 1С) | `PGSQL1C_VAR` | **`/var/pgsql1c`** | **`postgres/`** — файлы кластера PostgreSQL (PGDATA); **`1cv8/`** — домашний каталог кластера 1С; **`cache/`** — cfstorage и кеш приложения |

Внутри контейнера по-прежнему: PGDATA → `/var/lib/pgpro/std-16/data`, данные 1С → `/home/usr1cv8/.1cv8`.

Создание каталогов и прав: **`sudo ./scripts/docker-data-init.sh`** (или переменные `PGSQL1C_*` перед вызовом). Каталог **`…/postgres`** (PGDATA на хосте) должен быть **`0700`** для пользователя **postgres (uid 1001 в образе)** — скрипт и **`postinst`** пакета выставляют это явно.

Для работы **из каталога репозитория** без `/var/...` задайте в файле **`.env`** в корне проекта, например:

```env
PGSQL1C_VAR=./data
PGSQL1C_LOG=./data/logs
PGSQL1C_ETC=./data/pgconf
```

и создайте `data/pgconf/conf.d/` (скрипт `docker-data-init.sh` можно вызвать с этими переменными).

---

## PostgreSQL: где настройки

| Что | Где на хосте (пути по умолчанию) |
|-----|----------------------------------|
| Кластер (файлы БД, `postgresql.conf`, `PG_VERSION`) | **`/var/pgsql1c/postgres/`** |
| Доп. параметры (`conf.d`) | **`/etc/pgsql1c/conf.d/`** → в контейнере `PGDATA/conf.d` |
| `pg_hba.conf` | **`/var/pgsql1c/postgres/pg_hba.conf`** — при **`PGSQL1C_PGHBA_MODE=managed`** (по умолчанию) перезаписывается при старте контейнера скриптом **`docker/vvz-configure-pg-hba.sh`**. Редактировать вручную на хосте можно только при **`PGSQL1C_PGHBA_MODE=skip`** в **`/etc/default/pgsql1c-stack`** (и перезапуск сервиса). |
| Лог `pg_ctl` / postmaster | **`/var/log/pgsql1c/`** (файл `postgres.log` задаётся в `docker/start-stack.sh`) |
| Порт PostgreSQL на хост | **не публикуется** (внутри контейнера **5432**; админ-доступ: **`docker compose exec`**) |

Шаблон параметров для 1С в репозитории: **`install/pg/conf.d/99-1c-enterprise.conf`**, переопределение шифрования паролей для клиента 1С на Windows: **`zz-1c-password-md5.conf`** (в образе; в **`conf.d`** кластера копируются при отсутствии файлов). Нужны **`password_encryption = md5`** и **`pg_hba`** с **`md5`** (по умолчанию в **`managed`**). После смены с SCRAM на MD5 заново задайте пароли ролей (**`pg1cchkpwd`**, **`ALTER USER`**). Ошибка 1С «**authentication method 10 not supported**» — сервер предлагал SCRAM, клиент не умеет.

### Доступ к PostgreSQL (только хост и Docker-сеть)

В **`docker-compose.yml`** задана отдельная сеть **`pgsql1c_net`** с подсетью **`PGSQL1C_DOCKER_SUBNET`** (по умолчанию **`172.31.0.0/16`**) и статическим адресом контейнера **`PGSQL1C_CONTAINER_IP`** (по умолчанию **`172.31.0.2`**). Имя сервиса **`app`** по-прежнему резолвится в Docker DNS; для подключения с других контейнеров в той же сети можно использовать и этот IP.

**`pg_hba.conf`** в режиме **`managed`** разрешает TCP-подключения с **`127.0.0.1`**, **`::1`** и из **`PGSQL1C_DOCKER_SUBNET`** (метод по умолчанию **`md5`**, см. **`PGSQL1C_PGHBA_AUTH_METHOD`**). Локальные сокеты — **`peer`**. Порт PostgreSQL на хост **не пробрасывается**, поэтому с другой машины сети «случайно» к БД не подключиться; с хоста для администрирования используйте **`docker compose exec app …`** (или клиент в контейнере в той же Docker-сети). Своё правило вручную: **`PGSQL1C_PGHBA_MODE=skip`** и редактирование **`pg_hba.conf`** на томе. Если всё же нужен проброс на хост — добавьте в **`docker-compose.override.yml`** строку **`ports: - "5432:5432"`** для сервиса **`app`**.

### Смена пароля пользователя `postgres`

Из каталога с **`docker-compose.yml`**:

```bash
./scripts/pgsql1c-set-postgres-password.sh 'новый_секретный_пароль'
```

Или переменная окружения **`PGSQL1C_POSTGRES_PASSWORD`**, или пароль со **stdin**. Каталог compose берётся из **`/etc/default/pgsql1c-stack`** (поле **`COMPOSE_PROJECT_DIR`**), при отсутствии — из текущего каталога, если там есть **`docker-compose.yml`**, иначе **`/usr/share/vvz-1csrv-postgres`**. Явный **`COMPOSE_PROJECT_DIR`** только если нужно переопределить. Подключение — от **`postgres`** внутри контейнера (**`peer`**), старый пароль не нужен.

---

## 1С: где настройки

| Что | Где |
|-----|-----|
| Данные кластера | На хосте **`/var/pgsql1c/1cv8/...`**, реестр **`.../reg_1541/*.lst`** |
| Hostname контейнера | Должен совпадать с именем узла в реестре; переменная **`ONEC_HOSTNAME`** |
| Параметры ragent | В контейнере **`/etc/default/srv1cv83`**, запуск **`/etc/init.d/srv1cv83`** (см. `docker/srv1cv83.default`) |
| Порты | **1540**, **1541**, **1560–1591** |

---

## Запуск через systemd

Unit **`pgsql1c-stack.service`** поднимает и останавливает стек через **`docker compose`** в каталоге **`COMPOSE_PROJECT_DIR`** (где лежит `docker-compose.yml`).

### Установка unit с репозитория

```bash
sudo ./install/linux/systemd/install-pgsql1c-stack-service.sh
```

Отредактируйте **`/etc/default/pgsql1c-stack`**: для клона репозитория укажите **`COMPOSE_PROJECT_DIR=/полный/путь/к/проекту`**, пути **`PGSQL1C_*`** при необходимости.

Включение:

```bash
sudo systemctl enable --now pgsql1c-stack.service
```

Остановка: **`sudo systemctl stop pgsql1c-stack.service`**.

Скрипты: **`/usr/libexec/vvz-1csrv-postgres/stack-start`**, **`stack-stop`** (подхватывают **`/etc/default/pgsql1c-stack`** и **`/etc/default/vvz-1csrv-postgres`**).

### Пакет .deb

После **`apt install`** доступны **`/usr/bin/vvz-1csrv-postgres`** и unit **`pgsql1c-stack.service`**. По умолчанию **`COMPOSE_PROJECT_DIR=/usr/share/vvz-1csrv-postgres`**.

Удаление (**`apt remove`** / **`apt purge`**): **`prerm`** вызывает **`stack-stop`** (**`docker compose down --remove-orphans`**) и отключает **`pgsql1c-stack.service`** — контейнеры стека снимаются с движка Docker.

---

## Запуск вручную (docker compose)

Требования: Docker, Compose plugin; для **сборки** образа — каталог **`install/`** с `.deb` (см. `Dockerfile`).

```bash
sudo ./scripts/docker-data-init.sh
docker compose build    # если используете локальный образ
docker compose up -d
```

Первичная инициализация **пустого** каталога PostgreSQL (`initdb`, UTF-8):

**Скрипт** (по умолчанию локаль **русский для Украины, UTF-8** — **`ru_UA.utf8`**):

```bash
./scripts/pgsql1c-init-cluster.sh
```

Интерактивное меню локалей (**`1`** — ru_RU, **`2`** — uk_UA, **`3`** или Enter — ru_UA):

```bash
./scripts/pgsql1c-init-cluster.sh -i
```

Иная локаль: **`INITDB_LOCALE=uk_UA.utf8 ./scripts/pgsql1c-init-cluster.sh`**

Вручную (неинтерактивно, **`ru_UA.utf8`**):

```bash
INIT_PGDATA=1 INITDB_LOCALE=ru_UA.utf8 docker compose run --rm app true
```

Локали собираются в образе (см. `Dockerfile`). Если **`INITDB_LOCALE`** не задан и нет TTY, **`docker-entrypoint`** использует **`ru_UA.utf8`**.

Порт **5432** на хост стеком **не занимает** (PostgreSQL доступен только внутри контейнера и из Docker-сети). Проброс на хост — только через свой **`docker-compose.override.yml`**, если он вам нужен.

---

## Пакет для Ubuntu (.deb)

```bash
./packaging/build-deb.sh
sudo apt install ./packaging/vvz-1csrv-postgres_1.0.14_all.deb
```

Сообщение **`debconf: delaying package configuration, since apt-utils is not installed`** при установке пакетов — обычное: без **apt-utils** debconf откладывает настройку. Пакет рекомендует **apt-utils**; при желании: **`sudo apt install apt-utils`** — предупреждение пропадёт.

**На пустой системе без Docker** используйте именно **`apt install ./…deb`** (или **`apt install ./packaging/…`**) — по полю **`Depends`** подтянутся **`docker.io`** или **`docker-ce`**, а также **Compose v2** (`docker-compose-plugin` или `docker-compose-v2`). Установка только через **`dpkg -i`** без последующего **`apt-get install -f`** зависимости не поставит; тогда нужно доустановить Docker и Compose вручную.

Образ **`VVZ_IMAGE`** проверяется и при отсутствии скачивается в **`preinst`** (до распаковки файлов пакета): нужны запущенный Docker и сеть. Значение берётся из **`/etc/default/vvz-1csrv-postgres`**, если файл уже есть (обновление или вы создали его вручную до первой установки); иначе — **`docker.io/vasilyvz/vvz-1csrv-postgres:latest`** (публичный образ по умолчанию в **`/etc/default/vvz-1csrv-postgres`**; замените на свой логин Hub при сборке образа самостоятельно). После установки образ можно сменить в этом файле и перезапустить **`pgsql1c-stack.service`**.

**При первой установке** debconf спросит **локаль кластера PostgreSQL** (`ru_UA.utf8`, `ru_RU.utf8` или `uk_UA.utf8`). Ответ записывается в **`INITDB_LOCALE`** в **`/etc/default/pgsql1c-stack`**. При обновлении пакета вопрос не показывается — используется сохранённый ответ. Для неинтерактивной установки задайте значение заранее:

```bash
echo 'vvz-1csrv-postgres vvz-1csrv-postgres/default-locale select ru_RU.utf8' | sudo debconf-set-selections
```

**При установке** (**`postinst`**): создаёт каталоги данных, при пустом каталоге данных инициализирует кластер с выбранной локалью, включает и запускает **`pgsql1c-stack.service`** (**`docker compose up -d`**). Образ к этому моменту уже должен быть локально (см. **`preinst`** выше). При сбое сервиса смотрите **`sudo journalctl -u pgsql1c-stack.service -b`** и **`sudo vvz-1csrv-postgres status`**.

**Смена пароля пользователя `postgres` без старого пароля** (только **root**): утилита **`pg1cchkpwd`** выполняет **`ALTER USER`** внутри контейнера. Пароль задаётся переменной **`PGSQL1C_POSTGRES_PASSWORD`**, первым аргументом, со stdin или интерактивным запросом:

```bash
sudo pg1cchkpwd 'новый_секрет'
# или: echo 'новый_секрет' | sudo pg1cchkpwd
```

**Управление (systemd):**

```bash
sudo systemctl start pgsql1c-stack.service    # поднять контейнеры
sudo systemctl stop pgsql1c-stack.service     # остановить (docker compose down)
sudo systemctl status pgsql1c-stack.service   # состояние unit
```

**Состояние PostgreSQL и сервера 1С внутри контейнера:**

```bash
sudo vvz-1csrv-postgres status
```

Показывается вывод **`docker compose ps`**, результат **`pg_isready`** и наличие процесса **`ragent`**.

**Удаление пакета** останавливает и отключает сервис, контейнеры завершаются (**`prerm`**).

---

## Релиз: .deb + образ + Docker Hub (одна команда)

Из корня репозитория (нужен **`docker login`** к Hub):

```bash
./scripts/release.sh
```

Собирается **`packaging/vvz-1csrv-postgres_<версия>_all.deb`**, образ с тегами **`<версия>`** и **`latest`**, выполняется **`docker push`**. Имя репозитория по умолчанию **`docker.io/vasilyvz/vvz-1csrv-postgres`**; переопределение: переменные **`DOCKER_USER`**, **`DOCKER_IMAGE`**, **`DOCKER_REGISTRY`**, при необходимости **`DOCKERFILE`** (например **`Dockerfile.offline`**).

Вручную:

```bash
./packaging/build-deb.sh
docker build -t <логин>/vvz-1csrv-postgres:latest .
docker push <логин>/vvz-1csrv-postgres:latest
```

Учётные данные реестра после **`docker login`** хранятся в **`~/.docker/config.json`**; токены не коммитьте, в CI используйте секреты.

---

## Дополнительно

- Установка unit-ов 1С/Postgres **без Docker** на «железе»: **`install/linux/systemd/install-systemd-services.sh`**.
- USB / HASP: см. `docker-compose.yml` (`devices`, при необходимости `privileged`).
