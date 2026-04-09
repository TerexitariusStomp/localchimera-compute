#!/usr/bin/env -S guile
!#
;;; server/gateway.scm — OCapN gateway for playnet
;;;
;;; Replaces relay.scm.  Spawns a Goblins mycapn listening on
;;; WebSocket (always) and Reticulum (optional, when configured).
;;; Registers a ^lobby actor, and prints the sturdyref URI.
;;; Browser and mesh clients enliven this sturdyref to get
;;; capability-secured access to all services.
;;;
;;; Usage:
;;;   guile -L module -L key-pool server/gateway.scm [--port PORT] [--reticulum]
;;;
;;; Environment:
;;;   API_KEYS      — comma-separated API keys (fallback: OPENROUTER_KEYS)
;;;   API_PROVIDER  — provider name: openrouter, openai, or generic (default: openrouter)
;;;   PLAYNET_DATA_DIR — persistent state dir (default /var/lib/playnet)
;;;   RETICULUM_BRIDGE_SOCKET — path to reticulum-bridge control socket
;;;                             (enables Reticulum netlayer; overrides default path)

(use-modules (fibers)
             (fibers conditions)
             (fibers operations)
             (goblins)
             (goblins actor-lib methods)
             (goblins ocapn ids)
             (goblins ocapn captp)
             (goblins ocapn netlayer websocket)
             (goblins utils crypto)
             (goblins utils hashmap)
             (ice-9 format)
             (ice-9 match)
             (ice-9 textual-ports)
             (playnet gateway lobby)
             (goblins persistence-store memory)
             (playnet gateway presence)
             (playnet gateway services)
             (playnet gateway terminal)
             (playnet gateway mailbox))

;; Load key-pool from its directory
(add-to-load-path "key-pool")
(use-modules (key-pool))

;; Load signup-agent definition
(primitive-load "server/signup-agent.scm")

;; Load the planner (chdir wrapper resolves load-all.scm relative paths),
;; then the planner-service actor and the demo seed. These three files
;; are not Guile modules; they primitive-load planner top-level defs.
(primitive-load "server/planner-loader.scm")
(primitive-load "server/planner-service.scm")
(primitive-load "server/seed-meeting-scope.scm")

;;; ── Configuration ──────────────────────────────────────────────────────────

(define %data-dir
  (or (getenv "PLAYNET_DATA_DIR") "/var/lib/playnet"))

(define (data-path filename)
  (string-append %data-dir "/" filename))

(define (log! fmt . args)
  (apply format (current-error-port) fmt args)
  (force-output (current-error-port)))

;;; ── Designator key persistence ─────────────────────────────────────────────
;;;
;;; The designator key determines the server's OCapN identity.
;;; It must survive restarts so sturdyrefs remain stable.

(define (load-or-generate-designator-key!)
  "Load the designator key from disk, or generate and save a new one."
  (let ((path (data-path "designator-key.scm")))
    (if (file-exists? path)
        (let ((data (call-with-input-file path read)))
          (log!
                  "  [gateway] loaded designator key from ~a~%" path)
          (data->private-key data))
        ;; Generate new key
        (let ((key (generate-key-pair)))
          ;; Ensure data directory exists
          (catch #t
            (lambda () (mkdir %data-dir))
            (lambda args #f))  ;; ignore if exists
          (call-with-output-file path
            (lambda (port)
              (write (private-key->data key) port)
              (newline port)))
          (log!
                  "  [gateway] generated new designator key at ~a~%" path)
          key))))

;;; ── Parse arguments ────────────────────────────────────────────────────────

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

;;; ── Main ───────────────────────────────────────────────────────────────────

(define (main args)
  (define-values (ws-host ws-port reticulum-flag?) (parse-args args))

  ;; Reticulum is enabled if --reticulum flag was passed OR if
  ;; RETICULUM_BRIDGE_SOCKET environment variable is set.
  (define reticulum-enabled?
    (or reticulum-flag? (getenv "RETICULUM_BRIDGE_SOCKET")))

  (define reticulum-control-path
    (or (getenv "RETICULUM_BRIDGE_SOCKET")
        "/var/run/reticulum-bridge.sock"))

  ;; Conditionally load the Reticulum netlayer module at runtime.
  ;; use-modules is a top-level macro, so we resolve dynamically.
  (define ^reticulum-netlayer
    (if reticulum-enabled?
        (begin
          (resolve-module '(goblins ocapn netlayer reticulum))
          (module-ref (resolve-interface '(goblins ocapn netlayer reticulum))
                      '^reticulum-netlayer))
        #f))

  (let ()

    ;; ── Spawn service vats + actors ─────────────────────────────────────

    (define signup-vat (spawn-vat #:name "signup"))
    (define signup-agent
      (with-vat signup-vat (spawn ^signup-agent (hashmap))))

    (define pool-vat (spawn-vat #:name "key-pool"))
    (define key-pool
      (let ((keys-env (or (getenv "API_KEYS")
                          (getenv "OPENROUTER_KEYS")
                          ""))
            (provider-name (or (getenv "API_PROVIDER") "openrouter")))
        (if (string=? keys-env "")
            (begin
              (log! "  [gateway] No API_KEYS — transcription disabled~%")
              #f)
            (let* ((provider (case (string->symbol provider-name)
                               ((openrouter) (openrouter-provider))
                               ((openai)     (openai-provider))
                               ((generic)    (generic-provider
                                              (or (getenv "API_BASE_URL")
                                                  (error "API_PROVIDER=generic requires API_BASE_URL"))))
                               (else (error "unknown API_PROVIDER" provider-name))))
                   (pool (make-key-pool pool-vat keys-env #:provider provider)))
              (log! "  [gateway] key-pool loaded (~a) — transcription enabled~%"
                    provider-name)
              pool))))

    ;; Start key-pool health monitor
    (when key-pool
      (start-key-pool-monitor pool-vat key-pool))

    ;; ── Run under fibers (required by WebSocket netlayer) ───────────────

    (run-fibers
     (lambda ()
       (define designator-key (load-or-generate-designator-key!))

       ;; OCapN vat + netlayer
       (define ocapn-vat (spawn-vat #:name "ocapn"))

       (define ws-netlayer
         (with-vat ocapn-vat
           (spawn ^websocket-netlayer
                  #:host ws-host
                  #:port ws-port
                  #:encrypted? #f
                  #:designator-key designator-key
                  #:max-peers 64)))

       (define mycapn
         (with-vat ocapn-vat
           (spawn-mycapn ws-netlayer)))

       ;; Optionally spawn and install Reticulum netlayer
       (define ret-netlayer
         (if reticulum-enabled?
             (with-vat ocapn-vat
               (spawn ^reticulum-netlayer
                      #:control-path reticulum-control-path))
             #f))

       (when ret-netlayer
         (with-vat ocapn-vat
           (<- mycapn 'install-netlayer ret-netlayer))
         (log! "  [gateway] Reticulum netlayer installed (control: ~a)~%"
               reticulum-control-path))

       ;; Gateway actors
       (define gateway-vat (spawn-vat #:name "gateway"))

       ;; ── Planner vat + scope + seed (Phase 2: memory store) ──────────
       ;; ^planner-service lives inside planner-vat alongside the stores
       ;; so its methods have synchronous near-call access. The lobby
       ;; (in gateway-vat) holds a reference; the OCapN wire is the only
       ;; cross-vat boundary.
       (define planner-store (make-memory-store))
       (define-values (planner-vat meeting-scope)
         (spawn-persistent-vat
           scope-env
           (lambda () (spawn-scope "Meeting Commune"))
           planner-store))

       (define planner-service
         (with-vat planner-vat
           (seed-meeting-scope! meeting-scope)
           (spawn ^planner-service
                  (hashmap-set (hashmap) "org:meeting" meeting-scope))))

       (log! "  [gateway] planner: meeting commune seeded~%")

       (define presence-actor
         (with-vat gateway-vat (spawn ^presence (hashmap))))

       (define mailbox-mgr
         (with-vat gateway-vat (spawn ^mailbox-manager (hashmap))))

       (define transcription-svc
         (with-vat gateway-vat
           (spawn ^transcription-service pool-vat key-pool)))

       (define express-svc
         (with-vat gateway-vat
           (spawn ^express-service pool-vat key-pool)))

       (define terminal-svc
         (with-vat gateway-vat
           (spawn ^terminal-service signup-vat signup-agent)))

       (define lobby
         (with-vat gateway-vat
           (spawn ^lobby signup-agent transcription-svc express-svc
                  presence-actor terminal-svc mailbox-mgr
                  planner-service)))

       ;; Register lobby with OCapN — get sturdyref
       (with-vat ocapn-vat
         (on (<- mycapn 'register lobby 'websocket)
             (lambda (sref)
               (let ((uri (ocapn-id->string sref)))
                 (log!
                         "~%  playnet OCapN gateway on ws://~a:~a~%"
                         ws-host ws-port)
                 (log!
                         "  sturdyref: ~a~%~%" uri)
                 ;; Write to file for browser / other clients
                 (catch #t
                   (lambda ()
                     (call-with-output-file (data-path "gateway-sref.txt")
                       (lambda (p) (display uri p) (newline p))))
                   (lambda args
                     (log!
                             "  warning: could not write sref file: ~a~%"
                             args)))))))

       ;; Register lobby with Reticulum transport when enabled
       (when ret-netlayer
         (with-vat ocapn-vat
           (on (<- mycapn 'register lobby 'reticulum)
               (lambda (ret-sref)
                 (let* ((ret-uri (ocapn-id->string ret-sref))
                        ;; Extract destination hash from ocapn://<hash>.reticulum/...
                        ;; string-split on #\/ gives ("ocapn:" "" "<hash>.reticulum" ...)
                        (dest-hash
                         (let ((authority (caddr (string-split ret-uri #\/))))
                           (car (string-split authority #\.)))))
                   (log! "  reticulum sturdyref: ~a~%" ret-uri)
                   (log! "  reticulum destination hash: ~a~%~%" dest-hash)
                   ;; Write reticulum sref alongside websocket one
                   (catch #t
                     (lambda ()
                       (call-with-output-file (data-path "gateway-ret-sref.txt")
                         (lambda (p) (display ret-uri p) (newline p))))
                     (lambda args
                       (log! "  warning: could not write reticulum sref file: ~a~%"
                             args))))))))

       ;; Hold open
       (perform-operation (wait-operation (make-condition)))))))

(main (command-line))
