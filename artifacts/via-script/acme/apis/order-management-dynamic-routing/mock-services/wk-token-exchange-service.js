/*
 * Mock "WK token-exchange service" for the org-token-exchange gateway policy
 * (policies/org-token-exchange). Stands in for the real WK-specific service
 * until one exists: accepts the caller's own token, decodes org_id/org_name
 * from it (no signature verification here — this is a throwaway mock, not a
 * replacement for jwt-auth, which already verified the token before this
 * policy ever ran), and returns a synthetic backend-specific token.
 *
 * Usage: PORT=7099 node wk-token-exchange-service.js
 *
 * Request  (from org-token-exchange, see exchangeRequest in the policy):
 *   POST /exchange
 *   Authorization: Bearer <caller token>
 *   Content-Type: application/json
 *   { "token": "<caller token>", "org_id": "...", "org_name": "..." }
 *
 * Response:
 *   200 { "access_token": "<backend-specific token>", "org_name": "...", "issued_for": "<sub>" }
 *   400 { "error": "..." }              -- no token supplied
 */
'use strict';

const http = require('http');
const crypto = require('crypto');

const PORT = parseInt(process.env.PORT || '7099', 10);

function decodeJwtPayload(token) {
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  try {
    const json = Buffer.from(parts[1], 'base64url').toString('utf8');
    return JSON.parse(json);
  } catch {
    return null;
  }
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (chunk) => { data += chunk; });
    req.on('end', () => resolve(data));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method !== 'POST' || req.url !== '/exchange') {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'not found' }));
    return;
  }

  let parsedBody;
  try {
    parsedBody = JSON.parse(await readBody(req));
  } catch {
    parsedBody = {};
  }

  const callerToken = parsedBody.token || (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!callerToken) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'missing token' }));
    return;
  }

  const claims = decodeJwtPayload(callerToken) || {};
  const orgId = parsedBody.org_id || claims.org_id || 'unknown-org-id';
  const orgName = parsedBody.org_name || claims.org_name || 'unknown-org';
  const subject = claims.sub || 'unknown-subject';

  // Synthetic backend-specific token: proves this is NOT the caller's own
  // token, and is deterministic enough per org to eyeball in logs/captures.
  const backendToken = `wk-backend-token.${orgName}.${crypto.randomBytes(12).toString('hex')}`;

  console.log(`[wk-token-exchange] org_id=${orgId} org_name=${orgName} sub=${subject} -> issued ${backendToken}`);

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({
    access_token: backendToken,
    org_id: orgId,
    org_name: orgName,
    issued_for: subject,
  }));
});

server.listen(PORT, () => console.log(`[wk-token-exchange] mock token-exchange service listening on :${PORT}`));
