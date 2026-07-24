# Wolf OTP — WhatsApp OTP API (WAHA + Express)

Self-hosted OTP verification over WhatsApp for **Wolf Auth** (WordPress). WAHA is the transport; Express exposes a locked-down send/verify API.

## Architecture

```
WordPress (Wolf Auth)  --API_KEY-->  OTP API (:4000)  -->  Redis (hashed OTP)
                                           |
                                           v
                                         WAHA (WhatsApp Web session)
```

- WordPress never sees or stores the raw OTP.
- Only HMAC hashes live in Redis (TTL).
- All `/api/otp/*` routes require `Authorization: Bearer <API_KEY>`.

## One-command VPS deploy

On your Ubuntu VPS (as root), after DNS `otp.yourdomain.com` → VPS IP:

```bash
curl -fsSL https://raw.githubusercontent.com/Yassir-Zbida/wolf-otp/main/deploy.sh | bash
```

Defaults to `DOMAIN=otp.wolfstor.com`. Override if needed:

```bash
DOMAIN=otp.example.com EMAIL=you@example.com bash <(curl -fsSL https://raw.githubusercontent.com/Yassir-Zbida/wolf-otp/main/deploy.sh)
```

The script installs Docker/nginx/certbot if missing, clones into `/opt/wolf-otp`, generates secrets, proxies only this subdomain (won't replace other nginx sites), issues HTTPS, and starts the stack on localhost ports so it won't fight an existing app.

Credentials are saved to `/opt/wolf-otp/CREDENTIALS.txt`.

If the VPS already uses **Caddy in Docker** (port 80/443 taken), after deploy run:

```bash
bash /opt/wolf-otp/scripts/wire-caddy.sh
```

That joins the OTP container to Caddy’s network and adds `otp.wolfstor.com` with HTTPS.

## Manual / local start

```bash
cp .env.example .env
# Set API_KEY, OTP_SECRET, WAHA_* passwords (openssl rand -hex 32)

docker compose up --build -d
```

| Service | Exposure | Role |
|---------|----------|------|
| `app`   | `127.0.0.1:4000` (default) | OTP API behind nginx |
| `waha`  | `127.0.0.1:3000` only | Dashboard / QR — not public |
| `redis` | internal network only | OTP hashes / cooldowns |

## Link WhatsApp (QR)

1. Open [http://127.0.0.1:3000/dashboard](http://127.0.0.1:3000/dashboard) (on the server, or via SSH tunnel).
2. Login with `WAHA_DASHBOARD_USERNAME` / `WAHA_DASHBOARD_PASSWORD`.
3. Set the Worker API key to `WAHA_API_KEY` from `.env`.
4. Start session `default`, scan QR → status **WORKING**.

On a remote VPS:

```bash
ssh -L 3000:127.0.0.1:3000 user@your-server
# then open http://127.0.0.1:3000/dashboard locally
```

## API (for Wolf Auth)

### Send

```bash
curl -X POST https://otp.example.com/api/otp/send \
  -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"phone":"9665XXXXXXXX","lang":"ar"}'
```

```json
{ "success": true, "expiresIn": 300 }
```

### Verify

```bash
curl -X POST https://otp.example.com/api/otp/verify \
  -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"phone":"9665XXXXXXXX","code":"123456"}'
```

```json
{ "success": true }
```

Unauthorized requests return `401`.

## WordPress (Wolf Auth) setup

1. Deploy this stack with HTTPS (nginx/Caddy reverse proxy to port 4000).
2. In **WP Admin → Wolf Auth**:
   - **Base URL**: `https://otp.yourdomain.com`
   - **API key**: same as `API_KEY` in `.env`
   - **Language**: `ar` / `en` / `fr`

## Production checklist

- [ ] Strong unique `API_KEY` and `OTP_SECRET` (not the repo defaults)
- [ ] Strong `WAHA_DASHBOARD_PASSWORD` / `WAHA_API_KEY`
- [ ] HTTPS on the public OTP URL (TLS terminate at nginx/Caddy)
- [ ] Firewall: only `443` (and SSH) public; WAHA stays on `127.0.0.1:3000`
- [ ] `TRUST_PROXY=1` when behind a reverse proxy (for correct IP rate limits)
- [ ] Optional: set `APP_BIND=127.0.0.1` so only nginx on the same host can reach the app
- [ ] WAHA session linked and **WORKING**
- [ ] Wolf Auth settings match `API_KEY` + Base URL

### Example nginx snippet

```nginx
server {
  server_name otp.example.com;
  listen 443 ssl;
  # ssl_certificate ...;

  location / {
    proxy_pass http://127.0.0.1:4000;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
```

With that, set in `.env`:

```
APP_BIND=127.0.0.1
TRUST_PROXY=1
```

## Environment

| Variable | Required | Meaning |
|----------|----------|---------|
| `API_KEY` | yes | Shared secret for WordPress |
| `OTP_SECRET` | yes | HMAC key for OTP hashes |
| `WAHA_API_KEY` | yes | WAHA HTTP API key |
| `WAHA_DASHBOARD_PASSWORD` | yes | Dashboard login |
| `OTP_EXPIRY_SECONDS` | no | Default `300` |
| `OTP_MAX_ATTEMPTS` | no | Default `5` |
| `OTP_RESEND_COOLDOWN_SECONDS` | no | Default `60` |
| `OTP_IP_RATE_MAX` | no | Send limit per IP / window |
| `TRUST_PROXY` | no | `1` behind nginx |

## Security

- API key required on all OTP routes (constant-time compare)
- Helmet security headers; `x-powered-by` disabled
- IP rate limits on send + verify
- Per-phone cooldown + max verify attempts
- Raw OTP never logged, never returned, never stored in WordPress
- WAHA dashboard bound to localhost only
- App container runs as non-root, read-only filesystem

## Caveat

WAHA uses an unofficial WhatsApp Web session. Keep volume low; accounts can be flagged under heavy automation.
