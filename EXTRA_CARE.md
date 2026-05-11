# EXTRA_CARE.md — Многоступенчатый fallback VPN

> **Статус: развёрнуто 2026-05-11.** L1+L2+L3 работают на сервере, observatory+balancer работают на роутере, cron-rollback снят. См. раздел «Что фактически сделано» внизу. Следующие задачи — обновление репо (`install.sh`, `server-install.sh`, `README.md`) + TG-watchdog.

## Исходные данные

- **Сервер**: `<<SERVER_DOMAIN>>` (значение хранится в `public/state.env` локально, в публичных доках/коммитах не светим), 3x-ui уже установлен.
- **Роутер**: Xiaomi AX3000T, OpenWrt 25, xray-core с TProxy и Split-DNS (см. CLAUDE.md и `install.sh`).
- **Текущий конфиг**: один outbound `proxy` (VLESS + Reality + TCP). Если сервер недоступен — трафик к проксируемым сайтам **просто обрывается**, остальное (direct-правила: ru, steam, microsoft, apple, торренты) продолжает работать. Внешне это выглядит как «VPN свалился, всё пошло напрямую» — именно так это произошло прошлой ночью.

## Цель

Многоступенчатый fallback **на тот же IP сервера** (`<<SERVER_DOMAIN>>`):

- При проблеме с одним транспортом — клиент автоматически переключается на следующий.
- Все слои терминируются на одном сервере, один и тот же VLESS UUID.
- При полном падении всех слоёв — трафик **дропается**, а не идёт через direct (согласовано: безопаснее дропнуть, чем светить реальный IP).

## Архитектура

### Слои fallback

| Слой | Порт | Транспорт | Назначение |
|---|---|---|---|
| **L1** — основной | 443 TCP | VLESS + Reality + Vision | Базовое состояние, максимум скорости, маскировка под чужой TLS |
| **L2** — WS-маскировка | 8443 TCP | VLESS + TLS + WebSocket `/ws` | Работает если DPI начал резать Reality по fingerprint |
| **L3** — gRPC | 2053 TCP | VLESS + TLS + gRPC `multi/grpc-service` | Альтернативная TLS-маскировка; иногда жив когда WS режут |
| **L4** *(опционально, потом)* | 51820 UDP | AmneziaWG | Если весь TCP-443 режут на провайдере; обходит даже UDP-блокировки |

L1–L3 — это inbound'ы xray на сервере, управляются через 3x-ui.
L4 — отдельный туннель уровня ядра, **не часть xray**, подключается внешним watchdog'ом.

### Механизм переключения (клиент)

Используем нативные фичи xray-core:

- **Observatory** — встроенный health-checker. Раз в `probeInterval` секунд (10s) пингует каждый proxy-outbound через `https://www.gstatic.com/generate_204`. Хранит ping и состояние alive/dead.
- **Balancer** в routing — выбирает живой outbound из группы по стратегии `leastPing`.
- В routing-правиле вместо `outboundTag: "proxy"` указываем `balancerTag: "vpn-balancer"`.

Если все outbound'ы группы мертвы — xray дропает соединение (это то что мы хотим). В `direct` ничего не падает.

## Что нужно сделать на сервере (3x-ui)

### Шаг S0. Подготовка

1. Убедиться что есть TLS-сертификат на `<<SERVER_DOMAIN>>` (Let's Encrypt). 3x-ui это умеет сам через панель → Settings → Certificates.
2. Проверить что порты 443/8443/2053 свободны на сервере (`ss -tlnp`).
3. **Сделать снапшот текущей конфигурации 3x-ui** перед любыми изменениями: `cp /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.bak-$(date +%F)`. И сохранить дамп `xray-config.json` который генерирует панель — путь обычно `/usr/local/x-ui/bin/config.json` (уточнить).

### Шаг S1. Текущий VLESS+Reality оставить как L1

Ничего не трогать. Это уже работает.

### Шаг S2. Добавить L2 — VLESS + WS + TLS на 8443

В 3x-ui создать новый inbound:
- Protocol: VLESS
- Port: 8443
- UUID: **тот же что у L1** (важно — один пользователь на все слои)
- Network: ws
  - Path: `/ws` (можно длиннее и случайнее)
  - Host: `<<SERVER_DOMAIN>>`
- Security: TLS
  - SNI: `<<SERVER_DOMAIN>>`
  - Cert: тот что выдан Let's Encrypt
- Flow: пусто (Vision несовместим с WS)

### Шаг S3. Добавить L3 — VLESS + gRPC + TLS на 2053

В 3x-ui новый inbound:
- Protocol: VLESS
- Port: 2053
- UUID: тот же
- Network: grpc
  - serviceName: `grpc-<host>` (тоже желательно «нестандартное»; в `install.sh` генерится как `grpc-$(echo $SERVER_DOMAIN | tr . -)`)
  - multiMode: on
- Security: TLS, SNI = `<<SERVER_DOMAIN>>`

### Шаг S4. Проверить с сервера что все три слоя слушают

```
ss -tlnp | grep -E ':443|:8443|:2053'
```

И с клиентского хоста (не из-под xray):
```
curl -v --connect-timeout 5 https://<<SERVER_DOMAIN>>:8443/ws
curl -v --connect-timeout 5 https://<<SERVER_DOMAIN>>:2053/
```

Должны быть TLS-хендшейки (даже если 400/404 в ответе — это норма).

### Шаг S5. Firewall

Открыть на сервере порты 8443/tcp и 2053/tcp если ufw/iptables их режет.

## Что нужно сделать на роутере (xray)

### Шаг C0. Подготовка

1. Снапшот текущего конфига: `cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.bak-$(date +%F)`.
2. Снапшот шаблона в репо: `cp public/config.json.template public/config.json.template.bak`.

### Шаг C1. Обновить `config.json.template`

Изменения:

**1. Расширить блок `outbounds`** — три proxy-outbound'а вместо одного:

```jsonc
{
  "tag": "proxy-reality",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "<<VLESS_SERVER>>",
      "port": 443,
      "users": [{
        "id": "<<VLESS_UUID>>",
        "flow": "xtls-rprx-vision",
        "encryption": "none"
      }]
    }]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "serverName": "<<VLESS_SNI>>",
      "fingerprint": "<<VLESS_FP>>",
      "publicKey": "<<VLESS_PBKEY>>",
      "shortId": "<<VLESS_SID>>"
    }
  },
  "sockopt": { "mark": 255 }
},
{
  "tag": "proxy-ws",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "<<VLESS_SERVER>>",
      "port": 8443,
      "users": [{
        "id": "<<VLESS_UUID>>",
        "encryption": "none"
      }]
    }]
  },
  "streamSettings": {
    "network": "ws",
    "security": "tls",
    "tlsSettings": {
      "serverName": "<<SERVER_DOMAIN>>",
      "fingerprint": "chrome"
    },
    "wsSettings": {
      "path": "/ws",
      "headers": { "Host": "<<SERVER_DOMAIN>>" }
    }
  },
  "sockopt": { "mark": 255 }
},
{
  "tag": "proxy-grpc",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "<<VLESS_SERVER>>",
      "port": 2053,
      "users": [{
        "id": "<<VLESS_UUID>>",
        "encryption": "none"
      }]
    }]
  },
  "streamSettings": {
    "network": "grpc",
    "security": "tls",
    "tlsSettings": {
      "serverName": "<<SERVER_DOMAIN>>",
      "fingerprint": "chrome"
    },
    "grpcSettings": {
      "serviceName": "grpc-<<SERVER_DOMAIN>>",
      "multiMode": true
    }
  },
  "sockopt": { "mark": 255 }
}
```

`direct`, `block`, `dns-out` — оставить как есть.

**2. Добавить блок `observatory`** на верхнем уровне конфига:

```jsonc
"observatory": {
  "subjectSelector": ["proxy-"],
  "probeURL": "https://www.gstatic.com/generate_204",
  "probeInterval": "10s",
  "enableConcurrency": true
}
```

**3. Добавить `balancers` в `routing`**:

```jsonc
"routing": {
  "domainStrategy": "IPIfNonMatch",
  "balancers": [{
    "tag": "vpn-balancer",
    "selector": ["proxy-"],
    "strategy": { "type": "leastPing" }
  }],
  "rules": [
    // ... все существующие правила оставить ...
    // ... последнее правило меняется: ...
    {
      "type": "field",
      "balancerTag": "vpn-balancer",
      "network": "tcp,udp"
    }
  ]
}
```

Старое последнее правило `{"outboundTag": "proxy", "network": "tcp,udp"}` **удаляем** — его заменяет balancer.

**4. API для мониторинга** — добавить inbound на API и роутинг к нему, чтобы можно было `xray api statsquery` дергать:

```jsonc
"api": {
  "tag": "api",
  "services": ["StatsService", "ObservatoryService"]
},
"inbounds": [
  // ... существующие ...
  {
    "tag": "api-in",
    "listen": "127.0.0.1",
    "port": 10085,
    "protocol": "dokodemo-door",
    "settings": { "address": "127.0.0.1" }
  }
]
```

И первое routing-правило:
```jsonc
{ "type": "field", "inboundTag": ["api-in"], "outboundTag": "api" }
```

### Шаг C2. Обновить `install.sh`

Функция `generate_config` сейчас подставляет один `<<STREAM_SETTINGS>>` блок. Нужно изменить логику:

- Принимать на вход параметры **только L1 (Reality)** из VLESS-ссылки.
- Для L2 (WS) и L3 (gRPC) — параметры **захардкодить** в шаблон (port/path/serviceName/sni — известны заранее).
- UUID — общий для всех трёх, берётся из VLESS-ссылки (`$VLESS_UUID`).
- Server address (`$VLESS_SERVER`) — общий.

Альтернатива: завести ещё два VLESS_URL_L2 и VLESS_URL_L3 в `state.env`, и каждый парсить отдельно. Это гибче но скучнее. **Рекомендую первый вариант** (хардкод L2/L3 параметров в шаблоне) — проще и поддерживать легче.

### Шаг C3. Логирование переключений

Маленький watchdog `/usr/local/bin/xray-balancer-watch.sh`:

```sh
#!/bin/sh
# Раз в минуту опрашивает observatory и пишет в лог состояние outbound'ов
LOG=/var/log/xray/balancer.log
STATE_FILE=/tmp/xray-balancer-state

while true; do
  STATE=$(xray api statsquery --server=127.0.0.1:10085 2>/dev/null \
    | grep -E 'proxy-(reality|ws|grpc).*alive' || echo unknown)
  PREV=$(cat $STATE_FILE 2>/dev/null)
  if [ "$STATE" != "$PREV" ]; then
    echo "[$(date)] state changed: $STATE" >> $LOG
    echo "$STATE" > $STATE_FILE
  fi
  sleep 60
done
```

Запустить как procd-сервис или просто в фоне через init.d/xray.

**Альтернатива попроще**: периодически дёргать `xray api` cron-задачей раз в минуту и логировать **только изменения** состояния. Никаких demon'ов.

### Шаг C4. Тестирование

Сценарии которые нужно прогнать **до того как считать «готово»**:

1. **Базовый**: всё живо → balancer должен выбрать `proxy-reality` (наименьший ping обычно у Reality+Vision). Проверить через `xray api`.
2. **L1 умер**: на сервере остановить inbound 443 → роутер должен переключиться на `proxy-ws` за ≤30 секунд (3 цикла probe). На клиенте: `curl ifconfig.me` всё ещё показывает IP сервера.
3. **L1+L2 умерли**: остановить и 443 и 8443 → переход на `proxy-grpc`.
4. **Все умерли**: остановить все три inbound'а → клиентский трафик дропается. **На direct не падает** — это критично, проверить чтоб `curl ifconfig.me` показал ошибку, а не реальный IP клиента.
5. **Восстановление**: поднять L1 обратно → balancer вернулся на reality.

Для каждого сценария — записать в лог поведение, latency перехода, есть ли потеря пакетов.

### Шаг C5. Обновить `vless-tproxy-openwrt-ax3000t.md`

Документировать новую архитектуру: схема, таблица слоёв, где смотреть состояние, команды диагностики (`xray api statsquery`, `tail -f /var/log/xray/balancer.log`).

## Опциональный L4 — AmneziaWG

Это **отдельный этап** на потом, когда L1-L3 будут стабильны.

### На сервере

- Установить `amneziawg-go` или `awg` (modded WireGuard с обфускацией junk-пакетами).
- Конфиг: те же `Jc/Jmin/Jmax/S1/S2/H1/H2/H3/H4` параметры обфускации (читать [docs.amnezia.org](https://docs.amnezia.org/) — публичные).
- Порт 51820/udp, peer-конфиг для роутера.

### На роутере (OpenWrt 25)

Пакеты в feeds:
- `amneziawg-tools` (userspace)
- `kmod-amneziawg` (если ядро поддерживает — у AX3000T MediaTek MT7981, ядро 6.x, должно завестись; если нет — userspace fallback)

Конфиг через `/etc/config/network`:
```
config interface 'awg0'
    option proto 'amneziawg'
    option private_key '...'
    option listen_port '51820'
    list addresses '10.66.66.2/32'
```
+ peer-секция с публичным ключом сервера и junk-параметрами.

### Watchdog для L4

xray Observatory **не умеет** ping'овать туннель уровня ядра. Поэтому:

`/usr/local/bin/xray-l4-watchdog.sh` — bash, проверяет каждую минуту:
- Если **все** proxy-outbound'ы в xray мёртвы (через `xray api`) → останавливает xray → поднимает `awg0` → меняет default route на awg0 → ждёт.
- Если xray-observatory ожил → опускает `awg0` → возвращает дефолт через xray.

**Опасности**:
- При переходе TProxy/nftables должен быть переключён или обойдён — иначе пакеты ловятся в TProxy port 12345 а xray-то стоит.
- Маршрут default через awg0 ловит и сам трафик к серверу (`<<SERVER_DOMAIN>>:51820 UDP`) — будет петля. Нужно `ip rule add` чтобы трафик до IP сервера шёл напрямую, минуя туннель.

Это **нетривиально** и легко себе сломать сеть. Поэтому **на потом, отдельной задачей, и только если L1-L3 не хватит**.

## Откат и безопасность

**До любого деплоя**:

1. Снапшот клиентского `config.json` (`config.json.bak-DATE`).
2. Снапшот серверной БД 3x-ui.
3. Тест нового config'а через `xray run -test -c new-config.json` **прежде чем** заменять рабочий.
4. Cron-rollback на роутере: `(crontab -l; echo "*/5 * * * * /usr/local/bin/xray-rollback-if-broken.sh") | crontab -` — если через 5 минут после деплоя интернет не работает, скрипт возвращает `config.json.bak`. Снять руками после успешного теста. *(Это паттерн который Сид использует, см. MEMORY.md)*.

## План работ по этапам

| Этап | Что делается | Где | Риск |
|---|---|---|---|
| 1 | S0: снапшот 3x-ui, проверка портов | сервер | низкий |
| 2 | C0: снапшоты на роутере + cron-rollback | роутер | низкий |
| 3 | S2+S3: добавить L2 и L3 inbound'ы | сервер | низкий — не трогает L1 |
| 4 | S4: проверить TLS-хендшейки снаружи | сервер | нулевой |
| 5 | C1: новый `config.json.template` | роутер | средний — может сломать клиентский интернет |
| 6 | Написать `server-install.sh` | репо | нулевой |
| 7 | Обновить `install.sh` (новый шаблон + diag) | репо | нулевой (не деплой) |
| 8 | Обновить `README.md` | репо | нулевой |
| 9 | Тесты переключения по 5 сценариям | оба | средний |
| 10 | Watchdog для логов balancer'а | роутер | низкий |
| 11 | Снять cron-rollback, финальная проверка | роутер | низкий |
| 12 *(потом)* | L4 AmneziaWG | оба | высокий — отдельная сессия |

## Решения (согласованы)

1. **UUID для L2/L3** — общий с L1.
2. **`serviceName` (gRPC) и `path` (WS)** — захардкодить в шаблоне.
3. **Reality SNI** — не трогаем.
4. **TLS-cert** — на основной домен сервера.
5. **Probe-URL** — `https://www.gstatic.com/generate_204` (Cloudflare исключён, есть подозрение что фильтруется на пути).
6. **Доступ для Claude** — выдаётся после согласования плана; до этого момента деплоя нет.
7. **Имя домена в репо** — не светим. В публичных файлах placeholder `<<SERVER_DOMAIN>>`, реальное значение в `public/state.env` (этот файл уже в `.gitignore`, проверить).

## Про 3x-ui: как добавлять inbound'ы

3x-ui хранит конфигурацию в SQLite (`/etc/x-ui/x-ui.db`), а файл `config.json` для xray генерирует из неё при перезапуске сервиса. Есть три пути:

| Способ | Видно в панели | Безопасность | Когда использовать |
|---|---|---|---|
| Web UI (накликать руками) | да | максимальная | для контроля и первого раза |
| REST API панели | да | высокая (валидация на стороне 3x-ui) | автоматизация из скрипта |
| Прямые `INSERT` в SQLite | да, **после рестарта** `x-ui restart` | низкая — легко сломать JSON-поля | не используем |

**Используем REST API**. Endpoints (примерные, версии 3x-ui могут отличаться — уточнить на месте):
- `POST /login` → cookie session
- `GET  /panel/api/inbounds/list` → список текущих inbound'ов
- `POST /panel/api/inbounds/add` → добавить inbound (JSON body)
- `POST /panel/api/inbounds/del/{id}` → удалить (для отката)

`server-install.sh` (см. ниже) использует именно API. Если что-то пойдёт не так — Сид всегда сможет открыть панель и проверить/поправить руками.

## Что в репо нужно сделать (помимо EXTRA_CARE.md)

### Новый файл: `public/server-install.sh`

Интерактивный скрипт по образу `install.sh` (запускается локально, ходит на сервер по SSH/HTTP). Меню:

```
1) Установить L2 (VLESS+WS+TLS) на 8443
2) Установить L3 (VLESS+gRPC+TLS) на 2053
3) Диагностика — показать все inbound'ы и их статус
4) Удалить L2/L3 (откат)
5) Проверить TLS-сертификат на сервере
6) Проверить занятость портов
```

Что нужно скрипту:
- `SERVER_HOST` (берётся из `state.env`)
- `SSH_USER` + `SSH_KEY` или пароль
- Креды 3x-ui (логин/пароль панели; URL панели; обычно `http://server:54321/<random-path>`)
- UUID из текущего L1 (читать с сервера через API → найти inbound на 443 → достать UUID)

Скрипт делает:
1. Снапшот `/etc/x-ui/x-ui.db` (по SSH).
2. Через API панели — `POST /panel/api/inbounds/add` с заранее подготовленным JSON для L2/L3.
3. Перезапуск `x-ui restart`.
4. Проверка: с локального хоста `openssl s_client -connect <host>:8443 -servername <host>` — должен быть валидный TLS handshake.
5. Записывает в локальный `public/server-state.env` факт деплоя (timestamp, какие inbound id созданы) — чтобы скрипт «удалить L2/L3» знал что сносить.

### Обновление `public/install.sh`

Изменения в существующем скрипте:

1. **`generate_config()`** — генерирует новый формат с тремя outbound'ами + observatory + balancer + API inbound.
2. **Меню → «Полная установка»** — без изменений в UI, но под капотом теперь шаблон с balancer'ом.
3. **Меню → «Update»** — при обновлении конфига сохранять `config.json.bak`.
4. **Меню → «Diagnostics»** — добавить пункт «Состояние balancer'а»: `xray api statsquery --server=127.0.0.1:10085 | grep outbound`, плюс tail последних 20 строк `/var/log/xray/balancer.log`.
5. **Новая фича toggle** (custom install) — «Включить fallback (L2+L3)» yes/no. По умолчанию yes для нового деплоя. Для старых установок без L2/L3 на сервере — это noop (просто observatory ничего не найдёт и balancer пометит outbound'ы как dead, что **сломает интернет**). Поэтому проверка: **перед** обновлением клиента — убедиться что на сервере все три inbound'а живы.

### Обновление `public/README.md`

Перепиcать секции:
- **Архитектура** — добавить схему трёх слоёв + observatory.
- **Требования к серверу** — упомянуть что нужен 3x-ui и три inbound'а; ссылка на `server-install.sh`.
- **Диагностика** — добавить команды проверки balancer'а.
- **FAQ** — пункт «как понять что VPN свалился на запасной слой» → `tail -f /var/log/xray/balancer.log` или `xray api statsquery`.

### Прочее: `.gitignore` и `state.env`

- Убедиться что `public/state.env` и `public/server-state.env` в `.gitignore`.
- В коммитах **не должно быть** реального `<<SERVER_DOMAIN>>`, UUID, паролей, путей API панели.
- Сделать `grep -rE '<реальный домен>|<реальный UUID>|<IP сервера>' public/` перед коммитом — нулевой результат.

## После согласования

Когда Сид одобрит план и даст SSH-доступ к серверу + креды от 3x-ui — Claude:

1. Снапшоты (этапы 1-2): `x-ui.db` на сервере, `config.json` на роутере.
2. Пишет `server-install.sh` (этап 6) **локально, без выполнения** — даёт Сиду посмотреть.
3. Запускает `server-install.sh` с опцией только-снапшот → потом добавляет L2 → проверяет TLS снаружи → добавляет L3 → проверяет.
4. Обновляет шаблон конфига и `install.sh` (этап 7) в репо.
5. Раскатывает новый config на роутер с cron-rollback на 5 минут (этап 5).
6. Прогоняет 5 сценариев тестирования вместе с Сидом (этап 9). Каждый сценарий — сам Сид останавливает inbound в панели (`server-install.sh` тоже умеет), Claude замеряет время переключения.
7. Снимает cron-rollback, добавляет watchdog (этап 10), обновляет README (этап 8).
8. Перед коммитом — `grep`-проверка на отсутствие реального домена и UUID в репо.

L4 (AmneziaWG) — отдельной сессией, не сейчас.

---

## Telegram-watchdog (новый раздел)

### Что отслеживаем

1. **Переключение balancer'а** — `xray api bi vpn-balancer` показывает текущий выбранный outbound. При смене (`reality → grpc`, `grpc → ws`, и т.д.) — сообщение в TG.
2. **Полный отвал** — все три proxy-outbound'а dead → красный алерт.
3. **Xray-процесс умер** — `pgrep xray` пуст → критический алерт.
4. **Daily summary** в 23:59 — сколько переключений за день, какой outbound доминировал.

### Архитектура

- Скрипт `/usr/local/bin/xray-tg-watchdog.sh` на роутере.
- Запуск через cron каждую минуту.
- Состояние хранится в `/etc/xray-tg-state` (после ребута сохраняется — на overlay, не на tmpfs).
- Токен и chat_id хранятся в `/etc/xray-tg-creds` (chmod 600), не в основном скрипте.

### Маршрутизация запросов к Telegram API

api.telegram.org заблокирован в РФ. Чтобы curl с роутера достучался, **трафик watchdog'а должен идти через xray-balancer**, а не через WAN напрямую.

Способ: запускать curl с **explicit interface** = LAN адрес роутера, чтобы пакеты попали в TProxy. Альтернатива — `curl --proxy socks5://127.0.0.1:1080` если поднять socks-inbound в xray (тогда нужно править config.json — лишний шаг).

Решение по варианту **1** (выбрано): `curl --interface br-lan --retry 30 --retry-delay 60` — если в момент срабатывания все proxy мертвы, curl будет ретраить 30 минут. Когда что-нибудь оживёт — алерт уйдёт отложенно.

### Скрипт (черновик)

```sh
#!/bin/sh
# /usr/local/bin/xray-tg-watchdog.sh
. /etc/xray-tg-creds   # exports TG_TOKEN, TG_CHAT_ID

STATE=/etc/xray-tg-state
PREV=$(cat $STATE 2>/dev/null || echo INIT)

# 1. Process check
if ! pidof xray >/dev/null 2>&1; then
  NOW="XRAY_DEAD"
else
  # 2. Balancer current selection
  NOW=$(/usr/local/bin/xray api bi --server=127.0.0.1:10085 vpn-balancer 2>/dev/null \
    | awk '/Selects:/{getline; print $2}')
  [ -z "$NOW" ] && NOW="ALL_DEAD"
fi

if [ "$NOW" != "$PREV" ]; then
  case "$NOW" in
    XRAY_DEAD)  ICON="🛑"; TEXT="xray процесс умер";;
    ALL_DEAD)   ICON="🚨"; TEXT="ВСЕ proxy-outbound'ы dead — VPN не работает";;
    proxy-reality) ICON="✅"; TEXT="balancer выбрал L1 (Reality)";;
    proxy-ws)      ICON="🔄"; TEXT="balancer выбрал L2 (WS+TLS)";;
    proxy-grpc)    ICON="🔄"; TEXT="balancer выбрал L3 (gRPC+TLS)";;
    *)             ICON="❓"; TEXT="balancer: $NOW";;
  esac
  MSG="$ICON $TEXT
prev: $PREV
time: $(date '+%Y-%m-%d %H:%M:%S')"

  curl -sk --max-time 30 --retry 30 --retry-delay 60 --retry-connrefused \
    --interface br-lan \
    "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    -d "chat_id=$TG_CHAT_ID" \
    --data-urlencode "text=$MSG" >/dev/null 2>&1 &

  echo "$NOW" > $STATE
fi
```

`pidof` есть в OpenWrt (procps-ng). Если нет — заменить на `[ -d /proc/$(cat /var/run/xray.pid 2>/dev/null) ]`.

### Cron

```
* * * * * /usr/local/bin/xray-tg-watchdog.sh >/dev/null 2>&1
59 23 * * * /usr/local/bin/xray-tg-daily-summary.sh
```

### Daily summary

Отдельный скрипт `xray-tg-daily-summary.sh` парсит `/var/log/xray/access.log` за сегодня:

```sh
grep -oE 'proxy-[a-z]+' /var/log/xray/access.log \
  | sort | uniq -c | sort -rn
```

Шлёт в TG: `Сегодня (DATE): reality=N1, grpc=N2, ws=N3, переключений=K`.

### Что нужно от Сида (один раз)

1. Создать бота через `@BotFather` → получить TOKEN.
2. Написать боту `/start`.
3. Узнать свой chat_id через `@userinfobot` (отправить ему любое сообщение → ответит твоим id).
4. Положить в `/etc/xray-tg-creds` на роутере:
   ```
   export TG_TOKEN=123456:ABC...
   export TG_CHAT_ID=987654321
   ```

После этого `install.sh` подцепит и применит.

### Нюансы которые вылезли при первой установке (2026-05-11)

1. **api.telegram.org блокируется по SNI** провайдером. Прямой запрос (curl/wget с router'а через WAN) даёт `Operation not permitted` — это reset от DPI. **Решение:** ходить через xray http-inbound (см. ниже).

2. **На OpenWrt нет curl по умолчанию**. Стоит только `wget-nossl` (без HTTPS) и `uclient-fetch` (умеет HTTPS, но **не умеет CONNECT-туннель** к HTTPS через HTTP-proxy — критично для нашей схемы).
   - **`apk add curl` через online feeds не работает** — Fastly режет `downloads.openwrt.org` (та же причина что для setup в install.sh).
   - **Решение:** скачать вручную с локального ПК и поставить через `apk add --no-network --allow-untrusted`. Нужны 8 пакетов: `curl`, `libcurl4`, `libopenssl3`, `libmbedtls21`, `libnghttp2-14`, `libssh2-1`, `zlib`, `ca-bundle`. URL шаблон: `https://downloads.openwrt.org/releases/25.12.2/packages/aarch64_cortex-a53/{packages|base}/<name>-<ver>-r1.apk`.

3. **xray HTTP-inbound на 127.0.0.1:8118** нужен чтобы curl ходил через balancer. Добавлен в config.json и в шаблон. Простой `http` inbound, `timeout: 30`, без auth. `allowTransparent: true` — **не работает** с uclient-fetch (даёт connection timeout), оставлен дефолт.

4. **Routing для http-local**: ничего отдельного делать не надо — общие routing rules (geoip:ru → direct, balancerTag → VPN) корректно матчат запросы к api.telegram.org (149.154.166/24 не в RU/private/categories) и отправляют через balancer.

5. **Логика «алерт когда все proxy мертвы»**: curl с `--retry 10 --retry-delay 30 --retry-all-errors` — если все proxy в balancer мертвы, curl попробует 10 раз с интервалом 30с. Когда хоть один outbound оживёт — алерт уйдёт отложенно (~5 минут).

### Интеграция в `install.sh`

Новая feature-функция `feature_tg_watchdog_install()`:
- Спрашивает TOKEN и CHAT_ID (если нет в state).
- Заливает `xray-tg-watchdog.sh` и `xray-tg-daily-summary.sh` через scp.
- Создаёт `/etc/xray-tg-creds` с правильными правами.
- Прописывает cron-задачи.
- Toggle в custom install: «Включить TG-уведомления yes/no».

---

## Что фактически сделано (2026-05-11)

### Сервер `<<SERVER_DOMAIN>>` (через 3x-ui REST API)

- Снапшот: `/etc/x-ui/x-ui.db.bak-2026-05-11-1255`.
- Свежий LE-сертификат на основной домен выпущен через `acme.sh --issue --standalone --httpport 80 --server letsencrypt`.
- Установлен в `/root/cert/<<SERVER_DOMAIN>>/{fullchain.pem,privkey.pem}` через `acme.sh --install-cert ... --reloadcmd 'x-ui restart-xray'` — auto-renew через ежедневный cron acme.sh.
- L1 inbound id=1 на :443 (Reality+Vision, SNI=`www.apple.com`) — **не трогали**, остался как был.
- L2 inbound id=4 на :8443 — VLESS+WS+TLS, path `/ws`, тот же UUID что у L1, ALPN `http/1.1`, cert на основной домен.
- L3 inbound id=5 на :2053 — VLESS+gRPC+TLS, serviceName `grpc-<host>`, multiMode=true, тот же UUID, ALPN `h2`.
- Внешний TLS-handshake на L2 и L3: `Verify return code: 0 (ok)`.

### Роутер 192.168.2.1

- Снапшоты: `config.json.bak-2026-05-11-1321` и `config.json.bak-rollback`.
- Cron-rollback watchdog (`/tmp/xray-rollback-watchdog.sh`): спал 300с после деплоя, при отсутствии cancel-flag сделал бы проверку через 3 URL и откатил. Cancel-flag поставил, watchdog отработал чисто.
- Новый `config.json`:
  - `api` со `services: [StatsService, ObservatoryService, RoutingService]`.
  - `observatory` с `probeURL: https://www.gstatic.com/generate_204`, `probeInterval: 10s`.
  - Новый inbound `api-in` на 127.0.0.1:10085.
  - Три outbound'а: `proxy-reality`, `proxy-ws`, `proxy-grpc` (вместо одного `proxy`).
  - `routing.balancers: [{tag: "vpn-balancer", selector: ["proxy-"], strategy: leastPing}]`.
  - Последнее правило: `balancerTag: "vpn-balancer"` вместо `outboundTag: "proxy"`.
- Все прочие правила routing (direct/block/dns/whitelists/torrent-ports/QUIC-block) сохранены 1:1.

### Замеченные нюансы

- xray 26.3.27 ругается warning'ами что WS и gRPC deprecated в пользу XHTTP. Сейчас работает, через 1-2 года надо мигрировать.
- `xray api bi vpn-balancer` без флагов даёт только текущий выбор без ping-метрик. Метрики latency observatory хранит внутри и наружу не отдаёт.
- На OpenWrt нет `ss` и `pgrep` — приходится использовать `netstat -tlnp` и обходиться без них.
- 3x-ui SCP требует `-O` (legacy mode), потому что sftp-server не установлен.
- На сервере параллельно крутятся danted, ss-server, mtg, OpenVPN — **не касались**, работают независимо.
- **curl не установлен на роутере по умолчанию** — нужно ставить руками через локальный `.apk` (см. раздел про TG-watchdog выше).
- В config.json добавлен **четвёртый inbound** `http-local` на 127.0.0.1:8118 (HTTP-proxy для локальных скриптов на роутере, ходит через balancer → нужный outbound).

### Команды для Сида

```powershell
# Текущий выбор balancer'а
ssh root@192.168.2.1 "/usr/local/bin/xray api bi --server=127.0.0.1:10085 vpn-balancer"

# Распределение трафика по слоям с момента старта
ssh root@192.168.2.1 "grep -oE 'proxy-[a-z]+' /var/log/xray/access.log | sort | uniq -c"

# Логи xray
ssh root@192.168.2.1 "tail -f /var/log/xray/error.log"

# Откат к предыдущему конфигу если что
ssh root@192.168.2.1 "cp /usr/local/etc/xray/config.json.bak-rollback /usr/local/etc/xray/config.json && /etc/init.d/xray restart"
```

## Что осталось сделать в репо

1. Обновить `public/config.json.template` под новый формат (3 outbound + observatory + balancer + api).
2. Обновить `public/install.sh` — `generate_config()` под новый шаблон, диагностика balancer'а в Diagnostics-меню.
3. Написать `public/server-install.sh` — интерактивный, ходит на сервер по SSH+панель-API.
4. Обновить `public/README.md` — новая архитектура, новые команды, ссылка на EXTRA_CARE.
5. Написать TG-watchdog скрипты (`xray-tg-watchdog.sh`, `xray-tg-daily-summary.sh`) и интегрировать в `install.sh`.
6. Перед коммитом — `grep -ri '<реальный домен>\|<реальный UUID>\|<публичный ключ Reality>\|185\.241\.55\.130' public/` — должен быть пуст.
