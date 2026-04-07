#!/usr/bin/env -S guile -L module
!#
;;; server/weave-dev.scm — Weave development server for live hacking.
;;;
;;; Uses Hoot 0.8's (hoot web-server) which doubles as a WebSocket REPL
;;; proxy: Geiser (or any TCP REPL client) connects on port 37146 and the
;;; dev server forwards traffic over a WebSocket to the in-Wasm REPL
;;; running inside the browser tab. Combined with the -g2 wasm bundle in
;;; weave/.dev/weave.wasm, this lets you edit UI render procedures in
;;; your editor and have them take effect in the running tab without a
;;; page reload.
;;;
;;; Routes are shared with server/weave.scm via (weave routes) — the API
;;; table lives in one place. Unknown routes fall through to the base
;;; router in (hoot web-server), which handles /repl (WebSocket upgrade),
;;; /repl/load/... (module source fetching), and static files from
;;; weave/.dev/.
;;;
;;; Ports:
;;;   8082   — HTTP (configurable via WEAVE_DEV_PORT)
;;;   37146  — Hoot TCP REPL listener (geiser-hoot connects here)
;;;
;;; Both bind to 127.0.0.1 only (INADDR_LOOPBACK default). Access from a
;;; remote developer machine requires an SSH tunnel:
;;;   ssh -L 8082:127.0.0.1:8082 -L 37146:127.0.0.1:37146 playnet@…
;;;
;;; DO NOT run this alongside the production server/weave.scm expecting
;;; shared state — they spawn independent vats and see different rooms.

(use-modules (ice-9 format)
             (hoot web-server)
             (weave routes))

;;; ── Actor state ─────────────────────────────────────────────────────────────
;;; Independent vat from server/weave.scm. Dev rooms/meetings are not
;;; visible to prod and vice-versa.

(define *state*
  (let* ((here (or (current-filename) "server/weave-dev.scm"))
         (repo-root (dirname (dirname here)))
         (assets    (string-append repo-root "/weave/.dev")))
    (spawn-weave-state "weave-dev" #:assets-dir assets)))

;;; ── Entry point ─────────────────────────────────────────────────────────────

(define (main)
  (let* ((port (string->number (or (getenv "WEAVE_DEV_PORT") "8082")))
         (repl-port
          (string->number (or (getenv "WEAVE_DEV_REPL_PORT") "37146")))
         (work-dir (weave-state-assets-dir *state*)))
    (format #t "\n╔═══════════════════════════════════════════════╗\n")
    (format #t "║  Weave DEV server (live hacking)              ║\n")
    (format #t "║  HTTP       →  http://127.0.0.1:~a         ║\n" port)
    (format #t "║  REPL proxy →  /repl WebSocket                ║\n")
    (format #t "║  Geiser     →  M-x geiser-hoot localhost ~a ║\n" repl-port)
    (format #t "║  Work dir   →  ~a\n" work-dir)
    (format #t "╚═══════════════════════════════════════════════╝\n\n")
    (serve #:work-dir work-dir
           #:port port
           #:repl-port repl-port
           #:router (weave-hoot-router *state*))))

(main)
