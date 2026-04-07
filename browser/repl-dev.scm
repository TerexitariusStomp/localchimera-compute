;;; browser/repl-dev.scm — dev-only "tail" fragment.
;;;
;;; NOT compiled directly. The Makefile (target browser/.dev/repl-live.scm)
;;; concatenates:
;;;
;;;   (1) a (use-modules (hoot web-repl)) preamble,
;;;   (2) the entire prod browser/repl.scm verbatim,
;;;   (3) this file,
;;;
;;; into browser/.dev/repl-live.scm which is then passed to guild
;;; compile-wasm with -g2. The ordering guarantees that every top-level
;;; form in repl.scm (FFI, (refresh!), event listeners, OCapN bootstrap)
;;; has already run before run-web-repl takes over the thread.
;;;
;;; We can't use (include "repl.scm") here because Hoot's library-group
;;; compiler only recognises `include` inside (define-library …) forms —
;;; concatenation at build time is the least-intrusive workaround.
;;;
;;; current-repl-server defaults to "http://localhost:8080" upstream;
;;; `make serve-dev` runs `(hoot web-server) serve` from browser/.dev/
;;; on that same default, so no parameterize is needed for the local
;;; case. Override with another `parameterize` here if you ever want
;;; the dev wasm to dial a non-default origin.

(run-web-repl)
