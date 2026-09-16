/*
 * Mock WK Agent backend. A WK Agent is "just a REST API" whose response
 * carries a custom header reporting token usage for that call (completion
 * tokens, output tokens, etc.) — this stands in for a real agent so the
 * org-wide token-based rate limit (advanced-ratelimit, costExtraction from
 * response_header) can be exercised without a real LLM backend.
 *
 * Usage: PORT=7094 COMPLETION_TOKENS=50 node mock-agent-backend.js
 * (COMPLETION_TOKENS is fixed per call here, for a predictable, easy-to-verify
 * quota countdown in testing — a real agent's value varies per response.)
 */
'use strict';

const http = require('http');

const PORT = parseInt(process.env.PORT || '7094', 10);
const COMPLETION_TOKENS = parseInt(process.env.COMPLETION_TOKENS || '50', 10);

const server = http.createServer((req, res) => {
  console.log(`[mock-agent-backend] ${req.method} ${req.url} -> X-Completion-Tokens: ${COMPLETION_TOKENS}`);
  res.writeHead(200, {
    'Content-Type': 'application/json',
    'X-Completion-Tokens': String(COMPLETION_TOKENS),
  });
  res.end(JSON.stringify({
    result: 'Agent response',
    usage: { completion_tokens: COMPLETION_TOKENS },
  }));
});

server.listen(PORT, () => console.log(`[mock-agent-backend] listening on :${PORT}, completion_tokens=${COMPLETION_TOKENS} per call`));
