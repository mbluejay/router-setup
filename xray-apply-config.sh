#!/bin/sh
#
# xray-apply-config.sh — безопасное применение нового config.json для xray.
#
# Что делает:
#   1. Валидирует новый конфиг (xray run -test).
#   2. Бэкапит текущий /usr/local/etc/xray/config.json.
#   3. Подменяет на новый, рестартит xray.
#   4. Взводит auto-rollback через cron (по умолчанию +5 минут): если
#      /tmp/xray-rollback-cancel НЕ создан к моменту срабатывания — конфиг
#      откатывается на бэкап и xray рестартится. Скрипт rollback'а лежит в
#      /root/ (не /tmp/!), переживает ребут.
#
# Использование:
#   xray-apply-config.sh <путь_к_новому_config.json> [tag] [rollback_min]
#     tag           — короткий идентификатор для логов/файлов (default: stamp)
#     rollback_min  — через сколько минут откат, если не подтвердишь (default: 5)
#
#   Подтвердить (отменить rollback):
#     touch /tmp/xray-rollback-cancel
#
#   Промоут конфига в «безопасный» после успешного теста:
#     cp /usr/local/etc/xray/config.json /root/xray-config.safe.json
#
# Связь с selfheal/memguard:
#   - selfheal сравнивает с /root/xray-config.safe.json — поэтому apply-config
#     НЕ трогает .safe (это делается вручную после подтверждения).
#   - memguard рестартит xray при низкой RAM — независимо.

set -e

NEW="$1"
TAG="${2:-stamp}"
ROLLBACK_MIN="${3:-5}"

if [ -z "$NEW" ] || [ ! -f "$NEW" ]; then
  echo "usage: $0 <new_config.json> [tag] [rollback_min]" >&2
  exit 2
fi

ACTIVE=/usr/local/etc/xray/config.json
BAK="${ACTIVE}.bak-${TAG}-$(date +%Y%m%d-%H%M%S)"
ROLLBACK_SCRIPT="/root/xray-rollback-${TAG}.sh"
CANCEL_FLAG=/tmp/xray-rollback-cancel

echo "→ Валидирую $NEW"
if ! XRAY_LOCATION_ASSET=/usr/local/etc/xray /usr/local/bin/xray run -test -c "$NEW" 2>&1 | tail -3 | grep -q 'Configuration OK'; then
  echo "✗ Новый конфиг невалиден. Не применяю." >&2
  exit 1
fi
echo "  OK"

echo "→ Бэкап текущего: $BAK"
cp "$ACTIVE" "$BAK"

echo "→ Подмена + рестарт xray (пауза ~10с без интернета у клиентов)"
cp "$NEW" "$ACTIVE"
/etc/init.d/xray restart
sleep 3
/etc/init.d/xray status 2>&1 | tail -1

echo "→ Готовлю auto-rollback (через $ROLLBACK_MIN минут, если не отменишь)"
rm -f "$CANCEL_FLAG"
cat > "$ROLLBACK_SCRIPT" <<EOF
#!/bin/sh
if [ -f $CANCEL_FLAG ]; then
    rm -f $CANCEL_FLAG
    logger -t xray-rollback "[$TAG] cancelled by user"
    rm -f $ROLLBACK_SCRIPT
    crontab -l 2>/dev/null | grep -v 'xray-rollback-${TAG}' | crontab -
    exit 0
fi
cp $BAK $ACTIVE
/etc/init.d/xray restart
logger -t xray-rollback "[$TAG] reverted to $BAK"
rm -f $ROLLBACK_SCRIPT
crontab -l 2>/dev/null | grep -v 'xray-rollback-${TAG}' | crontab -
EOF
chmod +x "$ROLLBACK_SCRIPT"

# Считаем время срабатывания
M=$(date '+%M'); H=$(date '+%H'); D=$(date '+%d'); MO=$(date '+%m')
NM=$(( (M + ROLLBACK_MIN) % 60 ))
NH=$H
[ $NM -lt $M ] && NH=$(( (H + 1) % 24 ))
LINE="$NM $NH $D $MO * $ROLLBACK_SCRIPT"

(crontab -l 2>/dev/null | grep -v "xray-rollback-${TAG}" ; echo "$LINE") | crontab -

cat <<EOF

═══════════════════════════════════════════════════════════════
  Конфиг применён: $NEW → $ACTIVE
  Бэкап:           $BAK
  Auto-rollback:   $NH:$NM (через $ROLLBACK_MIN мин)
  Rollback script: $ROLLBACK_SCRIPT (переживёт ребут)

  Если всё хорошо  →  touch $CANCEL_FLAG
  Промоут в .safe  →  cp $ACTIVE /root/xray-config.safe.json
═══════════════════════════════════════════════════════════════
EOF
