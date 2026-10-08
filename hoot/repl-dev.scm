;;; hoot/repl-dev.scm — dev-only "tail" fragment.
;;;
;;; NOT compiled directly. The Makefile (target browser/.dev/repl-live.scm)
;;; concatenates:
;;;
;;;   (1) a (use-modules (hoot web-repl)) preamble,
;;;   (2) the entire prod hoot/repl.scm verbatim,
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
;;; current-repl-server defaults to "http://localhost:8080" upstream. The
;;; dev wasm dials the origin that served the page, so `PORT=8090 make
;;; serve-dev` (any host or port) reaches its own relay.

;; Defer the REPL websocket dial until after wasm init finishes —
;; otherwise any failure inside (run-web-repl) (no fibers scheduler,
;; websocket open error, etc.) trips a SchemeTrapError that aborts the
;; whole module init and the page never renders.
(window-set-timeout
 (procedure->external/cached
  (lambda ()
    (call-with-current-continuation
     (lambda (k)
       (with-exception-handler
        (lambda (exc) (k #f))
        (lambda ()
          (parameterize ((current-repl-server (get-location-origin)))
            (run-web-repl))))))))
 250)
