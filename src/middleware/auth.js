const crypto = require('crypto');

/**
 * Require a shared API key on protected routes.
 * Accepts: Authorization: Bearer <key>  OR  X-Api-Key: <key>
 */
function requireApiKey(req, res, next) {
  const expected = process.env.API_KEY;
  if (!expected || expected.length < 16) {
    console.error('[auth] API_KEY is missing or too short — refusing requests');
    return res.status(503).json({
      error: 'misconfigured',
      message: 'Service is not configured for authenticated access.',
    });
  }

  const header = req.get('authorization') || '';
  const bearer = header.match(/^Bearer\s+(.+)$/i)?.[1]?.trim();
  const provided = bearer || req.get('x-api-key') || '';

  if (!provided || !safeEqual(provided, expected)) {
    return res.status(401).json({
      error: 'unauthorized',
      message: 'Invalid or missing API key.',
    });
  }

  return next();
}

function safeEqual(a, b) {
  const bufA = Buffer.from(String(a), 'utf8');
  const bufB = Buffer.from(String(b), 'utf8');
  if (bufA.length !== bufB.length) {
    // Still run a comparison to reduce timing leaks on length
    crypto.timingSafeEqual(bufA, bufA);
    return false;
  }
  return crypto.timingSafeEqual(bufA, bufB);
}

module.exports = { requireApiKey };
