#!/bin/sh
#
# xray-memguard.sh — превентивный рестарт xray при критически низкой свободной RAM.
#
# На AX3000T (239MB total) xray (Go) под нагрузкой раздувается до 100+MB и не
# отдаёт память ОС. GOMEMLIMIT в init.d сдерживает рост, но если запас всё равно
# уползает к нулю — лучше контролируемо рестартнуть xray (освобождает heap), чем
# дождаться memory-thrash → зависание ядра → hardware-watchdog ребут (31с).
#
# Запускается из cron каждую минуту:
#   * * * * * /usr/local/bin/xray-memguard.sh >/dev/null 2>&1
#
# Логика:
#   - MemAvailable < THRESHOLD_KB → рестарт xray, лог, TG-нотификация.
#   - Cooldown COOLDOWN_SEC между рестартами (чтобы не зациклиться, если рестарт
#     не помогает — тогда проблема не в xray, и спам рестартами только хуже).

THRESHOLD_KB=8000          # ниже этого свободной памяти — рестарт xray
COOLDOWN_SEC=600           # не чаще раза в 10 минут
STAMP=/tmp/xray-memguard-last
CREDS=/etc/xray-tg-creds
LOG=/var/log/xray-memguard.log
PROXY=http://127.0.0.1:8118

avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
[ -z "$avail" ] && exit 0
[ "$avail" -ge "$THRESHOLD_KB" ] && exit 0

# cooldown
now=$(date +%s)
if [ -f "$STAMP" ]; then
  last=$(cat "$STAMP" 2>/dev/null || echo 0)
  [ $((now - last)) -lt "$COOLDOWN_SEC" ] && {
    echo "[$(date)] MemAvailable ${avail}KB < ${THRESHOLD_KB}KB, но cooldown активен — пропускаю" >> "$LOG"
    exit 0
  }
fi
echo "$now" > "$STAMP"

rss=$(awk '/VmRSS/{print $2}' /proc/$(cat /var/run/xray.pid 2>/dev/null)/status 2>/dev/null)
echo "[$(date)] MemAvailable ${avail}KB < ${THRESHOLD_KB}KB (xray RSS ${rss:-?}KB) — превентивный рестарт xray" >> "$LOG"
logger -t xray-memguard "low RAM (${avail}KB avail) — restarting xray"
/etc/init.d/xray restart

(
  sleep 25
  if [ -r "$CREDS" ]; then
    . "$CREDS"
    [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT_ID" ] && \
      curl -sk --max-time 30 --retry 5 --retry-delay 20 --proxy "$PROXY" \
        -d "chat_id=$TG_CHAT_ID" \
        --data-urlencode "text=♻️ xray-memguard: свободной RAM было ${avail}KB (xray RSS ${rss:-?}KB) — превентивно перезапустил xray, чтобы роутер не завис." \
        "https://api.telegram.org/bot$TG_TOKEN/sendMessage" >/dev/null 2>>"$LOG"
  fi
) &
