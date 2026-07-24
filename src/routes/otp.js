const express = require('express');
const Redis = require('ioredis');
const { generateOtp, hashOtp, safeEqualHex } = require('../lib/otp');
const { sendWhatsAppMessage, WahaError } = require('../lib/waha');
const { sendRateLimiter, verifyRateLimiter } = require('../middleware/rateLimit');

const router = express.Router();

const redis = new Redis(process.env.REDIS_URL || 'redis://127.0.0.1:6379', {
  maxRetriesPerRequest: 3,
  lazyConnect: true,
});

redis.on('error', (err) => {
  console.error('[redis]', err.message);
});

const OTP_EXPIRY_SECONDS = () => Number(process.env.OTP_EXPIRY_SECONDS || 300);
const OTP_MAX_ATTEMPTS = () => Number(process.env.OTP_MAX_ATTEMPTS || 5);
const OTP_RESEND_COOLDOWN_SECONDS = () =>
  Number(process.env.OTP_RESEND_COOLDOWN_SECONDS || 60);

function otpKey(phone) {
  return `otp:${phone}`;
}

function attemptsKey(phone) {
  return `otp_attempts:${phone}`;
}

function cooldownKey(phone) {
  return `otp_cooldown:${phone}`;
}

/**
 * Normalize to digits-only; require E.164-ish length (8–15 digits).
 * @param {unknown} raw
 * @returns {string|null}
 */
function normalizePhone(raw) {
  if (typeof raw !== 'string' && typeof raw !== 'number') return null;
  const digits = String(raw).replace(/\D/g, '');
  if (digits.length < 8 || digits.length > 15) return null;
  return digits;
}

const MESSAGES = {
  en: (code) => `Your verification code is: ${code}\nValid for a limited time. Do not share it.`,
  fr: (code) => `Votre code de vérification est : ${code}\nValable pour une durée limitée. Ne le partagez pas.`,
  ar: (code) => `رمز التحقق الخاص بك هو: ${code}\nصالح لمدة محدودة. لا تشاركه مع أحد.`,
};

function buildMessage(code, lang) {
  const key = typeof lang === 'string' ? lang.toLowerCase() : 'en';
  const template = MESSAGES[key] || MESSAGES.en;
  return template(code);
}

router.post('/send', sendRateLimiter, async (req, res, next) => {
  try {
    const phone = normalizePhone(req.body?.phone);
    if (!phone) {
      return res.status(400).json({
        error: 'invalid_phone',
        message: 'Provide a valid phone number (8–15 digits, E.164-ish).',
      });
    }

    const cooldownTtl = await redis.ttl(cooldownKey(phone));
    if (cooldownTtl > 0) {
      return res.status(429).json({
        error: 'cooldown',
        message: 'Please wait before requesting another code.',
        retryAfterSeconds: cooldownTtl,
      });
    }

    const code = generateOtp();
    const hashed = hashOtp(code, phone);
    const expiresIn = OTP_EXPIRY_SECONDS();

    await redis.set(otpKey(phone), hashed, 'EX', expiresIn);
    await redis.del(attemptsKey(phone));
    const cooldownSeconds = OTP_RESEND_COOLDOWN_SECONDS();
    if (cooldownSeconds > 0) {
      await redis.set(cooldownKey(phone), '1', 'EX', cooldownSeconds);
    }

    const text = buildMessage(code, req.body?.lang);

    try {
      await sendWhatsAppMessage(phone, text);
    } catch (err) {
      // Roll back stored OTP so a failed send doesn't leave a usable code
      await redis.del(otpKey(phone), attemptsKey(phone), cooldownKey(phone));

      console.error('[waha:send]', {
        phone,
        timestamp: new Date().toISOString(),
        code: err.code,
        status: err.status,
        details: err.details,
        message: err.message,
      });

      if (err instanceof WahaError) {
        const clientStatus =
          err.code === 'session_not_ready' || err.code === 'session_not_found'
            ? 503
            : 502;
        return res.status(clientStatus).json({
          error: err.code,
          message: 'Unable to send verification message. Try again later.',
        });
      }
      throw err;
    }

    return res.json({ success: true, expiresIn });
  } catch (err) {
    return next(err);
  }
});

router.post('/verify', verifyRateLimiter, async (req, res, next) => {
  try {
    const phone = normalizePhone(req.body?.phone);
    const code = typeof req.body?.code === 'string' || typeof req.body?.code === 'number'
      ? String(req.body.code).trim()
      : '';

    if (!phone) {
      return res.status(400).json({
        error: 'invalid_phone',
        message: 'Provide a valid phone number (8–15 digits, E.164-ish).',
      });
    }

    if (!/^\d{6}$/.test(code)) {
      return res.status(400).json({
        error: 'invalid_code',
        message: 'Code must be a 6-digit number.',
      });
    }

    const maxAttempts = OTP_MAX_ATTEMPTS();
    const attemptsRaw = await redis.get(attemptsKey(phone));
    const attempts = attemptsRaw ? Number(attemptsRaw) : 0;

    if (attempts >= maxAttempts) {
      return res.status(429).json({
        error: 'too_many_attempts',
        message: 'Too many failed attempts. Request a new code via /send.',
      });
    }

    const stored = await redis.get(otpKey(phone));
    if (!stored) {
      return res.status(400).json({ error: 'expired_or_not_found' });
    }

    const incoming = hashOtp(code, phone);
    const match = safeEqualHex(incoming, stored);

    if (!match) {
      const nextAttempts = await redis.incr(attemptsKey(phone));
      // Align attempts TTL with remaining OTP TTL when possible
      const otpTtl = await redis.ttl(otpKey(phone));
      if (otpTtl > 0) {
        await redis.expire(attemptsKey(phone), otpTtl);
      }

      if (nextAttempts >= maxAttempts) {
        return res.status(429).json({
          error: 'too_many_attempts',
          message: 'Too many failed attempts. Request a new code via /send.',
          attemptsRemaining: 0,
        });
      }

      return res.status(400).json({
        success: false,
        attemptsRemaining: Math.max(0, maxAttempts - nextAttempts),
      });
    }

    await redis.del(otpKey(phone), attemptsKey(phone), cooldownKey(phone));
    return res.json({ success: true });
  } catch (err) {
    return next(err);
  }
});

module.exports = router;
module.exports.redis = redis;
