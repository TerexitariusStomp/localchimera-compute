#!/usr/bin/env -S guile
;;; SPDX-License-Identifier: AGPL-3.0-or-later
!#
;;; server/gateway.scm — OCapN gateway for playnet: the entry point.
;;;
;;; Parses the arguments and boots the gateway (module/playnet/boot/gateway.scm):
;;; a Goblins mycapn listening on WebSocket (always) and Reticulum (optional,
;;; when configured), the ^lobby every browser and mesh client enlivens for
;;; capability-secured access to all services, and the vats behind it.
;;;
;;; Usage:
;;;   guile -L module server/gateway.scm [--host HOST] [--port PORT] [--reticulum]
;;;
;;; Environment:
;;;   API_KEYS      — comma-separated API keys (fallback: OPENROUTER_KEYS)
;;;   API_PROVIDER  — provider name: nano-gpt, openrouter, openai, or generic (default: nano-gpt)
;;;   PLAYNET_DATA_DIR — persistent state dir (default /var/lib/playnet)
;;;   RETICULUM_BRIDGE_SOCKET — path to reticulum-bridge control socket
;;;                             (enables Reticulum netlayer; overrides default path)
;;;   KERIA_BRAN    — 21-char CESR passcode for KERIA agent (required for KERI auth)
;;;   KERIA_AGENT_URL — KERIA agent API URL (default: http://localhost:3901)
;;;   KERIA_BOOT_URL  — KERIA boot URL (default: http://localhost:3903)
;;;   PLAYNET_SCOPES_DURABLE, PLAYNET_FOUNDERS, PLAYNET_LAW_PACKS, PLAYNET_PEERS,
;;;   PLAYNET_UC_AID, PLAYNET_SEED_DEMO and the rest: read where they matter, in
;;;   module/playnet/boot/.

;; A sturdyref is this PROCESS's: its swiss-num is minted at register time,
;; near the end of boot, and dies with the process. Until then the file on
;; disk names the previous process, and entry-points.json would hand every
;; fresh tab a dead address. So it goes FIRST — before the module graph
;; below loads, which takes the better part of a minute on the box: a page
;; reconnecting in that window (found live 2026-09-23) read the old address
;; back and enlivened on it. Absent, serve-static answers 503 "not yet
;; written" and the page asks again on each reconnect (day-boot.js
;; discoverGateway) until this boot has written its own. Core bindings
;; only: nothing is loaded yet.
(let ((dir (or (getenv "PLAYNET_DATA_DIR") "/var/lib/playnet")))
  (for-each (lambda (f)
              (false-if-exception (delete-file (string-append dir "/" f))))
            '("gateway-sref.txt" "gateway-ret-sref.txt")))

(use-modules (ice-9 match)
             (playnet boot gateway)
             ;; The REPL prelude: an operator evaluates in (guile-user) over the
             ;; REPL socket (boot/repl), where everything this script imports is
             ;; bound. The prelude makes the whole planner and governance surface
             ;; available there unqualified, and Goblins and fibers are the forms
             ;; the operator's own expressions take (tools/dev/dev-loop-close.scm
             ;; sends `with-vat`). They are here for the operator, not for the
             ;; code, which states its own imports in module/playnet/boot/.
             (playnet boot prelude)
             (goblins) (goblins vat) (fibers))

(define (parse-args args)
  "Parse command-line arguments.  Returns (values host port reticulum?)."
  (let loop ((args (cdr args))  ;; skip program name
             (host "0.0.0.0")
             (port 9090)
             (reticulum? #f))
    (match args
      (() (values host port reticulum?))
      (("--host" h . rest)
       (loop rest h port reticulum?))
      (("--port" p . rest)
       (loop rest host (string->number p) reticulum?))
      (("--reticulum" . rest)
       (loop rest host port #t))
      ((p . rest)
       (let ((n (string->number p)))
         (if n (loop rest host n reticulum?) (loop rest host port reticulum?)))))))

(define (main args)
  (define-values (host port reticulum?) (parse-args args))
  (boot-gateway! #:host host #:port port #:reticulum? reticulum?))

(main (command-line))
