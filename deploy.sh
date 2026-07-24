#!/usr/bin/env bash
# Wolf OTP — one-shot VPS deploy (safe alongside an existing app)
# VERSION: 2026-07-24d
#
# Preferred (uses latest from this repo after clone/pull):
#   bash /opt/wolf-otp/deploy.sh
#
# Or:
#   curl -fsSL "https://raw.githubusercontent.com/Yassir-Zbida/wolf-otp/main/deploy.sh?$(date +%s)" | bash
#
# Optional env:
#   DOMAIN=otp.wolfstor.com EMAIL=admin@wolfstor.com APP_DIR=/opt/wolf-otp

set -euo pipefail

DEPLOY_VERSION="2026-07-24d"
REPO_URL="${REPO_URL:-https://github.com/Yassir-Zbida/wolf-otp.git}"
DOMAIN="${DOMAIN:-otp.wolfstor.com}"
EMAIL="${EMAIL:-admin@${DOMAIN#*.}}"
APP_DIR="${APP_DIR:-/opt/wolf-otp}"
APP_HOST_PORT="${APP_HOST_PORT:-4000}"
WAHA_HOST_PORT="${WAHA_HOST_PORT:-3000}"
APP_BIND="127.0.0.1"
PROXY_MODE="${PROXY_MODE:-auto}" # auto|nginx|caddy|traefik|manual

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[wolf-otp]${NC} $*"; }
warn() { echo -e "${YELLOW}[wolf-otp]${NC} $*"; }
die()  { echo -e "${RED}[wolf-otp]${NC} $*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root"
}

# Reliable listen check (avoid fragile ss filter DSL)
port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\.)${port}$"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

pick_free_port() {
  local start="$1" p="$1" i=0
  while port_in_use "$p"; do
    if docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -qE "wolf-otp-(app|waha).*[:.]${p}->"; then
      echo "$p"; return
    fi
    # Also allow if only our previous publish is bound (compose project name)
    if docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -qE "wolf-otp.*[:.]${p}->"; then
      echo "$p"; return
    fi
    p=$((p + 1)); i=$((i + 1))
    (( i > 50 )) && die "No free port near ${start}"
  done
  echo "$p"
}

who_owns_port() {
  local port="$1"
  ss -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print}' || true
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null | grep -E "NAMES|:${port}->" || true
}

detect_proxy() {
  if [[ "${PROXY_MODE}" != "auto" ]]; then
    log "Proxy mode forced: ${PROXY_MODE}"
    return
  fi

  if docker ps --format '{{.Image}}' 2>/dev/null | grep -qi traefik; then
    PROXY_MODE="traefik"; log "Detected Traefik."; return
  fi
  if docker ps --format '{{.Image}}' 2>/dev/null | grep -qi caddy; then
    PROXY_MODE="caddy-docker"; log "Detected Caddy (Docker)."; return
  fi
  if systemctl is-active --quiet caddy 2>/dev/null; then
    PROXY_MODE="caddy"; log "Detected Caddy (systemd)."; return
  fi

  if port_in_use 80; then
    if who_owns_port 80 | grep -qi nginx && systemctl is-active --quiet nginx 2>/dev/null; then
      PROXY_MODE="nginx"; log "Detected active nginx on :80."; return
    fi
    PROXY_MODE="manual"
    warn "Port 80 is in use — will NOT start a second nginx."
    who_owns_port 80 | sed 's/^/  /' || true
    return
  fi

  PROXY_MODE="nginx"
  log "Port 80 free — will use nginx + certbot."
}

install_base() {
  export DEBIAN_FRONTEND=noninteractive
  log "Installing base packages (git/curl/openssl)..."
  apt-get update -y >/dev/null
  apt-get install -y ca-certificates curl gnupg git openssl >/dev/null

  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker..."
    install -m 0755 -d /etc/apt/keyrings
    [[ -f /etc/apt/keyrings/docker.asc ]] || {
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
    }
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y >/dev/null
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
  else
    log "Docker already installed."
  fi
  docker compose version >/dev/null || die "docker compose plugin missing"

  # Only install/start nginx when we own port 80
  if [[ "${PROXY_MODE}" == "nginx" ]]; then
    apt-get install -y nginx certbot python3-certbot-nginx >/dev/null
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl start nginx || {
      warn "nginx failed to start — falling back to manual proxy mode."
      PROXY_MODE="manual"
      systemctl disable nginx >/dev/null 2>&1 || true
      systemctl stop nginx >/dev/null 2>&1 || true
    }
  else
    # Stop packaged nginx if it was installed earlier and is fighting the real proxy
    if systemctl list-unit-files nginx.service >/dev/null 2>&1; then
      if ! systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl disable nginx >/dev/null 2>&1 || true
        systemctl stop nginx >/dev/null 2>&1 || true
      fi
    fi
  fi
}

clone_or_update() {
  if [[ -d "${APP_DIR}/.git" ]]; then
    log "Updating repo in ${APP_DIR}..."
    git -C "${APP_DIR}" fetch --depth 1 origin main
    git -C "${APP_DIR}" reset --hard origin/main
  else
    log "Cloning into ${APP_DIR}..."
    mkdir -p "$(dirname "${APP_DIR}")"
    git clone --depth 1 "${REPO_URL}" "${APP_DIR}"
  fi
  # Re-exec latest script from disk once (avoids curl CDN cache)
  if [[ "${WOLF_OTP_REEXEC:-}" != "1" && -f "${APP_DIR}/deploy.sh" ]]; then
    local disk_ver
    disk_ver="$(grep -E '^DEPLOY_VERSION=' "${APP_DIR}/deploy.sh" | head -1 | cut -d= -f2- | tr -d '"' || true)"
    if [[ -n "${disk_ver}" && "${disk_ver}" != "${DEPLOY_VERSION}" ]]; then
      log "Newer deploy.sh on disk (${disk_ver}) — re-executing..."
      exec env WOLF_OTP_REEXEC=1 DOMAIN="${DOMAIN}" EMAIL="${EMAIL}" APP_DIR="${APP_DIR}" \
        APP_HOST_PORT="${APP_HOST_PORT}" WAHA_HOST_PORT="${WAHA_HOST_PORT}" PROXY_MODE="${PROXY_MODE}" \
        bash "${APP_DIR}/deploy.sh"
    fi
  fi
}

write_env() {
  local env_file="${APP_DIR}/.env"
  touch_kv() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "${env_file}" 2>/dev/null; then
      sed -i "s|^${key}=.*|${key}=${val}|" "${env_file}"
    else
      echo "${key}=${val}" >> "${env_file}"
    fi
  }

  if [[ -f "${env_file}" ]]; then
    log ".env exists — keeping secrets, refreshing bind/ports."
    touch_kv APP_BIND "${APP_BIND}"
    touch_kv TRUST_PROXY 1
    touch_kv APP_HOST_PORT "${APP_HOST_PORT}"
    touch_kv WAHA_HOST_PORT "${WAHA_HOST_PORT}"
    return
  fi

  log "Generating .env secrets..."
  local api_key otp_secret waha_key dash_pass
  api_key="$(openssl rand -hex 32)"
  otp_secret="$(openssl rand -hex 32)"
  waha_key="$(openssl rand -hex 16)"
  dash_pass="$(openssl rand -hex 16)"

  cat > "${env_file}" <<EOF
PORT=4000
APP_BIND=${APP_BIND}
APP_HOST_PORT=${APP_HOST_PORT}
WAHA_HOST_PORT=${WAHA_HOST_PORT}
TRUST_PROXY=1
REDIS_URL=redis://redis:6379
WAHA_BASE_URL=http://waha:3000
WAHA_SESSION=default
WAHA_API_KEY=${waha_key}
WAHA_DASHBOARD_USERNAME=admin
WAHA_DASHBOARD_PASSWORD=${dash_pass}
WHATSAPP_SWAGGER_USERNAME=admin
WHATSAPP_SWAGGER_PASSWORD=${dash_pass}
API_KEY=${api_key}
OTP_SECRET=${otp_secret}
OTP_EXPIRY_SECONDS=300
OTP_MAX_ATTEMPTS=5
OTP_RESEND_COOLDOWN_SECONDS=60
OTP_IP_RATE_MAX=30
OTP_IP_RATE_WINDOW_MS=3600000
OTP_VERIFY_IP_RATE_MAX=60
OTP_VERIFY_IP_RATE_WINDOW_MS=900000
EOF
  chmod 600 "${env_file}"

  cat > "${APP_DIR}/CREDENTIALS.txt" <<EOF
Wolf OTP credentials — keep private
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Public URL:     https://${DOMAIN}
API_KEY:        ${api_key}

WAHA dashboard (SSH tunnel only):
  ssh -L ${WAHA_HOST_PORT}:127.0.0.1:${WAHA_HOST_PORT} root@YOUR_VPS_IP
  then open http://127.0.0.1:${WAHA_HOST_PORT}/dashboard
  user: admin
  pass: ${dash_pass}
  Worker API Key: ${waha_key}

WordPress Wolf Auth settings:
  Base URL: https://${DOMAIN}
  API key:  ${api_key}
EOF
  chmod 600 "${APP_DIR}/CREDENTIALS.txt"
}

write_proxy_snippets() {
  mkdir -p "${APP_DIR}/proxy"
  cat > "${APP_DIR}/proxy/nginx.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    location / {
        proxy_pass http://127.0.0.1:${APP_HOST_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 64k;
    }
}
EOF
  cat > "${APP_DIR}/proxy/Caddyfile.snippet" <<EOF
${DOMAIN} {
	reverse_proxy 127.0.0.1:${APP_HOST_PORT}
}
EOF
}

configure_nginx() {
  local conf="/etc/nginx/sites-available/wolf-otp.conf"
  log "Writing nginx site ${DOMAIN} → 127.0.0.1:${APP_HOST_PORT}"
  cat > "${conf}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / {
        proxy_pass http://127.0.0.1:${APP_HOST_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 64k;
    }
}
EOF
  ln -sfn "${conf}" /etc/nginx/sites-enabled/wolf-otp.conf
  nginx -t
  systemctl reload nginx || systemctl start nginx
  if [[ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
    log "Requesting Let's Encrypt cert..."
    certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos -m "${EMAIL}" --redirect \
      || warn "Certbot failed — check DNS, then: certbot --nginx -d ${DOMAIN}"
  fi
}

configure_caddy() {
  local conf="/etc/caddy/Caddyfile"
  mkdir -p /etc/caddy; touch "${conf}"
  if ! grep -qF "${DOMAIN}" "${conf}"; then
    { echo; echo "# wolf-otp"; cat "${APP_DIR}/proxy/Caddyfile.snippet"; } >> "${conf}"
  fi
  caddy validate --config "${conf}" 2>/dev/null || true
  systemctl reload caddy || systemctl restart caddy || warn "Reload Caddy manually."
}

configure_traefik() {
  local tname network
  tname="$(docker ps --format '{{.Names}} {{.Image}}' | grep -i traefik | awk '{print $1}' | head -1 || true)"
  [[ -n "${tname}" ]] || { PROXY_MODE="manual"; return; }
  network="$(docker inspect "${tname}" --format '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' | head -1)"
  [[ -n "${network}" ]] || { PROXY_MODE="manual"; return; }
  log "Traefik network: ${network}"
  cat > "${APP_DIR}/docker-compose.override.yml" <<EOF
services:
  app:
    labels:
      - traefik.enable=true
      - traefik.docker.network=${network}
      - traefik.http.routers.wolfotp.rule=Host(\`${DOMAIN}\`)
      - traefik.http.routers.wolfotp.entrypoints=websecure
      - traefik.http.routers.wolfotp.tls=true
      - traefik.http.routers.wolfotp.tls.certresolver=letsencrypt
      - traefik.http.services.wolfotp.loadbalancer.server.port=4000
    networks:
      - internal
      - traefik_public
networks:
  traefik_public:
    external: true
    name: ${network}
EOF
  warn "If TLS fails, rename certresolver in override to match your Traefik config."
}

start_stack() {
  log "Starting Docker stack (this always runs)..."
  cd "${APP_DIR}"
  docker compose pull || true
  docker compose up --build -d
  sleep 4
  docker compose ps
}

health_check() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${APP_HOST_PORT}/health" || true)"
  if [[ "${code}" == "200" ]]; then
    log "Local health OK."
  else
    warn "Local health=${code}. Try: cd ${APP_DIR} && docker compose logs --tail=100"
  fi
}

print_summary() {
  echo
  echo "=============================================="
  echo "  Wolf OTP  (deploy ${DEPLOY_VERSION})"
  echo "=============================================="
  echo "  Domain:   https://${DOMAIN}"
  echo "  App dir:  ${APP_DIR}"
  echo "  Proxy:    ${PROXY_MODE}"
  echo "  App:      127.0.0.1:${APP_HOST_PORT}"
  if [[ -f "${APP_DIR}/CREDENTIALS.txt" ]]; then
    echo "  Secrets:  ${APP_DIR}/CREDENTIALS.txt"
    grep -E '^(Public URL|API_KEY|  user:|  pass:|  Worker|  Base URL|  API key)' "${APP_DIR}/CREDENTIALS.txt" || true
  elif [[ -f "${APP_DIR}/.env" ]]; then
    echo "  API_KEY:  $(grep '^API_KEY=' "${APP_DIR}/.env" | cut -d= -f2-)"
  fi
  if [[ "${PROXY_MODE}" == "manual" || "${PROXY_MODE}" == "caddy-docker" ]]; then
    echo
    echo "  ACTION: point ${DOMAIN} → 127.0.0.1:${APP_HOST_PORT} in your existing reverse proxy"
    echo "  Snippets: ${APP_DIR}/proxy/"
  fi
  echo "=============================================="
}

configure_proxy() {
  write_proxy_snippets
  case "${PROXY_MODE}" in
    nginx) configure_nginx || warn "nginx config failed — stack still runs locally." ;;
    caddy) configure_caddy || true ;;
    caddy-docker) log "Caddy (Docker) will be wired after the stack starts." ;;
    traefik) configure_traefik || true ;;
    manual) warn "Wire proxy manually using ${APP_DIR}/proxy/" ;;
  esac
}

main() {
  require_root
  log "version=${DEPLOY_VERSION} domain=${DOMAIN} dir=${APP_DIR}"

  detect_proxy
  install_base

  local old
  old="${APP_HOST_PORT}"; APP_HOST_PORT="$(pick_free_port "${APP_HOST_PORT}")"
  [[ "${APP_HOST_PORT}" == "${old}" ]] || warn "APP_HOST_PORT ${old}→${APP_HOST_PORT}"
  old="${WAHA_HOST_PORT}"; WAHA_HOST_PORT="$(pick_free_port "${WAHA_HOST_PORT}")"
  [[ "${WAHA_HOST_PORT}" == "${old}" ]] || warn "WAHA_HOST_PORT ${old}→${WAHA_HOST_PORT}"

  clone_or_update
  write_env
  configure_proxy
  start_stack

  if [[ "${PROXY_MODE}" == "traefik" && -f "${APP_DIR}/docker-compose.override.yml" ]]; then
    (cd "${APP_DIR}" && docker compose up -d --force-recreate app) || true
  fi

  if [[ "${PROXY_MODE}" == "caddy-docker" ]]; then
    log "Wiring ${DOMAIN} into Caddy..."
    if [[ -f "${APP_DIR}/scripts/wire-caddy.sh" ]]; then
      bash "${APP_DIR}/scripts/wire-caddy.sh" || warn "Auto-wire failed — run: bash ${APP_DIR}/scripts/wire-caddy.sh"
    else
      warn "Missing ${APP_DIR}/scripts/wire-caddy.sh — pull latest and re-run it."
    fi
  fi

  health_check
  print_summary
}

main "$@"
