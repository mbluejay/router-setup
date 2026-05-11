# VLESS TProxy на Xiaomi AX3000T

Прозрачный VPN-роутер на Xiaomi Mi Router AX3000T с OpenWrt и xray-core.
Все устройства в сети автоматически пользуются VLESS без настройки.

## TL;DR

| Хост | Команда |
|---|---|
| Linux / macOS / Windows Git Bash | `./install.sh` |
| Windows PowerShell | `.\install.ps1` |

Запускать **на своём компьютере** — скрипт сам подключается к роутеру по SSH.
На роутер ничего копировать не нужно.

Скрипт — интерактивное меню. Есть пункты **Full install**, **Custom install**, **Update**, **Diagnostics**, **Uninstall**.

Требования: Xiaomi AX3000T с установленным OpenWrt 25.x, SSH-доступ с root, рабочая VLESS-ссылка от своего VPN-сервера.
Если OpenWrt ещё не стоит — сначала прошить его по инструкции [openwrt.org/toh/xiaomi/ax3000t](https://openwrt.org/toh/xiaomi/ax3000t).

## Что делает

- **Прозрачный прокси** через TProxy (nftables) — ничего не настраивать на клиентах
- **Multi-layer fallback (v2)**: три proxy-outbound'а на один сервер (Reality / WS+TLS / gRPC+TLS), xray Observatory мониторит каждый, balancer выбирает живой с минимальным ping'ом. Подробно — [EXTRA_CARE.md](EXTRA_CARE.md)
- **Split-routing**: российское напрямую, остальное через balancer
  - direct: `geoip:ru`, `geosite:category-ru`, `geosite:whitelist`, `geosite:steam`, `geosite:microsoft`, `geosite:apple`, торренты 6881–6889
  - block: `geosite:win-spy` (телеметрия Windows → blackhole)
  - proxy: всё остальное (через balancer)
- **Custom direct list**: команды `xray-add-direct <domain>` / `xray-remove-direct <domain>` — добавлять/удалять домены в обход VPN одной командой. Для сайтов, детектящих VPN по outbound IP (СБП-кассы, платёжные фингерпринт-сервисы)
- **Split-DNS**: DoH Cloudflare для проблемных доменов, Yandex для RU, 8.8.8.8 fallback через VPN
- **WiFi**: только 5ГГц (2.4ГГц отключён)
- **Блокировка** Windows-телеметрии (win-spy → blackhole)
- **DNS-хайджек**: принудительно заворачивает DNS всех клиентов в локальный dnsmasq (фикс Xbox/PS5/Chromecast)
- **IPv6 отключён** — нет Happy Eyeballs-задержек и IPv6-утечек
- Авто-обновление geo-баз раз в неделю, ротация логов ежечасно
- **(опционально) TG-watchdog**: бот в Telegram отчитывается о переключениях balancer'а и полном отвале VPN. См. EXTRA_CARE.md
- **(опционально) zram-swap**: 128MB сжатого swap в RAM (lzo-rle ~2x) — запас памяти на роутере с 256MB total. Защищает от OOM-kill xray при пиковом расходе.
- **OOM-protection**: xray получает `oom_score_adj=-500` через init.d — при OOM убивается последним, не первым.

Подробности — в [vless-tproxy-openwrt-ax3000t.md](vless-tproxy-openwrt-ax3000t.md).

## Меню установщика

```
═══════════════════════════════════════
  Xiaomi AX3000T · VLESS TProxy Setup
═══════════════════════════════════════
Router:   192.168.1.1
OpenWrt:  25.12.2
xray:     not installed

 1)  Connect to router / change IP
 2)  Full install
 3)  Custom install
 4)  Update
 5)  Diagnostics
 6)  Uninstall
 0)  Exit
```

**Full install** — все фичи включены, одним проходом.

**Custom install** — выбрать какие фичи нужны:

```
 [x] 1) Core xray + TProxy + Split-DNS          (обязательно)
 [x] 2) WiFi 5GHz-only (disable 2.4GHz)
 [x] 3) IPv6 disable on LAN
 [x] 4) DNS hijack (Xbox/PS5 fix)
 [x] 5) Log rotation
 [x] 6) Cloudflare DoH для x.com/twitter/themoviedb/...
 [x] 7) QUIC block (UDP:443 → drop, глобальный)
 [ ] 8) Telegram watchdog (нужны TG_TOKEN и chat_id)
 [x] z) zram-swap (compressed RAM ~128M)
```

**Update** — меняет VLESS-ссылку, обновляет geo-базы, переливает свежие версии скриптов. Идемпотентно — не трогает то что уже актуально.

Если нужно поменять только VLESS-ссылку без полного переустановщика — есть `update-vless.sh`:

```
./update-vless.sh
```

Спросит IP роутера и новую VLESS-ссылку, распарсит, покажет параметры, зальёт конфиг и применит.

**Diagnostics** — статус xray, тест конфига, live access.log, DNS-проверки, полный audit, состояние balancer'а (`xray api bi vpn-balancer`), распределение трафика по слоям (reality/ws/grpc).

**Uninstall** — откатывает xray-установку к состоянию до запуска скрипта.
Установщик сохраняет снэпшот `uci` конфигурации до правок (dnsmasq, network, odhcpd) — откат возвращает их в исходное состояние.
WiFi и LAN IP по умолчанию не трогает (они меняют сетевую топологию, откат без подтверждения опасен).

## Ручной путь (без скрипта)

Документ [vless-tproxy-openwrt-ax3000t.md](vless-tproxy-openwrt-ax3000t.md) описывает архитектуру, все команды и подводные камни. Можно поставить всё руками по нему, если не хочется скрипта.

Для Claude Code / агентных запусков — [vless-tproxy-openwrt-ax3000t.claude.xml](vless-tproxy-openwrt-ax3000t.claude.xml). Структурированный промпт с шагами, подводными камнями и параметрами для парсинга VLESS URL.

## Содержимое репозитория

| Файл | Назначение |
|---|---|
| `README.md` | Этот файл — обзор и точка входа |
| `vless-tproxy-openwrt-ax3000t.md` | Документация для человека — архитектура, диагностика, подводные камни |
| `vless-tproxy-openwrt-ax3000t.claude.xml` | То же для Claude Code — структурированный XML-промпт |
| `install.sh` | Интерактивный установщик клиентской части (bash, Linux/macOS/Git Bash) |
| `install.ps1` | Интерактивный установщик (PowerShell, Windows) |
| `server-install.sh` | Интерактивный установщик **серверной** части (L2/L3 inbound + LE-cert) через 3x-ui API |
| `EXTRA_CARE.md` | Архитектура multi-layer fallback, что фактически сделано, что осталось |
| `config.json.template` | Шаблон конфига xray v2 (3 outbound + observatory + balancer) |
| `proxy-only.json.template` | Шаблон временного HTTP proxy для bootstrap |
| `xray-init` | init.d сервис procd + OOM-protection (`oom_score_adj=-500`) |
| `xray-tproxy-setup.sh` | nftables TProxy + ip rules + DNS hijack |
| `zram-swap-init` | init.d zram-swap (128M lzo-rle compressed RAM) |
| `xray-tg-watchdog.sh` | TG-уведомления при смене balancer'а (rate-limit 5 мин) |
| `xray-tg-daily-summary.sh` | TG-отчёт раз в день в 23:59 |
| `xray-geo-update.sh` | Обновление geo-баз (cron еженедельно) |
| `xray-log-truncate.sh` | Обрезка access.log (cron ежечасно) |
| `xray-add-direct` | CLI на роутере: добавить домен в белый список (direct) |
| `xray-remove-direct` | CLI на роутере: удалить домен из белого списка |
| `custom-direct.list` | Seed-список кастомных direct-доменов (`tpass.me` как пример) |
| `update-vless.sh` | Замена VLESS-ссылки без полной переустановки |
| `xray-quic-toggle` | Включить/выключить глобальный QUIC-блок (UDP:443) на роутере |
| `add-direct.sh` / `add-direct.ps1` | Клиентские обёртки — одна команда с ноутбука |
| `remove-direct.sh` / `remove-direct.ps1` | Симметрично, удаление |
| `bin/xray` | Бинарник xray для OpenWrt arm64 |

## Geo-базы

- **geoip.dat** — v2fly: `https://github.com/v2fly/geoip/releases/latest/download/geoip.dat`
- **geosite.dat** — roscomvpn-geosite: `https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat`

Второй содержит специфичные для РФ категории: `whitelist`, `category-ru`, `steam`, `microsoft`, `apple`, `win-spy`.

## Отказоустойчивость

- xray автостарт при загрузке (init.d, START=99)
- При краше — автоперезапуск через procd
- **OOM-protection**: xray `oom_score_adj=-500` — убивается последним
- **zram-swap** START=10 — активен раньше xray, даёт +60-70MB compressed memory
- **Multi-layer fallback**: при отвале одного outbound balancer мгновенно выбирает живой (см. EXTRA_CARE.md)
- **TG-watchdog**: rate-limit 5 мин на шумные переходы, мгновенно на критичные
- ip rules восстанавливаются через hotplug при перезапуске сети
- `/var/log/xray/` пересоздаётся при каждом старте (tmpfs)
- DNS работает даже если xray ещё не поднялся — fallback на Yandex DNS
- Логи обрезаются ежечасно — tmpfs не забивается

## Лицензия и авторство

Проверено на OpenWrt 25.12.2 + xray 26.3.27, апрель 2026. Делал для себя, заработает у любого с той же моделью роутера.
