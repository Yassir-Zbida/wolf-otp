require('dotenv').config();

const express = require('express');
const helmet = require('helmet');
const otpRoutes = require('./routes/otp');
const { requireApiKey } = require('./middleware/auth');

const app = express();
const PORT = Number(process.env.PORT || 4000);

if (process.env.TRUST_PROXY === '1' || process.env.TRUST_PROXY === 'true') {
  app.set('trust proxy', 1);
}

app.disable('x-powered-by');
app.use(helmet({ contentSecurityPolicy: false }));
app.use(express.json({ limit: '16kb' }));

app.get('/health', (_req, res) => {
  res.json({ ok: true });
});

app.use('/api/otp', requireApiKey, otpRoutes);

app.use((_req, res) => {
  res.status(404).json({ error: 'not_found' });
});

// Centralized error handler — never leak stacks or internal WAHA details
// eslint-disable-next-line no-unused-vars
app.use((err, _req, res, _next) => {
  console.error('[error]', {
    timestamp: new Date().toISOString(),
    message: err.message,
    code: err.code,
  });

  res.status(500).json({
    error: 'internal_error',
    message: 'Something went wrong. Please try again later.',
  });
});

async function start() {
  if (!process.env.OTP_SECRET || process.env.OTP_SECRET.includes('changeme')) {
    console.error('[startup] Set a strong OTP_SECRET before running (see .env.example).');
    process.exit(1);
  }
  if (!process.env.API_KEY || process.env.API_KEY.length < 16) {
    console.error('[startup] Set a strong API_KEY (min 16 chars) before running.');
    process.exit(1);
  }

  try {
    await otpRoutes.redis.connect();
    await otpRoutes.redis.ping();
  } catch (err) {
    console.error('[startup] Redis connection failed:', err.message);
    process.exit(1);
  }

  app.listen(PORT, '0.0.0.0', () => {
    console.log(`OTP service listening on port ${PORT}`);
  });
}

start();
