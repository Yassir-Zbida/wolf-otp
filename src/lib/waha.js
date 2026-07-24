const WAHA_BASE_URL = () => process.env.WAHA_BASE_URL || 'http://localhost:3000';
const WAHA_SESSION = () => process.env.WAHA_SESSION || 'default';

class WahaError extends Error {
  /**
   * @param {string} message
   * @param {{ status?: number, code?: string, details?: unknown }} [opts]
   */
  constructor(message, opts = {}) {
    super(message);
    this.name = 'WahaError';
    this.status = opts.status;
    this.code = opts.code || 'waha_error';
    this.details = opts.details;
  }
}

/** @returns {Record<string, string>} */
function wahaHeaders(extra = {}) {
  const headers = {
    Accept: 'application/json',
    ...extra,
  };
  const apiKey = process.env.WAHA_API_KEY;
  if (apiKey) {
    headers['X-Api-Key'] = apiKey;
  }
  return headers;
}

/**
 * Fetch session status from WAHA.
 * @returns {Promise<{ name: string, status: string }>}
 */
async function checkSessionStatus() {
  const session = WAHA_SESSION();
  const url = `${WAHA_BASE_URL()}/api/sessions/${encodeURIComponent(session)}`;

  let res;
  try {
    res = await fetch(url, {
      method: 'GET',
      headers: wahaHeaders(),
    });
  } catch (err) {
    throw new WahaError('Unable to reach WAHA service', {
      code: 'waha_unreachable',
      details: err.message,
    });
  }

  if (res.status === 401 || res.status === 403) {
    throw new WahaError('WAHA rejected the API key', {
      status: res.status,
      code: 'waha_unauthorized',
    });
  }

  if (res.status === 404) {
    throw new WahaError(`WAHA session "${session}" not found`, {
      status: 404,
      code: 'session_not_found',
    });
  }

  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new WahaError('Failed to read WAHA session status', {
      status: res.status,
      code: 'session_status_error',
      details: body,
    });
  }

  const data = await res.json();
  return { name: data.name || session, status: data.status };
}

/**
 * Send a WhatsApp text message via WAHA.
 * Fails clearly if the session is not in WORKING state.
 * @param {string} phone digits-only phone number
 * @param {string} text
 */
async function sendWhatsAppMessage(phone, text) {
  const sessionInfo = await checkSessionStatus();

  if (sessionInfo.status !== 'WORKING') {
    const hint =
      sessionInfo.status === 'SCAN_QR_CODE'
        ? 'Scan the QR code in the WAHA dashboard to authenticate.'
        : `Current status: ${sessionInfo.status}.`;
    throw new WahaError(
      `WhatsApp session is not ready. ${hint}`,
      {
        code: 'session_not_ready',
        details: { status: sessionInfo.status },
      }
    );
  }

  const session = WAHA_SESSION();
  const chatId = `${phone}@c.us`;
  const url = `${WAHA_BASE_URL()}/api/sendText`;

  let res;
  try {
    res = await fetch(url, {
      method: 'POST',
      headers: wahaHeaders({ 'Content-Type': 'application/json' }),
      body: JSON.stringify({ session, chatId, text }),
    });
  } catch (err) {
    throw new WahaError('Unable to reach WAHA service', {
      code: 'waha_unreachable',
      details: err.message,
    });
  }

  if (res.status === 401 || res.status === 403) {
    throw new WahaError('WAHA rejected the API key', {
      status: res.status,
      code: 'waha_unauthorized',
    });
  }

  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new WahaError('WAHA failed to send message', {
      status: res.status,
      code: 'send_failed',
      details: body,
    });
  }

  return res.json().catch(() => ({}));
}

module.exports = {
  checkSessionStatus,
  sendWhatsAppMessage,
  WahaError,
};
