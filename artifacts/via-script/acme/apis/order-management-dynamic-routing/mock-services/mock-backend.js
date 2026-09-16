/*
 * Minimal mock backend, parameterized by env vars, so each issuer can be
 * routed to a visibly distinct destination for testing dynamic-endpoint
 * routing (see interceptor-service/interceptor.js).
 *
 * Usage: NAME=keycloak_backend PORT=7091 node mock-backend.js
 */
'use strict';

const http = require('http');

const NAME = process.env.NAME || 'mock_backend';
const PORT = parseInt(process.env.PORT || '7090', 10);

const server = http.createServer((req, res) => {
  console.log(`[${NAME}] ${req.method} ${req.url}`);
  console.log(`[${NAME}] headers: ${JSON.stringify(req.headers)}`);
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({
    backend: NAME,
    books: [{ id: '1', title: `Book served by ${NAME}`, author: 'Mock', status: 'read' }],
  }));
});

server.listen(PORT, () => console.log(`[${NAME}] mock backend listening on :${PORT}`));
