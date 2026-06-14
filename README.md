# Автоматическая установка telemt MTProxy

Набор Bash-скриптов для развёртывания нескольких независимых экземпляров [telemt](https://github.com/telemt/telemt) в Docker.

Каждый экземпляр получает:

* отдельный Docker-контейнер;
* отдельный внешний TCP-порт;
* собственный FakeTLS-домен;
* отдельную таблицу nftables;
* SYN limiter для каждого IP-адреса клиента;
* systemd watcher для автоматического восстановления правила nftables;
* готовые ссылки для подключения к Telegram;
* отдельный каталог конфигурации.

## Скрипты

```text
install-telemt.sh
uninstall-telemt.sh
```

### `install-telemt.sh`

Устанавливает новый экземпляр telemt.

### `uninstall-telemt.sh`

Полностью удаляет выбранный экземпляр:

* Docker-контейнер;
* Docker Compose-проект;
* Docker-сеть;
* systemd watcher;
* таблицу nftables;
* служебные скрипты;
* каталог проекта.

---

## Требования

Поддерживаются:

* Ubuntu;
* Debian;
* архитектура `amd64` или `arm64`;
* запуск от пользователя `root`;
* доступ к интернету;
* свободный внешний TCP-порт.

Скрипт автоматически устанавливает необходимые пакеты:

```text
Docker
Docker Compose Plugin
nftables
curl
openssl
tcpdump
iproute2
```

---

## Подготовка

Создайте каталог для скриптов:

```bash
mkdir -p /opt/auto_teleproxy
```

Поместите файлы:

```text
/opt/auto_teleproxy/install-telemt.sh
/opt/auto_teleproxy/uninstall-telemt.sh
```

Сделайте их исполняемыми:

```bash
chmod +x /opt/auto_teleproxy/install-telemt.sh
chmod +x /opt/auto_teleproxy/uninstall-telemt.sh
```

Проверьте синтаксис:

```bash
bash -n /opt/auto_teleproxy/install-telemt.sh
bash -n /opt/auto_teleproxy/uninstall-telemt.sh
```

---

# Установка telemt

## Параметры

Скрипт установки принимает четыре обязательных параметра:

| Параметр   | Описание                    | Пример         |
| ---------- | --------------------------- | -------------- |
| `--domain` | FakeTLS-домен               | `apple.com`    |
| `--dir`    | Каталог проекта             | `/opt/telemt4` |
| `--port`   | Внешний TCP-порт            | `11443`        |
| `--name`   | Имя экземпляра и контейнера | `telemt4`      |

Все значения должны быть уникальными для каждого нового экземпляра.

## Пример установки

```bash
/opt/auto_teleproxy/install-telemt.sh \
  --domain apple.com \
  --dir /opt/telemt4 \
  --port 11443 \
  --name telemt4
```

После завершения будет создана структура:

```text
/opt/telemt4/
├── config/
│   └── config.toml
├── data/
├── connection.txt
└── docker-compose.yml
```

Дополнительно будут созданы:

```text
/usr/local/sbin/telemt4-in-syn-limit.sh
/usr/local/sbin/telemt4-in-syn-watch.sh
/etc/systemd/system/telemt4-in-syn-watch.service
```

И таблица nftables:

```text
telemt4_limit
```

---

## Результат установки

После успешной установки скрипт выведет:

* состояние Docker-контейнера;
* правило nftables;
* состояние systemd watcher;
* HTTPS-ссылку;
* `tg://` ссылку;
* путь к файлу с параметрами подключения.

Пример:

```text
HTTPS-ссылка:
https://t.me/proxy?server=SERVER_IP&port=11443&secret=...

Telegram-ссылка:
tg://proxy?server=SERVER_IP&port=11443&secret=...
```

Ссылки также сохраняются в:

```text
/opt/telemt4/connection.txt
```

Файл доступен только пользователю `root`.

Просмотр:

```bash
cat /opt/telemt4/connection.txt
```

---

# SYN limiter

Telegram-клиент при подключении может открыть несколько TCP-соединений к одному адресу подряд.

Скрипт создаёт nftables limiter, который ограничивает новые SYN-пакеты отдельно для каждого внешнего IP-адреса.

Значения по умолчанию:

```text
rate: 1/second
burst: 1
timeout: 60s
```

Правило применяется после Docker DNAT, поэтому оно привязано к внутреннему IP контейнера и порту `443`.

Пример схемы:

```text
Telegram client
      |
      v
VPS:11443
      |
      v
Docker DNAT
      |
      v
telemt4:443
```

Проверка правила:

```bash
nft list chain inet telemt4_limit forward
```

Наблюдение за счётчиком:

```bash
watch -n 1 'nft list chain inet telemt4_limit forward'
```

---

# Systemd watcher

Docker может изменить внутренний IP контейнера после:

* перезапуска контейнера;
* пересоздания Docker Compose-проекта;
* перезагрузки сервера;
* изменения Docker-сети.

Для этого создаётся watcher:

```text
telemt4-in-syn-watch.service
```

Watcher:

* проверяет состояние контейнера;
* определяет его текущий IP;
* проверяет наличие правильного nftables-правила;
* пересоздаёт правило при смене IP;
* восстанавливает правило после перезагрузки.

Проверка состояния:

```bash
systemctl status telemt4-in-syn-watch.service --no-pager
```

Просмотр журнала:

```bash
journalctl -u telemt4-in-syn-watch.service -n 50 --no-pager
```

Просмотр журнала в реальном времени:

```bash
journalctl -fu telemt4-in-syn-watch.service
```

---

# Управление контейнером

Просмотр состояния:

```bash
docker ps --filter name=telemt4
```

Просмотр последних логов:

```bash
docker logs telemt4 --tail=100
```

Просмотр логов в реальном времени:

```bash
docker logs -f telemt4
```

Перезапуск:

```bash
docker restart telemt4
```

Перезапуск через Docker Compose:

```bash
cd /opt/telemt4
docker compose restart
```

Обновление образа:

```bash
cd /opt/telemt4
docker compose pull
docker compose up -d
```

После пересоздания контейнера watcher автоматически обновит nftables-правило.

---

# Установка нескольких экземпляров

Для каждого экземпляра необходимо использовать отдельные:

* имя;
* каталог;
* внешний порт.

Пример:

```bash
/opt/auto_teleproxy/install-telemt.sh \
  --domain apple.com \
  --dir /opt/telemt3 \
  --port 10443 \
  --name telemt3
```

```bash
/opt/auto_teleproxy/install-telemt.sh \
  --domain microsoft.com \
  --dir /opt/telemt4 \
  --port 11443 \
  --name telemt4
```

```bash
/opt/auto_teleproxy/install-telemt.sh \
  --domain cloudflare.com \
  --dir /opt/telemt5 \
  --port 12443 \
  --name telemt5
```

Проверка всех контейнеров:

```bash
docker ps --filter ancestor=ghcr.io/telemt/telemt:latest
```

Проверка таблиц nftables:

```bash
nft list tables | grep telemt
```

Проверка watcher-сервисов:

```bash
systemctl list-units --type=service | grep telemt
```

---

# Удаление экземпляра

## Параметры

Скрипт удаления принимает:

| Параметр | Описание                                               |
| -------- | ------------------------------------------------------ |
| `--name` | Имя экземпляра и Docker-контейнера                     |
| `--dir`  | Каталог проекта                                        |
| `--yes`  | Необязательный параметр для удаления без подтверждения |

## Удаление с подтверждением

```bash
/opt/auto_teleproxy/uninstall-telemt.sh \
  --name telemt4 \
  --dir /opt/telemt4
```

Перед удалением скрипт покажет:

```text
Имя экземпляра
Каталог проекта
Systemd-сервис
Таблицу nftables
```

После этого потребуется подтверждение.

## Удаление без подтверждения

```bash
/opt/auto_teleproxy/uninstall-telemt.sh \
  --name telemt4 \
  --dir /opt/telemt4 \
  --yes
```

Скрипт удалит только ресурсы, относящиеся к указанному экземпляру.

Другие экземпляры, например `telemt`, `telemt2` или `telemt3`, затронуты не будут.

---

# Проверка удаления

После удаления:

```bash
docker ps -a --filter name=telemt4
```

```bash
systemctl status telemt4-in-syn-watch.service
```

```bash
nft list tables | grep telemt4
```

```bash
ls -ld /opt/telemt4
```

При полном удалении:

```text
контейнер отсутствует
systemd-сервис отсутствует
таблица nftables отсутствует
каталог проекта отсутствует
```

---

# Диагностика

## Контейнер не запускается

Проверьте логи:

```bash
docker logs telemt4 --tail=200
```

Проверьте конфигурацию:

```bash
cat /opt/telemt4/config/config.toml
```

Проверьте Compose:

```bash
cd /opt/telemt4
docker compose config
```

---

## Порт уже занят

Проверка:

```bash
ss -lntp | grep ':11443'
```

Нужно выбрать другой внешний порт.

---

## Нет nftables-правила

Запустите limiter вручную:

```bash
/usr/local/sbin/telemt4-in-syn-limit.sh
```

Проверьте таблицу:

```bash
nft list chain inet telemt4_limit forward
```

Перезапустите watcher:

```bash
systemctl restart telemt4-in-syn-watch.service
```

Проверьте журнал:

```bash
journalctl -u telemt4-in-syn-watch.service -n 100 --no-pager
```

---

## Изменился IP контейнера

Посмотреть IP:

```bash
docker inspect \
  -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' \
  telemt4
```

Watcher должен автоматически заметить изменение и пересоздать правило.

Принудительное обновление:

```bash
/usr/local/sbin/telemt4-in-syn-limit.sh
```

---

## Проверка доступности порта

На сервере:

```bash
ss -lntp | grep ':11443'
```

С другого устройства:

```bash
nc -vz SERVER_IP 11443
```

Или:

```bash
nmap -p 11443 SERVER_IP
```

---

## Проверка входящих подключений

```bash
tcpdump -ni any tcp port 11443
```

Только SYN-пакеты:

```bash
tcpdump -ni any \
  'tcp port 11443 and tcp[tcpflags] & tcp-syn != 0'
```

---

# Важные замечания

1. Каждый экземпляр должен иметь уникальное имя.

2. Каждый экземпляр должен использовать отдельный внешний TCP-порт.

3. Не используйте одинаковый каталог для разных экземпляров.

4. Не удаляйте nftables-таблицу вручную без необходимости. Watcher восстановит её автоматически.

5. Файл `connection.txt` содержит secret для подключения. Не публикуйте его в открытом доступе.

6. Каталог `data` доступен контейнеру для записи runtime-файлов telemt.

7. Удаление каталога проекта вручную не удаляет systemd-сервис и nftables-правило. Для полного удаления используйте `uninstall-telemt.sh`.

8. Перед удалением внимательно проверяйте параметры `--name` и `--dir`.

---

# Быстрый пример

## Установка

```bash
/opt/auto_teleproxy/install-telemt.sh \
  --domain apple.com \
  --dir /opt/telemt4 \
  --port 11443 \
  --name telemt4
```

## Проверка

```bash
docker ps --filter name=telemt4
nft list chain inet telemt4_limit forward
systemctl status telemt4-in-syn-watch.service --no-pager
cat /opt/telemt4/connection.txt
```

## Удаление

```bash
/opt/auto_teleproxy/uninstall-telemt.sh \
  --name telemt4 \
  --dir /opt/telemt4

