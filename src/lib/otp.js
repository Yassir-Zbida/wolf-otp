const crypto = require('crypto');

/**
 * Generate a 6-digit numeric OTP using a CSPRNG.
 * @returns {string}
 */
function generateOtp() {
  // 0–999999, zero-padded to 6 digits
  const n = crypto.randomInt(0, 1_000_000);
  return String(n).padStart(6, '0');
}

/**
 * HMAC-SHA256 hash of the OTP, keyed by phone so hashes are not reusable across numbers.
 * @param {string} code
 * @param {string} phone
 * @returns {string} hex digest
 */
function hashOtp(code, phone) {
  const secret = process.env.OTP_SECRET;
  if (!secret) {
    throw new Error('OTP_SECRET is not configured');
  }
  return crypto
    .createHmac('sha256', secret)
    .update(`${phone}:${code}`)
    .digest('hex');
}

/**
 * Constant-time comparison of two hex digests.
 * @param {string} a
 * @param {string} b
 * @returns {boolean}
 */
function safeEqualHex(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const bufA = Buffer.from(a, 'utf8');
  const bufB = Buffer.from(b, 'utf8');
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

module.exports = { generateOtp, hashOtp, safeEqualHex };
