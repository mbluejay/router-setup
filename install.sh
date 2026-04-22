#!/usr/bin/env bash
#
# VLESS TProxy installer for Xiaomi AX3000T (OpenWrt).
# Interactive menu — install / update / diagnose / uninstall.
#
# Запускать на ЛОКАЛЬНОЙ машине (Windows Git Bash / macOS / Linux).
# Скрипт сам подключается к роутеру по SSH — на роутер его копировать НЕ НУЖНО.
#
# Requirements on host: bash 4+, ssh, scp.
# Requirements on router: OpenWrt 25.x with root SSH access.
#
# See public/README.md and public/vless-tproxy-openwrt-ax3000t.md for details.

set -u

# ══════════════════════════════════════════════════════════════════════════
# Configuration
# ══════════════════════════════════════════════════════════════════════════

STATE_DIR="$HOME/.xray-installer"
STATE_FILE="$STATE_DIR/state"
ASKPASS_FILE="$STATE_DIR/askpass.sh"
LOCK_FILE="/tmp/xray-installer-${USER:-unknown}.lock"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_SNAPSHOT="/usr/local/etc/xray-installer/pre-install.snapshot"
DRY_RUN=0

# State variables (defaults, overwritten by load_state)
ROUTER_IP="192.168.1.1"
ROOT_PASSWORD=""
VLESS_URL=""
WIFI_SSID=""
WIFI_PASSWORD=""
WIFI_CHANNEL="auto"
NEW_LAN_IP=""

# Parsed VLESS fields
VLESS_NAME="" VLESS_UUID="" VLESS_SERVER="" VLESS_PORT=""
VLESS_SECURITY="" VLESS_PBKEY="" VLESS_SNI="" VLESS_FP="chrome"
VLESS_FLOW="" VLESS_SID="" VLESS_TRANSPORT="tcp"
VLESS_PATH="" VLESS_HOST=""

# Detected router state
ROUTER_CONNECTED=0
ROUTER_OPENWRT_VERSION=""
ROUTER_ARCH=""
ROUTER_XRAY_VERSION=""

# ══════════════════════════════════════════════════════════════════════════
# Colors and logging
# ══════════════════════════════════════════════════════════════════════════

if [ -t 1 ]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'; C_MAGENTA=$'\e[35m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_MAGENTA=""
fi

log_info()  { printf '%s[INFO]%s %s\n' "$C_CYAN"   "$C_RESET" "$1"; }
log_ok()    { printf '%s[ OK ]%s %s\n' "$C_GREEN"  "$C_RESET" "$1"; }
log_warn()  { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
log_err()   { printf '%s[ERR ]%s %s\n' "$C_RED"    "$C_RESET" "$1" >&2; }
log_step()  { printf '\n%s▶ %s%s\n' "$C_BOLD$C_BLUE" "$1" "$C_RESET"; }
show_cmd()  { printf '  %s$ %s%s\n' "$C_DIM" "$1" "$C_RESET"; }

pause() {
  printf '\nНажми Enter для продолжения...'
  read -r _
}

# ══════════════════════════════════════════════════════════════════════════
# State persistence
# ══════════════════════════════════════════════════════════════════════════

save_state() {
  mkdir -p "$STATE_DIR"
  cat > "$STATE_FILE" <<EOF
ROUTER_IP=$(printf '%q' "$ROUTER_IP")
VLESS_URL=$(printf '%q' "$VLESS_URL")
WIFI_SSID=$(printf '%q' "$WIFI_SSID")
WIFI_CHANNEL=$(printf '%q' "$WIFI_CHANNEL")
NEW_LAN_IP=$(printf '%q' "$NEW_LAN_IP")
EOF
}

load_state() {
  [ -f "$STATE_FILE" ] && . "$STATE_FILE"
}

write_askpass() {
  mkdir -p "$STATE_DIR"
  cat > "$ASKPASS_FILE" <<EOF
#!/bin/sh
echo "$ROOT_PASSWORD"
EOF
  chmod 700 "$ASKPASS_FILE"
}

acquire_lock() {
  if [ -f "$LOCK_FILE" ]; then
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log_err "Установщик уже запущен (PID $pid). Закрой другое окно или терминал."
      exit 1
    fi
    log_warn "Найден старый lock-файл (PID $pid завершён), удаляю..."
    rm -f "$LOCK_FILE"
  fi
  echo $$ > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT INT TERM HUP
}

# ══════════════════════════════════════════════════════════════════════════
# SSH helpers
# ══════════════════════════════════════════════════════════════════════════

# Run command on router. $1 = command. Return code = ssh exit code.
rssh() {
  local cmd="$1"
  show_cmd "ssh root@$ROUTER_IP '$cmd'"
  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[DRY-RUN]%s\n' "$C_DIM" "$C_RESET"
    return 0
  fi
  SSH_ASKPASS="$ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force DISPLAY=1 \
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      root@"$ROUTER_IP" "$cmd"
}

# Quiet version — no show_cmd, for internal checks
rssh_q() {
  [ "$DRY_RUN" = 1 ] && return 0
  SSH_ASKPASS="$ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force DISPLAY=1 \
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      root@"$ROUTER_IP" "$1" 2>/dev/null
}

rscp() {
  local src="$1" dst="$2"
  show_cmd "scp '$src' → root@$ROUTER_IP:$dst"
  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[DRY-RUN]%s\n' "$C_DIM" "$C_RESET"
    return 0
  fi
  SSH_ASKPASS="$ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force DISPLAY=1 \
    scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      "$src" root@"$ROUTER_IP":"$dst"
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
    printf '%s [Y/n]: ' "$prompt"
    read -r yn
    [ -z "$yn" ] || [ "$yn" = "y" ] || [ "$yn" = "Y" ]
  else
    printf '%s [y/N]: ' "$prompt"
    read -r yn
    [ "$yn" = "y" ] || [ "$yn" = "Y" ]
  fi
}

# ══════════════════════════════════════════════════════════════════════════
# VLESS URL parsing
# ══════════════════════════════════════════════════════════════════════════

urldecode() {
  # Portable URL decoder
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

  local old_ifs="$IFS"
  IFS='&'
  for pair in $query; do
    local k="${pair%%=*}" v="${pair#*=}"
    v="$(urldecode "$v")"
    case "$k" in
      security) VLESS_SECURITY="$v" ;;
      pbk)      VLESS_PBKEY="$v" ;;
      sni)      VLESS_SNI="$v" ;;
      fp)       VLESS_FP="$v" ;;
      flow)     VLESS_FLOW="$v" ;;
      sid)      VLESS_SID="$v" ;;
      type)     VLESS_TRANSPORT="$v" ;;
      path)     VLESS_PATH="$v" ;;
      host)     VLESS_HOST="$v" ;;
    esac
  done
  IFS="$old_ifs"
}

show_vless_parsed() {
  printf '\n%sРаспознанные параметры VLESS:%s\n' "$C_BOLD" "$C_RESET"
  printf '  Имя:        %s\n' "$VLESS_NAME"
  printf '  UUID:       %s\n' "$VLESS_UUID"
  printf '  Сервер:     %s:%s\n' "$VLESS_SERVER" "$VLESS_PORT"
  printf '  Security:   %s\n' "$VLESS_SECURITY"
  printf '  Transport:  %s\n' "$VLESS_TRANSPORT"
  printf '  SNI:        %s\n' "$VLESS_SNI"
  printf '  Fingerprint: %s\n' "$VLESS_FP"
  if [ "$VLESS_SECURITY" = "reality" ]; then
    printf '  PublicKey:  %s\n' "$VLESS_PBKEY"
    printf '  ShortID:    %s\n' "$VLESS_SID"
  fi
  [ -n "$VLESS_FLOW" ] && printf '  Flow:       %s\n' "$VLESS_FLOW"
  [ -n "$VLESS_PATH" ] && printf '  Path:       %s\n' "$VLESS_PATH"
  [ -n "$VLESS_HOST" ] && printf '  Host:       %s\n' "$VLESS_HOST"
  printf '\n'
}

# ══════════════════════════════════════════════════════════════════════════
# Router connection & detection
# ══════════════════════════════════════════════════════════════════════════

ping_host() {
  local host="$1"
  case "$(uname -s)" in
    MINGW*|CYGWIN*|MSYS*)
      ping -n 1 "$host" > /dev/null 2>&1 ;;
    *)
      ping -c 1 -W 2 "$host" > /dev/null 2>&1 ;;
  esac
}

connect_to_router() {
  log_step "Подключение к роутеру"

  if [ "$DRY_RUN" = 1 ]; then
    log_info "[DRY-RUN] Пропускаю ping и SSH-проверку"
    ROUTER_CONNECTED=1
    ROUTER_ARCH="aarch64_cortex-a53"
    ROUTER_OPENWRT_VERSION="DRY-RUN"
    ROUTER_XRAY_VERSION="DRY-RUN"
    log_ok "arch=$ROUTER_ARCH, OpenWrt=$ROUTER_OPENWRT_VERSION, xray=$ROUTER_XRAY_VERSION"
    pause
    return 0
  fi

  ask "IP роутера" ROUTER_IP
  if [ -z "$ROOT_PASSWORD" ]; then
    ask_secret "Root-пароль (пусто если нет)" ROOT_PASSWORD
  fi
  save_state
  write_askpass

  # Reachability
  log_info "Проверяю доступность $ROUTER_IP..."
  if ! ping_host "$ROUTER_IP"; then
    log_err "$ROUTER_IP не отвечает на ping. Проверь кабель и IP."
    ROUTER_CONNECTED=0
    pause
    return 1
  fi
  log_ok "ping OK"

  # SSH
  log_info "Проверяю SSH..."
  local uname arch release
  uname="$(rssh_q 'uname -m')"
  if [ -z "$uname" ]; then
    log_err "SSH не работает. Проверь пароль и firewall."
    ROUTER_CONNECTED=0
    pause
    return 1
  fi
  ROUTER_ARCH="$uname"

  release="$(rssh_q 'cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_DESCRIPTION')"
  if [ -z "$release" ]; then
    log_err "Это не OpenWrt."
    log_warn "Нужно прошить роутер: https://openwrt.org/toh/xiaomi/ax3000t"
    ROUTER_CONNECTED=0
    pause
    return 1
  fi
  ROUTER_OPENWRT_VERSION="$(echo "$release" | sed -n "s/.*='OpenWrt \(.*\)'/\1/p")"
  [ -z "$ROUTER_OPENWRT_VERSION" ] && ROUTER_OPENWRT_VERSION="unknown"

  # Detect xray
  local xray_ver
  xray_ver="$(rssh_q '/usr/local/bin/xray version 2>/dev/null | head -1')"
  if [ -n "$xray_ver" ]; then
    ROUTER_XRAY_VERSION="$(echo "$xray_ver" | awk '{print $2}')"
  else
    ROUTER_XRAY_VERSION="not installed"
  fi

  ROUTER_CONNECTED=1
  log_ok "arch=$ROUTER_ARCH, OpenWrt=$ROUTER_OPENWRT_VERSION, xray=$ROUTER_XRAY_VERSION"
  pause
}

# ══════════════════════════════════════════════════════════════════════════
# Snapshot / restore pre-install state on router
# ══════════════════════════════════════════════════════════════════════════

create_snapshot() {
  log_step "Создаю снэпшот текущего состояния для возможного отката"
  rssh "mkdir -p $(dirname $REMOTE_SNAPSHOT) && {
    echo '=== dhcp_section ===';
    uci export dhcp 2>/dev/null || true;
    echo '=== network_section ===';
    uci export network 2>/dev/null || true;
    echo '=== wireless_section ===';
    uci export wireless 2>/dev/null || true;
    echo '=== firewall_section ===';
    uci export firewall 2>/dev/null || true;
    echo '=== odhcpd_enabled ===';
    [ -x /etc/init.d/odhcpd ] && /etc/init.d/odhcpd enabled && echo yes || echo no;
    echo '=== crontab ===';
    crontab -l 2>/dev/null || true;
    echo '=== end ===';
  } > $REMOTE_SNAPSHOT" && log_ok "Снэпшот сохранён в $REMOTE_SNAPSHOT"
}

has_snapshot() {
  [ -n "$(rssh_q "[ -f $REMOTE_SNAPSHOT ] && echo yes")" ]
}

# ══════════════════════════════════════════════════════════════════════════
# Feature: collect parameters for install
# ══════════════════════════════════════════════════════════════════════════

collect_install_params() {
  log_step "Сбор параметров установки"
  while :; do
    ask "VLESS URL" VLESS_URL
    if parse_vless_url "$VLESS_URL"; then
      show_vless_parsed
      if confirm "Параметры корректны?" y; then
        break
      fi
    fi
  done

  ask "WiFi SSID (5ГГц)" WIFI_SSID
  if [ -z "$WIFI_PASSWORD" ]; then
    ask_secret "WiFi пароль (мин 8 симв)" WIFI_PASSWORD
  else
    if ! confirm "Оставить текущий WiFi пароль?" y; then
      ask_secret "Новый WiFi пароль" WIFI_PASSWORD
    fi
  fi

  printf '\n'
  if confirm "Сменить LAN IP роутера? (если 192.168.1.x занят корневым роутером)" n; then
    ask "Новый LAN IP (будет IP роутера после установки)" NEW_LAN_IP
  fi

  save_state
}

# ══════════════════════════════════════════════════════════════════════════
# Feature: generate config.json with parsed VLESS params
# ══════════════════════════════════════════════════════════════════════════

generate_config() {
  local out="$1"
  local stream=""
  case "$VLESS_SECURITY-$VLESS_TRANSPORT" in
    reality-tcp)
      stream=$(cat <<EOF
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
EOF
)
      ;;
    tls-ws)
      stream=$(cat <<EOF
        "streamSettings": {
          "network": "ws",
          "security": "tls",
          "tlsSettings": { "serverName": "$VLESS_SNI", "fingerprint": "$VLESS_FP" },
          "wsSettings": { "path": "$VLESS_PATH", "headers": { "Host": "$VLESS_HOST" } },
          "sockopt": { "mark": 255 }
        }
EOF
)
      ;;
    tls-grpc)
      stream=$(cat <<EOF
        "streamSettings": {
          "network": "grpc",
          "security": "tls",
          "tlsSettings": { "serverName": "$VLESS_SNI" },
          "grpcSettings": { "serviceName": "$VLESS_PATH" },
          "sockopt": { "mark": 255 }
        }
EOF
)
      ;;
    *)
      log_err "Неподдерживаемая комбинация security=$VLESS_SECURITY transport=$VLESS_TRANSPORT"
      return 1
      ;;
  esac

  cat > "$out" <<CFG
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      {
        "address": "https://1.1.1.1/dns-query",
        "domains": [
          "domain:x.com",
          "domain:twitter.com",
          "domain:t.co",
          "domain:twimg.com",
          "domain:themoviedb.org",
          "domain:tmdb.org"
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
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$VLESS_SERVER",
          "port": $VLESS_PORT,
          "users": [{ "id": "$VLESS_UUID", "flow": "$VLESS_FLOW", "encryption": "none" }]
        }]
      },
$stream
    },
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" },
      "streamSettings": { "sockopt": { "mark": 255 } }
    },
    { "tag": "block", "protocol": "blackhole" },
    { "tag": "dns-out", "protocol": "dns" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["dns-in"], "outboundTag": "dns-out" },
      { "type": "field", "outboundTag": "block", "domain": ["geosite:win-spy"] },
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
      { "type": "field", "outboundTag": "block", "domain": ["domain:rutracker.org", "domain:claude.ai", "domain:claude.com", "domain:anthropic.com"], "network": "udp", "port": "443" },
      { "type": "field", "outboundTag": "proxy", "network": "tcp,udp" }
    ]
  }
}
CFG
}

# ══════════════════════════════════════════════════════════════════════════
# Feature functions — each is idempotent
# ══════════════════════════════════════════════════════════════════════════

# Feature: Core xray + TProxy + Split-DNS
feature_core_install() {
  log_step "[CORE] Устанавливаю xray, TProxy, Split-DNS"

  # 1. Upload xray binary
  if [ ! -f "$SCRIPT_DIR/bin/xray" ]; then
    log_err "Не найден $SCRIPT_DIR/bin/xray — скачай бинарник xray для linux/arm64 в папку bin/"
    return 1
  fi

  log_info "Загружаю бинарник xray..."
  rssh "mkdir -p /usr/local/bin /usr/local/etc/xray /var/log/xray"
  rscp "$SCRIPT_DIR/bin/xray" "/usr/local/bin/xray"
  rssh "chmod +x /usr/local/bin/xray"

  # 2. Install required packages (via bootstrap proxy if apk is blocked)
  log_info "Проверяю наличие пакетов (nftables, kmod-nft-tproxy)..."
  local have_pkgs
  have_pkgs="$(rssh_q 'apk list --installed 2>/dev/null | grep -cE "^(nftables|kmod-nft-tproxy|kmod-nft-socket) "')"
  if [ "${have_pkgs:-0}" -lt 3 ]; then
    log_warn "Нужных пакетов нет, запускаю bootstrap через временный xray HTTP proxy"
    bootstrap_xray_http_proxy || { log_err "Bootstrap proxy не поднялся"; return 1; }
    install_packages_via_bootstrap || { log_err "Установка пакетов через proxy не удалась"; return 1; }
  else
    log_ok "Пакеты уже установлены"
  fi

  # 3. Download geo bases
  log_info "Скачиваю geo-базы..."
  rssh "cd /usr/local/etc/xray && {
    [ -s geoip.dat ] || wget -q --no-check-certificate -O geoip.dat https://github.com/v2fly/geoip/releases/latest/download/geoip.dat;
    [ -s geosite.dat ] || wget -q --no-check-certificate -O geosite.dat https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat;
    ls -lh *.dat;
  }"

  # 4. Generate and upload config
  log_info "Генерирую config.json..."
  local tmp_cfg
  tmp_cfg="$(mktemp)"
  generate_config "$tmp_cfg" || { rm -f "$tmp_cfg"; return 1; }
  rscp "$tmp_cfg" "/usr/local/etc/xray/config.json"
  rm -f "$tmp_cfg"
  rssh "XRAY_LOCATION_ASSET=/usr/local/etc/xray /usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json | tail -3"

  # 5. Upload scripts
  log_info "Загружаю скрипты..."
  rscp "$SCRIPT_DIR/xray-tproxy-setup.sh" "/usr/local/bin/xray-tproxy-setup.sh"
  rscp "$SCRIPT_DIR/xray-geo-update.sh" "/usr/local/bin/xray-geo-update.sh"
  rscp "$SCRIPT_DIR/xray-add-direct" "/usr/local/bin/xray-add-direct"
  rscp "$SCRIPT_DIR/xray-remove-direct" "/usr/local/bin/xray-remove-direct"
  rscp "$SCRIPT_DIR/xray-init" "/etc/init.d/xray"
  rssh "chmod +x /usr/local/bin/xray-tproxy-setup.sh /usr/local/bin/xray-geo-update.sh /usr/local/bin/xray-add-direct /usr/local/bin/xray-remove-direct /etc/init.d/xray"

  # 5a. Upload config template + custom-direct list (list only if not present)
  log_info "Загружаю шаблон конфига и custom-direct список..."
  rscp "$SCRIPT_DIR/config.json.template" "/usr/local/etc/xray/config.json.template"
  if rssh_q "test -f /usr/local/etc/xray/custom-direct.list && echo exists" | grep -q exists; then
    log_info "custom-direct.list уже есть на роутере — не перетираю"
  else
    rscp "$SCRIPT_DIR/custom-direct.list" "/usr/local/etc/xray/custom-direct.list"
  fi

  # 6. Hotplug
  log_info "Устанавливаю hotplug..."
  rssh 'mkdir -p /etc/hotplug.d/iface && cat > /etc/hotplug.d/iface/99-xray-tproxy <<"HP"
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
ip rule show | grep -q "fwmark 0x1 lookup 100" || {
    ip rule add fwmark 1 lookup 100 2>/dev/null
    ip route show table 100 | grep -q "local default" || \
        ip route add local default dev lo table 100 2>/dev/null
    logger -t xray-tproxy "ip rules restored via hotplug"
}
HP
chmod +x /etc/hotplug.d/iface/99-xray-tproxy'

  # 7. Cron for geo-update (log-truncate added by its own feature)
  log_info "Настраиваю cron для geo-update..."
  rssh "(crontab -l 2>/dev/null | grep -v xray-geo-update; echo '0 4 * * 0 /usr/local/bin/xray-geo-update.sh') | crontab -"

  # 8. Split DNS in dnsmasq
  log_info "Настраиваю split-DNS..."
  rssh "
    uci set dhcp.@dnsmasq[0].noresolv=1
    uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null || true
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5300'
    uci add_list dhcp.@dnsmasq[0].server='77.88.8.8'
    uci set dhcp.@dnsmasq[0].strictorder=1
    uci set dhcp.@dnsmasq[0].cachesize=3000
    uci commit dhcp
    /etc/init.d/dnsmasq restart
  "

  # 9. Enable and start xray (stops any bootstrap proxy first)
  log_info "Запускаю xray как сервис..."
  rssh "pkill -f 'xray run -c /tmp/proxy' 2>/dev/null; sleep 1
    /etc/init.d/xray enable
    /etc/init.d/xray start
    sleep 4
    /etc/init.d/xray status
  "

  # 10. Regenerate config from template + custom-direct.list (injects seed domains)
  log_info "Применяю custom-direct список к конфигу..."
  rssh "/usr/local/bin/xray-add-direct 2>&1 | tail -2"

  log_ok "[CORE] Установлено"
}

bootstrap_xray_http_proxy() {
  log_info "Поднимаю временный HTTP proxy через xray для установки пакетов..."
  local tmp_cfg
  tmp_cfg="$(mktemp)"
  local stream
  stream=$(cat <<EOF
{
  "network": "$VLESS_TRANSPORT",
  "security": "$VLESS_SECURITY",
  "realitySettings": {
    "serverName": "$VLESS_SNI",
    "fingerprint": "$VLESS_FP",
    "publicKey": "$VLESS_PBKEY",
    "shortId": "$VLESS_SID"
  }
}
EOF
)
  cat > "$tmp_cfg" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"port": 8118, "listen": "127.0.0.1", "protocol": "http", "settings": {}}],
  "outbounds": [{
    "protocol": "vless",
    "settings": {"vnext": [{"address": "$VLESS_SERVER", "port": $VLESS_PORT,
      "users": [{"id": "$VLESS_UUID", "flow": "$VLESS_FLOW", "encryption": "none"}]}]},
    "streamSettings": $stream
  }]
}
EOF
  rscp "$tmp_cfg" "/tmp/proxy.json"
  rm -f "$tmp_cfg"
  rssh "/usr/local/bin/xray run -c /tmp/proxy.json > /tmp/xray-proxy.log 2>&1 &
    sleep 3
    http_proxy=http://127.0.0.1:8118 wget -q --timeout=15 -O /dev/null http://example.com && echo BOOTSTRAP_OK"
}

install_packages_via_bootstrap() {
  log_info "Ставлю пакеты через bootstrap proxy..."
  rssh "sed -i 's|https://|http://|g' /etc/apk/repositories.d/distfeeds.list
    export http_proxy=http://127.0.0.1:8118
    apk update
    apk add wget unzip kmod-tun ip-full nftables kmod-nft-tproxy kmod-nft-socket jq
    sed -i 's|http://downloads|https://downloads|g' /etc/apk/repositories.d/distfeeds.list
    echo PACKAGES_OK"
}

# Feature: WiFi 5GHz-only
feature_wifi_install() {
  log_step "[WIFI] Настраиваю 5ГГц AP '$WIFI_SSID'"
  rssh "
    uci set wireless.radio0.disabled=1
    for iface in \$(uci show wireless | grep \"device='radio0'\" | cut -d. -f2); do
      uci set wireless.\${iface}.disabled=1
    done
    uci set wireless.radio1.disabled=0
    uci set wireless.radio1.channel="${WIFI_CHANNEL:-auto}"
    uci set wireless.radio1.htmode=HE80
    uci set wireless.radio1.country=RU
    uci set wireless.radio1.txpower=30
    uci set wireless.default_radio1.mode=ap
    uci set wireless.default_radio1.ssid='$WIFI_SSID'
    uci set wireless.default_radio1.encryption=psk2+ccmp
    uci set wireless.default_radio1.key='$WIFI_PASSWORD'
    uci set wireless.default_radio1.disabled=0
    uci set wireless.default_radio1.ieee80211r=0
    uci commit wireless
    wifi down && sleep 2 && wifi up
  "
  log_ok "[WIFI] Настроено"
}

# Feature: IPv6 disable on LAN
feature_ipv6_install() {
  log_step "[IPV6] Отключаю IPv6 на LAN"
  rssh "
    uci set dhcp.@dnsmasq[0].filter_aaaa=1
    uci -q delete network.lan.ip6assign 2>/dev/null || true
    /etc/init.d/odhcpd stop 2>/dev/null
    /etc/init.d/odhcpd disable 2>/dev/null
    uci commit dhcp
    uci commit network
    /etc/init.d/dnsmasq restart
    /etc/init.d/network reload
  "
  log_ok "[IPV6] Отключено"
}

# Feature: DNS hijack (Xbox/PS5 fix) — included in xray-tproxy-setup.sh already
feature_dns_hijack_install() {
  log_step "[DNS-HIJACK] Применяю правила (перезапуск xray)"
  rssh "/etc/init.d/xray restart && sleep 3 && nft list table inet dns_hijack | head -10"
  log_ok "[DNS-HIJACK] Активно"
}

# Feature: log rotation
feature_log_truncate_install() {
  log_step "[LOG-ROTATE] Устанавливаю обрезку access.log"
  rscp "$SCRIPT_DIR/xray-log-truncate.sh" "/usr/local/bin/xray-log-truncate.sh"
  rssh "chmod +x /usr/local/bin/xray-log-truncate.sh
    (crontab -l 2>/dev/null | grep -v xray-log-truncate; echo '0 * * * * /usr/local/bin/xray-log-truncate.sh') | crontab -
  "
  log_ok "[LOG-ROTATE] Установлено"
}

# Feature: Cloudflare DoH for problematic domains (included in config.json.template)
feature_doh_install() {
  log_step "[DOH-CF] DoH для x.com/twitter/themoviedb — уже в config.json"
  log_ok "[DOH-CF] Активно (часть конфига)"
}

# Feature: QUIC block for rutracker + claude.ai (included in config.json.template)
feature_quic_block_install() {
  log_step "[QUIC-BLOCK] QUIC-блок для rutracker + claude — уже в config.json"
  log_ok "[QUIC-BLOCK] Активно (часть конфига)"
}

# ══════════════════════════════════════════════════════════════════════════
# LAN IP change (optional, destructive — SSH drops)
# ══════════════════════════════════════════════════════════════════════════

change_lan_ip() {
  [ -z "$NEW_LAN_IP" ] && return 0
  [ "$NEW_LAN_IP" = "$ROUTER_IP" ] && return 0
  log_step "[LAN-IP] Меняю LAN IP на $NEW_LAN_IP"
  log_warn "SSH соединение оборвётся после этого шага!"
  log_warn "Поменяй IP адаптера ноутбука на ${NEW_LAN_IP%.*}.100 / 255.255.255.0"
  if confirm "Продолжить?" n; then
    rssh "
      uci set network.lan.ipaddr='$NEW_LAN_IP'
      uci set network.lan.netmask='255.255.255.0'
      uci commit network
      (sleep 2 && /etc/init.d/network restart) &
    " || true
    ROUTER_IP="$NEW_LAN_IP"
    save_state
    log_info "После смены IP адаптера — запусти скрипт заново и выбери 'Connect to router'."
  fi
}

# ══════════════════════════════════════════════════════════════════════════
# Menu: Full install
# ══════════════════════════════════════════════════════════════════════════

menu_full_install() {
  [ "$ROUTER_CONNECTED" = 1 ] || { log_warn "Сначала подключись к роутеру (пункт 1)"; pause; return; }

  log_step "Полная установка"
  collect_install_params

  printf '%sБудут выполнены шаги:%s\n' "$C_BOLD" "$C_RESET"
  printf '  1. Снэпшот текущей конфигурации (для отката)\n'
  printf '  2. Установка xray + geo-баз + TProxy + Split-DNS + DNS-хайджек\n'
  printf '  3. Cron-задачи: geo-update, log-truncate\n'
  printf '  4. WiFi 5ГГц AP "%s"\n' "$WIFI_SSID"
  printf '  5. Отключение IPv6 на LAN\n'
  [ -n "$NEW_LAN_IP" ] && printf '  6. Смена LAN IP на %s\n' "$NEW_LAN_IP"
  printf '\n'

  if ! confirm "Начать установку?" y; then
    log_info "Отменено"
    pause
    return
  fi

  create_snapshot
  feature_core_install          || { log_err "Core install failed"; pause; return; }
  feature_log_truncate_install  || log_warn "Log rotate failed (не критично)"
  feature_dns_hijack_install    || log_warn "DNS hijack failed"
  feature_doh_install
  feature_quic_block_install
  feature_wifi_install          || log_warn "WiFi failed"
  feature_ipv6_install          || log_warn "IPv6 disable failed"
  change_lan_ip

  log_ok "Полная установка завершена"
  pause
}

# ══════════════════════════════════════════════════════════════════════════
# Menu: Custom install
# ══════════════════════════════════════════════════════════════════════════

# Feature toggle state
declare -A FEATURE_ENABLED=(
  [core]=1 [log]=1 [dnshj]=1 [doh]=1 [quic]=1 [wifi]=1 [ipv6]=1
)

render_feature() {
  local key="$1" name="$2" num="$3"
  local mark="[ ]"
  [ "${FEATURE_ENABLED[$key]}" = 1 ] && mark="[x]"
  printf '  %s %s) %s\n' "$mark" "$num" "$name"
}

menu_custom_install() {
  [ "$ROUTER_CONNECTED" = 1 ] || { log_warn "Сначала подключись к роутеру (пункт 1)"; pause; return; }

  while :; do
    clear
    printf '%s═══ Custom install — выбор фич ═══%s\n\n' "$C_BOLD" "$C_RESET"
    render_feature core  "Core xray + TProxy + Split-DNS (обязательно)" 1
    render_feature wifi  "WiFi 5GHz-only ($WIFI_SSID)" 2
    render_feature ipv6  "IPv6 disable on LAN" 3
    render_feature dnshj "DNS hijack (Xbox/PS5 fix)" 4
    render_feature log   "Log rotation" 5
    render_feature doh   "Cloudflare DoH for x.com/twitter/themoviedb" 6
    render_feature quic  "QUIC block rutracker.org + claude.ai" 7
    printf '    c) WiFi канал: %-6s  [auto | 36 | 100 | 149]\n' "$WIFI_CHANNEL"
    printf '\n  9) Продолжить к установке\n'
    printf '  0) Назад\n\n'
    printf '> '
    read -r choice
    case "$choice" in
      1) log_warn "Core обязателен — нельзя отключить" ; sleep 1 ;;
      2) toggle_feature wifi ;;
      3) toggle_feature ipv6 ;;
      4) toggle_feature dnshj ;;
      5) toggle_feature log ;;
      6) toggle_feature doh ;;
      7) toggle_feature quic ;;
      c|C)
        case "$WIFI_CHANNEL" in
          auto) WIFI_CHANNEL=36 ;;
          36)   WIFI_CHANNEL=100 ;;
          100)  WIFI_CHANNEL=149 ;;
          *)    WIFI_CHANNEL=auto ;;
        esac ;;
      9) break ;;
      0) return ;;
      *) log_warn "Неверный выбор"; sleep 1 ;;
    esac
  done

  collect_install_params

  printf '%sБудут установлены выбранные фичи.%s\n' "$C_BOLD" "$C_RESET"
  if ! confirm "Начать?" y; then
    log_info "Отменено"
    pause
    return
  fi

  create_snapshot
  feature_core_install || { log_err "Core failed"; pause; return; }
  [ "${FEATURE_ENABLED[log]}"   = 1 ] && feature_log_truncate_install
  [ "${FEATURE_ENABLED[dnshj]}" = 1 ] && feature_dns_hijack_install
  [ "${FEATURE_ENABLED[doh]}"   = 1 ] && feature_doh_install
  [ "${FEATURE_ENABLED[quic]}"  = 1 ] && feature_quic_block_install
  [ "${FEATURE_ENABLED[wifi]}"  = 1 ] && feature_wifi_install
  [ "${FEATURE_ENABLED[ipv6]}"  = 1 ] && feature_ipv6_install
  change_lan_ip

  log_ok "Custom install завершена"
  pause
}

toggle_feature() {
  local key="$1"
  if [ "${FEATURE_ENABLED[$key]}" = 1 ]; then
    FEATURE_ENABLED[$key]=0
  else
    FEATURE_ENABLED[$key]=1
  fi
}

# ══════════════════════════════════════════════════════════════════════════
# Menu: Update
# ══════════════════════════════════════════════════════════════════════════

menu_update() {
  [ "$ROUTER_CONNECTED" = 1 ] || { log_warn "Сначала подключись к роутеру"; pause; return; }

  while :; do
    clear
    printf '%s═══ Update ═══%s\n\n' "$C_BOLD" "$C_RESET"
    printf '  1) Сменить VLESS URL (перегенерировать config.json)\n'
    printf '  2) Обновить geo-базы сейчас\n'
    printf '  3) Перелить скрипты (tproxy-setup, log-truncate, geo-update, init.d)\n'
    printf '  4) Поменять WiFi SSID/пароль\n'
    printf '  0) Назад\n\n'
    printf '> '
    read -r choice
    case "$choice" in
      1) update_vless_url ;;
      2) rssh "/usr/local/bin/xray-geo-update.sh && ls -lh /usr/local/etc/xray/*.dat"; pause ;;
      3) update_scripts ;;
      4) update_wifi ;;
      0) return ;;
      *) log_warn "Неверный выбор"; sleep 1 ;;
    esac
  done
}

update_vless_url() {
  while :; do
    ask "Новый VLESS URL" VLESS_URL
    if parse_vless_url "$VLESS_URL"; then
      show_vless_parsed
      if confirm "Параметры корректны?" y; then
        break
      fi
    fi
  done
  save_state
  local tmp_cfg
  tmp_cfg="$(mktemp)"
  generate_config "$tmp_cfg" || { rm -f "$tmp_cfg"; pause; return; }
  rscp "$tmp_cfg" "/usr/local/etc/xray/config.json"
  rm -f "$tmp_cfg"
  rssh "XRAY_LOCATION_ASSET=/usr/local/etc/xray /usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json | tail -3
    /etc/init.d/xray restart && sleep 3 && /etc/init.d/xray status"
  pause
}

update_scripts() {
  log_info "Перезаливаю скрипты..."
  rscp "$SCRIPT_DIR/xray-tproxy-setup.sh" "/usr/local/bin/xray-tproxy-setup.sh"
  rscp "$SCRIPT_DIR/xray-geo-update.sh"   "/usr/local/bin/xray-geo-update.sh"
  rscp "$SCRIPT_DIR/xray-log-truncate.sh" "/usr/local/bin/xray-log-truncate.sh"
  rscp "$SCRIPT_DIR/xray-add-direct"      "/usr/local/bin/xray-add-direct"
  rscp "$SCRIPT_DIR/xray-remove-direct"   "/usr/local/bin/xray-remove-direct"
  rscp "$SCRIPT_DIR/xray-init"             "/etc/init.d/xray"
  rscp "$SCRIPT_DIR/config.json.template"  "/usr/local/etc/xray/config.json.template"
  # custom-direct.list — пользовательские данные, не перетираем
  rssh "chmod +x /usr/local/bin/xray-*.sh /usr/local/bin/xray-add-direct /usr/local/bin/xray-remove-direct /etc/init.d/xray
    /etc/init.d/xray restart && sleep 3 && /etc/init.d/xray status
    /usr/local/bin/xray-add-direct 2>&1 | tail -1"
  pause
}

update_wifi() {
  ask "WiFi SSID" WIFI_SSID
  ask_secret "WiFi пароль" WIFI_PASSWORD
  save_state
  feature_wifi_install
  pause
}

# ══════════════════════════════════════════════════════════════════════════
# Menu: Diagnostics
# ══════════════════════════════════════════════════════════════════════════

menu_diagnostics() {
  [ "$ROUTER_CONNECTED" = 1 ] || { log_warn "Сначала подключись к роутеру"; pause; return; }

  while :; do
    clear
    printf '%s═══ Diagnostics ═══%s\n\n' "$C_BOLD" "$C_RESET"
    printf '  1) xray status\n'
    printf '  2) Тест конфига\n'
    printf '  3) Live access log (Ctrl+C чтобы выйти)\n'
    printf '  4) DNS-тесты (youtube/yandex/themoviedb/x.com)\n'
    printf '  5) nftables rules\n'
    printf '  6) ip rules + routes\n'
    printf '  7) Полный audit\n'
    printf '  8) Custom-direct список (cat custom-direct.list)\n'
    printf '  0) Назад\n\n'
    printf '> '
    read -r choice
    case "$choice" in
      1) rssh "/etc/init.d/xray status"; pause ;;
      2) rssh "XRAY_LOCATION_ASSET=/usr/local/etc/xray /usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json"; pause ;;
      3) rssh "tail -f /var/log/xray/access.log" ;;
      4) diag_dns ;;
      5) rssh "echo '=== xray_tproxy ==='; nft list table inet xray_tproxy; echo '=== dns_hijack ==='; nft list table inet dns_hijack"; pause ;;
      6) rssh "ip rule show; echo; ip route show table 100"; pause ;;
      7) diag_full_audit ;;
      8) rssh "echo '=== /usr/local/etc/xray/custom-direct.list ==='; cat /usr/local/etc/xray/custom-direct.list 2>/dev/null || echo '(empty or missing)'"; pause ;;
      0) return ;;
      *) log_warn "Неверный выбор"; sleep 1 ;;
    esac
  done
}

diag_dns() {
  log_info "DNS тесты:"
  rssh "for d in youtube.com yandex.ru api.themoviedb.org x.com rutracker.org; do
    echo -n \"\$d -> \"
    nslookup \"\$d\" 127.0.0.1 2>/dev/null | awk '/^Address: [0-9]/{print \$2; exit}'
  done"
  pause
}

diag_full_audit() {
  log_info "Полный audit:"
  rssh "
    echo '=== [1] XRAY STATUS ==='
    /etc/init.d/xray status
    echo '=== [2] CONFIG TEST ==='
    XRAY_LOCATION_ASSET=/usr/local/etc/xray /usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json 2>&1 | tail -2
    echo '=== [3] NFT TPROXY ==='
    nft list table inet xray_tproxy 2>&1 | head -15
    echo '=== [4] NFT DNS HIJACK ==='
    nft list table inet dns_hijack 2>&1 | head -10
    echo '=== [5] IP RULES ==='
    ip rule show | grep -E 'fwmark|lookup 100'
    echo '=== [6] IP ROUTE TABLE 100 ==='
    ip route show table 100
    echo '=== [7] PORTS ==='
    netstat -ulnp 2>/dev/null | grep -E '5300|12345'
    netstat -tlnp 2>/dev/null | grep -E '5300|12345'
    echo '=== [8] DNS TESTS ==='
    for d in youtube.com yandex.ru api.themoviedb.org x.com; do
      printf '  %s -> ' \$d
      nslookup \$d 127.0.0.1 2>/dev/null | awk '/^Address: [0-9]/{print \$2; exit}'
    done
    echo '=== [9] DNSMASQ ==='
    uci show dhcp | grep -E 'server|noresolv|strictorder|cachesize|filter_aaaa'
    echo '=== [10] CRON ==='
    crontab -l
    echo '=== [11] GEO ==='
    ls -lh /usr/local/etc/xray/*.dat
    echo '=== [12] WIFI ==='
    uci show wireless | grep -E '(radio[01]\.disabled|default_radio1\.ssid)'
    echo '=== [13] TMPFS USAGE ==='
    df -h /tmp
    echo '=== [14] LAST XRAY ERRORS ==='
    tail -5 /var/log/xray/error.log 2>/dev/null
  "
  pause
}

# ══════════════════════════════════════════════════════════════════════════
# Menu: Uninstall
# ══════════════════════════════════════════════════════════════════════════

menu_uninstall() {
  [ "$ROUTER_CONNECTED" = 1 ] || { log_warn "Сначала подключись к роутеру"; pause; return; }

  log_step "Uninstall"
  log_warn "Откатываются:"
  log_warn "  - xray сервис, бинарник, конфиги, geo-базы"
  log_warn "  - nftables таблицы (xray_tproxy, dns_hijack)"
  log_warn "  - cron записи (geo-update, log-truncate)"
  log_warn "  - hotplug скрипт"
  log_warn "  - dnsmasq настройки → восстановление из снэпшота"
  log_warn "  - odhcpd и IPv6 → восстановление из снэпшота"
  log_warn ""
  log_warn "НЕ откатываются (нужно явное подтверждение):"
  log_warn "  - WiFi настройки (SSID, пароль, radio0/radio1)"
  log_warn "  - LAN IP роутера"

  if ! confirm "Продолжить?" n; then
    log_info "Отменено"
    pause
    return
  fi

  if ! has_snapshot; then
    log_warn "Снэпшот не найден — восстановление dnsmasq/odhcpd невозможно, только удаление xray"
    if ! confirm "Всё равно удалить xray?" n; then
      pause
      return
    fi
  fi

  log_info "Останавливаю xray..."
  rssh "
    /etc/init.d/xray stop 2>/dev/null
    /etc/init.d/xray disable 2>/dev/null
    rm -f /etc/init.d/xray
    nft delete table inet xray_tproxy 2>/dev/null
    nft delete table inet dns_hijack 2>/dev/null
    ip rule del fwmark 1 lookup 100 2>/dev/null
    ip route flush table 100 2>/dev/null
  "

  log_info "Удаляю файлы..."
  rssh "
    rm -rf /usr/local/bin/xray /usr/local/bin/xray-tproxy-setup.sh \
           /usr/local/bin/xray-geo-update.sh /usr/local/bin/xray-log-truncate.sh \
           /usr/local/bin/xray-add-direct /usr/local/bin/xray-remove-direct \
           /usr/local/etc/xray /var/log/xray \
           /etc/hotplug.d/iface/99-xray-tproxy
  "

  log_info "Очищаю cron..."
  rssh "crontab -l 2>/dev/null | grep -vE 'xray-geo-update|xray-log-truncate' | crontab -"

  if has_snapshot; then
    log_info "Восстанавливаю dnsmasq/network/odhcpd из снэпшота..."
    rssh "
      awk '/^=== dhcp_section ===$/,/^=== network_section ===$/' $REMOTE_SNAPSHOT \
        | sed '1d;\$d' > /tmp/dhcp.restore
      awk '/^=== network_section ===$/,/^=== wireless_section ===$/' $REMOTE_SNAPSHOT \
        | sed '1d;\$d' > /tmp/network.restore

      if [ -s /tmp/dhcp.restore ]; then
        uci -q delete dhcp 2>/dev/null; uci import dhcp < /tmp/dhcp.restore; uci commit dhcp
      fi
      # network restore: rewriting whole config risky for LAN/WAN; better just restore IPv6 bits
      # Extract ip6assign if was present:
      if grep -q \"ip6assign\" $REMOTE_SNAPSHOT; then
        ASSIGN=\$(grep ip6assign $REMOTE_SNAPSHOT | head -1 | sed \"s/.*'\\(.*\\)'.*/\\1/\")
        [ -n \"\$ASSIGN\" ] && uci set network.lan.ip6assign=\"\$ASSIGN\" && uci commit network
      fi

      # odhcpd
      if grep -q '^=== odhcpd_enabled ===' $REMOTE_SNAPSHOT; then
        WAS=\$(awk '/^=== odhcpd_enabled ===$/{getline; print; exit}' $REMOTE_SNAPSHOT)
        if [ \"\$WAS\" = 'yes' ]; then
          /etc/init.d/odhcpd enable 2>/dev/null
          /etc/init.d/odhcpd start 2>/dev/null
        fi
      fi

      /etc/init.d/dnsmasq restart
      /etc/init.d/network reload
      rm -f /tmp/dhcp.restore /tmp/network.restore
    "
  fi

  log_ok "Uninstall завершён"
  log_info "WiFi и LAN IP остались как есть (по умолчанию не откатываются)"

  if confirm "Удалить снэпшот с роутера?" n; then
    rssh "rm -rf $(dirname $REMOTE_SNAPSHOT)"
  fi

  # Clear local state (optional)
  if confirm "Удалить локальный state-файл ($STATE_FILE)?" n; then
    rm -f "$STATE_FILE" "$ASKPASS_FILE"
  fi

  pause
}

# ══════════════════════════════════════════════════════════════════════════
# Main menu
# ══════════════════════════════════════════════════════════════════════════

main_menu() {
  while :; do
    clear
    cat <<EOF
${C_BOLD}═══════════════════════════════════════${C_RESET}
  Xiaomi AX3000T · VLESS TProxy Setup
${C_BOLD}═══════════════════════════════════════${C_RESET}
EOF
    if [ "$DRY_RUN" = 1 ]; then
      printf '%s  *** DRY-RUN: команды показываются, не выполняются ***%s\n' "$C_YELLOW" "$C_RESET"
    fi
    if [ "$ROUTER_CONNECTED" = 1 ]; then
      printf 'Router:   %s%s%s\n' "$C_GREEN" "$ROUTER_IP" "$C_RESET"
      printf 'OpenWrt:  %s\n' "$ROUTER_OPENWRT_VERSION"
      printf 'xray:     %s\n' "$ROUTER_XRAY_VERSION"
    else
      printf 'Router:   %s%s (not connected)%s\n' "$C_DIM" "$ROUTER_IP" "$C_RESET"
    fi
    printf '\n'
    printf ' 1)  Connect to router / change IP\n'
    printf ' 2)  Full install\n'
    printf ' 3)  Custom install\n'
    printf ' 4)  Update\n'
    printf ' 5)  Diagnostics\n'
    printf ' 6)  Uninstall\n'
    printf ' 0)  Exit\n\n'
    printf '> '
    read -r choice
    case "$choice" in
      1) connect_to_router ;;
      2) menu_full_install ;;
      3) menu_custom_install ;;
      4) menu_update ;;
      5) menu_diagnostics ;;
      6) menu_uninstall ;;
      0) printf 'Пока!\n'; exit 0 ;;
      *) log_warn "Неверный выбор"; sleep 1 ;;
    esac
  done
}

# ══════════════════════════════════════════════════════════════════════════
# Entry point
# ══════════════════════════════════════════════════════════════════════════

# Sanity checks
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  log_err "Нужен bash 4+ (у тебя: ${BASH_VERSION:-не bash})"
  log_err "На macOS: brew install bash"
  exit 1
fi
command -v ssh >/dev/null || { log_err "ssh не найден в PATH"; exit 1; }
command -v scp >/dev/null || { log_err "scp не найден в PATH"; exit 1; }

for _arg in "$@"; do
  case "$_arg" in
    --dry-run) DRY_RUN=1 ;;
  esac
done

if [ -f /etc/openwrt_release ]; then
  log_err "Похоже, скрипт запущен на роутере, а не на локальной машине."
  log_err "Скопируй папку public/ к себе и запусти install.sh оттуда (Git Bash / macOS / Linux)."
  exit 1
fi

acquire_lock
load_state
if [ "$DRY_RUN" = 1 ]; then
  ROUTER_CONNECTED=1
  ROUTER_ARCH="aarch64_cortex-a53"
  ROUTER_OPENWRT_VERSION="DRY-RUN"
  ROUTER_XRAY_VERSION="DRY-RUN"
fi
main_menu
