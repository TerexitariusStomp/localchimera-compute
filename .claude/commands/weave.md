Start the Weave HTTP server on port 8081.

Run this command from the project root:
```
LIVEKIT_API_KEY=${LIVEKIT_API_KEY:-devkey} \
LIVEKIT_API_SECRET=${LIVEKIT_API_SECRET:-devkey_secret_at_least_32_chars_long} \
LIVEKIT_HOST=${LIVEKIT_HOST:-http://localhost:7880} \
LIVEKIT_WS_HOST=${LIVEKIT_WS_HOST:-ws://localhost:7880} \
guile -L module server/weave.scm 8081
```

The server will be available at http://localhost:8081

For the **live-hacking** dev variant on port 8082 (separate vat, loopback only,
runs the `-g2` wasm bundle with the Hoot REPL relay), use `make weave-dev`
instead. Routes are shared with this prod server via `module/weave/routes.scm`.
See `docs/weave/LIVE_HACKING.md`.
