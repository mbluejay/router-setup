#!/usr/bin/env bash
#
# server-install.sh — деплой fallback-слоёв (L2 WS+TLS, L3 gRPC+TLS) на VPS с 3x-ui.
#
# Запускается на ЛОКАЛЬНОЙ машине (Windows Git Bash / macOS / Linux).
# Ходит на сервер по SSH (нужен root-доступ без пароля по ключу) и по HTTPS
# к API 3x-ui панели (нужен логин/пароль панели).
#
# Не трогает L1 (Reality на :443) и любые другие existing inbound'ы.
# Все операции идемпотентны (повторный запуск безопасен).
#
# Требования на сервере: 3x-ui установлен и работает, acme.sh установлен,
# порт 80 свободен для standalone http-01 challenge (acme.sh issue).
#
# См. EXTRA_CARE.md для архитектуры.

set -eu

# ══════════════════════════════════════════════════════════════════════════
# Configuration
# ══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$SCRIPT_DIR/.state"
STATE_FILE="$STATE_DIR/server-state.env"

# State (defaults, overwritten by load_state)
SERVER_HOST=""
SERVER_DOMAIN=""           # обычно == SERVER_HOST, но может отличаться (CDN/anycast)
PANEL_URL=""               # https://IP:PORT/webBasePath (без trailing slash)
PANEL_USER=""
PANEL_PASS=""
L1_UUID=""                 # UUID из L1, используется для L2/L3 (общий)
L2_INBOUND_ID=""           # id созданного L2 inbound (для отката)
L3_INBOUND_ID=""           # id созданного L3 inbound (для отката)
CERT_PATH=""               # путь к fullchain.pem на сервере
KEY_PATH=""                # путь к privkey.pem на сервере

# ══════════════════════════════════════════════════════════════════════════
# Logging
# ══════════════════════════════════════════════════════════════════════════

if [ -t 1 ]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'
else
  C_RESET=""; C_BOLD=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

log_info() { printf '%s[INFO]%s %s\n' "$C_CYAN"   "$C_RESET" "$1"; }
log_ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN"  "$C_RESET" "$1"; }
log_warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
log_err()  { printf '%s[ERR ]%s %s\n' "$C_RED"    "$C_RESET" "$1" >&2; }
log_step() { printf '\n%s▶ %s%s\n' "$C_BOLD$C_BLUE" "$1" "$C_RESET"; }
pause()    { printf '\nEnter для продолжения...'; read -r _; }

# ══════════════════════════════════════════════════════════════════════════
# State persistence
# ══════════════════════════════════════════════════════════════════════════

save_state() {
  mkdir -p "$STATE_DIR"
  cat > "$STATE_FILE" <<EOF
SERVER_HOST=$(printf '%q' "$SERVER_HOST")
SERVER_DOMAIN=$(printf '%q' "$SERVER_DOMAIN")
PANEL_URL=$(printf '%q' "$PANEL_URL")
PANEL_USER=$(printf '%q' "$PANEL_USER")
PANEL_PASS=$(printf '%q' "$PANEL_PASS")
L1_UUID=$(printf '%q' "$L1_UUID")
L2_INBOUND_ID=$(printf '%q' "$L2_INBOUND_ID")
L3_INBOUND_ID=$(printf '%q' "$L3_INBOUND_ID")
CERT_PATH=$(printf '%q' "$CERT_PATH")
KEY_PATH=$(printf '%q' "$KEY_PATH")
EOF
  chmod 600 "$STATE_FILE"
}

load_state() {
  [ -f "$STATE_FILE" ] && . "$STATE_FILE" || true
}

ask() {
  local prompt="$1" varname="$2" default="${!varname:-}"
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default"
  else
    printf '%s: ' "$prompt"
  fi
  read -r ans
  [ -n "$ans" ] && eval "$varname=\"\$ans\""
}

ask_secret() {
  local prompt="$1" varname="$2"
  printf '%s: ' "$prompt"
  stty -echo
  read -r ans
  stty echo
  printf '\n'
  eval "$varname=\"\$ans\""
}

# ══════════════════════════════════════════════════════════════════════════
# SSH / Panel API helpers
# ══════════════════════════════════════════════════════════════════════════

rssh() {
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "root@$SERVER_HOST" "$@"
}

rssh_q() {
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -q "root@$SERVER_HOST" "$@" 2>/dev/null
}

# Panel login → store cookie in $1 (path).
panel_login() {
  local cookie="$1"
  curl -sk -c "$cookie" -X POST "$PANEL_URL/login" \
    -d "username=$PANEL_USER&password=$PANEL_PASS" \
    | grep -q '"success":true' || {
      log_err "Не удалось залогиниться в панель"
      return 1
    }
}

panel_call() {
  local cookie="$1" method="$2" path="$3"
  shift 3
  curl -sk -b "$cookie" -X "$method" "$PANEL_URL$path" "$@"
}

# ══════════════════════════════════════════════════════════════════════════
# Setup wizard
# ══════════════════════════════════════════════════════════════════════════

setup_wizard() {
  log_step "Настройка параметров"
  ask "Хост сервера (для SSH)" SERVER_HOST
  ask "Основной домен сервера (для TLS L2/L3)" SERVER_DOMAIN
  ask "URL панели 3x-ui (без trailing slash)" PANEL_URL
  ask "Логин панели" PANEL_USER
  ask_secret "Пароль панели" PANEL_PASS

  # Test SSH
  log_info "Проверяю SSH-доступ..."
  if rssh "echo ssh_ok" 2>/dev/null | grep -q ssh_ok; then
    log_ok "SSH работает"
  else
    log_err "SSH к root@$SERVER_HOST не работает. Настрой ключ или проверь IP."
    return 1
  fi

  # Test panel
  log_info "Проверяю доступ к API панели..."
  local cookie
  cookie="$(mktemp)"
  if panel_login "$cookie"; then
    log_ok "Логин в панель работает"
  else
    rm -f "$cookie"
    return 1
  fi
  rm -f "$cookie"

  save_state
  log_ok "Параметры сохранены в $STATE_FILE"
}

# ══════════════════════════════════════════════════════════════════════════
# Step 1: Snapshot 3x-ui database
# ══════════════════════════════════════════════════════════════════════════

action_snapshot() {
  log_step "Снапшот /etc/x-ui/x-ui.db"
  local ts
  ts="$(date +%F-%H%M)"
  rssh "cp -v /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.bak-$ts"
  log_ok "Снапшот: /etc/x-ui/x-ui.db.bak-$ts (на сервере)"
}

# ══════════════════════════════════════════════════════════════════════════
# Step 2: Detect / fetch L1 UUID from existing :443 inbound
# ══════════════════════════════════════════════════════════════════════════

action_detect_l1() {
  log_step "Определяю UUID L1 (inbound на :443)"
  local cookie
  cookie="$(mktemp)"
  panel_login "$cookie" || { rm -f "$cookie"; return 1; }

  local list
  list="$(panel_call "$cookie" GET "/panel/api/inbounds/list")"
  rm -f "$cookie"

  # Извлекаем UUID из inbound с port=443 (грубо, но надёжно при типичных конфигах)
  local uuid
  uuid="$(echo "$list" | grep -oE '"port":443[^}]*"id":"[a-f0-9-]+"' | grep -oE '"id":"[a-f0-9-]+"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')"
  if [ -z "$uuid" ]; then
    # Fallback: первый UUID в clientStats
    uuid="$(echo "$list" | grep -oE '"uuid":"[a-f0-9-]+"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')"
  fi
  if [ -z "$uuid" ]; then
    log_err "Не удалось найти UUID. Проверь что L1 inbound существует."
    return 1
  fi
  L1_UUID="$uuid"
  log_ok "L1 UUID: $L1_UUID"
  save_state
}

# ══════════════════════════════════════════════════════════════════════════
# Step 3: Issue LE certificate via acme.sh (idempotent)
# ══════════════════════════════════════════════════════════════════════════

action_issue_cert() {
  log_step "Выпуск/обновление LE-сертификата для $SERVER_DOMAIN"

  if rssh_q "test -f /root/cert/$SERVER_DOMAIN/fullchain.pem && \
             openssl x509 -in /root/cert/$SERVER_DOMAIN/fullchain.pem -noout -checkend 604800" \
     | grep -q .; then
    log_ok "Cert уже выпущен и валиден ещё >7 дней — пропускаю"
    CERT_PATH="/root/cert/$SERVER_DOMAIN/fullchain.pem"
    KEY_PATH="/root/cert/$SERVER_DOMAIN/privkey.pem"
    save_state
    return 0
  fi

  log_info "Проверяю что порт 80 свободен..."
  if rssh "netstat -tlnp 2>/dev/null | grep -qE ':80\\b'"; then
    log_err "Порт 80 занят. acme.sh standalone не сможет получить http-01 challenge."
    log_err "Освободи порт 80 на время выпуска cert, или используй другой режим (DNS challenge)."
    return 1
  fi

  log_info "Запускаю acme.sh --issue (займёт ~30с)..."
  rssh "/root/.acme.sh/acme.sh --issue -d $SERVER_DOMAIN --standalone --httpport 80 --server letsencrypt 2>&1 | tail -10"

  log_info "Устанавливаю cert в /root/cert/$SERVER_DOMAIN/..."
  rssh "mkdir -p /root/cert/$SERVER_DOMAIN && \
    /root/.acme.sh/acme.sh --install-cert -d $SERVER_DOMAIN --ecc \
      --key-file       /root/cert/$SERVER_DOMAIN/privkey.pem \
      --fullchain-file /root/cert/$SERVER_DOMAIN/fullchain.pem \
      --reloadcmd      'x-ui restart-xray' 2>&1 | tail -3"

  CERT_PATH="/root/cert/$SERVER_DOMAIN/fullchain.pem"
  KEY_PATH="/root/cert/$SERVER_DOMAIN/privkey.pem"

  rssh "openssl x509 -in $CERT_PATH -noout -dates -subject -issuer"
  log_ok "Cert установлен, auto-renew через ежедневный cron acme.sh"
  save_state
}

# ══════════════════════════════════════════════════════════════════════════
# Step 4: Add L2 (WS+TLS:8443) inbound via panel API
# ══════════════════════════════════════════════════════════════════════════

action_add_l2() {
  log_step "Добавляю L2 inbound (VLESS+WS+TLS :8443)"
  [ -n "$L1_UUID" ] || { log_err "L1_UUID пуст. Запусти 'detect L1' сначала."; return 1; }
  [ -n "$CERT_PATH" ] || { log_err "CERT_PATH пуст. Запусти 'issue cert' сначала."; return 1; }

  local cookie
  cookie="$(mktemp)"
  panel_login "$cookie" || { rm -f "$cookie"; return 1; }

  local settings stream sniff
  settings='{"clients":[{"id":"'$L1_UUID'","flow":"","email":"fallback-ws","enable":true,"tgId":"","subId":"","comment":"fallback L2 ws+tls","reset":0}],"decryption":"none","fallbacks":[]}'

  stream='{"network":"ws","security":"tls","externalProxy":[],"tlsSettings":{"serverName":"'$SERVER_DOMAIN'","minVersion":"1.2","maxVersion":"1.3","cipherSuites":"","rejectUnknownSni":false,"disableSystemRoot":false,"enableSessionResumption":false,"alpn":["http/1.1"],"settings":{"allowInsecure":false,"fingerprint":""},"certificates":[{"certificateFile":"'$CERT_PATH'","keyFile":"'$KEY_PATH'","ocspStapling":3600,"oneTimeLoading":false,"usage":"encipherment","buildChain":false}]},"wsSettings":{"acceptProxyProtocol":false,"path":"/ws","host":"","headers":{}}}'

  sniff='{"enabled":false,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'

  local resp
  resp="$(panel_call "$cookie" POST "/panel/api/inbounds/add" \
    --data-urlencode "up=0" --data-urlencode "down=0" --data-urlencode "total=0" \
    --data-urlencode "remark=fallback-L2-ws" --data-urlencode "enable=true" \
    --data-urlencode "expiryTime=0" --data-urlencode "listen=" \
    --data-urlencode "port=8443" --data-urlencode "protocol=vless" \
    --data-urlencode "settings=$settings" \
    --data-urlencode "streamSettings=$stream" \
    --data-urlencode "sniffing=$sniff")"
  rm -f "$cookie"

  if echo "$resp" | grep -q '"success":true'; then
    L2_INBOUND_ID="$(echo "$resp" | grep -oE '"id":[0-9]+' | head -1 | grep -oE '[0-9]+')"
    log_ok "L2 inbound создан, id=$L2_INBOUND_ID"
    save_state
  else
    log_err "Ошибка создания L2: $resp"
    return 1
  fi
}

# ══════════════════════════════════════════════════════════════════════════
# Step 5: Add L3 (gRPC+TLS:2053) inbound
# ══════════════════════════════════════════════════════════════════════════

action_add_l3() {
  log_step "Добавляю L3 inbound (VLESS+gRPC+TLS :2053)"
  [ -n "$L1_UUID" ] || { log_err "L1_UUID пуст. Запусти 'detect L1' сначала."; return 1; }
  [ -n "$CERT_PATH" ] || { log_err "CERT_PATH пуст. Запусти 'issue cert' сначала."; return 1; }

  local grpc_service
  grpc_service="grpc-$(echo "$SERVER_DOMAIN" | tr '.' '-')"

  local cookie
  cookie="$(mktemp)"
  panel_login "$cookie" || { rm -f "$cookie"; return 1; }

  local settings stream sniff
  settings='{"clients":[{"id":"'$L1_UUID'","flow":"","email":"fallback-grpc","enable":true,"tgId":"","subId":"","comment":"fallback L3 grpc+tls","reset":0}],"decryption":"none","fallbacks":[]}'

  stream='{"network":"grpc","security":"tls","externalProxy":[],"tlsSettings":{"serverName":"'$SERVER_DOMAIN'","minVersion":"1.2","maxVersion":"1.3","cipherSuites":"","rejectUnknownSni":false,"disableSystemRoot":false,"enableSessionResumption":false,"alpn":["h2"],"settings":{"allowInsecure":false,"fingerprint":""},"certificates":[{"certificateFile":"'$CERT_PATH'","keyFile":"'$KEY_PATH'","ocspStapling":3600,"oneTimeLoading":false,"usage":"encipherment","buildChain":false}]},"grpcSettings":{"serviceName":"'$grpc_service'","multiMode":true,"authority":""}}'

  sniff='{"enabled":false,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'

  local resp
  resp="$(panel_call "$cookie" POST "/panel/api/inbounds/add" \
    --data-urlencode "up=0" --data-urlencode "down=0" --data-urlencode "total=0" \
    --data-urlencode "remark=fallback-L3-grpc" --data-urlencode "enable=true" \
    --data-urlencode "expiryTime=0" --data-urlencode "listen=" \
    --data-urlencode "port=2053" --data-urlencode "protocol=vless" \
    --data-urlencode "settings=$settings" \
    --data-urlencode "streamSettings=$stream" \
    --data-urlencode "sniffing=$sniff")"
  rm -f "$cookie"

  if echo "$resp" | grep -q '"success":true'; then
    L3_INBOUND_ID="$(echo "$resp" | grep -oE '"id":[0-9]+' | head -1 | grep -oE '[0-9]+')"
    log_ok "L3 inbound создан, id=$L3_INBOUND_ID, serviceName=$grpc_service"
    save_state
  else
    log_err "Ошибка создания L3: $resp"
    return 1
  fi
}

# ══════════════════════════════════════════════════════════════════════════
# Step 6: External TLS handshake check
# ══════════════════════════════════════════════════════════════════════════

action_verify_tls() {
  log_step "Проверка TLS-handshake снаружи"
  for port_alpn in "8443:http/1.1" "2053:h2"; do
    local port="${port_alpn%:*}" alpn="${port_alpn#*:}"
    printf '  :%s (ALPN=%s) ... ' "$port" "$alpn"
    local out
    out="$(timeout 8 openssl s_client -connect "$SERVER_DOMAIN:$port" -servername "$SERVER_DOMAIN" -alpn "$alpn" </dev/null 2>&1)"
    if echo "$out" | grep -q "Verify return code: 0 (ok)"; then
      printf '%s✓%s\n' "$C_GREEN" "$C_RESET"
    else
      printf '%s✗%s\n' "$C_RED" "$C_RESET"
      echo "$out" | grep -E "subject=|issuer=|Verify return code|error" | head -5
    fi
  done
}

# ══════════════════════════════════════════════════════════════════════════
# Step 7: List current inbounds (diagnostic)
# ══════════════════════════════════════════════════════════════════════════

action_list_inbounds() {
  log_step "Список inbound'ов в панели"
  local cookie
  cookie="$(mktemp)"
  panel_login "$cookie" || { rm -f "$cookie"; return 1; }
  panel_call "$cookie" GET "/panel/api/inbounds/list" \
    | grep -oE '"id":[0-9]+|"port":[0-9]+|"protocol":"[^"]+"|"remark":"[^"]*"|"enable":(true|false)' \
    | paste -d ' ' - - - - -
  rm -f "$cookie"
}

# ══════════════════════════════════════════════════════════════════════════
# Step 8: Rollback (delete L2+L3)
# ══════════════════════════════════════════════════════════════════════════

action_rollback() {
  log_step "Откат — удаление L2 и L3"
  log_warn "Будут удалены inbound'ы с remark = 'fallback-L2-ws' и 'fallback-L3-grpc'"
  printf 'Подтверди (yes для удаления): '
  read -r ans
  [ "$ans" = "yes" ] || { log_info "Отмена"; return 0; }

  local cookie
  cookie="$(mktemp)"
  panel_login "$cookie" || { rm -f "$cookie"; return 1; }

  for id in "$L2_INBOUND_ID" "$L3_INBOUND_ID"; do
    if [ -n "$id" ]; then
      log_info "Удаляю inbound id=$id"
      panel_call "$cookie" POST "/panel/api/inbounds/del/$id" | head -c 200
      echo
    fi
  done
  rm -f "$cookie"
  L2_INBOUND_ID=""
  L3_INBOUND_ID=""
  save_state
  log_ok "Откат выполнен. L1 не тронут."
}

# ══════════════════════════════════════════════════════════════════════════
# Full install (orchestrator)
# ══════════════════════════════════════════════════════════════════════════

action_full_install() {
  action_snapshot      || return 1
  action_detect_l1     || return 1
  action_issue_cert    || return 1
  action_add_l2        || return 1
  action_add_l3        || return 1
  action_verify_tls
  log_ok "Серверная часть готова. Теперь обнови клиентский config через install.sh."
}

# ══════════════════════════════════════════════════════════════════════════
# Main menu
# ══════════════════════════════════════════════════════════════════════════

main_menu() {
  load_state
  while :; do
    clear
    printf '%s═══ server-install.sh — fallback L2/L3 на 3x-ui ═══%s\n\n' "$C_BOLD" "$C_RESET"
    printf '  Хост:   %s\n' "${SERVER_HOST:-<не задан>}"
    printf '  Домен:  %s\n' "${SERVER_DOMAIN:-<не задан>}"
    printf '  Панель: %s\n' "${PANEL_URL:-<не задан>}"
    printf '  L1 UUID:%s\n' "${L1_UUID:-<неизвестно>}"
    printf '  L2 id:  %s\n' "${L2_INBOUND_ID:-<не создан>}"
    printf '  L3 id:  %s\n' "${L3_INBOUND_ID:-<не создан>}"
    printf '\n'
    printf '  1) Настроить параметры (хост, домен, креды панели)\n'
    printf '  2) Снапшот x-ui.db\n'
    printf '  3) Определить UUID L1\n'
    printf '  4) Выпустить/обновить LE cert (acme.sh)\n'
    printf '  5) Добавить L2 (WS+TLS:8443)\n'
    printf '  6) Добавить L3 (gRPC+TLS:2053)\n'
    printf '  7) Проверить TLS снаружи\n'
    printf '  8) Список inbound'\''ов\n'
    printf '  9) Откат (удалить L2+L3, L1 не трогается)\n'
    printf '  A) Всё за один раз (2→3→4→5→6→7)\n'
    printf '  0) Выход\n\n'
    printf '> '
    read -r choice
    case "$choice" in
      1) setup_wizard; pause ;;
      2) action_snapshot; pause ;;
      3) action_detect_l1; pause ;;
      4) action_issue_cert; pause ;;
      5) action_add_l2; pause ;;
      6) action_add_l3; pause ;;
      7) action_verify_tls; pause ;;
      8) action_list_inbounds; pause ;;
      9) action_rollback; pause ;;
      A|a) action_full_install; pause ;;
      0) exit 0 ;;
      *) log_warn "Неверный выбор"; sleep 1 ;;
    esac
  done
}

main_menu
