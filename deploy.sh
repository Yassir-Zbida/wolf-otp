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
PROXY_MODE="auto" # auto|nginx|caddy|traefik|manual

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
    ss -ltn "( sport = :${port} )" 2>/dev/null | tail -n +2 | grep -q .
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
    # Skip if our own wolf-otp containers already own it
    if docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -qE "wolf-otp.*(:${p}->|0\.0\.0\.0:${p}|127\.0\.0\.1:${p})"; then
      echo "$p"
      return
    fi
    p=$((p + 1))
    i=$((i + 1))
    if (( i > 50 )); then
      die "Could not find a free port near ${start}"
    fi
  done
  echo "$p"
}

who_owns_port() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp "( sport = :${port} )" 2>/dev/null | tail -n +2 || true
  else
    lsof -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true
  fi
}

detect_proxy() {
  if [[ "${PROXY_MODE}" != "auto" ]]; then
    log "Proxy mode forced: ${PROXY_MODE}"
    return
  fi

  # Docker Traefik?
  if docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -qiE 'traefik'; then
    PROXY_MODE="traefik"
    log "Detected Traefik (Docker) on this host."
    return
  fi

  # Docker or systemd Caddy?
  if docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -qiE 'caddy'; then
    PROXY_MODE="caddy-docker"
    log "Detected Caddy (Docker) on this host."
    return
  fi
  if systemctl is-active --quiet caddy 2>/dev/null || command -v caddy >/dev/null 2>&1; then
    PROXY_MODE="caddy"
    log "Detected Caddy (systemd/binary) on this host."
    return
  fi

  # Working nginx already listening on 80?
  if systemctl is-active --quiet nginx 2>/dev/null && port_in_use 80; then
    if who_owns_port 80 | grep -qi nginx; then
      PROXY_MODE="nginx"
      log "Detected active nginx on port 80."
      return
    fi
  fi

  # Port 80 free → we can own it with nginx
  if ! port_in_use 80; then
    PROXY_MODE="nginx"
    log "Port 80 is free — will use nginx + certbot."
    return
  fi

  # Port 80 taken by something else
  PROXY_MODE="manual"
  warn "Port 80 is already in use by another process:"
  who_owns_port 80 | sed 's/^/  /' || true
  if docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null | grep -E ':80->|:443->' ; then
    warn "Docker containers publishing 80/443:"
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' | grep -E 'NAMES|:80->|:443->' || true
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  log "Installing base packages..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg git openssl

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

  if [[ "${PROXY_MODE}" == "nginx" ]]; then
    apt-get install -y nginx
    if ! command -v certbot >/dev/null 2>&1; then
      apt-get install -y certbot python3-certbot-nginx
    fi
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl start nginx || die "Failed to start nginx (is port 80 free?)."
  fi
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
    touch_kv() {
      local key="$1" val="$2"
      if grep -q "^${key}=" "${env_file}"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "${env_file}"
      else
        echo "${key}=${val}" >> "${env_file}"
      fi
    }
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
# Add as a server block (or sites-available) on your existing nginx
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
        proxy_read_timeout 60s;
        client_max_body_size 64k;
    }
}
EOF

  cat > "${APP_DIR}/proxy/Caddyfile.snippet" <<EOF
${DOMAIN} {
	reverse_proxy 127.0.0.1:${APP_HOST_PORT}
}
EOF

  cat > "${APP_DIR}/proxy/README.txt" <<EOF
Wolf OTP reverse-proxy helpers for ${DOMAIN} → 127.0.0.1:${APP_HOST_PORT}

Detected mode during deploy: ${PROXY_MODE}

If auto-config did not apply, add the matching snippet to your existing reverse proxy,
then reload it. Snippets are in this folder.
EOF
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
  # Avoid clashing with default site only if it steals our server_name — leave other sites alone
  nginx -t
  systemctl reload nginx || systemctl start nginx
}

issue_ssl_nginx() {
  if [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
    log "TLS cert already exists for ${DOMAIN}."
    return
  fi
  log "Requesting Let's Encrypt certificate for ${DOMAIN}..."
  wait_for_dns
  certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos -m "${EMAIL}" --redirect \
    || warn "Certbot failed. HTTP may still work; fix DNS and re-run certbot --nginx -d ${DOMAIN}"
}

configure_caddy_systemd() {
  local snippet="${APP_DIR}/proxy/Caddyfile.snippet"
  local conf="/etc/caddy/Caddyfile"
  log "Adding ${DOMAIN} to Caddyfile..."
  mkdir -p /etc/caddy
  touch "${conf}"
  if grep -qF "${DOMAIN}" "${conf}" 2>/dev/null; then
    log "Caddy already has an entry for ${DOMAIN}."
  else
    {
      echo
      echo "# wolf-otp"
      cat "${snippet}"
    } >> "${conf}"
  fi
  if systemctl is-active --quiet caddy 2>/dev/null; then
    caddy validate --config "${conf}" || warn "Caddyfile validate failed — check /etc/caddy/Caddyfile"
    systemctl reload caddy || systemctl restart caddy
  else
    warn "Caddy binary present but service not active. Snippet saved at ${snippet}"
  fi
}

configure_caddy_docker() {
  log "Caddy runs in Docker — writing snippet for you to include."
  warn "Add contents of ${APP_DIR}/proxy/Caddyfile.snippet to your Caddy container config, then reload Caddy."
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' | grep -i caddy || true
}

configure_traefik() {
  log "Configuring Traefik labels via docker-compose.override.yml"
  local network
  network="$(docker inspect "$(docker ps --format '{{.Names}} {{.Image}}' | grep -i traefik | awk '{print $1}' | head -1)" \
    --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null | head -1 || true)"

  if [[ -z "${network}" ]]; then
    warn "Could not detect Traefik docker network. Snippets saved under ${APP_DIR}/proxy/"
    PROXY_MODE="manual"
    return
  fi

  log "Joining Traefik network: ${network}"
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
      - traefik.http.routers.wolfotp-http.rule=Host(\`${DOMAIN}\`)
      - traefik.http.routers.wolfotp-http.entrypoints=web
      - traefik.http.routers.wolfotp-http.middlewares=wolfotp-https-redirect
      - traefik.http.middlewares.wolfotp-https-redirect.redirectscheme.scheme=https
      - traefik.http.services.wolfotp.loadbalancer.server.port=4000
    networks:
      - internal
      - traefik_public

networks:
  traefik_public:
    external: true
    name: ${network}
EOF
  warn "If TLS fails, edit certresolver name in docker-compose.override.yml to match your Traefik config."
}

wait_for_dns() {
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
    warn "DNS still not resolving — HTTPS may fail until it does."
  fi
}

start_stack() {
  log "Starting Docker stack..."
  cd "${APP_DIR}"
  docker compose pull || true
  docker compose up --build -d
  sleep 4
  docker compose ps
}

health_check() {
  log "Checking local health endpoint..."
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${APP_HOST_PORT}/health" || true)"
  if [[ "${code}" == "200" ]]; then
    log "App health OK (HTTP 200)."
  else
    warn "Health check returned '${code}'. Logs: cd ${APP_DIR} && docker compose logs --tail=80"
  fi

  code="$(curl -sk -o /dev/null -w '%{http_code}' "https://${DOMAIN}/health" || true)"
  if [[ "${code}" == "200" ]]; then
    log "Public https://${DOMAIN}/health OK."
  else
    local code80
    code80="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${DOMAIN}" "http://127.0.0.1/health" || true)"
    warn "Public HTTPS health='${code}'. Local Host-header via :80 health='${code80}'."
  fi
}

disable_conflicting_pkg_nginx() {
  # If we installed nginx earlier but can't use it, keep it disabled so it doesn't fight the real proxy
  if systemctl is-enabled --quiet nginx 2>/dev/null && ! systemctl is-active --quiet nginx 2>/dev/null; then
    if [[ "${PROXY_MODE}" != "nginx" ]]; then
      log "Disabling unused packaged nginx (port 80 owned by another proxy)."
      systemctl disable nginx >/dev/null 2>&1 || true
      systemctl stop nginx >/dev/null 2>&1 || true
    fi
  fi
}

print_summary() {
  echo
  echo "=============================================="
  echo "  Wolf OTP deploy status"
  echo "=============================================="
  echo "  Domain:   https://${DOMAIN}"
  echo "  App dir:  ${APP_DIR}"
  echo "  Proxy:    ${PROXY_MODE}"
  echo "  App port: 127.0.0.1:${APP_HOST_PORT}"
  if [[ -f "${APP_DIR}/CREDENTIALS.txt" ]]; then
    echo "  Secrets:  ${APP_DIR}/CREDENTIALS.txt"
    echo
    grep -E '^(Public URL|API_KEY|  user:|  pass:|  Worker|  Base URL|  API key)' "${APP_DIR}/CREDENTIALS.txt" || true
  elif [[ -f "${APP_DIR}/.env" ]]; then
    echo "  API_KEY:  $(grep '^API_KEY=' "${APP_DIR}/.env" | cut -d= -f2-)"
  fi
  if [[ "${PROXY_MODE}" == "manual" || "${PROXY_MODE}" == "caddy-docker" ]]; then
    echo
    echo "  ACTION REQUIRED: point your existing reverse proxy to"
    echo "  127.0.0.1:${APP_HOST_PORT} for host ${DOMAIN}"
    echo "  Snippets: ${APP_DIR}/proxy/"
  fi
  echo "=============================================="
}

configure_proxy() {
  write_proxy_snippets
  case "${PROXY_MODE}" in
    nginx)
      configure_nginx
      issue_ssl_nginx
      ;;
    caddy)
      configure_caddy_systemd
      ;;
    caddy-docker)
      configure_caddy_docker
      ;;
    traefik)
      configure_traefik
      ;;
    manual)
      warn "Stack will run locally. Wire ${DOMAIN} → 127.0.0.1:${APP_HOST_PORT} in your existing proxy."
      warn "Ready-made configs: ${APP_DIR}/proxy/"
      ;;
    *)
      die "Unknown PROXY_MODE=${PROXY_MODE}"
      ;;
  esac
}

main() {
  require_root
  log "Domain=${DOMAIN}  AppDir=${APP_DIR}"

  detect_proxy
  disable_conflicting_pkg_nginx
  install_packages

  # Avoid clashing with whatever else is on this VPS (localhost app ports)
  local old
  old="${APP_HOST_PORT}"
  APP_HOST_PORT="$(pick_free_port "${APP_HOST_PORT}")"
  if [[ "${APP_HOST_PORT}" != "${old}" ]]; then
    warn "Port ${old} busy — using APP_HOST_PORT=${APP_HOST_PORT}"
  fi
  old="${WAHA_HOST_PORT}"
  WAHA_HOST_PORT="$(pick_free_port "${WAHA_HOST_PORT}")"
  if [[ "${WAHA_HOST_PORT}" != "${old}" ]]; then
    warn "Port ${old} busy — using WAHA_HOST_PORT=${WAHA_HOST_PORT}"
  fi

  clone_or_update
  write_env
  configure_proxy
  start_stack

  # Traefik override needs a recreate after override file is written
  if [[ "${PROXY_MODE}" == "traefik" && -f "${APP_DIR}/docker-compose.override.yml" ]]; then
    log "Recreating app with Traefik labels..."
    (cd "${APP_DIR}" && docker compose up -d --force-recreate app)
  fi

  health_check
  print_summary
}

main "$@"
