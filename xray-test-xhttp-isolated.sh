#!/bin/sh
#
# xray-test-xhttp-isolated.sh — изолированный тест XHTTP-клиента.
#
# Запускает второй экземпляр xray с минимальным конфигом (только proxy-xhttp
# outbound + локальный SOCKS5 inbound на 127.0.0.1:10888), без balancer,
# observatory, tproxy. Прод-xray не трогается. Если конфиг кривой и второй
# xray зависает/падает — пользователь и интернет не задеты.
#
# Использование:
#   xray-test-xhttp-isolated.sh <UUID> <SERVER> <PORT> <SNI> [PATH] [HOST]
#     UUID       — VLESS UUID (тот же что и у Reality)
#     SERVER     — IP или домен сервера
#     PORT       — порт XHTTP-inbound на сервере
#     SNI        — TLS serverName (обычно домен сервера)
#     PATH       — xhttpSettings.path (default: /xhttp)
#     HOST       — Host header (default: = SNI)
#
# Что делает:
#   1. Пишет /tmp/xhttp-test.json (минимальный конфиг).
#   2. Валидирует.
#   3. Запускает в фоне на порту 10888 (SOCKS5).
#   4. curl --socks5 через него к httpbin.org/ip.
#   5. Выводит результат + чему этот трафик показался для DPI/сервера.
#   6. Останавливает тестовый xray.
#
# Если httpbin вернёт IP сервера (<<VLESS_SERVER>>) — клиентский XHTTP-конфиг рабочий.

set -e

UUID="$1"
SERVER="$2"
PORT="$3"
SNI="$4"
XPATH="${5:-/xhttp}"
HOST="${6:-$SNI}"

if [ -z "$UUID" ] || [ -z "$SERVER" ] || [ -z "$PORT" ] || [ -z "$SNI" ]; then
  cat >&2 <<EOF
usage: $0 <UUID> <SERVER> <PORT> <SNI> [PATH] [HOST]
example: $0 c37c79cc-... <<VLESS_SERVER>> 2087 <<SERVER_DOMAIN>>
EOF
  exit 2
fi

CFG=/tmp/xhttp-test.json
PID_FILE=/tmp/xhttp-test.pid
LOG=/tmp/xhttp-test.log
SOCKS_PORT=10888

cat > "$CFG" <<EOF
{
  "log": { "loglevel": "warning", "error": "$LOG" },
  "inbounds": [
    {
      "tag": "socks-test",
      "listen": "127.0.0.1",
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": false }
    }
  ],
  "outbounds": [
    {
      "tag": "test-xhttp",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$SERVER",
          "port": $PORT,
          "users": [{ "id": "$UUID", "encryption": "none" }]
        }]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$SNI",
          "fingerprint": "chrome",
          "alpn": ["h2"]
        },
        "xhttpSettings": {
          "path": "$XPATH",
          "mode": "auto",
          "host": "$HOST"
        }
      }
    }
  ]
}
EOF

echo "→ Валидирую конфиг"
if ! XRAY_LOCATION_ASSET=/usr/local/etc/xray /usr/local/bin/xray run -test -c "$CFG" 2>&1 | tail -3 | grep -q 'Configuration OK'; then
  echo "✗ Тестовый конфиг невалиден" >&2
  cat "$CFG" >&2
  exit 1
fi
echo "  OK"

# Убиваем предыдущий запуск если есть
if [ -f "$PID_FILE" ]; then
  kill "$(cat "$PID_FILE")" 2>/dev/null
  rm -f "$PID_FILE"
fi

echo "→ Запускаю тестовый xray в фоне (SOCKS5 на 127.0.0.1:$SOCKS_PORT)"
XRAY_LOCATION_ASSET=/usr/local/etc/xray /usr/local/bin/xray run -c "$CFG" >> "$LOG" 2>&1 &
TPID=$!
echo "$TPID" > "$PID_FILE"
sleep 3

if ! kill -0 "$TPID" 2>/dev/null; then
  echo "✗ Тестовый xray умер на старте. Лог:" >&2
  tail -20 "$LOG"
  exit 1
fi

echo "→ Тест через SOCKS5: curl https://httpbin.org/ip"
RESULT=$(curl -s --max-time 15 --socks5-hostname "127.0.0.1:$SOCKS_PORT" https://httpbin.org/ip 2>&1)
echo "  $RESULT"

echo "→ Останавливаю тестовый xray"
kill "$TPID" 2>/dev/null
rm -f "$PID_FILE"

echo ""
echo "═══════════════════════════════════════════════════════════════"
if echo "$RESULT" | grep -q "$SERVER"; then
  echo "  ✓ УСПЕХ: трафик прошёл через $SERVER (XHTTP-клиент рабочий)"
  echo "  Можно деплоить в прод (см. MIGRATION-XHTTP.md, путь A)"
else
  echo "  ✗ ПРОБЛЕМА: трафик НЕ дошёл до $SERVER через XHTTP."
  echo "  Возможные причины:"
  echo "   - server XHTTP inbound на $PORT не слушает / не отвечает h2"
  echo "   - неверный путь ($XPATH) или host ($HOST)"
  echo "   - TLS handshake фейлится (проверь serverName и cert)"
  echo "   - провайдер режет $SERVER:$PORT"
  echo "  Лог тестового xray: $LOG"
fi
echo "═══════════════════════════════════════════════════════════════"
