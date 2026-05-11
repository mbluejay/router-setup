#!/bin/sh
#
# xray-tg-daily-summary.sh — ежедневный отчёт в Telegram о работе fallback.
# Запускать через cron в 23:59:
#   59 23 * * * /usr/local/bin/xray-tg-daily-summary.sh >/dev/null 2>&1

CREDS=/etc/xray-tg-creds
[ -r "$CREDS" ] || exit 1
. "$CREDS"

LOG=/var/log/xray-tg-watchdog.log
ACCESS=/var/log/xray/access.log

TODAY=$(date '+%Y-%m-%d')

# Подсчёт коннектов по слоям (parser работает на любом awk)
COUNTS=$(grep -oE 'proxy-[a-z]+' "$ACCESS" 2>/dev/null | sort | uniq -c | sort -rn)
[ -z "$COUNTS" ] && COUNTS="(пусто — access.log не содержит proxy-* записей)"

# Переключения за сегодня (из watchdog-лога)
SWITCHES=$(grep "$TODAY" "$LOG" 2>/dev/null | grep -c "state changed" || echo 0)

# Текущий выбранный outbound
CURRENT=$(/usr/local/bin/xray api bi --server=127.0.0.1:10085 vpn-balancer 2>/dev/null \
  | awk '/Selects:/{getline; print $2}')
[ -z "$CURRENT" ] && CURRENT="неизвестно"

MSG="📊 Итог за $TODAY

Переключений balancer'а: $SWITCHES
Сейчас выбран: $CURRENT

Распределение коннектов (с момента старта xray):
$COUNTS"

curl -sk --max-time 30 --retry 5 --retry-delay 30 \
  --interface br-lan \
  "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
  -d "chat_id=$TG_CHAT_ID" \
  --data-urlencode "text=$MSG" >/dev/null 2>&1
