#!/bin/sh
#
# xray-tg-watchdog.sh — мониторит состояние xray balancer'а и шлёт уведомления в Telegram.
# Запускается через cron каждую минуту:
#   * * * * * /usr/local/bin/xray-tg-watchdog.sh >/dev/null 2>&1
#
# Креды лежат в /etc/xray-tg-creds (chmod 600):
#   export TG_TOKEN=123456:ABC...
#   export TG_CHAT_ID=987654321
#
# Состояние в /etc/xray-tg-state — после ребута сохраняется на overlay.
# При первом запуске после ребута будет сообщение типа "INIT → proxy-..."

CREDS=/etc/xray-tg-creds
STATE=/etc/xray-tg-state
LOG=/var/log/xray-tg-watchdog.log

if [ ! -r "$CREDS" ]; then
  echo "[$(date)] $CREDS not readable, exit" >> "$LOG"
  exit 1
fi
. "$CREDS"

PREV=$(cat "$STATE" 2>/dev/null || echo INIT)

# 1) xray process check (without pgrep — OpenWrt не всегда его имеет)
XRAY_PID=""
for pid_dir in /proc/[0-9]*; do
  [ -r "$pid_dir/comm" ] || continue
  if [ "$(cat "$pid_dir/comm" 2>/dev/null)" = "xray" ]; then
    XRAY_PID="${pid_dir##*/}"
    break
  fi
done

if [ -z "$XRAY_PID" ]; then
  NOW="XRAY_DEAD"
else
  # 2) balancer current selection
  NOW=$(/usr/local/bin/xray api bi --server=127.0.0.1:10085 vpn-balancer 2>/dev/null \
    | awk '/Selects:/{getline; print $2}')
  [ -z "$NOW" ] && NOW="ALL_DEAD"
fi

if [ "$NOW" = "$PREV" ]; then
  exit 0
fi

case "$NOW" in
  XRAY_DEAD)     ICON="🛑"; TEXT="xray процесс умер — VPN полностью не работает";;
  ALL_DEAD)      ICON="🚨"; TEXT="ВСЕ proxy-outbound dead — observatory не может найти живой";;
  proxy-reality) ICON="✅"; TEXT="balancer: L1 (Reality)";;
  proxy-ws)      ICON="🔄"; TEXT="balancer: L2 (WS+TLS)";;
  proxy-grpc)    ICON="🔄"; TEXT="balancer: L3 (gRPC+TLS)";;
  *)             ICON="❓"; TEXT="balancer выбрал: $NOW";;
esac

MSG="$ICON $TEXT
prev: $PREV
now:  $NOW
time: $(date '+%Y-%m-%d %H:%M:%S')"

# Запрос идёт через TProxy (без mark=255), чтобы api.telegram.org прошёл через VPN.
# Если все proxy мертвы — curl ретраит 30 раз по минуте; алерт уйдёт когда хоть один оживёт.
curl -sk --max-time 30 --retry 30 --retry-delay 60 --retry-connrefused \
  --interface br-lan \
  "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
  -d "chat_id=$TG_CHAT_ID" \
  --data-urlencode "text=$MSG" >/dev/null 2>&1 &

echo "[$(date)] state changed: $PREV -> $NOW" >> "$LOG"
echo "$NOW" > "$STATE"
