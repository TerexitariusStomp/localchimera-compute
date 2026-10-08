#!/usr/bin/env -S guile --no-auto-compile -L module
!#
;;; server/wallet-service.scm — isolated Monero wallet process
;;;
;;; Runs ^monero-wallet + ^wallet-policy in a SEPARATE process from the
;;; gateway. Exposes the policy actor via OCapN over a localhost-only
;;; WebSocket (port 9092 by default). The gateway enlivens the sturdyref
;;; written to <run-dir>/wallet-sref.txt and gets a true
;;; capability-attenuated reference to the policy — no raw wallet methods
;;; reachable, period.
;;;
;;; Why WebSocket and not a custom Unix socket netlayer? Because
;;; ^websocket-netlayer already exists, works, and the gateway can connect
;;; outbound to it via the same mycapn it uses for everything else. Zero
;;; new code. CapTP handles authentication via designator keys even over
;;; localhost — defense-in-depth.
;;;
;;; Architecture:
;;;
;;;   wallet-service (port 9092)         gateway (port 9090)
;;;   ┌────────────────────────┐         ┌────────────────────────┐
;;;   │ ^monero-wallet         │         │ ^lobby                 │
;;;   │   └─ ^wallet-policy ◄──┼── OCapN ┼──► enliven(sref)      │
;;;   │        (budget, audit)  │  ws://  │    → cap to policy    │
;;;   │                        │  :9092  │                        │
;;;   │ REPL (0600 socket)     │         │ REPL (0600 socket)     │
;;;   │   └─ raw wallet access │         │   └─ NO wallet access  │
;;;   └────────────────────────┘         └────────────────────────┘
;;;
;;; Usage:
;;;   guile --no-auto-compile -L module server/wallet-service.scm [--port PORT]
;;;
;;; Environment:
;;;   PLAYNET_DATA_DIR       — persistent state dir (default /var/lib/playnet)
;;;   PLAYNET_WALLET_RUN_DIR — sturdyref + REPL socket dir
;;;                            (default /var/run/playnet-wallet)

(use-modules (fibers)
             (fibers conditions)
             (fibers operations)
             (goblins)
             (goblins vat)
             (goblins actor-lib methods)
             (goblins ocapn ids)
             (goblins ocapn captp)
             (goblins ocapn netlayer websocket)
             (goblins utils crypto)
             (ice-9 format)
             (ice-9 getopt-long)
             (ice-9 textual-ports)
             (ice-9 threads)
             (system repl server)
             (playnet monero wallet)
             (playnet monero policy)
             (playnet monero policy-wire)
             (playnet utils secure-memory)
             (playnet utils time))

;;; ── Configuration ──────────────────────────────────────────────────────

(define %data-dir
  (or (getenv "PLAYNET_DATA_DIR") "/var/lib/playnet"))

;; The wallet's own run directory: the sturdyref handoff and the REPL
;; socket. The deploy keeps <data-dir>/wallet-sref.txt as a symlink into
;; it, which is the path the gateway reads.
(define %run-dir
  (or (getenv "PLAYNET_WALLET_RUN_DIR") "/var/run/playnet-wallet"))

(define (run-path filename)
  (string-append %run-dir "/" filename))

(define (data-path filename)
  (string-append %data-dir "/" filename))

(define (log! fmt . args)
  (apply format (current-error-port) fmt args)
  (force-output (current-error-port)))

;;; ── Policy loading ─────────────────────────────────────────────────────
;;;
;;; Fails CLOSED: if the policy file is missing or malformed, the wallet
;;; starts with a zero-budget policy so every transfer errors. Better to
;;; break visibly than to silently run at an unintended budget.

(define (zero-budget-policy reason)
  (make-monero-spend-policy 0 0 '()
    (string-append "fail-closed policy: " reason)))

(define (load-spend-policy policy-file log-fn)
  (cond
    ((not (file-exists? policy-file))
     (log-fn "  [wallet-service] ~a missing — zero-budget policy (transfers will fail)~%"
             policy-file)
     (zero-budget-policy "no policy file"))
    (else
     (catch #t
       (lambda ()
         (let* ((data (call-with-input-file policy-file read))
                (p    (deserialize-policy data)))
           (log-fn "  [wallet-service] policy: ~a XMR/month, ~a XMR default per-tx, ~a payees~%"
                   (monero-spend-policy-monthly-budget p)
                   (monero-spend-policy-default-max-per-tx p)
                   (length (monero-spend-policy-allowlist p)))
           p))
       (lambda (key . args)
         (log-fn "  [wallet-service] FAILED to parse ~a (~a ~a) — zero-budget fallback~%"
                 policy-file key args)
         (zero-budget-policy "parse error"))))))

;;; ── CLI ────────────────────────────────────────────────────────────────

(define option-spec
  '((port  (single-char #\p) (value #t))
    (help  (single-char #\h) (value #f))))

(define (main args)
  (let* ((options  (getopt-long args option-spec))
         (help?    (option-ref options 'help #f))
         (ws-port  (string->number (or (option-ref options 'port #f) "9092"))))
    (when help?
      (format #t "Usage: wallet-service.scm [--port PORT]~%")
      (format #t "Runs ^monero-wallet + ^wallet-policy on a localhost WebSocket.~%")
      (exit 0))

    (log! "~%  === playnet wallet-service ===~%")
    (log! "  data-dir: ~a~%" %data-dir)
    (log! "  ws-port:  ~a~%" ws-port)

    ;; A sturdyref from an earlier run names an identity that ended with
    ;; that run (the designator key below is fresh each start), and the run
    ;; directory outlives a reboot. It goes before anything else, so the
    ;; file's presence always means: this running wallet wrote it.
    (let ((stale (run-path "wallet-sref.txt")))
      (when (file-exists? stale)
        (delete-file stale)))

    ;; ── Spawn wallet + policy ─────────────────────────────────────
    (let* ((pw-file     (data-path "monero/rpc-login.txt"))
           (policy-file (data-path "wallet-policy.scm"))
           (spend-policy (load-spend-policy policy-file log!)))
      (unless (file-exists? pw-file)
        (log! "  ERROR: ~a not found — cannot start wallet~%" pw-file)
        (exit 1))

      (run-fibers
       (lambda ()
         (define designator-key (generate-key-pair))

         (define wallet-vat (spawn-vat #:name "wallet"))

         (define the-wallet
           (with-vat wallet-vat
             (spawn ^monero-wallet
                    (make-wallet-provider
                     #:base-url "http://127.0.0.1:18082"
                     #:rpc-user "playnet"
                     #:rpc-password-file pw-file))))

         (define the-policy
           (with-vat wallet-vat
             (spawn ^wallet-policy the-wallet
                    spend-policy
                    0 0
                    (lambda (evt)
                      (log! "  [wallet-service] audit: ~a~%" evt))
                    (lambda (_) #t))))   ; credential-check (no KERI in wallet process)

         ;; What OCapN hands out: the policy's spend and read surface, its
         ;; values in a form CapTP carries (see policy-wire.scm). Same vat
         ;; as the policy — the facet calls it synchronously.
         (define the-policy-wire
           (with-vat wallet-vat
             (spawn ^wallet-policy-wire the-policy)))

         (log! "  [wallet-service] wallet + policy spawned~%")

         ;; ── OCapN WebSocket netlayer (localhost only) ───────────
         (define ocapn-vat (spawn-vat #:name "wallet-ocapn"))

         (define ws-netlayer
           (with-vat ocapn-vat
             (spawn ^websocket-netlayer
                    #:host "127.0.0.1"
                    #:port ws-port
                    #:encrypted? #f
                    #:designator-key designator-key
                    #:max-peers 4)))

         (define mycapn
           (with-vat ocapn-vat
             (spawn-mycapn ws-netlayer)))

         ;; Register the policy's WIRE FACET (not the raw wallet, not the
         ;; policy with its rewiring methods) — the gateway gets a cap to
         ;; this and nothing else.
         (with-vat ocapn-vat
           (on (<- mycapn 'register the-policy-wire 'websocket)
               (lambda (sref)
                 (let ((uri (ocapn-id->string sref)))
                   ;; The URI is a spend capability: it goes to the 0640
                   ;; file below and nowhere else — the log stays clean of it.
                   ;; Write to file for the gateway to read
                   ;; 0640: the owner is this process, the group is the
                   ;; service group the gateway reads it through. The
                   ;; sturdyref is a spend capability — never world-readable.
                   (let ((sref-path (run-path "wallet-sref.txt")))
                     (call-with-output-file sref-path
                       (lambda (p) (display uri p) (newline p)))
                     (chmod sref-path #o640)
                     (log! "  [wallet-service] sturdyref written to ~a~%" sref-path))))))

         ;; ── In-process REPL (0600 — operator-only) ─────────────
         ;; This is the ONLY way to reach raw wallet methods
         ;; (transfer without policy, sweep-all). The gateway
         ;; process cannot access these.
         (let ((gu (resolve-module '(guile-user))))
           (module-define! gu 'wallet-vat   wallet-vat)
           (module-define! gu 'the-wallet   the-wallet)
           (module-define! gu 'the-policy   the-policy))

         (let ((repl-sock (run-path "wallet-repl.sock")))
           (when (file-exists? repl-sock)
             (delete-file repl-sock))
           ;; The socket is made here, 0600 from its first instant (umask),
           ;; and only then handed to the server thread: this is raw wallet
           ;; access, and a chmod after the thread starts races the bind.
           (let* ((old-umask (umask #o177))
                  (sock (make-unix-domain-server-socket #:path repl-sock)))
             (umask old-umask)
             (chmod repl-sock #o600)
             (call-with-new-thread
              (lambda () (run-server sock))))
           (log! "  [wallet-service] REPL on ~a (0600)~%" repl-sock))

         ;; ── VM suspend watchdog ──────────────────────────────────
         ;; Polls CLOCK_MONOTONIC every second. If the clock jumps
         ;; by >5s (= VM was suspended/resumed), log a CRITICAL
         ;; alert. The snapshot file may contain secrets; the live
         ;; process is now aware that it was suspended.
         (make-suspend-watchdog
          #:interval 1
          #:threshold 5
          #:on-suspend
          (lambda (gap)
            (log! "~%  ╔═══════════════════════════════════════════════╗~%")
            (log! "  ║  CRITICAL: VM SUSPEND DETECTED (~,1fs gap)  ║~%" gap)
            (log! "  ║  Monotonic clock jumped — hypervisor snapshot  ║~%")
            (log! "  ║  may exist. Rotate credentials immediately.   ║~%")
            (log! "  ╚═══════════════════════════════════════════════╝~%")))

         (log! "  [wallet-service] ready on ws://127.0.0.1:~a~%~%" ws-port)
         (log! "  [wallet-service] suspend watchdog active (1s poll, 5s threshold)~%")

         ;; Hold open
         (perform-operation (wait-operation (make-condition))))))))

(main (command-line))
