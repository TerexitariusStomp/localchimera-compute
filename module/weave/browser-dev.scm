;;; module/weave/browser-dev.scm — dev-only "tail" fragment.
;;;
;;; NOT compiled directly. The Makefile (target weave/.dev/weave-live.scm)
;;; concatenates:
;;;
;;;   (1) a (use-modules (hoot web-repl)) preamble,
;;;   (2) the entire prod module/weave/browser.scm verbatim,
;;;   (3) this file,
;;;
;;; into weave/.dev/weave-live.scm which is then passed to guild
;;; compile-wasm with -g2. The ordering guarantees that (refresh!) and
;;; register-callbacks! (which wires LiveKit events into WASM) have run
;;; before run-web-repl takes over the thread.
;;;
;;; We can't use (include "browser.scm") here because Hoot's
;;; library-group compiler only recognises `include` inside
;;; (define-library …) forms — concatenation at build time is the
;;; least-intrusive workaround.
;;;
;;; The dev WASM is served on the same origin as the (hoot web-server)
;;; that hosts it. server/weave-dev.scm binds port 8082, so we override
;;; current-repl-server (which defaults to localhost:8080 upstream) to
;;; match.

(parameterize ((current-repl-server "http://localhost:8082"))
  (run-web-repl))
