# Coding Agent Prompt — WhatsApp OTP Service (WAHA + Express)

Build a self-hosted WhatsApp OTP verification API using WAHA (https://github.com/devlikeapro/waha) as the WhatsApp transport layer and Node.js/Express as the API layer.

## Stack
- Node.js + Express (or Fastify if you prefer)
- Redis for OTP storage (with TTL-based expiry)
- WAHA running via Docker (devlikeapro/waha image) as the WhatsApp session/sending engine
- dotenv for config

## Project structure
```
/otp-service
  /src
    server.js
    routes/otp.js
    lib/otp.js         (generate, hash, verify logic)
    lib/waha.js         (WAHA API client wrapper)
    middleware/rateLimit.js
  docker-compose.yml     (WAHA + Redis + app service)
  .env.example
  README.md
```

## docker-compose.yml
Include three services:
1. `waha` — devlikeapro/waha image, expose port 3000 internally, persist session data in a volume
2. `redis` — official redis image, expose 6379 internally only
3. `app` — this Express service, depends_on waha + redis, exposes the public port (e.g. 4000)

## Environment variables (.env.example)
```
PORT=4000
REDIS_URL=redis://redis:6379
WAHA_BASE_URL=http://waha:3000
WAHA_SESSION=default
OTP_SECRET=changeme-generate-a-real-secret
OTP_EXPIRY_SECONDS=300
OTP_MAX_ATTEMPTS=5
OTP_RESEND_COOLDOWN_SECONDS=60
```

## Core requirements

### 1. OTP generation & hashing (`lib/otp.js`)
- Generate a 6-digit numeric code using a cryptographically secure random generator (not Math.random)
- Never store the raw code — hash it with HMAC-SHA256 using `OTP_SECRET`, keyed by phone number, before storing
- Export: `generateOtp()`, `hashOtp(code, phone)`

### 2. WAHA client wrapper (`lib/waha.js`)
- Function `sendWhatsAppMessage(phone, text)` that POSTs to WAHA's `/api/sendText` endpoint with `{ session, chatId: \`${phone}@c.us\`, text }`
- Handle and surface WAHA connection/session errors clearly (e.g. session not authenticated / QR not scanned yet)
- Add a `checkSessionStatus()` helper that hits WAHA's session status endpoint — the send endpoint should fail gracefully with a clear error if the session isn't in "WORKING" state

### 3. Routes (`routes/otp.js`)

**POST /api/otp/send**
- Body: `{ phone }` (validate E.164-ish format, normalize by stripping non-digits)
- Enforce `OTP_RESEND_COOLDOWN_SECONDS` per phone (return 429 if within cooldown)
- Generate code, store hashed code in Redis with key `otp:{phone}` and TTL = `OTP_EXPIRY_SECONDS`
- Reset attempt counter in Redis: `otp_attempts:{phone}`
- Send via WAHA with a clear message template (support Arabic/French/English text based on optional `lang` param)
- Respond `{ success: true, expiresIn: OTP_EXPIRY_SECONDS }` — never echo the code back in the response

**POST /api/otp/verify**
- Body: `{ phone, code }`
- Check attempt count first — if >= `OTP_MAX_ATTEMPTS`, return 429 and require a fresh `/send` call
- Compare hashed input against stored hash (constant-time comparison, e.g. `crypto.timingSafeEqual`)
- On success: delete the Redis key, return `{ success: true }`
- On failure: increment attempt counter, return `{ success: false, attemptsRemaining }`
- On expired/missing key: return 400 `{ error: 'expired_or_not_found' }`

### 4. Rate limiting (`middleware/rateLimit.js`)
- Apply IP-based rate limiting on `/api/otp/send` (e.g. max 10 requests/hour/IP) in addition to the per-phone cooldown, to prevent abuse/cost blowout

### 5. Error handling
- Centralized error handler middleware — never leak stack traces or internal WAHA errors to the client
- Log WAHA send failures server-side with enough context to debug (phone, timestamp, WAHA response) but never log the OTP code itself

### 6. README.md should cover
- How to spin up `docker-compose up`
- How to scan the QR code to link WAHA (hit `http://localhost:3000` or WAHA's session QR endpoint)
- Example curl requests for `/send` and `/verify`
- A note that this rides on an unofficial WhatsApp Web session, so it can get flagged/banned under heavy or bulk-style automated traffic — recommend keeping volume low and having an SMS fallback for production use

## Deliverable
A working, runnable project via `docker-compose up` with the two endpoints functional end-to-end once the WAHA session is linked via QR code.

## Do NOT
- Do not store raw OTP codes anywhere (logs, DB, Redis) — only hashed
- Do not use Math.random() for code generation
- Do not skip the per-phone rate limit / cooldown
- Do not return the code in any API response
