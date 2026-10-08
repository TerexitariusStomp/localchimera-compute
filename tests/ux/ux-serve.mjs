/// tests/ux/ux-serve.mjs — the static server every UX suite runs the dial over.
///
/// Eighteen suites carried a byte-identical copy of this, differing only in
/// where the MIME table wrapped. It is a real dependency of every one of them —
/// the dial is ES modules with no bundler, so it MUST be served rather than
/// opened from a file:// path, and the content types have to be right or the
/// browser refuses the module.
///
/// A suite gets the dial as the repo holds it by calling serveBrowser() bare,
/// and almost every suite does. The three options exist for the suite whose
/// SUBJECT is the serving: tests/ux/sw-offline-ux.mjs serves a stamped scratch
/// copy, answers `/` with the dial and sends the server's cache headers,
/// because the service worker's behaviour depends on all three.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';


/** The types the dial's own assets need. Anything else is served as bytes. */
const MIME = {
  '.html': 'text/html',
  '.js':   'text/javascript',   // wrong here and every module import fails
  '.mjs':  'text/javascript',   // the vendored ONNX runtime's loader is imported as a module
  '.css':  'text/css',
  '.json': 'application/json',
  '.wasm': 'application/wasm',
  '.woff2': 'font/woff2',
  '.svg':  'image/svg+xml',
  '.png':  'image/png',
};

/**
 * Serve the dial on an ephemeral port.
 *
 *   root     the directory served (default: browser/)
 *   index    the file `/` answers with (default: none — `/` is a 404)
 *   headers  (pathname) => extra response headers
 *   host     the name the returned base URL uses (the listener is loopback)
 *
 * Returns the base URL and the closer. The port is 0 — chosen by the OS —
 * because suites run concurrently under `make -j` and a fixed port would make
 * them collide in a way that reads as a flaky test rather than as a clash.
 */
export async function serveBrowser({ root = 'browser', index = null, headers = () => ({}), host = '127.0.0.1' } = {}) {
  const ROOT = path.resolve(root);
  const srv = http.createServer((req, res) => {
    let p = decodeURIComponent(req.url.split('?')[0]);
    if (p === '/' && index) p = '/' + index;
    const f = path.join(ROOT, p);
    fs.readFile(f, (err, data) => {
      if (err) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { 'content-type': MIME[path.extname(f)] || 'application/octet-stream', ...headers(p) });
      res.end(data);
    });
  });
  await new Promise(r => srv.listen(0, '127.0.0.1', r));
  return {
    base: `http://${host}:${srv.address().port}`,
    close: () => srv.close(),
  };
}
