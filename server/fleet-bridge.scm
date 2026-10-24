;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; server/fleet-bridge.scm — MQTT → fleet reconciler bridge
;;;
;;; Two responsibilities:
;;;
;;;   1. On infrastructure deficit signals (`localchimera/signals/deficit/#`),
;;;      poke `^fleet-reconciler` to run a reconcile tick (after a random
;;;      0–600 s jitter, in a fresh thread).
;;;
;;;   2. On per-host liveness heartbeats (`localchimera/signals/liveness/#`),
;;;      track last-seen time + provider per host. A background thread
;;;      every 60 s recomputes the set of unhealthy providers — a
;;;      provider is unhealthy iff every host claiming it has gone
;;;      silent — and pushes the set into the reconciler via
;;;      `mark-providers-unhealthy`.
;;;
;;; The bridge talks to the reconciler over OCapN: gateway/monero-boot.scm
;;; mints a sturdyref for the reconciler at startup and writes it to
;;; /var/lib/localchimera/reconciler-sref.txt. We enliven that sref once and
;;; reuse the cap. (Replaces the previous REPL-eval-over-Unix-socket
;;; approach, which was brittle text-protocol parsing.)
;;;
;;; Run as a Shepherd service or manually:
;;;   guile --no-auto-compile -L module -s server/fleet-bridge.scm

(use-modules (localchimera mqtt subscriber)
             (goblins)
             (goblins vat)
             (goblins actor-lib on)
             (goblins ocapn ids)
             (goblins ocapn captp)
             (goblins ocapn netlayer websocket)
             (ice-9 format)
             (ice-9 textual-ports)
             (ice-9 threads)
             (srfi srfi-1)
             (srfi srfi-13)
             (json))

;; Reseed PRNG from /dev/urandom. Without this the jitter sequence is
;; identical across reboots, defeating the timing-correlation defense.
(set! *random-state* (random-state-from-platform))

(define RECONCILER_SREF_PATH
  (or (getenv "RECONCILER_SREF_PATH")
      "/var/lib/localchimera/reconciler-sref.txt"))

(define liveness-stale-seconds 120)
(define liveness-recompute-seconds 60)

;; Random delay (seconds) inserted between a deficit signal arriving and
;; the reconciler being poked. Breaks timing correlation between the
;; planner's signal, the resulting Monero transfer in the mempool, and
;; the SporeStack new-VM event. The MQTT subscriber dispatches the wait
;; to a fresh thread so the main loop doesn't block.
(define reconcile-jitter-max-seconds 600)

;; host-id -> (last-seen-epoch . provider-name)
(define liveness-table (make-hash-table))
(define liveness-mutex (make-mutex))

(define-values (cooldown-ok? record-cooldown!)
  (make-cooldown #:seconds 300))

(define (now-epoch) (car (gettimeofday)))

;;; ── Reconciler cap (lazy-refreshed by sref-file mtime) ─────────────────
;;;
;;; Both sides can restart independently:
;;;   - Gateway restart: monero-boot.scm mints a fresh sturdyref each
;;;     boot and overwrites reconciler-sref.txt → mtime changes → we
;;;     re-enliven on the next call.
;;;   - fleet-bridge restart: this module re-runs from scratch; the
;;;     sref file is the source of truth.
;;;
;;; We cache the cap by file mtime so steady-state calls don't pay any
;;; file-I/O. The first call after a gateway restart pays one stat() +
;;; one read() + one enliven(); after that, cached again.

(define ocapn-vat (spawn-vat #:name "fleet-bridge-ocapn"))

(define mycapn
  (with-vat ocapn-vat
    (let ((netlayer (spawn ^websocket-netlayer
                           #:host "127.0.0.1"
                           #:port 0
                           #:encrypted? #f)))
      (spawn-mycapn netlayer))))

(define reconciler-cap #f)
(define reconciler-cap-mtime #f)

(define (current-reconciler-cap!)
  "Return a live reconciler cap, re-enlivening from disk if the sref
file has changed since last lookup. Returns #f if the file is missing
or unreadable."
  (cond
   ((not (file-exists? RECONCILER_SREF_PATH))
    (set! reconciler-cap #f)
    (set! reconciler-cap-mtime #f)
    #f)
   (else
    (let ((mtime (stat:mtime (stat RECONCILER_SREF_PATH))))
      (when (or (not reconciler-cap)
                (not (eqv? mtime reconciler-cap-mtime)))
        (catch #t
          (lambda ()
            (let* ((uri (string-trim-both
                         (call-with-input-file RECONCILER_SREF_PATH
                           get-string-all)))
                   (sref (string->ocapn-id uri)))
              (set! reconciler-cap
                    (with-vat ocapn-vat (<- mycapn 'enliven sref)))
              (set! reconciler-cap-mtime mtime)
              (format #t "[fleet-bridge] reconciler cap (re-)enlivened~%")))
          (lambda (key . args)
            (format #t "[fleet-bridge] enliven failed: ~a ~a~%" key args)
            (set! reconciler-cap #f)
            (set! reconciler-cap-mtime #f))))
      reconciler-cap))))

(define (call-reconciler! method . args)
  "Async OCapN call to the reconciler. Returns the result via an `on`
callback that just logs — fleet-bridge doesn't need the return value
synchronously. Auto-refreshes a stale cap on each call via mtime check.
If the sref file is missing entirely, log and skip."
  (let ((cap (current-reconciler-cap!)))
    (cond
     ((not cap)
      (format #t "[fleet-bridge] no reconciler cap — skipping ~a~%" method)
      #f)
     (else
      (with-vat ocapn-vat
        (on (apply <- cap method args)
            (lambda (result)
              (format #t "[fleet-bridge] ~a → ~a~%" method result))
            #:catch
            (lambda (err)
              ;; Cap might have just gone stale (gateway restarted between
              ;; current-reconciler-cap! and the actual <-). Drop the
              ;; cached cap; the next call refreshes.
              (set! reconciler-cap #f)
              (set! reconciler-cap-mtime #f)
              (format #t "[fleet-bridge] ~a failed: ~a (cap invalidated)~%"
                      method err))))
      #t))))

;;; ── Deficit signals → reconcile ─────────────────────────────────────────

(define (infra-signal? payload)
  (let ((signal (parse-signal-json payload)))
    (and signal
         (equal? (assoc-ref signal "kind") "deficit")
         (let ((spec-id (assoc-ref signal "spec-id")))
           (and spec-id (string-prefix? "spec-infra-" spec-id))))))

(define (poke-reconciler!)
  (call-reconciler! 'reconcile))

;;; ── Liveness signals → unhealthy-providers tracker ──────────────────────

(define (record-liveness! host provider)
  (with-mutex liveness-mutex
    (hash-set! liveness-table host (cons (now-epoch) provider))))

(define (compute-unhealthy-providers)
  "Walk the liveness table; for each provider seen, return those whose
every host is stale (no fresh heartbeat within liveness-stale-seconds)."
  (with-mutex liveness-mutex
    (let* ((cutoff (- (now-epoch) liveness-stale-seconds))
           (per-prov (make-hash-table)))   ; provider -> (any-fresh? . any-stale?)
      (hash-for-each
       (lambda (host ts+prov)
         (let* ((ts (car ts+prov))
                (prov (cdr ts+prov))
                (cur (hash-ref per-prov prov (cons #f #f)))
                (fresh? (or (car cur) (>= ts cutoff)))
                (stale? (or (cdr cur) (< ts cutoff))))
           (hash-set! per-prov prov (cons fresh? stale?))))
       liveness-table)
      (hash-fold
       (lambda (prov fresh+stale acc)
         (if (and (not (car fresh+stale)) (cdr fresh+stale))
             (cons prov acc)
             acc))
       '()
       per-prov))))

(define (push-unhealthy-providers!)
  (call-reconciler! 'mark-providers-unhealthy
                    (compute-unhealthy-providers)))

(define (start-health-recompute-thread!)
  (call-with-new-thread
   (lambda ()
     (let loop ()
       (sleep liveness-recompute-seconds)
       (catch #t
         (lambda () (push-unhealthy-providers!))
         (lambda (key . args)
           (format #t "[fleet-bridge] recompute failed: ~a ~a~%" key args)))
       (loop)))))

;;; ── MQTT dispatch ───────────────────────────────────────────────────────

(define (schedule-jittered-reconcile!)
  "Sleep a random 0..N seconds in a fresh thread, then poke the
reconciler. Returns immediately so the MQTT subscriber loop keeps
draining messages."
  (call-with-new-thread
   (lambda ()
     (let ((delay (random reconcile-jitter-max-seconds)))
       (format #t "[fleet-bridge] reconcile scheduled in ~as~%" delay)
       (sleep delay)
       (catch #t
         (lambda () (poke-reconciler!))
         (lambda (key . args)
           (format #t "[fleet-bridge] jittered poke failed: ~a ~a~%"
                   key args)))))))

(define (handle-message topic payload)
  (cond
   ;; deficit/...
   ((string-prefix? "localchimera/signals/deficit/" topic)
    ;; Cooldown is recorded at *schedule* time, not at poke time: a burst
    ;; of deficit signals in the next 5 min is suppressed even though the
    ;; jittered poke hasn't fired yet. That's deliberate — multiple
    ;; signals for the same shortfall should produce one reconciler
    ;; tick, not N pending ones.
    (when (and (infra-signal? payload) (cooldown-ok?))
      (record-cooldown!)
      (format #t "[fleet-bridge] deficit signal — scheduling reconcile~%")
      (schedule-jittered-reconcile!)))
   ;; liveness/<host-id>
   ((string-prefix? "localchimera/signals/liveness/" topic)
    (let* ((host (substring topic (string-length "localchimera/signals/liveness/")))
           (parsed (parse-signal-json payload))
           (provider (and parsed (assoc-ref parsed "provider"))))
      (when (and host provider)
        (record-liveness! host provider))))
   (else #f)))

(define MQTT_PASSWORD_FILE
  (or (getenv "MQTT_PASSWORD_FILE")
      "/var/lib/localchimera/mosquitto/pw-dev-bridge.txt"))

(start-health-recompute-thread!)

(mqtt-subscribe
 #:topic "localchimera/signals/#"
 #:log-prefix "[fleet-bridge]"
 #:username "dev-bridge"
 #:password-file MQTT_PASSWORD_FILE
 #:handler handle-message)
