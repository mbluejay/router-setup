#!/bin/sh
#
# xray-selfheal.sh — автовосстановление xray при сломанном конфиге.
#
# Проверяет, ходит ли интернет через xray-прокси (127.0.0.1:8118 → balancer → VPN).
# Если нет И активный конфиг отличается от заведомо рабочего (/root/xray-config.safe.json)
# — откатывает на .safe, рестартит xray, пишет в logread и шлёт уведомление в Telegram.
#
# Вызывается:
#   1) из /etc/init.d/xray фоновым хуком через ~50с после старта (ловит сломанный
#      конфиг при загрузке/ребуте — ребут сам себя чинит);
#   2) из cron каждые 2 минуты (ловит рантайм-деградацию):
#        */2 * * * * /usr/local/bin/xray-selfheal.sh >/dev/null 2>&1
#
# Защита от петли: если активный конфиг == .safe — выходим (откатывать не на что).
# При ISP-аутаже максимум один лишний рестарт, потом active==safe и тишина.
#
# Промоут нового конфига в «безопасный» (когда доказан рабочим):
#   cp /usr/local/etc/xray/config.json /root/xray-config.safe.json

SAFE=/root/xray-config.safe.json
ACTIVE=/usr/local/etc/xray/config.json
PROXY=http://127.0.0.1:8118
PROBE=https://www.gstatic.com/generate_204
CREDS=/etc/xray-tg-creds
LOG=/var/log/xray-selfheal.log

log() { echo "[$(date)] $1" >> "$LOG"; logger -t xray-selfheal "$1"; }

[ -f "$SAFE" ] || exit 0
# нечего откатывать — активный уже и есть безопасный
cmp -s "$ACTIVE" "$SAFE" && exit 0

# 3 попытки за ~25 секунд — переживаем кратковременный startup/restart window
ok=0
i=1
while [ "$i" -le 3 ]; do
  if curl -sf --max-time 12 --proxy "$PROXY" "$PROBE" >/dev/null 2>&1; then
    ok=1
    break
  fi
  i=$((i + 1))
  [ "$i" -le 3 ] && sleep 8
done
[ "$ok" = 1 ] && exit 0

log "VPN недоступен через $PROXY — откатываю $ACTIVE на $SAFE и рестартю xray"
cp "$SAFE" "$ACTIVE"
/etc/init.d/xray restart

# best-effort уведомление в Telegram (пойдёт уже через восстановленный конфиг)
(
  sleep 20
  if [ -r "$CREDS" ]; then
    . "$CREDS"
    [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT_ID" ] && \
      curl -sk --max-time 30 --retry 5 --retry-delay 20 --proxy "$PROXY" \
        -d "chat_id=$TG_CHAT_ID" \
        --data-urlencode "text=⚠️ xray-selfheal: активный config.json был сломан (VPN не отвечал), откатил на config.json.safe и перезапустил xray." \
        "https://api.telegram.org/bot$TG_TOKEN/sendMessage" >/dev/null 2>>"$LOG"
  fi
) &
