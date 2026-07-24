const rateLimit = require('express-rate-limit');

/**
 * IP-based rate limit for OTP send endpoint.
 * Behind a reverse proxy, set TRUST_PROXY=1 so req.ip is correct.
 */
const sendRateLimiter = rateLimit({
  windowMs: Number(process.env.OTP_IP_RATE_WINDOW_MS || 60 * 60 * 1000),
  max: Number(process.env.OTP_IP_RATE_MAX || 30),
  standardHeaders: true,
  legacyHeaders: false,
  message: {
    error: 'rate_limit_exceeded',
    message: 'Too many OTP send requests from this IP. Try again later.',
  },
});

const verifyRateLimiter = rateLimit({
  windowMs: Number(process.env.OTP_VERIFY_IP_RATE_WINDOW_MS || 15 * 60 * 1000),
  max: Number(process.env.OTP_VERIFY_IP_RATE_MAX || 60),
  standardHeaders: true,
  legacyHeaders: false,
  message: {
    error: 'rate_limit_exceeded',
    message: 'Too many verify attempts from this IP. Try again later.',
  },
});

module.exports = { sendRateLimiter, verifyRateLimiter };
