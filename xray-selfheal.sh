#!/bin/sh
#
# xray-selfheal.sh — end-to-end watchdog для xray.
#
# Каждые 2 минуты (через cron):
#   1. Пробует достучаться до интернета через xray-прокси 127.0.0.1:8118 →
#      внешний probe (gstatic/generate_204). Три попытки, ~25 секунд суммарно.
#   2. Если probe прошёл — ничего не делает, выходит.
#   3. Если probe провалился — превентивный рестарт xray (освобождает heap,
#      сбрасывает зависший runtime, переподнимает observatory).
#   4. Через 20 секунд probe ещё раз.
#   5. Если ок → TG-нотификация «auto-recovered after restart».
#   6. Если всё ещё мёртв И активный конфиг != /root/xray-config.safe.json →
#      откат на .safe + рестарт + нотификация.
#   7. Если всё ещё мёртв И конфиг уже == .safe → TG «не могу починить
#      автоматом, нужно вмешательство».
#
# Cooldown COOLDOWN_SEC между действиями (рестартами/откатами) — защита от
# зацикливания, если VPN-сервер реально лёг.
#
# Cron:
#   */2 * * * * /usr/local/bin/xray-selfheal.sh >/dev/null 2>&1
#
# Также вызывается из /etc/init.d/xray фоновым хуком через 50с после старта
# (ловит ситуацию «после ребута конфиг сломан, VPN не поднимается»).
#
# История: версия v1 (2026-05-12) реагировала только если active != safe —
# это оказалось бесполезным в реальной ситуации silent-failure (xray был
# запущен, выглядел «живым» для api, но трафик не ходил, 29 часов сидели
# без алертов до ручного ребута). Текущая версия v2 (2026-05-13) делает
# end-to-end curl-probe и рестартит безусловно.

SAFE=/root/xray-config.safe.json
ACTIVE=/usr/local/etc/xray/config.json
PROXY=http://127.0.0.1:8118
PROBE_URL=https://www.gstatic.com/generate_204
CREDS=/etc/xray-tg-creds
LOG=/var/log/xray-selfheal.log
COOLDOWN_SEC=900           # 15 минут между действиями
STAMP=/tmp/xray-selfheal-last-action

log() {
  echo "[$(date)] $1" >> "$LOG"
  logger -t xray-selfheal "$1"
}

probe() {
  # 3 попытки за ~25 секунд. Возвращает 0 если хотя бы одна успешна.
  i=1
  while [ "$i" -le 3 ]; do
    if curl -sf --max-time 12 --proxy "$PROXY" "$PROBE_URL" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    [ "$i" -le 3 ] && sleep 8
  done
  return 1
}

tg_notify() {
  msg="$1"
  (
    sleep 20  # дать xray время подняться после рестарта
    if [ -r "$CREDS" ]; then
      . "$CREDS"
      [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT_ID" ] && \
        curl -sk --max-time 30 --retry 8 --retry-delay 20 --retry-all-errors \
          --proxy "$PROXY" \
          -d "chat_id=$TG_CHAT_ID" \
          --data-urlencode "text=$msg" \
          "https://api.telegram.org/bot$TG_TOKEN/sendMessage" >/dev/null 2>>"$LOG"
    fi
  ) &
}

# === Шаг 1: probe ===
if probe; then
  exit 0
fi

# === Шаг 2: VPN мёртв — проверяем cooldown ===
now=$(date +%s)
if [ -f "$STAMP" ]; then
  last=$(cat "$STAMP" 2>/dev/null || echo 0)
  if [ $((now - last)) -lt "$COOLDOWN_SEC" ]; then
    log "VPN unreachable, но cooldown ($((now - last))s < ${COOLDOWN_SEC}s) — пропускаю"
    exit 0
  fi
fi
echo "$now" > "$STAMP"

# === Шаг 3: превентивный рестарт xray ===
log "VPN unreachable через $PROXY — рестартю xray (try 1: вернуть из зависшего состояния)"
/etc/init.d/xray restart
sleep 20

if probe; then
  log "✓ auto-recovered после рестарта xray"
  tg_notify "🛠️ xray-selfheal: VPN не отвечал, перезапустил xray — восстановилось. Без отката конфига."
  exit 0
fi

# === Шаг 4: рестарт не помог — если конфиг отличается от safe, откатываем ===
if [ -f "$SAFE" ] && ! cmp -s "$ACTIVE" "$SAFE"; then
  log "Рестарт не помог. Откатываю $ACTIVE на $SAFE"
  cp "$SAFE" "$ACTIVE"
  /etc/init.d/xray restart
  sleep 20
  if probe; then
    log "✓ восстановлено после отката на .safe"
    tg_notify "⚠️ xray-selfheal: xray restart не помог, откатил конфиг на /root/xray-config.safe.json — теперь работает."
    exit 0
  fi
  log "✗ даже после отката на .safe — не работает"
  tg_notify "🚨 xray-selfheal: рестарт + откат на .safe не помогли, VPN всё ещё мёртв. Нужно вмешательство."
  exit 1
fi

# === Шаг 5: конфиг и так safe, рестарт не помог ===
log "✗ рестарт не помог, конфиг уже == .safe — автоматом починить не могу"
tg_notify "🚨 xray-selfheal: VPN не отвечает, рестарт xray не помог, конфиг уже /root/xray-config.safe.json. Нужно ручное вмешательство (проверь сервер, ISP, RAM)."
exit 1
