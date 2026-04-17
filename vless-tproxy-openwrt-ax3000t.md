# Инструкция для Claude Code: VLESS TProxy на Xiaomi AX3000T (OpenWrt 25.12.2)

> **Как использовать этот файл**: передай его Claude Code как промпт или контекстный файл. Claude запросит все нужные параметры, установит и настроит роутер полностью автоматически. Файл содержит исчерпывающие инструкции, все известные подводные камни и команды восстановления.

---

## A. Инструкция для Claude Code

### Среда выполнения

- **ОС хоста**: Windows 10 (или совместимая)
- **Рабочая директория**: `%USERPROFILE%\router-setup\` (все локальные файлы здесь)
- **Роутер**: Xiaomi AX3000T, OpenWrt 25.12.2, архитектура `aarch64_cortex-a53`
- **Пакетный менеджер на роутере**: `apk` (Alpine Package Keeper, **НЕ opkg**)
- **SSH**: `root@<<ROUTER_IP>>`, пароль `<<ROOT_PASSWORD>>`

### Определение доступного shell (выполни в самом начале)

```powershell
where bash
wsl --status 2>$null
where ssh
```

**Приоритет:**
1. **Git Bash** (`bash`) — предпочтительно, поддерживает heredoc и unix-синтаксис
2. **WSL** — тоже подходит
3. **PowerShell** — крайний случай: heredoc не работает, файлы на роутер передавать через `scp`

Если нет ни Git Bash, ни WSL — сообщи пользователю и попроси установить [Git for Windows](https://git-scm.com/download/win).

### Обязательные флаги и особенности

- **SCP всегда с флагом `-O`**: dropbear SSH на OpenWrt не поддерживает SFTP
  ```bash
  scp -O -o StrictHostKeyChecking=no file root@<<ROUTER_IP>>:/path/
  ```
- **SSH_ASKPASS для автоматической аутентификации** (Git Bash):
  ```bash
  # Создать файл askpass.sh:
  echo '#!/bin/sh' > "$USERPROFILE/router-setup/askpass.sh"
  echo 'echo "<<ROOT_PASSWORD>>"' >> "$USERPROFILE/router-setup/askpass.sh"
  chmod +x "$USERPROFILE/router-setup/askpass.sh"
  # Использовать:
  SSH_ASKPASS="$USERPROFILE/router-setup/askpass.sh" DISPLAY=1 SSH_ASKPASS_REQUIRE=force ssh root@<<ROUTER_IP>> "команда"
  ```
- **LF-переносы строк** для всех файлов на роутер (sh-скрипты, JSON). В PowerShell:
  ```powershell
  [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
  ```
- **Переменная окружения для geo-баз**:
  ```bash
  XRAY_LOCATION_ASSET=/usr/local/etc/xray /usr/local/bin/xray run -c /path/config.json
  ```

### Правила безопасной работы

- Перед каждой деструктивной операцией (смена IP роутера, перезагрузка, изменение WiFi) — предупреди пользователя, что соединение может оборваться
- После смены LAN IP — напомни пользователю поменять IP на сетевом адаптере ноутбука
- Если SSH не отвечает — останови работу и диагностируй причину, не продолжай вслепую
- Перед каждым `scp` убедись что директория назначения существует (`mkdir -p`)

---

## B. Шаг 0: Сбор параметров

### Запроси у пользователя

1. **VLESS-ссылку** в формате:
   ```
   vless://UUID@SERVER:PORT?security=reality&pbk=PUBKEY&sni=SNI&fp=chrome&flow=xtls-rprx-vision#NAME
   ```
   (или ws+tls, grpc — парсинг ниже)

2. **IP роутера** (по умолчанию `192.168.1.1`, может быть другим)

3. **Root-пароль** роутера (может быть пустым на factory reset)

4. **Имя WiFi сети (SSID)** для 5GHz точки доступа

5. **Пароль WiFi** (минимум 8 символов)

6. **IP ноутбука в LAN** (нужен для настройки статического адреса после смены IP роутера; по умолчанию предложи `<<ROUTER_LAN_PREFIX>>.100`)

### Парсинг VLESS-ссылки

```
vless://[UUID]@[SERVER]:[PORT]?security=[SEC]&pbk=[PUBKEY]&sni=[SNI]&fp=[FP]&flow=[FLOW]&sid=[SID]&type=[TYPE]&path=[PATH]&host=[HOST]#[NAME]
```

| Переменная | Откуда брать | Пример |
|---|---|---|
| `VLESS_UUID` | часть до `@` после `vless://` | `c37c79cc-...` |
| `VLESS_SERVER` | хост после `@` до `:` | `1.2.3.4` |
| `VLESS_PORT` | число после `:` до `?` | `443` |
| `VLESS_SECURITY` | параметр `security` | `reality` / `tls` / `none` |
| `VLESS_PBKEY` | параметр `pbk` (только для reality) | |
| `VLESS_SNI` | параметр `sni` | `www.apple.com` |
| `VLESS_FP` | параметр `fp` | `chrome` |
| `VLESS_FLOW` | параметр `flow` | `xtls-rprx-vision` |
| `VLESS_SID` | параметр `sid` (может отсутствовать → `""`) | `ad35aa15` |
| `VLESS_TRANSPORT` | параметр `type` (по умолчанию `tcp`) | `tcp` / `ws` / `grpc` |
| `VLESS_PATH` | параметр `path` (для ws/grpc) | `/ws` |
| `VLESS_HOST` | параметр `host` (для ws) | `example.com` |

**После парсинга** — выведи все распознанные параметры в читаемом виде и **подожди подтверждения** от пользователя.

---

## C. Шаги установки

### Шаг 1: Проверка доступности роутера

```bash
ping -n 3 <<ROUTER_IP>>    # Windows
# или
ping -c 3 <<ROUTER_IP>>    # Linux/macOS/Git Bash

SSH_ASKPASS=... ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@<<ROUTER_IP>> \
  "uname -m && cat /etc/openwrt_release | head -3 && df -h / && free"
```

Ожидаемая архитектура: `aarch64_cortex-a53`
Ожидаемый OpenWrt: `25.x` или `24.x`

**Если SSH не отвечает** — остановись и сообщи пользователю:
- Проверить кабель (LAN-порт роутера, не WAN)
- Проверить IP (factory reset = `192.168.1.1`)
- Проверить брандмауэр Windows

### Шаг 2: Интернет на роутере

Нужен для скачивания пакетов. Варианты (спроси пользователя):

**Вариант A — кабель WAN от другого роутера/провайдера** (предпочтительно):
```bash
ssh root@<<ROUTER_IP>> "ping -c 3 8.8.8.8 && echo INTERNET_OK || echo NO_INTERNET"
```

**Вариант Б — WiFi WAN через телефон-хотспот**:
```bash
ssh root@<<ROUTER_IP>> << 'EOF'
uci set wireless.wwan_sta=wifi-iface
uci set wireless.wwan_sta.device=radio1      # radio1=5GHz; radio0=2.4GHz
uci set wireless.wwan_sta.mode=sta
uci set wireless.wwan_sta.ssid='<<HOTSPOT_SSID>>'
uci set wireless.wwan_sta.encryption=psk2
uci set wireless.wwan_sta.key='<<HOTSPOT_PASSWORD>>'
uci set wireless.wwan_sta.network=wwan
uci set wireless.radio1.disabled=0
uci set network.wwan=interface
uci set network.wwan.proto=dhcp
uci add_list firewall.@zone[1].network=wwan 2>/dev/null || true
uci commit wireless && uci commit network && uci commit firewall
wifi reload
sleep 25
ping -c 3 8.8.8.8 && echo INTERNET_OK || echo INTERNET_FAIL
EOF
```

> **Важно**: если WiFi WAN использует radio1 (5GHz), то до финальной настройки AP 5GHz не отключай radio1!

### Шаг 3: Временный xray HTTP proxy для установки пакетов

**Проблема**: `apk update` в России не работает без прокси — Fastly CDN (downloads.openwrt.org) заблокирован российскими провайдерами. Обычный wget также падает с SSL ошибкой (error 5) из-за busybox wget + mbedTLS.

**Решение**: поднять xray как HTTP proxy до установки пакетов.

1. Загрузить бинарник xray на роутер:
```bash
scp -O -o StrictHostKeyChecking=no bin/xray root@<<ROUTER_IP>>:/usr/local/bin/xray
ssh root@<<ROUTER_IP>> "chmod +x /usr/local/bin/xray && /usr/local/bin/xray version"
```

2. Создать минимальный конфиг HTTP proxy (заменить VLESS параметры):
```bash
# Сформировать proxy.json с реальными VLESS параметрами (streamSettings по типу транспорта)
# Загрузить на роутер:
scp -O proxy-only.json.template ... # после подстановки значений → /tmp/proxy.json
```

3. Запустить proxy и переключить репозитории на HTTP:
```bash
ssh root@<<ROUTER_IP>> << 'EOF'
/usr/local/bin/xray run -c /tmp/proxy.json > /tmp/xray-proxy.log 2>&1 &
sleep 4
# Проверить что proxy работает:
http_proxy=http://127.0.0.1:8118 wget -q --timeout=15 -O /dev/null http://example.com && echo PROXY_OK

# Переключить репо на HTTP (wget-nossl, который apk установит, не умеет HTTPS):
sed -i 's|https://|http://|g' /etc/apk/repositories.d/distfeeds.list
echo REPOS_HTTP
EOF
```

### Шаг 4: Установка пакетов

```bash
ssh root@<<ROUTER_IP>> << 'EOF'
export http_proxy=http://127.0.0.1:8118
apk update
apk add wget unzip kmod-tun ip-full nftables kmod-nft-tproxy kmod-nft-socket
# Восстановить HTTPS для репо:
sed -i 's|http://downloads|https://downloads|g' /etc/apk/repositories.d/distfeeds.list
echo PACKAGES_OK
EOF
```

> **Почему `wget-nossl`**: apk устанавливает `wget-nossl` как зависимость, заменяя busybox wget. Новый wget не поддерживает HTTPS (no-ssl = no-ssl), поэтому репо должны быть на HTTP во время `apk add`. После установки можно вернуть HTTPS.

### Шаг 5: Установка xray, скриптов, сервиса

#### 5а. Geo-базы и конфиг

```bash
ssh root@<<ROUTER_IP>> << 'EOF'
mkdir -p /usr/local/etc/xray /var/log/xray

# Скачать geo-базы (через proxy если нужно):
export http_proxy=http://127.0.0.1:8118
wget -q -O /usr/local/etc/xray/geoip.dat \
  https://github.com/v2fly/geoip/releases/latest/download/geoip.dat
wget -q -O /usr/local/etc/xray/geosite.dat \
  https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat
unset http_proxy

ls -lh /usr/local/etc/xray/*.dat
echo GEO_OK
EOF
```

Загрузить основной конфиг (сформировать из `config.json.template`):
```bash
# Подставить все <<PLACEHOLDER>> → сохранить с LF-переносами → загрузить:
scp -O -o StrictHostKeyChecking=no config.json root@<<ROUTER_IP>>:/usr/local/etc/xray/config.json
ssh root@<<ROUTER_IP>> "XRAY_LOCATION_ASSET=/usr/local/etc/xray /usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json && echo CONFIG_OK"
```

#### 5б. TProxy скрипт

```bash
scp -O -o StrictHostKeyChecking=no xray-tproxy-setup.sh root@<<ROUTER_IP>>:/usr/local/bin/xray-tproxy-setup.sh
ssh root@<<ROUTER_IP>> "chmod +x /usr/local/bin/xray-tproxy-setup.sh && echo TPROXY_SCRIPT_OK"
```

#### 5в. Init.d сервис (автозапуск)

```bash
scp -O -o StrictHostKeyChecking=no xray-init root@<<ROUTER_IP>>:/etc/init.d/xray
ssh root@<<ROUTER_IP>> "chmod +x /etc/init.d/xray && echo INIT_OK"
```

> **Критично**: `/etc/init.d/xray` должен содержать `mkdir -p /var/log/xray` в `start_service()` — `/var/log/` это tmpfs, стирается при каждой перезагрузке!

#### 5г. Скрипт обновления geo-баз

```bash
scp -O -o StrictHostKeyChecking=no xray-geo-update.sh root@<<ROUTER_IP>>:/usr/local/bin/xray-geo-update.sh
ssh root@<<ROUTER_IP>> "chmod +x /usr/local/bin/xray-geo-update.sh && echo GEO_UPDATE_OK"
```

#### 5д. Hotplug — восстановление ip rules при перезапуске сети

```bash
ssh root@<<ROUTER_IP>> << 'EOF'
mkdir -p /etc/hotplug.d/iface
cat > /etc/hotplug.d/iface/99-xray-tproxy << 'HOTPLUG'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
ip rule show | grep -q 'fwmark 0x1 lookup 100' || {
    ip rule add fwmark 1 lookup 100 2>/dev/null
    ip route show table 100 | grep -q 'local default' || \
        ip route add local default dev lo table 100 2>/dev/null
    logger -t xray-tproxy 'ip rules restored via hotplug'
}
HOTPLUG
chmod +x /etc/hotplug.d/iface/99-xray-tproxy
echo HOTPLUG_OK
EOF
```

#### 5е. Cron — еженедельное обновление geo-баз

```bash
ssh root@<<ROUTER_IP>> "(crontab -l 2>/dev/null | grep -v xray-geo-update; echo '0 4 * * 0 /usr/local/bin/xray-geo-update.sh') | crontab - && echo CRON_OK"
```

#### 5ж. Запуск сервиса

```bash
ssh root@<<ROUTER_IP>> << 'EOF'
# Остановить временный proxy xray:
pkill -f 'xray run -c /tmp/proxy' 2>/dev/null; sleep 1

# Запустить как постоянный сервис:
/etc/init.d/xray enable
/etc/init.d/xray start
sleep 4
/etc/init.d/xray status && echo SERVICE_OK || echo SERVICE_FAIL
EOF
```

### Шаг 6: Split DNS

**Зачем**: ISP блокирует 8.8.8.8 / 1.1.1.1. Российский DNS не резолвит заблокированные сайты (YouTube и т.д.). Решение: xray как DNS сервер с раздельной маршрутизацией.

**Архитектура**:
```
LAN клиент → dnsmasq :53 → xray :5300
                              ↓ routing:
               RU домены → Yandex DNS 77.88.8.8 (primary) / 77.88.8.1 (secondary) → direct
               Остальное  → 8.8.8.8 → proxy (через VPN)
```

```bash
ssh root@<<ROUTER_IP>> << 'EOF'
uci set dhcp.@dnsmasq[0].noresolv=1
uci delete dhcp.@dnsmasq[0].server 2>/dev/null
uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#5300"
uci add_list dhcp.@dnsmasq[0].server="77.88.8.8"   # fallback если xray ещё не стартовал
uci commit dhcp
/etc/init.d/dnsmasq restart
echo DNS_OK
EOF
```

Проверка DNS:
```bash
ssh root@<<ROUTER_IP>> "nslookup youtube.com 127.0.0.1 && nslookup yandex.ru 127.0.0.1"
# youtube.com → должен вернуть реальный IP (142.251.x.x)
# yandex.ru   → должен вернуть 77.88.x.x
```

> **DNS в config.json**: конфиг должен содержать секцию `dns` с серверами Yandex и 8.8.8.8, inbound `dns-in` на порту 5300, outbound `dns` и routing rule `dns-in → dns-out`. Подробности в `config.json.template`.

### Шаг 7: WiFi — только 5GHz

```bash
ssh root@<<ROUTER_IP>> "uci set wireless.radio0.disabled=1"
# Отключить все VAP на radio0:
ssh root@<<ROUTER_IP>> "for iface in \$(uci show wireless | grep \"device='radio0'\" | cut -d. -f2); do uci set wireless.\${iface}.disabled=1; done"

ssh root@<<ROUTER_IP>> "uci set wireless.radio1.disabled=0"
ssh root@<<ROUTER_IP>> "uci set wireless.radio1.channel=auto"
ssh root@<<ROUTER_IP>> "uci set wireless.radio1.htmode=HE80"
ssh root@<<ROUTER_IP>> "uci set wireless.radio1.country=RU"
ssh root@<<ROUTER_IP>> "uci set wireless.radio1.txpower=30"
ssh root@<<ROUTER_IP>> "uci set wireless.default_radio1.mode=ap"
ssh root@<<ROUTER_IP>> "uci set wireless.default_radio1.ssid='<<WIFI_SSID>>'"
ssh root@<<ROUTER_IP>> "uci set wireless.default_radio1.encryption=psk2+ccmp"
ssh root@<<ROUTER_IP>> "uci set wireless.default_radio1.key='<<WIFI_PASSWORD>>'"
ssh root@<<ROUTER_IP>> "uci set wireless.default_radio1.disabled=0"
ssh root@<<ROUTER_IP>> "uci set wireless.default_radio1.ieee80211r=0"
ssh root@<<ROUTER_IP>> "uci commit wireless && wifi down && sleep 2 && wifi up && echo WIFI_OK"
```

### Шаг 8: Смена LAN IP (если нужно)

По умолчанию роутер на `192.168.1.1`. Если нужен другой IP (например, `192.168.2.1` чтобы не конфликтовать с корневым роутером):

**Предупреди пользователя**: SSH-соединение оборвётся! После этого нужно поменять IP на сетевом адаптере ноутбука.

```bash
ssh root@<<ROUTER_IP>> "
uci set network.lan.ipaddr='<<NEW_LAN_IP>>'
uci set network.lan.netmask='255.255.255.0'
uci commit network
echo LAN_IP_COMMITTED
(sleep 2 && /etc/init.d/network restart) &
"
# Далее:
# 1. Поменять IP адаптера ноутбука: статический <<NEW_LAN_PREFIX>>.100 / 255.255.255.0 / GW <<NEW_LAN_IP>>
# 2. ssh root@<<NEW_LAN_IP>>
```

### Шаг 9: Финальная проверка

```bash
ssh root@<<NEW_LAN_IP>> "
echo '=== xray ===' && /etc/init.d/xray status
echo '=== config ===' && XRAY_LOCATION_ASSET=/usr/local/etc/xray /usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json 2>&1 | tail -2
echo '=== nft ===' && nft list table inet xray_tproxy | head -15
echo '=== ip rules ===' && ip rule show | grep fwmark
echo '=== ip route ===' && ip route show table 100
echo '=== ports ===' && netstat -ulnp | grep -E '5300|12345'
echo '=== dns youtube ===' && nslookup youtube.com 127.0.0.1 2>&1 | grep -v '^$'
echo '=== dns yandex ===' && nslookup yandex.ru 127.0.0.1 2>&1 | grep -v '^$'
echo '=== dnsmasq ===' && uci show dhcp | grep server
echo '=== wifi ===' && uci show wireless | grep -E '(disabled|ssid)'
echo '=== geo ===' && ls -lh /usr/local/etc/xray/*.dat
echo '=== cron ===' && crontab -l
echo '=== hotplug ===' && ls /etc/hotplug.d/iface/99-xray-tproxy
echo '=== error log ===' && tail -5 /var/log/xray/error.log 2>/dev/null || echo log_empty
"
```

**Ожидаемые результаты**:
- xray: `running`
- config: `Configuration OK`
- nft: таблица `xray_tproxy` с 7+ правилами
- ip rules: строка с `fwmark 0x1 lookup 100`
- ip route: `local default dev lo`
- ports: xray слушает 5300 и 12345 (UDP+TCP)
- dns youtube: реальный IP (142.251.x.x), не 0.0.0.0 и не REFUSED
- dns yandex: 77.88.x.x
- dnsmasq: `127.0.0.1#5300` и `77.88.8.8`
- wifi: radio0.disabled=1, radio1.disabled=0, ssid=твой SSID
- geo: geoip.dat (>20M), geosite.dat (>50K) — оба ненулевые
- cron: `0 4 * * 0 /usr/local/bin/xray-geo-update.sh`
- hotplug: файл существует
- error log: только строка `Xray X.X.X started`, никаких ERROR

---

## D. Аудит и отказоустойчивость

Выполни этот раздел когда пользователь говорит "проверь всё", "проведи аудит", "убедись что всё работает".

### Полный аудит одной командой

```bash
ssh root@<<ROUTER_IP>> "
echo '=== [1] XRAY STATUS ===' && /etc/init.d/xray status
echo '=== [2] CONFIG TEST ===' && XRAY_LOCATION_ASSET=/usr/local/etc/xray /usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json 2>&1 | grep -E 'OK|Error|Warning'
echo '=== [3] NFT TPROXY ===' && nft list table inet xray_tproxy 2>/dev/null || echo 'TABLE MISSING!'
echo '=== [4] IP RULES ===' && ip rule show | grep -E 'fwmark|lookup 100' || echo 'IP RULES MISSING!'
echo '=== [5] IP ROUTE TABLE 100 ===' && ip route show table 100 || echo 'ROUTE MISSING!'
echo '=== [6] PORTS ===' && netstat -ulnp 2>/dev/null | grep -E '5300|12345'; netstat -tlnp 2>/dev/null | grep -E '5300|12345'
echo '=== [7] DNS YOUTUBE ===' && nslookup youtube.com 127.0.0.1 2>&1 | grep -E 'Address|Name|error'
echo '=== [8] DNS YANDEX ===' && nslookup yandex.ru 127.0.0.1 2>&1 | grep -E 'Address|Name|error'
echo '=== [9] DNSMASQ CONFIG ===' && uci show dhcp | grep -E 'server|noresolv'
echo '=== [10] HOTPLUG ===' && ls -la /etc/hotplug.d/iface/99-xray-tproxy 2>/dev/null || echo 'HOTPLUG MISSING!'
echo '=== [11] CRON ===' && crontab -l 2>/dev/null || echo 'NO CRON'
echo '=== [12] GEO FILES ===' && ls -lh /usr/local/etc/xray/*.dat
echo '=== [13] WIFI ===' && uci show wireless | grep -E '(radio[01]\.disabled|default_radio1\.ssid)'
echo '=== [14] INIT.D ===' && grep -E 'mkdir|respawn|XRAY_LOCATION' /etc/init.d/xray
echo '=== [15] ERROR LOG ===' && tail -10 /var/log/xray/error.log 2>/dev/null || echo log_empty
"
```

### Матрица отказоустойчивости

| # | Угроза | Защита | Проверка |
|---|---|---|---|
| 1 | Reboot → `/var/log/xray/` пропадает (tmpfs) | `mkdir -p /var/log/xray` в init.d `start_service()` | `grep mkdir /etc/init.d/xray` |
| 2 | Reboot → ip rules/routes сброшены | hotplug `/etc/hotplug.d/iface/99-xray-tproxy` | файл существует и содержит `ip rule add` |
| 3 | `network restart` → ip rules сброшены | тот же hotplug (срабатывает на `ACTION=ifup`) | idem |
| 4 | xray упал/завис | `procd_set_param respawn` (5 попыток, порог 3600s) | `grep respawn /etc/init.d/xray` |
| 5 | Geo-базы устарели, сайты неверно маршрутизируются | cron каждое вс в 4:00 | `crontab -l` |
| 6 | Yandex DNS недоступен | xray fallback на 8.8.8.8 (следующий сервер в списке) | автоматически |
| 7 | DNS REFUSED при boot (xray ещё не стартовал, START=99) | fallback `77.88.8.8` в dnsmasq | `uci show dhcp \| grep server` |
| 8 | Routing loop (xray пакет снова перехвачен TProxy) | `sockopt: mark=255` на всех outbound; правило `mark=0xff → accept` в nftables | `grep mark /etc/init.d/xray`; `nft list ruleset` |
| 9 | DHCP/broadcast заблокирован TProxy | правила `ip daddr 255.255.255.255 accept` и `udp dport {67,68} accept` | `nft list table inet xray_tproxy` |

### Команды восстановления

```bash
# Экстренный откат TProxy (если пропал интернет у клиентов):
ssh root@<<ROUTER_IP>> "nft delete table inet xray_tproxy; ip rule del fwmark 1 lookup 100 2>/dev/null; ip route flush table 100"

# Восстановить TProxy без перезапуска xray:
ssh root@<<ROUTER_IP>> "/usr/local/bin/xray-tproxy-setup.sh"

# Полный перезапуск xray:
ssh root@<<ROUTER_IP>> "/etc/init.d/xray restart"

# Восстановить ip rules вручную (если hotplug не сработал):
ssh root@<<ROUTER_IP>> "ip rule add fwmark 1 lookup 100 2>/dev/null; ip route add local default dev lo table 100 2>/dev/null"

# DNS не работает (REFUSED): перезапустить dnsmasq:
ssh root@<<ROUTER_IP>> "/etc/init.d/dnsmasq restart"

# Принудительное обновление geo-баз:
ssh root@<<ROUTER_IP>> "/usr/local/bin/xray-geo-update.sh"

# Проверить текущий трафик (что проксируется):
ssh root@<<ROUTER_IP>> "tail -f /var/log/xray/access.log"

# Проверить ошибки xray:
ssh root@<<ROUTER_IP>> "tail -50 /var/log/xray/error.log"

# Перезапустить WiFi:
ssh root@<<ROUTER_IP>> "wifi down && sleep 2 && wifi up"

# Показать клиентов на 5GHz:
ssh root@<<ROUTER_IP>> "iw dev wlan1 station dump"
```

---

## E. Подводные камни

### 1. apk update падает с SSL ошибкой (error 5)

Fastly CDN (downloads.openwrt.org) заблокирован российскими провайдерами. Busybox wget падает с TLS ошибкой.

**Решение**: Шаг 3 — временный xray HTTP proxy + переключение репо на HTTP.

### 2. wget-nossl заменяет busybox wget в процессе apk add

`apk` устанавливает `wget-nossl` как зависимость, заменяя системный wget. `wget-nossl` не умеет HTTPS вообще.

**Решение**: переключить репо на HTTP *до* запуска `apk add` (см. Шаг 3).

### 3. ip rule/route сбрасываются при перезапуске сети

`ip rule` и `ip route table 100` — in-memory, не persistent.

**Решение**: hotplug `/etc/hotplug.d/iface/99-xray-tproxy` (Шаг 5д).

### 4. /var/log/ — tmpfs, очищается при перезагрузке

После reboot директория `/var/log/xray/` исчезает, xray не может писать логи и не стартует.

**Решение**: `mkdir -p /var/log/xray` в `start_service()` init.d.

### 5. nohup не установлен на OpenWrt

**Решение**: `command > /tmp/out.log 2>&1 &`

### 6. SCP требует флаг -O

dropbear SSH не поддерживает SFTP протокол.

**Решение**: всегда `scp -O file root@router:/path/`

### 7. TProxy перехватывает только PREROUTING (трафик от LAN клиентов)

Трафик самого роутера (wget, curl с роутерного CLI) не проксируется TProxy.

**Следствие**: `apk update` с роутера, `xray-geo-update.sh` (wget) идут напрямую, не через TProxy. Это нормально и ожидаемо.

### 8. Порядок правил в routing важен

```
1. dns-in → dns-out          (DNS запросы через xray DNS модуль)
2. block: win-spy             (первым, иначе может попасть в другое правило)
3. direct: geoip:private
4. direct: geoip:ru
5. direct: Valve IP ranges
6. direct: geosite:...
7. direct: ports 6881-6889
8. direct: udp 500,1701,4500
9. proxy: tcp,udp             (catch-all, последним)
```

### 9. SSH_ASKPASS без SSH_ASKPASS_REQUIRE=force

На Windows с Git Bash SSH может игнорировать SSH_ASKPASS если доступен TTY.

**Решение**: всегда добавлять `DISPLAY=1 SSH_ASKPASS_REQUIRE=force`.

### 10. DNS: dnsmasq без upstream → REFUSED

**Симптом**: `nslookup youtube.com` → REFUSED, ни один сайт не открывается.

**Причина**: dnsmasq без upstream серверов. ISP блокирует 8.8.8.8/1.1.1.1. Российский DNS не резолвит заблокированные сайты.

**Решение**: xray split DNS (Шаг 6). dnsmasq → xray :5300 → Yandex (RU домены) или 8.8.8.8 via proxy (остальное).

**Fallback**: `77.88.8.8` в dnsmasq для первых секунд boot (xray стартует позже dnsmasq).

---

## F. Диагностика

```bash
# Статус xray
ssh root@<<ROUTER_IP>> "/etc/init.d/xray status"

# Тест конфига без запуска
ssh root@<<ROUTER_IP>> "XRAY_LOCATION_ASSET=/usr/local/etc/xray /usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json"

# Живые логи доступа (что проксируется прямо сейчас)
ssh root@<<ROUTER_IP>> "tail -f /var/log/xray/access.log"

# Ошибки xray
ssh root@<<ROUTER_IP>> "tail -50 /var/log/xray/error.log"

# Активные nftables правила TProxy
ssh root@<<ROUTER_IP>> "nft list table inet xray_tproxy"

# Маршрутизация ip rules
ssh root@<<ROUTER_IP>> "ip rule show && ip route show table 100"

# DNS диагностика
ssh root@<<ROUTER_IP>> "nslookup youtube.com 127.0.0.1; nslookup yandex.ru 127.0.0.1; uci show dhcp | grep server"

# Что слушает xray
ssh root@<<ROUTER_IP>> "netstat -ulnp | grep xray; netstat -tlnp | grep xray"

# WiFi клиенты
ssh root@<<ROUTER_IP>> "iw dev wlan1 station dump"

# Версия xray
ssh root@<<ROUTER_IP>> "/usr/local/bin/xray version"

# Размер и дата geo-баз
ssh root@<<ROUTER_IP>> "ls -lh /usr/local/etc/xray/*.dat"

# Последнее обновление geo-баз (из cron)
ssh root@<<ROUTER_IP>> "cat /var/log/xray/geo-update.log 2>/dev/null || echo no_log"
```

---

## G. Ожидаемый итоговый результат

После успешной настройки:

- Роутер доступен по SSH на `<<NEW_LAN_IP>>`
- xray запущен как системный сервис, стартует автоматически при загрузке
- **Прозрачное проксирование** для всех LAN-клиентов (без настройки на каждом устройстве)
- **direct**: geoip:ru, geosite:category-ru, whitelist, steam, microsoft, apple, торренты 6881-6889, L2TP/IPsec
- **block**: geosite:win-spy (телеметрия Windows дропается в никуда)
- **proxy**: всё остальное → через VLESS
- **Split DNS**: российские домены → Yandex DNS (прямо), остальные → 8.8.8.8 (через VPN)
- Geo-базы обновляются автоматически каждое воскресенье в 4:00
- WiFi только на 5GHz, 2.4GHz полностью отключён
- ip rules восстанавливаются автоматически после перезапуска сети

---

*Проверено на OpenWrt 25.12.2, xray 26.3.27, апрель 2026*
