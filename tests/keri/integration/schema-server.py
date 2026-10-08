#!/usr/bin/env python3
# schema-server.py — serve saidified ACDC schemas at /oobi/<said>.
#
# KERIA resolves a schema by OOBI: GET <server>/oobi/<schema-said> must return
# the schema JSON whose "$id" == <schema-said>. This indexes the schema dir by
# $id and serves each at that path (and also /<said> bare, for tolerance).
#
#   python3 schema-server.py <schema-dir> <port>

import http.server, json, glob, os, sys

DIR  = sys.argv[1]
PORT = int(sys.argv[2])

BY_SAID = {}
for f in sorted(glob.glob(os.path.join(DIR, "*.json"))):
    try:
        said = json.load(open(f)).get("$id", "")
    except Exception:
        continue
    if said:
        BY_SAID[said] = f

sys.stderr.write(f"[schema-server] :{PORT} serving {len(BY_SAID)} schemas from {DIR}\n")
for s, f in BY_SAID.items():
    sys.stderr.write(f"  {s}  ->  {os.path.basename(f)}\n")
sys.stderr.flush()

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        said = self.path.rstrip("/").rsplit("/", 1)[-1].split("?")[0]
        f = BY_SAID.get(said)
        if not f:
            self.send_response(404); self.end_headers(); return
        body = open(f, "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "application/schema+json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
