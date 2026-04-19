#!/bin/sh
# Усекает access.log xray если размер превысил лимит.
# Оставляет последние N строк для диагностики.
# Работает безопасно с xray благодаря O_APPEND:
#   после `:> file` следующий write xray уходит в offset 0, sparse-файла не будет.

LOG=/var/log/xray/access.log
MAX_BYTES=10485760   # 10 MB
KEEP_LINES=2000

[ -f "$LOG" ] || exit 0

SIZE=$(wc -c < "$LOG" 2>/dev/null || echo 0)
[ "$SIZE" -gt "$MAX_BYTES" ] || exit 0

TMP=$(mktemp /tmp/xray-log-trunc.XXXXXX) || exit 1
tail -n "$KEEP_LINES" "$LOG" > "$TMP" || { rm -f "$TMP"; exit 1; }
: > "$LOG"
cat "$TMP" >> "$LOG"
rm -f "$TMP"
