#!/usr/bin/env node
// ws-mux.mjs — one public origin in front of the two gateway-side services.
//
// A deployment exposes ONE stable origin for the whole compute path:
//   GET /entry-points.json (and the static app) → serve-static
//   GET /ws with an Upgrade header              → the gateway's ws netlayer
// In production that origin is nginx or the CDN doing the same split; this
// is the dev-shaped version — one port cloudflared can front so a deployed
// static page gets discovery AND the socket through a single hostname.
//
//   HTTP_PORT   listen here            (default 19997)
//   WS_TARGET   ws netlayer host:port  (default 127.0.0.1:9097)
//   WEB_TARGET  serve-static host:port (default 127.0.0.1:8080)

import http from "node:http";
import net from "node:net";

const [wHost, wPort] = (process.env.WS_TARGET || "127.0.0.1:9097").split(":");
const [sHost, sPort] = (process.env.WEB_TARGET || "127.0.0.1:8080").split(":");
const listen = Number(process.env.HTTP_PORT || 19997);

const server = http.createServer((req, res) => {
  const opts = { host: sHost, port: Number(sPort), path: req.url,
                 method: req.method, headers: req.headers };
  const up = http.request(opts, (ur) => {
    res.writeHead(ur.statusCode || 502, ur.headers);
    ur.pipe(res);
  });
  up.on("error", (e) => {
    if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain" });
    res.end(`ws-mux: upstream ${e.code || e.message}`);
  });
  req.pipe(up);
});

server.on("upgrade", (req, sock, head) => {
  const target = net.connect(Number(wPort), wHost, () => {
    // same shape as prod: nginx proxies /ws to the netlayer unmodified
    target.write(`${req.method} ${req.url} HTTP/${req.httpVersion}\r\n`);
    for (const [k, v] of Object.entries(req.headers))
      target.write(`${k}: ${v}\r\n`);
    target.write("\r\n");
    if (head && head.length) target.write(head);
    sock.pipe(target).pipe(sock);
  });
  target.on("error", () => sock.destroy());
  sock.on("error", () => target.destroy());
});

server.listen(listen, () =>
  console.log(`ws-mux :${listen} — upgrade → ${wHost}:${wPort}, http → ${sHost}:${sPort}`));
