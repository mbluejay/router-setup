# VLESS TProxy на Xiaomi AX3000T (OpenWrt)

Прозрачный VPN-роутер на базе Xiaomi Mi Router AX3000T с OpenWrt 25.x и xray-core в режиме TProxy.
Все LAN-клиенты автоматически пользуются VLESS без настройки на устройствах.

## Что оно делает

- **Прозрачный прокси** через TProxy (nftables) — ничего настраивать на клиентах
- **Split-routing**: российские домены и IP идут напрямую, остальное — через VLESS
- **Split-DNS**: DoH Cloudflare для проблемных доменов, Yandex для RU-geosite, 8.8.8.8 fallback через VPN
- **WiFi**: только 5 ГГц (2.4 ГГц отключён навсегда)
- **Блокировка Windows-телеметрии** (`geosite:win-spy` → blackhole)
- **DNS-хайджек** внутри сети — принудительно заворачивает DNS-запросы клиентов в локальный dnsmasq (фикс для Xbox/PS5/Chromecast, которые игнорируют DHCP-DNS)
- **IPv6 на LAN отключён** — предотвращает Happy Eyeballs-задержки и утечки мимо TProxy
- **Geo-базы** обновляются автоматически раз в неделю
- **Ротация логов** — защита tmpfs от переполнения

## Правила маршрутизации

| Трафик | Куда |
|---|---|
| DNS-запросы | → локальный dnsmasq (перехватываются даже если клиент идёт мимо) |
| `geosite:win-spy` (Microsoft телеметрия) | **block** |
| Приватные IP (10/8, 172.16/12, 192.168/16, 127/8) | direct |
| `geoip:ru` | direct |
| Valve AS32590 (Steam CM-серверы) | direct |
| `geosite:whitelist`, `category-ru`, `steam`, `microsoft`, `apple` | direct |
| Порты 6881–6889 (BitTorrent) | direct |
| UDP 500/1701/4500 (L2TP/IPsec) | direct |
| UDP 443 к `rutracker.org`, `claude.ai`, `claude.com`, `anthropic.com` (QUIC) | block — браузер деградирует на TCP |
| Всё остальное | proxy (VLESS) |

## Требования

| Компонент | Что нужно |
|---|---|
| Роутер | Xiaomi Mi Router AX3000T, архитектура `aarch64_cortex-a53` |
| Прошивка | OpenWrt 25.x (24.x тоже работает) |
| Доступ | SSH с правами root |
| VLESS | Работающий сервер (VLESS+Reality TCP, либо WS+TLS, либо gRPC+TLS) |
| Управляющая машина | Windows 10+ (PowerShell) **или** Linux/macOS (bash), `ssh`/`scp` в PATH |

Если OpenWrt на роутере ещё нет — сначала прошиваем его. Инструкция вне этого документа:
[openwrt.org/toh/xiaomi/ax3000t](https://openwrt.org/toh/xiaomi/ax3000t).

## Быстрая установка

В папке `public/` есть интерактивные установщики. Подробнее — в [README.md](README.md).

```bash
# Linux / macOS / Windows Git Bash
./install.sh

# Windows PowerShell
.\install.ps1
```

Скрипт проведёт через подключение к роутеру, запросит параметры (VLESS-ссылка, WiFi SSID и т.д.) и установит всё нужное. Есть режимы **Full install**, **Custom install** (выбор фич), **Update**, **Diagnostics** и **Uninstall**.

Всё остальное в этом документе — **справочник** на случай если скрипт что-то делает не так или хочется понять что происходит под капотом.

---

## Что и куда ставится

```
/usr/local/bin/xray                      — бинарник xray
/usr/local/bin/xray-tproxy-setup.sh      — nftables + ip rules (запускается при старте)
/usr/local/bin/xray-geo-update.sh        — обновление geo-баз (cron)
/usr/local/bin/xray-log-truncate.sh      — обрезка access.log (cron)
/usr/local/bin/xray-add-direct           — CLI: добавить домен в обход VPN (direct)
/usr/local/bin/xray-remove-direct        — CLI: удалить домен из белого списка
/usr/local/etc/xray/config.json          — активный конфиг (регенерируется из шаблона)
/usr/local/etc/xray/config.json.template — шаблон конфига, источник базы
/usr/local/etc/xray/custom-direct.list   — список кастомных direct-доменов
/usr/local/etc/xray/geoip.dat            — база IP (v2fly)
/usr/local/etc/xray/geosite.dat          — база доменов (roscomvpn-geosite)
/etc/init.d/xray                         — сервис procd (START=99)
/etc/hotplug.d/iface/99-xray-tproxy      — восстановление ip rules при перезапуске сети
```

## Архитектура TProxy

```
LAN клиент → пакет TCP/UDP
    ↓
[nftables mangle prerouting, xray_tproxy]
    iifname br-lan → проверки:
    mark=0xff (пакет от xray)    → accept (не перехватываем)
    dst private IP                → accept
    dst broadcast / DHCP          → accept
    dport 53                      → accept (обрабатывается nat prerouting)
    иначе                         → tproxy to :12345, mark=1
    ↓
[nftables nat prerouting, dns_hijack]
    DNS пакет не на 192.168.2.1 → DNAT на 192.168.2.1:53 (dnsmasq)
    ↓
[ip rule: fwmark 1 → table 100]
[ip route table 100: local default dev lo]
    ↓
xray dokodemo-door :12345
    ↓
routing rules (geoip/geosite/port):
    win-spy                    → blackhole
    ru / private / Valve IPs   → freedom (mark=255, bypasses TProxy)
    whitelist / steam / ms / apple (по sniffing) → freedom
    6881-6889 / UDP 500-4500   → freedom
    rutracker/claude + udp 443 → blackhole (QUIC block)
    остальное                  → VLESS (mark=255)
    ↓
WAN interface → internet
```

**Ключевые моменты:**
- `mark=255` (0xff) на **всех** outbound xray предотвращает routing loop
- DNS обрабатывается отдельно: пропускается мимо TProxy, DNAT-ится в dnsmasq, оттуда на xray:5300 через dns-in
- Trafик самого роутера (wget, curl с CLI) НЕ перехватывается TProxy — PREROUTING ловит только LAN

## Split-DNS

```
LAN клиент → dnsmasq :53 → xray :5300
                              ↓ (первый match побеждает)
  DoH Cloudflare (приоритет):
    domain:x.com, twitter.com, t.co, twimg.com,
    themoviedb.org, tmdb.org                    → direct (HTTPS к 1.1.1.1 через VLESS)
  Yandex DNS:
    geosite:category-ru, whitelist,
    steam, microsoft, apple                     → direct (UDP к 77.88.8.8/8.1)
  8.8.8.8 fallback                              → proxy (через VLESS)
```

**Почему DoH для Cloudflare**: Google DNS через VPN-сервер отдаёт anycast-IP по местоположению VPN-сервера, а не клиента. Для некоторых сайтов (x.com, themoviedb.org) возвращается специализированный edge, который не обслуживает SNI корректно. Cloudflare DoH знает свою инфраструктуру и отдаёт работающий IP.

**Почему порядок важен**: `themoviedb.org` попадает в `geosite:whitelist`. Если Yandex-блок стоит выше — он выиграет матч, Yandex сам возвращает `127.0.0.1` для заблокированных в РФ доменов.

## Custom direct domains (белый список доменов)

Некоторые сайты детектируют VPN не по DNS, а по outbound IP — через fingerprint-API. Пример: `pally.info` (СБП-платежи) делает запрос к `veryfy.ai`, тот возвращает IP VLESS-сервера — сайт показывает «выключите VPN». Решение — маршрутизировать и сам сайт, и его fingerprint-сервис в `direct`.

Для таких случаев есть механизм: plain-text список доменов и CLI-утилита.

### Как добавить

```bash
ssh root@<router> "xray-add-direct pally.info"
ssh root@<router> "xray-add-direct veryfy.ai"
```

Или через клиентские обёртки (без необходимости запоминать IP роутера):

```bash
# Linux / macOS / Git Bash
./add-direct.sh pally.info

# Windows PowerShell
.\add-direct.ps1 pally.info
```

### Как удалить

```bash
ssh root@<router> "xray-remove-direct pally.info"
# или ./remove-direct.sh pally.info / .\remove-direct.ps1 pally.info
```

### Что происходит под капотом

- Домен попадает в `/usr/local/etc/xray/custom-direct.list` (plain text, один на строку, отсортирован, дедуп)
- Скрипт через `jq` инъектирует `"domain:X"` в `dns.servers[]` Yandex (77.88.8.8 / 77.88.8.1) и в direct-routing-rule
- `config.json` регенерируется из `config.json.template` + свежего списка, валидируется через `xray run -test`, xray перезапускается
- Шаблон остаётся неизменным — правки только в `custom-direct.list`

### Что НЕ делает

Не трогает IP-маршрутизацию (`geoip:ru`, Valve IP-ranges). Если сайт сидит на российском IP, он идёт direct и без добавления в этот список.

### Посмотреть текущий список

```bash
ssh root@<router> "cat /usr/local/etc/xray/custom-direct.list"
```

## Диагностика

```bash
# Статус сервиса
ssh root@<router> "/etc/init.d/xray status"

# Тест конфига
ssh root@<router> "XRAY_LOCATION_ASSET=/usr/local/etc/xray /usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json"

# Живые логи доступа (что проксируется прямо сейчас)
ssh root@<router> "tail -f /var/log/xray/access.log"

# Ошибки xray
ssh root@<router> "tail -50 /var/log/xray/error.log"

# Активные nftables правила
ssh root@<router> "nft list table inet xray_tproxy; nft list table inet dns_hijack"

# Маршрутизация
ssh root@<router> "ip rule show; ip route show table 100"

# DNS диагностика
ssh root@<router> "nslookup youtube.com 127.0.0.1"       # non-RU, через proxy
ssh root@<router> "nslookup yandex.ru 127.0.0.1"         # RU, через Yandex direct
ssh root@<router> "nslookup api.themoviedb.org 127.0.0.1" # Cloudflare, через DoH
ssh root@<router> "nslookup x.com 127.0.0.1"             # Cloudflare, через DoH

# Что слушает xray
ssh root@<router> "netstat -ulnp | grep xray; netstat -tlnp | grep xray"

# WiFi интерфейс и статистика клиентов (tx_failed = индикатор помех)
ssh root@<router> "iw dev"   # найти имя интерфейса (обычно phy1-ap0)
ssh root@<router> "iw dev phy1-ap0 station dump | grep -E 'Station|tx (retries|failed)|signal|expected'"

# Свежие DNS-запросы (видно перехватывает ли DNS-хайджек)
ssh root@<router> "cat /proc/net/nf_conntrack | grep 'dport=53'"
```

Полный аудит скрипт `install.sh/ps1` умеет через пункт меню **Diagnostics → Full audit report**.

## Подводные камни

### 1. apk update падает с SSL ошибкой

Fastly CDN (downloads.openwrt.org) заблокирован в РФ. Busybox wget + mbedTLS на OpenWrt 25.x падает с error 5.

**Решение**: временно поднять xray как HTTP proxy (до полной установки), переключить репозитории на HTTP, установить пакеты через proxy, вернуть HTTPS. Скрипт `install.sh` делает это автоматически на этапе bootstrap. Среди устанавливаемых пакетов — `jq` (нужен для `xray-add-direct`/`xray-remove-direct` — они манипулируют JSON-конфигом).

### 2. wget-nossl заменяет busybox wget

`apk add wget` устанавливает `wget-nossl` как зависимость, заменяя системный wget. Новый wget не умеет HTTPS.

**Решение**: переключить репо на HTTP **до** `apk add`. Скрипт это делает.

### 3. ip rule/route сбрасываются при перезапуске сети

`ip rule` и `ip route table 100` — in-memory, не persistent.

**Решение**: hotplug `/etc/hotplug.d/iface/99-xray-tproxy` восстанавливает правила на `ifup`.

### 4. /var/log/ — tmpfs, очищается при перезагрузке и может забиться

После reboot директория `/var/log/xray/` исчезает. Плюс tmpfs на AX3000T всего ~116 МБ, `access.log` растёт 5-8 МБ/час — за сутки активного использования забьёт.

**Решения:**
- `mkdir -p /var/log/xray` в `start_service()` init.d (решает проблему reboot)
- `xray-log-truncate.sh` в cron каждый час: если `access.log` > 10 МБ — оставляет последние 2000 строк

Скрипт использует `wc -c` потому что `stat -c%s` отсутствует в busybox. Безопасно работает с xray: `:> $LOG` → следующий write в offset 0 благодаря `O_APPEND` (без sparse-файла).

### 5. SCP требует флаг `-O`

dropbear SSH на OpenWrt не поддерживает SFTP. Всегда: `scp -O file root@router:/path/`.

### 6. TProxy перехватывает только PREROUTING

Трафик самого роутера (wget/curl с CLI) не проксируется. Это нормально — `xray-geo-update.sh` использует `--no-check-certificate` и выходит напрямую, не через VLESS.

### 7. Порядок правил в routing важен

```
1. dns-in → dns-out
2. block:  win-spy
3. direct: geoip:private
4. direct: geoip:ru
5. direct: Valve IP ranges
6. direct: geosite:whitelist, category-ru, steam, microsoft, apple
7. direct: ports 6881-6889
8. direct: udp 500,1701,4500
9. block:  rutracker.org / claude.ai / claude.com / anthropic.com udp 443
10. proxy: tcp,udp (catch-all)
```

`win-spy` первым — иначе может попасть в direct/proxy раньше. Catch-all proxy — последним.

### 8. DNS: dnsmasq без upstream → REFUSED

Без настроенных upstream-серверов dnsmasq возвращает REFUSED. Решение — xray split-DNS (см. архитектуру).

### 9. Cloudflare anycast через Google DNS даёт "не тот" edge

Для x.com, twitter.com и подобных — Google DNS через VLESS выдаёт edge из неподходящего пула (например Discord-range), SNI=x.com там работает криво → страница бесконечно грузится.

**Решение**: DoH-резолвер Cloudflare `https://1.1.1.1/dns-query` для этих доменов. Cloudflare сам знает какой IP валиден для каждого из своих сайтов.

### 10. DNS-фильтрация Yandex + параллельные запросы dnsmasq = sinkhole

Заблокированный в РФ домен (themoviedb.org и т.п.) возвращается как `127.0.0.1`:
- Yandex DNS сам фильтрует такие домены
- dnsmasq без `strictorder` опрашивает upstream параллельно и берёт первый ответ — Yandex отвечает `127.0.0.1` быстрее, чем DoH через VLESS

**Решение (три правки вместе):**
- DoH-блок первым в `dns.servers` xray (обходит geosite:whitelist матчинг)
- `strictorder=1` в dnsmasq (сначала xray, fallback только при молчании)
- Проблемные домены → в DoH-список

### 11. QUIC через VLESS ненадёжен для агрессивных CF-сайтов и long SSE-стримов

Два разных симптома, одна причина — VLESS Reality оптимизирован под TCP, UDP/QUIC через такой тоннель нестабилен:

- **rutracker.org** и другие сайты с Turnstile/WAF через QUIC (UDP:443) уходят в бесконечную загрузку → Connection timeout.
- **claude.ai / claude.com / api.anthropic.com** — длинные tool-result SSE-стримы срываются: `Tool result could not be submitted. The request may have expired or the connection was interrupted.` Браузер упорно тащит HTTP/3 (QUIC), который рвётся на дистанции.

**Решение**: в routing rules block для `domain:rutracker.org, domain:claude.ai, domain:claude.com, domain:anthropic.com + network:udp + port:443`. Браузер не получает ответ QUIC, деградирует на TCP/HTTP2, работает стабильно.

**Caveat**: xray не всегда успевает извлечь SNI из первого QUIC Initial-пакета — в access.log `-> block` записи могут не появляться, но страховка работает.

### 12. IPv6 Happy Eyeballs добавляет 300 мс к каждому новому домену

У клиентов ULA от `odhcpd`, DNS отдаёт AAAA. Браузер пробует IPv6 первым → у роутера нет IPv6 default route → таймаут → fallback на IPv4.

**Решение**: `filter_aaaa=1` в dnsmasq + `odhcpd` выключен + `ip6assign` удалён. LAN-клиенты не получают IPv6 и не узнают про него.

### 13. WiFi тормозит без видимых причин — помехи на канале

`iw dev <iface> station dump` показывает `tx retries` ≈ `tx failed` у всех клиентов (признак: 5–20% пакетов дропается на уровне WiFi). Роутер использует канал из верхнего диапазона (149, 153, 157…) — он популярен и перегружен в многоквартирных домах.

**Диагностика**:
```bash
iw dev phy1-ap0 station dump | grep -E 'Station|tx (retries|failed)'
# Тревожно: tx failed приближается к tx retries
```

**Решение**: сменить на канал из нижнего диапазона (36, 40, 44, 48 — без DFS, нет задержки при старте) или среднего (100–140 — DFS, ~60 с радарного скана при первом запуске, зато почти пустые).

```bash
uci set wireless.radio1.channel=36
uci commit wireless && wifi down && sleep 2 && wifi up
```

В `install.sh` → Custom install → клавиша **`c`** циклично переключает канал (auto → 36 → 100 → 149 → auto) до запуска установки.

### 14. Устройства игнорируют DHCP-DNS (Xbox, PS5, Chromecast)

Xbox шлёт DNS на зашитый в прошивку `111.88.96.50` мимо нашего split-DNS. Split-DNS для таких устройств не работает, они получают "как есть" от провайдера (часто с DPI-хайджеком).

**Решение**: DNAT `udp/tcp:53` от LAN к не-локальному IP → на `192.168.2.1:53`. Таблица `inet dns_hijack` в `nat prerouting` + `accept` для DNS в `xray_tproxy` mangle chain (чтобы DNAT успел сработать до TProxy).

**Важно**: правила DNAT **не применяются** к существующим conntrack-сессиям. После установки устройства со старыми UDP-сессиями продолжают слать туда же, пока сессии не истекут или устройство не перезагрузится.

### 15. IPv6-трафик обходит TProxy

TProxy перехватывает только IPv4. Если провайдер раздаёт глобальные IPv6-адреса на WAN и `odhcpd` транслирует префикс на LAN (SLAAC / DHCPv6-PD), клиенты получают глобальный IPv6 и ходят в интернет напрямую, минуя xray.

**Диагностика**: `ip -6 addr show br-lan` — есть ли адрес с префиксом не `fe80:` и не `fd00:`/`fc00:`.

**Решение**: использовать фичу **IPv6 disable** в установщике (включена по умолчанию) — она останавливает `odhcpd`, удаляет `ip6assign`, включает `filter_aaaa` в dnsmasq.

## Команды восстановления

```bash
# Экстренный откат TProxy (если пропал интернет у клиентов):
ssh root@<router> "nft delete table inet xray_tproxy; nft delete table inet dns_hijack; ip rule del fwmark 1 lookup 100 2>/dev/null; ip route flush table 100"

# Восстановить TProxy без перезапуска xray:
ssh root@<router> "/usr/local/bin/xray-tproxy-setup.sh"

# Полный перезапуск xray:
ssh root@<router> "/etc/init.d/xray restart"

# DNS не работает — перезапустить dnsmasq:
ssh root@<router> "/etc/init.d/dnsmasq restart"

# Принудительное обновление geo-баз:
ssh root@<router> "/usr/local/bin/xray-geo-update.sh"
```

## Обновление и удаление

Через меню скриптов:
- **Update** — обновляет geo-базы, свежие версии скриптов, ротирует логи, меняет VLESS-ссылку
- **Uninstall** — откатывает все изменения (xray + nftables + cron + dnsmasq + IPv6 + hotplug init.d) до состояния на момент установки (скрипт сохраняет снэпшот `uci show` до правок и использует его при откате)

WiFi и LAN IP uninstall по умолчанию **не трогает** — они меняют сетевую топологию, откат без подтверждения опасен.

## Опциональные улучшения

Эти изменения не входят в базовую установку, но могут быть полезны.

### Блокировка QUIC (UDP:443) для стабильного YouTube

VLESS Reality оптимизирован под TCP. HTTP/3 (QUIC) через такой тоннель нестабилен — буферизация, зависания. Заблокировать UDP:443 → браузеры деградируют на TCP/HTTP2:

```bash
ssh root@<router> "nft add rule inet xray_tproxy prerouting meta l4proto udp udp dport 443 drop"
```

Сделать persistent — добавить строку в `xray-tproxy-setup.sh`.

### Увеличить DNS-кеш dnsmasq

Дефолт 150 записей быстро вытесняется при активном браузинге. Поднять до 2000:

```bash
ssh root@<router> "uci set dhcp.@dnsmasq[0].cachesize=2000 && uci commit dhcp && /etc/init.d/dnsmasq restart"
```

### Мониторинг трафика (vnstat)

```bash
ssh root@<router> "apk add vnstat && vnstat -i wan --enable && /etc/init.d/vnstat enable && /etc/init.d/vnstat start"
# Статистика через сутки:
ssh root@<router> "vnstat -i wan -d"
```

## Проверено

- OpenWrt 25.12.2
- xray 26.3.27
- Апрель 2026
