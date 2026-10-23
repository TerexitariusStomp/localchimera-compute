;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/fleet/test-ocapn-roundtrip.scm — OCapN sturdyref round-trip
;;;
;;; Mirrors how fleet-bridge talks to ^fleet-reconciler in production:
;;;
;;;   server side: spawn an actor in vat-a, register it with
;;;                vat-a's mycapn (websocket netlayer), get a sturdyref,
;;;                write the sref's URI string to a file.
;;;   client side: vat-b has its own websocket netlayer + mycapn,
;;;                reads the sref URI, enlivens, sends async messages.
;;;                Asserts they arrive at vat-a's actor.
;;;
;;; This is the load-bearing integration that fleet-bridge ↔
;;; reconciler relies on. If it works in one process across two vats,
;;; it works across processes (the netlayer is the same).
;;;
;;; Run:
;;;   guile -L module -L tests tests/fleet/test-ocapn-roundtrip.scm

(use-modules (goblins)
             (goblins vat)
             (goblins actor-lib methods)
             (goblins actor-lib on)
             (goblins ocapn ids)
             (goblins ocapn captp)
             (goblins ocapn netlayer websocket)
             (goblins utils crypto)
             (ice-9 format)
             (ice-9 textual-ports)
             (ice-9 threads)
             (fibers)
             (playnet test harness))

;;; ── Pick a free port, retrying on a lost bind race ───────────────────────
;;; `pick-free-port` cannot RESERVE the port it reports — the socket has to
;;; close before the real server binds it, so a concurrent run can hand two
;;; tests the same number. `spawn ^websocket-netlayer` binds synchronously
;;; inside its own constructor, so a lost race raises an ordinary, catchable
;;; system-error right at the spawn call (verified directly: key=
;;; 'system-error, args=(bind ~A (Address already in use) (98))) — this
;;; retries on exactly that, the same principle as spawn-mock-server's fix
;;; to the same underlying race in the HTTP-mock harness.

(define* (spawn-netlayer-retrying vat host key #:key (attempts 6))
  "Picks a free port and spawns ^websocket-netlayer on VAT, retrying on a
   lost bind race. Returns (values netlayer port)."
  (let try ((n 1))
    (let ((port (pick-free-port)))
      (catch 'system-error
        (lambda ()
          (values (with-vat vat
                    (spawn ^websocket-netlayer #:host host #:port port
                           #:encrypted? #f #:designator-key key))
                  port))
        (lambda (k . args)
          (if (< n attempts)
              (try (+ n 1))
              (apply throw k args)))))))

(define sref-path
  (string-append "/tmp/test-ocapn-sref-" (number->string (getpid)) ".txt"))

;;; ── Stub recordable actor ────────────────────────────────────────────────
;;;
;;; A minimal Goblins actor that records every method invocation in a
;;; module-level list so the test can assert the routing landed.
;;; Same shape as ^fleet-reconciler (a few-method actor); we don't need
;;; the full reconciler since this test is about the wire, not the logic.

(define received '())
(define recv-mutex (make-mutex))

(define (record-call! method args)
  (with-mutex recv-mutex
    (set! received (cons (cons method args) received))))

(define (^stub-recon bcom)
  (methods
   [(reconcile)
    (record-call! 'reconcile '())
    'reconcile-ok]
   [(mark-providers-unhealthy names)
    (record-call! 'mark-providers-unhealthy (list names))
    'unhealthy-ok]))

;;; ── Run server + client inside fibers ────────────────────────────────────
;;;
;;; The websocket netlayer needs a fibers scheduler.  Both vats and
;;; their netlayers must run inside (run-fibers ...).

(define done-cond (make-condition-variable))
(define done-mutex (make-mutex))
(define done? #f)

(call-with-new-thread
 (lambda ()
   (run-fibers
    (lambda ()
      ;; ── Vat A: server side ─────────────────────────────────────────
      (define key-a (generate-key-pair))
      (define vat-a (spawn-vat #:name "ocapn-test-server"))
      (define stub
        (with-vat vat-a (spawn ^stub-recon)))
      (define-values (netlayer-a server-port)
        (spawn-netlayer-retrying vat-a "127.0.0.1" key-a))
      (format #t "=== Server listens on 127.0.0.1:~a; sref → ~a ===~%~%"
              server-port sref-path)
      (define mycapn-a
        (with-vat vat-a (spawn-mycapn netlayer-a)))

      ;; Register and write sref.
      (with-vat vat-a
        (on (<- mycapn-a 'register stub 'websocket)
            (lambda (sref)
              (let ((uri (ocapn-id->string sref)))
                (call-with-output-file sref-path
                  (lambda (port) (display uri port) (newline port)))
                (format #t "  [server] sref written: ~a~%" uri)))))

      ;; Give the register a moment to flush the file.
      (sleep 1)

      ;; ── Vat B: client side ─────────────────────────────────────────
      (define key-b (generate-key-pair))
      (define vat-b (spawn-vat #:name "ocapn-test-client"))
      (define-values (netlayer-b client-port)
        (spawn-netlayer-retrying vat-b "127.0.0.1" key-b))
      (define mycapn-b
        (with-vat vat-b (spawn-mycapn netlayer-b)))

      ;; Read sref, enliven.
      (define cap
        (let* ((uri (string-trim-both
                     (call-with-input-file sref-path get-string-all)))
               (sref (string->ocapn-id uri)))
          (with-vat vat-b (<- mycapn-b 'enliven sref))))

      (format #t "  [client] enlivened cap; sending calls...~%")

      ;; Send two messages. They land asynchronously — wait a moment
      ;; before asserting.
      (with-vat vat-b
        (on (<- cap 'reconcile)
            (lambda (r) (format #t "  [client] reconcile → ~a~%" r))))

      (with-vat vat-b
        (on (<- cap 'mark-providers-unhealthy '("vpsbg"))
            (lambda (r) (format #t "  [client] mark-unhealthy → ~a~%" r))))

      ;; Wait for both to land.
      (sleep 2)

      (with-mutex done-mutex
        (set! done? #t)
        (signal-condition-variable done-cond))))))

;; Block the main thread until the fiber thread signals done.
(with-mutex done-mutex
  (let loop ()
    (unless done?
      (wait-condition-variable done-cond done-mutex)
      (loop))))

;;; ── Assertions ───────────────────────────────────────────────────────────

(format #t "~%=== Assertions ===~%")

(define received-snapshot
  (with-mutex recv-mutex (reverse received)))

(format #t "  recorded: ~a~%" received-snapshot)

(check "received exactly two calls" (= 2 (length received-snapshot)))

(check "first call was 'reconcile"
       (eq? 'reconcile (car (car received-snapshot))))

(check "second call was 'mark-providers-unhealthy"
       (eq? 'mark-providers-unhealthy (car (cadr received-snapshot))))

(check "mark-unhealthy carried the right args"
       (equal? '(("vpsbg")) (cdr (cadr received-snapshot))))

;;; ── Cleanup ──────────────────────────────────────────────────────────────

(when (file-exists? sref-path)
  (delete-file sref-path))

(test-summary!)
