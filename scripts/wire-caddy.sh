#!/usr/bin/env bash
# Wire otp.wolfstor.com into an existing Caddy (Docker) reverse proxy.
#
# On the VPS:
#   bash /opt/wolf-otp/scripts/wire-caddy.sh
#
# Why not reverse_proxy 127.0.0.1:4000?
# Caddy runs in its own network namespace — 127.0.0.1 inside Caddy is Caddy itself.
# We join the OTP app to Caddy's docker network and proxy to the container name.

set -euo pipefail

DOMAIN="${DOMAIN:-otp.wolfstor.com}"
APP_DIR="${APP_DIR:-/opt/wolf-otp}"
APP_CONTAINER="${APP_CONTAINER:-}"
CADDY_CONTAINER="${CADDY_CONTAINER:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[wire-caddy]${NC} $*"; }
warn() { echo -e "${YELLOW}[wire-caddy]${NC} $*"; }
die()  { echo -e "${RED}[wire-caddy]${NC} $*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run as root"

if [[ -z "${APP_CONTAINER}" ]]; then
  APP_CONTAINER="$(docker ps --format '{{.Names}}' | grep -E '^wolf-otp-app' | head -1 || true)"
fi
[[ -n "${APP_CONTAINER}" ]] || die "wolf-otp app not running. cd ${APP_DIR} && docker compose up -d"

if [[ -z "${CADDY_CONTAINER}" ]]; then
  CADDY_CONTAINER="$(docker ps --format '{{.Names}} {{.Image}}' | grep -iE 'caddy' | awk '{print $1}' | head -1 || true)"
fi
[[ -n "${CADDY_CONTAINER}" ]] || die "No Caddy container found"

log "App=${APP_CONTAINER}  Caddy=${CADDY_CONTAINER}  Domain=${DOMAIN}"

mapfile -t NETS < <(docker inspect "${CADDY_CONTAINER}" --format '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' | sed '/^$/d')
NETWORK=""
for n in "${NETS[@]}"; do
  if [[ "${n}" != "bridge" && "${n}" != "host" && "${n}" != "none" ]]; then
    NETWORK="${n}"
    break
  fi
done
[[ -n "${NETWORK}" ]] || NETWORK="${NETS[0]:-}"
[[ -n "${NETWORK}" ]] || die "Caddy has no docker networks"
log "Using docker network: ${NETWORK}"

docker network connect "${NETWORK}" "${APP_CONTAINER}" 2>/dev/null || true
UPSTREAM="${APP_CONTAINER}:4000"

CADDYFILE=""
while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  src="$(awk '{print $1}' <<<"${line}")"
  dst="$(awk '{print $2}' <<<"${line}")"
  if [[ "${dst}" == *Caddyfile || "${dst}" == "/etc/caddy/Caddyfile" ]]; then
    CADDYFILE="${src}"
    break
  fi
  if [[ "${dst}" == "/etc/caddy" || "${dst}" == "/etc/caddy/" ]]; then
    if [[ -f "${src}/Caddyfile" ]]; then
      CADDYFILE="${src}/Caddyfile"
      break
    fi
  fi
done < <(docker inspect "${CADDY_CONTAINER}" --format '{{range .Mounts}}{{println .Source .Destination}}{{end}}')

if [[ -z "${CADDYFILE}" ]]; then
  for p in /etc/caddy/Caddyfile /data/caddy/Caddyfile /opt/caddy/Caddyfile; do
    [[ -f "${p}" ]] && CADDYFILE="${p}" && break
  done
fi

BLOCK=$(cat <<EOF
${DOMAIN} {
	encode gzip
	reverse_proxy ${UPSTREAM}
}
EOF
)

mkdir -p "${APP_DIR}/proxy"
printf '%s\n' "${BLOCK}" > "${APP_DIR}/proxy/Caddyfile.snippet"

if [[ -z "${CADDYFILE}" || ! -f "${CADDYFILE}" ]]; then
  warn "Could not find host-mounted Caddyfile automatically."
  echo
  echo "Add this to your Caddyfile, then: docker exec ${CADDY_CONTAINER} caddy reload --config /etc/caddy/Caddyfile"
  echo
  echo "${BLOCK}"
  echo
  echo "Caddy mounts:"
  docker inspect "${CADDY_CONTAINER}" --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
  exit 1
fi

log "Found Caddyfile: ${CADDYFILE}"
cp -a "${CADDYFILE}" "${CADDYFILE}.bak.$(date +%s)"

if grep -qF "${DOMAIN}" "${CADDYFILE}"; then
  warn "Domain already present in Caddyfile — not appending again."
  warn "Confirm it uses: reverse_proxy ${UPSTREAM}"
  # Try to fix a wrong 127.0.0.1 upstream if present for this domain
  if grep -A5 -F "${DOMAIN}" "${CADDYFILE}" | grep -q '127.0.0.1:4000'; then
    warn "Replacing 127.0.0.1:4000 with ${UPSTREAM} for Docker networking..."
    # Best-effort replace nearby — safer global replace of that upstream only
    sed -i "s/127\\.0\\.0\\.1:4000/${UPSTREAM}/g" "${CADDYFILE}"
  fi
else
  {
    echo
    echo "# wolf-otp (auto $(date -u +%Y-%m-%dT%H:%M:%SZ))"
    echo "${BLOCK}"
  } >> "${CADDYFILE}"
  log "Appended site block for ${DOMAIN}"
fi

log "Reloading Caddy..."
CFG_IN_CONTAINER="/etc/caddy/Caddyfile"
if docker exec "${CADDY_CONTAINER}" test -f /etc/caddy/Caddyfile; then
  CFG_IN_CONTAINER="/etc/caddy/Caddyfile"
elif docker exec "${CADDY_CONTAINER}" test -f /config/Caddyfile; then
  CFG_IN_CONTAINER="/config/Caddyfile"
fi

if docker exec "${CADDY_CONTAINER}" caddy validate --config "${CFG_IN_CONTAINER}"; then
  docker exec "${CADDY_CONTAINER}" caddy reload --config "${CFG_IN_CONTAINER}" \
    || docker restart "${CADDY_CONTAINER}"
else
  warn "validate failed — restarting Caddy"
  docker restart "${CADDY_CONTAINER}"
fi

sleep 3
code="$(curl -sk -o /dev/null -w '%{http_code}' "https://${DOMAIN}/health" || true)"
log "https://${DOMAIN}/health -> HTTP ${code}"
if [[ "${code}" == "200" ]]; then
  log "SUCCESS — OTP API is live behind Caddy + HTTPS."
else
  warn "Not healthy yet. Debug:"
  echo "  docker logs ${CADDY_CONTAINER} --tail 80"
  echo "  curl -vk https://${DOMAIN}/health"
  echo "  cat ${CADDYFILE}"
fi
