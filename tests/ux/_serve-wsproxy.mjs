// tests/ux/_serve-wsproxy.mjs — dev static server with a /ws → gateway WebSocket
// reverse-proxy, mirroring the production nginx (/ws → 127.0.0.1:GATEWAY_PORT).
// Lets discoverGateway()'s "self" entry (ws://<origin>/ws) reach a local gateway.
//
//   node _serve-wsproxy.mjs <browser-dir> <port> <gateway-port>
import http from 'http';
import net from 'net';
import { createReadStream, existsSync, statSync } from 'fs';
import { join, normalize, extname } from 'path';

const ROOT = process.argv[2];
const PORT = Number(process.argv[3] || 8089);
const GW   = Number(process.argv[4] || 9090);

const MIME = { '.html':'text/html', '.js':'text/javascript', '.mjs':'text/javascript',
  '.wasm':'application/wasm', '.css':'text/css', '.json':'application/json',
  '.png':'image/png', '.svg':'image/svg+xml', '.ico':'image/x-icon', '.map':'application/json' };

// The gateway sref WITHOUT its ?url= suffix — discoverGateway pairs this with
// the "self" entry's ws (ws://<origin>/ws, which we proxy to the gateway).
const SREF = (process.env.GATEWAY_SREF || '').split('?')[0];

const server = http.createServer((req, res) => {
  let path = decodeURIComponent(req.url.split('?')[0]);
  // Mirror nginx/serve-static: /entry-points.json drives discoverGateway().
  if (path === '/entry-points.json') {
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
    res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
    res.end(JSON.stringify({ sref: SREF, gateway: [] }));
    return;
  }
  // Refuse the dev live-reload signals so the e2e page never reloads mid-test.
  // app.html on a loopback origin is in dev mode (app/pwa.ts isDev): it polls
  // /reload-token.txt every 1s and reloads when it changes, and a page from
  // another origin would register /sw.js — either can destroy the
  // Playwright execution context if a file watcher (a stray `make serve` /
  // `make onion` livereload-watch) bumps the token while the test rebuilds
  // browser/*.wasm. 404-ing both makes the run hermetic and deterministic.
  if (path === '/reload-token.txt' || path === '/sw.js') {
    res.writeHead(404); res.end('not found'); return;
  }
  if (path === '/') path = '/index.html';
  const file = normalize(join(ROOT, path));
  if (!file.startsWith(ROOT) || !existsSync(file) || !statSync(file).isFile()) {
    res.writeHead(404); res.end('not found'); return;
  }
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
  res.setHeader('Content-Type', MIME[extname(file)] || 'application/octet-stream');
  createReadStream(file).pipe(res);
});

// WebSocket upgrade on /ws → raw TCP pipe to the gateway (path rewritten to /).
server.on('upgrade', (req, socket, head) => {
  if (!req.url.startsWith('/ws')) { socket.destroy(); return; }
  console.log(`[serve-wsproxy] upgrade ${req.url} → 127.0.0.1:${GW}`);
  const up = net.connect(GW, '127.0.0.1', () => {
    const headers = Object.entries(req.headers)
      .map(([k, v]) => `${k}: ${v}`).join('\r\n');
    up.write(`GET / HTTP/1.1\r\n${headers}\r\n\r\n`);
    if (head && head.length) up.write(head);
    let logged = false;
    up.on('data', (d) => { if (!logged) { logged = true;
      console.log(`[serve-wsproxy] gateway said: ${d.toString('latin1').split('\r\n')[0]}`); } });
    up.pipe(socket); socket.pipe(up);
  });
  up.on('error', (e) => { console.log(`[serve-wsproxy] gateway conn error: ${e.message}`); socket.destroy(); });
  socket.on('error', () => up.destroy());
});

server.listen(PORT, () => console.log(`[serve-wsproxy] :${PORT} static=${ROOT} /ws→127.0.0.1:${GW}`));
