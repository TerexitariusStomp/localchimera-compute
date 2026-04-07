#!/usr/bin/env -S guile -L module
!#
;;; server/weave.scm — Weave HTTP server (production)
;;;
;;; Thin adapter over (weave routes). Serves the Weave UI on WEAVE_PORT
;;; (default 8081) via Guile's stock (web server). Routes are defined once
;;; in module/weave/routes.scm and shared with server/weave-dev.scm (the
;;; live-hacking dev server that uses (hoot web-server) + its /repl proxy).
;;;
;;; Environment variables:
;;;   LIVEKIT_API_KEY    — LiveKit API key
;;;   LIVEKIT_API_SECRET — LiveKit API secret
;;;   LIVEKIT_URL        — LiveKit URL (default: ws://localhost:7880)
;;;   WEAVE_PORT         — HTTP port (default: 8081)
;;;   WEAVE_HOST         — bind address (default: 0.0.0.0)

(use-modules (web server)
             (web request)
             (web uri)
             (ice-9 format)
             (weave livekit)
             (weave routes))

;;; ── Actor state ─────────────────────────────────────────────────────────────

(define *state* (spawn-weave-state "weave"))

;;; ── Request dispatch ────────────────────────────────────────────────────────

(define (request-path req)
  (uri-path (request-uri req)))

;; Adapter: dispatch-weave-request and respond-static-asset return either #f
;; (single value, route not handled) or (values response body). `or` cannot
;; chain those because it discards extra values from non-tail expressions —
;; we'd return a bare response and (web server) would 500. Materialise the
;; result as a cons before falling through.
(define (capture proc)
  (call-with-values proc
    (case-lambda
      ((x) (and x (cons x #f)))
      ((resp body) (cons resp body)))))

(define (weave-handler request body)
  (let* ((method (request-method request))
         (path   (request-path request))
         (result (or (capture (lambda () (dispatch-weave-request *state* method path body)))
                     (capture (lambda () (respond-static-asset *state* path)))
                     (capture (lambda () (respond-not-found path))))))
    (format (current-error-port) "~a ~a\n" method path)
    (values (car result) (cdr result))))

;;; ── Entry point ─────────────────────────────────────────────────────────────

(define (main)
  (let ((port (string->number
               (or (getenv "WEAVE_PORT")
                   (if (> (length (command-line)) 1)
                       (cadr (command-line))
                       "8081")))))

    (format #t "\n╔══════════════════════════════════════╗\n")
    (format #t "║  Weave server  →  http://0.0.0.0:~a  ║\n" port)
    (format #t "║  LiveKit host  →  ~a\n" (livekit-host))
    (format #t "╚══════════════════════════════════════╝\n\n")

    (run-server weave-handler 'http
                `(#:host ,(or (getenv "WEAVE_HOST") "0.0.0.0")
                  #:port ,port))))

(main)
