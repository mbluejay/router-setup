#!/usr/bin/env bash
#
# update-vless.sh — обновить VLESS-конфиг на роутере без полной переустановки.
#
# Спрашивает IP роутера и новую VLESS-ссылку, парсит параметры,
# генерирует конфиг, заливает на роутер, применяет custom-direct список.
#
# Запускать на ЛОКАЛЬНОЙ машине (Windows Git Bash / macOS / Linux).
# Требования: bash 4+, ssh.

set -u

STATE_DIR="$HOME/.xray-installer"
STATE_FILE="$STATE_DIR/state"
ASKPASS_FILE="$STATE_DIR/askpass.sh"
LOCK_FILE="/tmp/xray-update-vless-${USER:-unknown}.lock"

ROUTER_IP="192.168.1.1"
ROOT_PASSWORD=""
VLESS_URL=""
SERVER_DOMAIN=""   # домен сервера для TLS на L2/L3 (см. EXTRA_CARE.md)

VLESS_NAME="" VLESS_UUID="" VLESS_SERVER="" VLESS_PORT=""
VLESS_SECURITY="" VLESS_PBKEY="" VLESS_SNI="" VLESS_FP="chrome"
VLESS_FLOW="" VLESS_SID="" VLESS_TRANSPORT="tcp"
VLESS_PATH="" VLESS_HOST=""

# ══════════════════════════════════════════════════════════════════════════
# Colors & logging
# ══════════════════════════════════════════════════════════════════════════

if [ -t 1 ]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

log_info()  { printf '%s[INFO]%s %s\n' "$C_CYAN"   "$C_RESET" "$1"; }
log_ok()    { printf '%s[ OK ]%s %s\n' "$C_GREEN"  "$C_RESET" "$1"; }
log_warn()  { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
log_err()   { printf '%s[ERR ]%s %s\n' "$C_RED"    "$C_RESET" "$1" >&2; }
log_step()  { printf '\n%s▶ %s%s\n' "$C_BOLD$C_BLUE" "$1" "$C_RESET"; }
show_cmd()  { printf '  %s$ %s%s\n' "$C_DIM" "$1" "$C_RESET"; }

pause() { printf '\nНажми Enter для продолжения...'; read -r _; }

# ══════════════════════════════════════════════════════════════════════════
# State
# ══════════════════════════════════════════════════════════════════════════

load_state() { [ -f "$STATE_FILE" ] && . "$STATE_FILE"; }

save_state() {
  mkdir -p "$STATE_DIR"
  cat > "$STATE_FILE" <<EOF
ROUTER_IP=$(printf '%q' "$ROUTER_IP")
VLESS_URL=$(printf '%q' "$VLESS_URL")
SERVER_DOMAIN=$(printf '%q' "$SERVER_DOMAIN")
EOF
}

write_askpass() {
  mkdir -p "$STATE_DIR"
  cat > "$ASKPASS_FILE" <<EOF
#!/bin/sh
echo "$ROOT_PASSWORD"
EOF
  chmod 700 "$ASKPASS_FILE"
}

# ══════════════════════════════════════════════════════════════════════════
# SSH helpers
# ══════════════════════════════════════════════════════════════════════════

rssh() {
  show_cmd "ssh root@$ROUTER_IP '$1'"
  SSH_ASKPASS="$ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force DISPLAY=1 \
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        root@"$ROUTER_IP" "$1"
}

rssh_q() {
  SSH_ASKPASS="$ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force DISPLAY=1 \
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        root@"$ROUTER_IP" "$1" 2>/dev/null
}

rssh_pipe() {
  local remote_path="$1"
  show_cmd "pipe → root@$ROUTER_IP:$remote_path"
  SSH_ASKPASS="$ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force DISPLAY=1 \
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        root@"$ROUTER_IP" "cat > $remote_path"
}

# ══════════════════════════════════════════════════════════════════════════
# Input helpers
# ══════════════════════════════════════════════════════════════════════════

ask() {
  local prompt="$1" varname="$2"
  local current="${!varname:-}"
  local suffix=""
  [ -n "$current" ] && suffix=" [${C_DIM}${current}${C_RESET}]"
  printf '%s%s: ' "$prompt" "$suffix"
  read -r input
  [ -z "$input" ] && input="$current"
  printf -v "$varname" '%s' "$input"
}

ask_secret() {
  local prompt="$1" varname="$2"
  printf '%s: ' "$prompt"
  stty -echo 2>/dev/null
  read -r input
  stty echo 2>/dev/null
  printf '\n'
  printf -v "$varname" '%s' "$input"
}

confirm() {
  local prompt="$1" default="${2:-n}" yn
  if [ "$default" = "y" ]; then
    printf '%s [Y/n]: ' "$prompt"; read -r yn
    [ -z "$yn" ] || [ "$yn" = "y" ] || [ "$yn" = "Y" ]
  else
    printf '%s [y/N]: ' "$prompt"; read -r yn
    [ "$yn" = "y" ] || [ "$yn" = "Y" ]
  fi
}

# ══════════════════════════════════════════════════════════════════════════
# VLESS parsing
# ══════════════════════════════════════════════════════════════════════════

urldecode() {
  local encoded="${1//+/ }"
  printf '%b' "${encoded//%/\\x}"
}

parse_vless_url() {
  local url="$1"
  [[ "$url" == vless://* ]] || { log_err "Не похоже на VLESS URL"; return 1; }
  local body="${url#vless://}"
  local before_frag="${body%%#*}"
  if [ "$body" != "$before_frag" ]; then
    VLESS_NAME="$(urldecode "${body#*#}")"
  else
    VLESS_NAME="(без имени)"
  fi
  local before_query="${before_frag%%\?*}"
  local query=""
  [ "$before_query" != "$before_frag" ] && query="${before_frag#*\?}"

  VLESS_UUID="${before_query%%@*}"
  local hostport="${before_query#*@}"
  VLESS_SERVER="${hostport%:*}"
  VLESS_PORT="${hostport##*:}"

  VLESS_SECURITY=""; VLESS_PBKEY=""; VLESS_SNI=""; VLESS_FP="chrome"
  VLESS_FLOW=""; VLESS_SID=""; VLESS_TRANSPORT="tcp"
  VLESS_PATH=""; VLESS_HOST=""

  local old_ifs="$IFS"; IFS='&'
  for pair in $query; do
    local k="${pair%%=*}" v="${pair#*=}"
    v="$(urldecode "$v")"
    case "$k" in
      security) VLESS_SECURITY="$v" ;;
      pbk)      VLESS_PBKEY="$v"    ;;
      sni)      VLESS_SNI="$v"      ;;
      fp)       VLESS_FP="$v"       ;;
      flow)     VLESS_FLOW="$v"     ;;
      sid)      VLESS_SID="$v"      ;;
      type)     VLESS_TRANSPORT="$v";;
      path)     VLESS_PATH="$v"     ;;
      host)     VLESS_HOST="$v"     ;;
    esac
  done
  IFS="$old_ifs"
}

show_vless_parsed() {
  printf '\n%sРаспознанные параметры VLESS:%s\n' "$C_BOLD" "$C_RESET"
  printf '  Имя:         %s\n' "$VLESS_NAME"
  printf '  UUID:        %s\n' "$VLESS_UUID"
  printf '  Сервер:      %s:%s\n' "$VLESS_SERVER" "$VLESS_PORT"
  printf '  Security:    %s\n' "$VLESS_SECURITY"
  printf '  Transport:   %s\n' "$VLESS_TRANSPORT"
  printf '  SNI:         %s\n' "$VLESS_SNI"
  printf '  Fingerprint: %s\n' "$VLESS_FP"
  if [ "$VLESS_SECURITY" = "reality" ]; then
    printf '  PublicKey:   %s\n' "$VLESS_PBKEY"
    printf '  ShortID:     %s\n' "$VLESS_SID"
  fi
  [ -n "$VLESS_FLOW" ] && printf '  Flow:        %s\n' "$VLESS_FLOW"
  [ -n "$VLESS_PATH" ] && printf '  Path:        %s\n' "$VLESS_PATH"
  [ -n "$VLESS_HOST" ] && printf '  Host:        %s\n' "$VLESS_HOST"
  printf '\n'
}

# ══════════════════════════════════════════════════════════════════════════
# Config generation (шаблон без custom-direct доменов — их добавит xray-add-direct)
# ══════════════════════════════════════════════════════════════════════════

# generate_config v2 — синхронизирован с install.sh generate_config.
# Один proxy-reality (Reality+TCP+Vision) из VLESS URL + два hardcoded fallback'а:
# proxy-ws (WS+TLS:8443) и proxy-grpc (gRPC+TLS:2053), оба на $VLESS_SERVER,
# TLS-сертификат для них предоставляет сервер по $SERVER_DOMAIN.
generate_config() {
  local out="$1"

  if [ "$VLESS_SECURITY-$VLESS_TRANSPORT" != "reality-tcp" ]; then
    log_err "Шаблон v2 ожидает Reality+TCP для L1. Получено: security=$VLESS_SECURITY transport=$VLESS_TRANSPORT"
    return 1
  fi

  if [ -z "$SERVER_DOMAIN" ]; then
    log_warn "SERVER_DOMAIN пуст — L2/L3 не смогут проверить TLS-сертификат"
    SERVER_DOMAIN="${VLESS_SERVER}"
  fi

  local grpc_service
  grpc_service="grpc-$(echo "$SERVER_DOMAIN" | tr '.' '-')"

  cat > "$out" <<CFG
{
  "log": {
    "loglevel": "warning",
    "access": "none",
    "error": "/var/log/xray/error.log"
  },
  "api": {
    "tag": "api",
    "services": ["StatsService", "ObservatoryService", "RoutingService"]
  },
  "observatory": {
    "subjectSelector": ["proxy-"],
    "probeURL": "https://www.gstatic.com/generate_204",
    "probeInterval": "30s",
    "enableConcurrency": false
  },
  "dns": {
    "servers": [
      {
        "address": "https://1.1.1.1/dns-query",
        "domains": [
          "domain:x.com", "domain:twitter.com", "domain:t.co",
          "domain:twimg.com", "domain:themoviedb.org", "domain:tmdb.org"
        ]
      },
      {
        "address": "77.88.8.8",
        "domains": ["geosite:category-ru", "geosite:whitelist", "geosite:steam", "geosite:microsoft", "geosite:apple"]
      },
      {
        "address": "77.88.8.1",
        "domains": ["geosite:category-ru", "geosite:whitelist", "geosite:steam", "geosite:microsoft", "geosite:apple"]
      },
      "8.8.8.8"
    ]
  },
  "inbounds": [
    {
      "tag": "tproxy-in",
      "port": 12345,
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy", "mark": 255 } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    },
    {
      "tag": "dns-in",
      "port": 5300,
      "protocol": "dokodemo-door",
      "settings": { "address": "8.8.8.8", "port": 53, "network": "tcp,udp" }
    },
    {
      "tag": "api-in",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    },
    {
      "tag": "http-local",
      "listen": "127.0.0.1",
      "port": 8118,
      "protocol": "http",
      "settings": { "timeout": 30 }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy-reality",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$VLESS_SERVER",
          "port": $VLESS_PORT,
          "users": [{ "id": "$VLESS_UUID", "flow": "$VLESS_FLOW", "encryption": "none" }]
        }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "$VLESS_SNI",
          "fingerprint": "$VLESS_FP",
          "publicKey": "$VLESS_PBKEY",
          "shortId": "$VLESS_SID"
        },
        "sockopt": { "mark": 255 }
      }
    },
    {
      "tag": "proxy-ws",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$VLESS_SERVER",
          "port": 8443,
          "users": [{ "id": "$VLESS_UUID", "encryption": "none" }]
        }]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": { "serverName": "$SERVER_DOMAIN", "fingerprint": "chrome", "alpn": ["http/1.1"] },
        "wsSettings": { "path": "/ws", "headers": { "Host": "$SERVER_DOMAIN" } },
        "sockopt": { "mark": 255 }
      }
    },
    {
      "tag": "proxy-grpc",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$VLESS_SERVER",
          "port": 2053,
          "users": [{ "id": "$VLESS_UUID", "encryption": "none" }]
        }]
      },
      "streamSettings": {
        "network": "grpc",
        "security": "tls",
        "tlsSettings": { "serverName": "$SERVER_DOMAIN", "fingerprint": "chrome", "alpn": ["h2"] },
        "grpcSettings": { "serviceName": "$grpc_service", "multiMode": true },
        "sockopt": { "mark": 255 }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" },
      "streamSettings": { "sockopt": { "mark": 255 } }
    },
    { "tag": "block",   "protocol": "blackhole" },
    { "tag": "dns-out", "protocol": "dns" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "balancers": [
      { "tag": "vpn-balancer", "selector": ["proxy-"], "strategy": { "type": "random" } }
    ],
    "rules": [
      { "type": "field", "inboundTag": ["api-in"], "outboundTag": "api" },
      { "type": "field", "inboundTag": ["dns-in"], "outboundTag": "dns-out" },
      { "type": "field", "outboundTag": "block",  "domain": ["geosite:win-spy"] },
      { "type": "field", "outboundTag": "direct", "ip": ["geoip:private"] },
      { "type": "field", "outboundTag": "direct", "ip": ["geoip:ru"] },
      { "type": "field", "outboundTag": "direct",
        "ip": ["103.10.124.0/22", "103.28.54.0/23", "146.66.152.0/21", "155.133.224.0/19",
               "162.254.192.0/18", "185.25.182.0/23", "185.86.148.0/22", "192.69.96.0/22",
               "198.52.192.0/22", "199.59.148.0/22", "205.196.6.0/23", "208.64.200.0/22"] },
      { "type": "field", "outboundTag": "direct",
        "domain": ["geosite:whitelist", "geosite:category-ru", "geosite:steam", "geosite:microsoft", "geosite:apple"] },
      { "type": "field", "outboundTag": "direct", "port": "6881-6889" },
      { "type": "field", "outboundTag": "direct", "network": "udp", "port": "500,1701,4500" },
      { "type": "field", "outboundTag": "block",  "network": "udp", "port": "443" },
      { "type": "field", "balancerTag": "vpn-balancer", "network": "tcp,udp" }
    ]
  }
}
CFG
}

# ══════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════

main() {
  clear
  printf '%s═══════════════════════════════════════%s\n' "$C_BOLD" "$C_RESET"
  printf '  Xiaomi AX3000T · Обновление VLESS\n'
  printf '%s═══════════════════════════════════════%s\n\n' "$C_BOLD" "$C_RESET"

  # ── 1. Router IP & password ──────────────────────────────────────────
  log_step "Подключение к роутеру"
  ask "IP роутера" ROUTER_IP
  ask_secret "Root-пароль (пусто если нет)" ROOT_PASSWORD
  save_state
  write_askpass

  log_info "Проверяю SSH..."
  local uname
  uname="$(rssh_q 'uname -m')"
  if [ -z "$uname" ]; then
    log_err "SSH не отвечает. Проверь IP и пароль."
    exit 1
  fi
  local xray_ver
  xray_ver="$(rssh_q '/usr/local/bin/xray version 2>/dev/null | head -1' | awk '{print $2}')"
  log_ok "arch=$uname  xray=${xray_ver:-не найден}"

  # ── 2. VLESS URL ─────────────────────────────────────────────────────
  log_step "Новая VLESS-ссылка"
  while :; do
    ask "VLESS URL" VLESS_URL
    if parse_vless_url "$VLESS_URL"; then
      show_vless_parsed
      confirm "Параметры корректны?" y && break
    fi
  done

  log_step "Основной домен сервера (для TLS на L2/L3 fallback-слоях)"
  ask "SERVER_DOMAIN" SERVER_DOMAIN
  save_state

  # ── 3. Generate + upload template ────────────────────────────────────
  log_step "Генерирую конфиг"
  local tmp_cfg
  tmp_cfg="$(mktemp)"
  generate_config "$tmp_cfg" || { rm -f "$tmp_cfg"; exit 1; }
  log_ok "Конфиг сгенерирован"

  log_info "Заливаю шаблон на роутер..."
  rssh_pipe "/usr/local/etc/xray/config.json.template" < "$tmp_cfg"
  rm -f "$tmp_cfg"

  # ── 4. Apply custom-direct list ──────────────────────────────────────
  log_step "Применяю custom-direct список"
  if ! rssh "/usr/local/bin/xray-add-direct 2>&1"; then
    log_err "xray-add-direct завершился с ошибкой — конфиг не применён"
    exit 1
  fi

  # ── 5. Status ─────────────────────────────────────────────────────────
  log_step "Проверка"
  rssh "/etc/init.d/xray status"
  printf '\n'
  log_ok "Готово — VLESS обновлён и xray перезапущен"
}

# ── Sanity checks ──────────────────────────────────────────────────────

if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "[ERR] Нужен bash 4+ (у тебя: ${BASH_VERSION:-не bash})" >&2
  exit 1
fi
command -v ssh >/dev/null || { echo "[ERR] ssh не найден в PATH" >&2; exit 1; }

if [ -f /etc/openwrt_release ]; then
  echo "[ERR] Скрипт запущен на роутере. Запускай на локальной машине (Git Bash)." >&2
  exit 1
fi

# Lock
if [ -f "$LOCK_FILE" ]; then
  pid=$(cat "$LOCK_FILE" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "[ERR] Уже запущен (PID $pid)" >&2; exit 1
  fi
  rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM HUP

load_state
main
