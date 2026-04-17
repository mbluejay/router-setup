# VLESS TProxy на Xiaomi AX3000T (OpenWrt 25.12.2)

Прозрачный прокси для обхода блокировок с умной маршрутизацией: российский трафик идёт напрямую, заблокированные сайты — через VLESS. Всё автоматически, без настройки на каждом устройстве.

---

## Как это работает

```
Устройства в сети (телефон, ноутбук, TV)
        ↓ обычный TCP/UDP
Роутер Xiaomi AX3000T (OpenWrt)
        ↓ nftables TProxy перехватывает весь трафик
xray-core (порт 12345)
        ↓ routing rules по geoip/geosite
  ┌─────────────────────────────────┐
  │ geoip:ru, geosite:category-ru,  │ → direct (напрямую)
  │ whitelist, steam, microsoft,    │
  │ apple, торренты 6881-6889       │
  ├─────────────────────────────────┤
  │ geosite:win-spy                 │ → block (телеметрия Windows дропается)
  ├─────────────────────────────────┤
  │ всё остальное                   │ → VLESS proxy (через VPN)
  └─────────────────────────────────┘
```

**DNS** тоже умный: российские домены резолвятся через Yandex DNS напрямую, заблокированные сайты — через 8.8.8.8 по VPN.

---

## Аппаратура

| Параметр | Значение |
|---|---|
| Роутер | Xiaomi Mi Router AX3000T |
| Архитектура | `aarch64_cortex-a53` (MediaTek MT7981B) |
| OpenWrt | 25.12.2 |
| Пакетный менеджер | `apk` (Alpine Package Keeper, **не opkg**) |
| xray-core | 26.x, linux/arm64 |

---

## Правила маршрутизации

| Трафик | Куда |
|---|---|
| Приватные IP (10.x, 172.16.x, 192.168.x, 127.x) | direct |
| geoip:ru (российские IP) | direct |
| geosite:category-ru, whitelist | direct |
| geosite:steam, microsoft, apple | direct |
| Порты 6881–6889 TCP+UDP (торренты) | direct |
| UDP 500, 1701, 4500 (L2TP/IPsec) | direct |
| Диапазоны IP Valve Corp (AS32590) | direct |
| geosite:win-spy (телеметрия Windows) | **block** |
| Всё остальное | **proxy → VLESS** |

---

## Что в этом репозитории

| Файл | Описание |
|---|---|
| `vless-tproxy-openwrt-ax3000t.md` | Главный файл — инструкция и промпт для Claude Code |
| `config.json.template` | Шаблон конфига xray с плейсхолдерами вместо реальных данных |
| `proxy-only.json.template` | Шаблон временного HTTP proxy (нужен для установки пакетов) |
| `xray-tproxy-setup.sh` | Скрипт настройки nftables TProxy и ip rules |
| `xray-init` | Сервис init.d для автозапуска xray через procd |
| `xray-geo-update.sh` | Скрипт еженедельного обновления geo-баз |
| `bin/xray` | Скомпилированный бинарник xray для OpenWrt arm64 |

---

## Как использовать

### Вариант 1 — с Claude Code (рекомендуется)

Передай файл `vless-tproxy-openwrt-ax3000t.md` как инструкцию:

```
claude --add-file vless-tproxy-openwrt-ax3000t.md
```

или скопируй содержимое в начало сессии Claude Code. Он запросит все нужные параметры и выполнит настройку сам.

### Вариант 2 — вручную

Следуй пошаговой инструкции в `vless-tproxy-openwrt-ax3000t.md`.

---

## Что нужно иметь заранее

1. **VLESS-ссылку** от своего VPN-сервера в формате:
   ```
   vless://UUID@SERVER:PORT?security=reality&pbk=PUBKEY&sni=SNI&fp=chrome&flow=xtls-rprx-vision#NAME
   ```
2. **Xiaomi AX3000T** с установленным OpenWrt 25.x
3. **Windows/Mac/Linux** с доступом к роутеру по кабелю (LAN-порт) или WiFi
4. **SSH** (обычно уже есть: `ssh root@192.168.1.1`)
5. **Интернет на роутере** — через WAN-кабель или временный WiFi WAN (см. инструкцию)

---

## Geo-базы

Используются кастомные geo-базы для корректной работы в российском интернете:

- **geoip.dat** — IP-базы: `https://github.com/v2fly/geoip/releases/latest/download/geoip.dat`
- **geosite.dat** — Домены (включая whitelist, category-ru, win-spy и др.): `https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat`

Базы обновляются автоматически каждое воскресенье в 4:00 через cron.

---

## Отказоустойчивость

- xray стартует автоматически при загрузке (init.d, START=99)
- При краше — автоперезапуск через procd (respawn)
- ip rules восстанавливаются через hotplug при перезапуске сети
- `/var/log/xray/` пересоздаётся при каждом старте (tmpfs)
- DNS работает даже если xray ещё не поднялся (fallback Yandex DNS)

---

*Проверено на OpenWrt 25.12.2, xray 26.3.27, апрель 2026*
