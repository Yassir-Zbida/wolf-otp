#!/usr/bin/env bash
# Wolf OTP — one-shot VPS deploy (safe alongside an existing app)
#
# Usage (as root on the VPS):
#   curl -fsSL https://raw.githubusercontent.com/Yassir-Zbida/wolf-otp/main/deploy.sh | bash
#
# Optional env overrides:
#   DOMAIN=otp.wolfstor.com
#   EMAIL=admin@wolfstor.com
#   APP_DIR=/opt/wolf-otp
#   APP_HOST_PORT=4000
#   WAHA_HOST_PORT=3000

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Yassir-Zbida/wolf-otp.git}"
DOMAIN="${DOMAIN:-otp.wolfstor.com}"
EMAIL="${EMAIL:-admin@${DOMAIN#*.}}"
APP_DIR="${APP_DIR:-/opt/wolf-otp}"
APP_HOST_PORT="${APP_HOST_PORT:-4000}"
WAHA_HOST_PORT="${WAHA_HOST_PORT:-3000}"
APP_BIND="127.0.0.1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[wolf-otp]${NC} $*"; }
warn() { echo -e "${YELLOW}[wolf-otp]${NC} $*"; }
die()  { echo -e "${RED}[wolf-otp]${NC} $*" >&2; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root (or: sudo bash deploy.sh)"
  fi
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "sport = :${port}" 2>/dev/null | grep -q ":${port}"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

pick_free_port() {
  local start="$1"
  local p="$start"
  local i=0
  while port_in_use "$p"; do
    p=$((p + 1))
    i=$((i + 1))
    if (( i > 50 )); then
      die "Could not find a free port near ${start}"
    fi
  done
  echo "$p"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  log "Updating apt and installing prerequisites..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg git nginx openssl

  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker..."
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
    fi
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
  else
    log "Docker already installed."
  fi

  if ! docker compose version >/dev/null 2>&1; then
    die "docker compose plugin missing. Install docker-compose-plugin and re-run."
  fi

  if ! command -v certbot >/dev/null 2>&1; then
    log "Installing Certbot..."
    apt-get install -y certbot python3-certbot-nginx
  fi

  systemctl enable --now nginx
}

clone_or_update() {
  if [[ -d "${APP_DIR}/.git" ]]; then
    log "Updating repo in ${APP_DIR}..."
    git -C "${APP_DIR}" fetch --depth 1 origin main
    git -C "${APP_DIR}" reset --hard origin/main
  else
    log "Cloning repo into ${APP_DIR}..."
    mkdir -p "$(dirname "${APP_DIR}")"
    git clone --depth 1 "${REPO_URL}" "${APP_DIR}"
  fi
}

write_env() {
  local env_file="${APP_DIR}/.env"
  if [[ -f "${env_file}" ]]; then
    log ".env already exists — keeping secrets, refreshing ports/bind."
    # Update bind/ports without wiping keys
    grep -q '^APP_BIND=' "${env_file}" && sed -i "s/^APP_BIND=.*/APP_BIND=${APP_BIND}/" "${env_file}" || echo "APP_BIND=${APP_BIND}" >> "${env_file}"
    grep -q '^TRUST_PROXY=' "${env_file}" && sed -i "s/^TRUST_PROXY=.*/TRUST_PROXY=1/" "${env_file}" || echo "TRUST_PROXY=1" >> "${env_file}"
    grep -q '^APP_HOST_PORT=' "${env_file}" && sed -i "s/^APP_HOST_PORT=.*/APP_HOST_PORT=${APP_HOST_PORT}/" "${env_file}" || echo "APP_HOST_PORT=${APP_HOST_PORT}" >> "${env_file}"
    grep -q '^WAHA_HOST_PORT=' "${env_file}" && sed -i "s/^WAHA_HOST_PORT=.*/WAHA_HOST_PORT=${WAHA_HOST_PORT}/" "${env_file}" || echo "WAHA_HOST_PORT=${WAHA_HOST_PORT}" >> "${env_file}"
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

configure_nginx() {
  local conf="/etc/nginx/sites-available/wolf-otp.conf"
  log "Writing nginx site for ${DOMAIN} → 127.0.0.1:${APP_HOST_PORT}"

  cat > "${conf}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:${APP_HOST_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
        client_max_body_size 64k;
    }
}
EOF

  ln -sfn "${conf}" /etc/nginx/sites-enabled/wolf-otp.conf
  nginx -t
  systemctl reload nginx
}

issue_ssl() {
  if [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
    log "TLS cert already exists for ${DOMAIN}."
    certbot renew --quiet || true
    return
  fi

  log "Requesting Let's Encrypt certificate for ${DOMAIN}..."
  # Wait briefly for DNS if just added
  local ok=0
  for i in 1 2 3 4 5 6; do
    if getent hosts "${DOMAIN}" >/dev/null 2>&1; then
      ok=1
      break
    fi
    warn "DNS for ${DOMAIN} not resolving yet (try ${i}/6)..."
    sleep 5
  done
  if [[ "$ok" -ne 1 ]]; then
    warn "DNS still not resolving — certbot may fail. Re-run deploy later."
  fi

  certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos -m "${EMAIL}" --redirect \
    || warn "Certbot failed. HTTP proxy still works; fix DNS and re-run: certbot --nginx -d ${DOMAIN}"
}

start_stack() {
  log "Starting Docker stack..."
  cd "${APP_DIR}"
  docker compose pull || true
  docker compose up --build -d
  sleep 3
  docker compose ps
}

health_check() {
  log "Checking local health endpoint..."
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${APP_HOST_PORT}/health" || true)"
  if [[ "${code}" == "200" ]]; then
    log "App health OK (HTTP 200)."
  else
    warn "Health check returned '${code}'. Check: docker compose -f ${APP_DIR}/docker-compose.yml logs --tail=80"
  fi

  code="$(curl -s -o /dev/null -w '%{http_code}' "https://${DOMAIN}/health" || true)"
  if [[ "${code}" == "200" ]]; then
    log "Public https://${DOMAIN}/health OK."
  else
    warn "Public health check returned '${code}' (DNS/SSL may still be propagating)."
  fi
}

print_summary() {
  echo
  echo "=============================================="
  echo "  Wolf OTP deployed"
  echo "=============================================="
  echo "  URL:      https://${DOMAIN}"
  echo "  App dir:  ${APP_DIR}"
  if [[ -f "${APP_DIR}/CREDENTIALS.txt" ]]; then
    echo "  Secrets:  ${APP_DIR}/CREDENTIALS.txt"
    echo
    grep -E '^(Public URL|API_KEY|  user:|  pass:|  Worker|  Base URL|  API key)' "${APP_DIR}/CREDENTIALS.txt" || true
  else
    echo "  API_KEY:  (see ${APP_DIR}/.env)"
  fi
  echo
  echo "  Next: link WhatsApp via SSH tunnel to WAHA dashboard,"
  echo "  then paste Base URL + API_KEY into Wolf Auth."
  echo "=============================================="
}

main() {
  require_root
  log "Domain=${DOMAIN}  AppDir=${APP_DIR}"

  install_packages

  # Avoid clashing with whatever else is on this VPS
  if port_in_use "${APP_HOST_PORT}"; then
    local old="${APP_HOST_PORT}"
    APP_HOST_PORT="$(pick_free_port "${APP_HOST_PORT}")"
    warn "Port ${old} busy — using APP_HOST_PORT=${APP_HOST_PORT} (nginx will proxy to it)."
  fi
  if port_in_use "${WAHA_HOST_PORT}"; then
    local old="${WAHA_HOST_PORT}"
    WAHA_HOST_PORT="$(pick_free_port "${WAHA_HOST_PORT}")"
    warn "Port ${old} busy — using WAHA_HOST_PORT=${WAHA_HOST_PORT}."
  fi

  clone_or_update
  write_env
  configure_nginx
  start_stack
  issue_ssl
  systemctl reload nginx || true
  health_check
  print_summary
}

main "$@"
