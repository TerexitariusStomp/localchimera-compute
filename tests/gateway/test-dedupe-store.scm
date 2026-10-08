;;; test-dedupe-store.scm — opId + gateway dedupe (offline-outbox.md phase 1)
;;;
;;; "Every queued write carries a client-minted opId, and the gateway
;;; records the ids it has already applied per AID, returning the original
;;; result on a replay." This pins that contract directly on ^dedupe-store:
;;; a first call executes and caches; a replay with the same (aid, op-id)
;;; returns the cached result WITHOUT re-executing; a different op-id or a
;;; different aid is NOT deduped; and the dedup survives a simulated
;;; restart (durable-dir + reload), the scenario an interrupted-then-
;;; retried flush actually needs.
;;;
;;; Run: guile -L module -L tests tests/gateway/test-dedupe-store.scm

(use-modules (playnet test harness)
             (playnet gateway dedupe-store)
             (goblins) (goblins vat))

(define vat (spawn-vat))

(display "\n── a replay returns the cached result without re-executing ──\n")

(with-vat vat
  (define store (spawn-dedupe-store))
  (define calls 0)
  (define (apply-once!) (set! calls (+ calls 1)) (list 'applied calls))

  (define r1 ($ store 'check-or-record! "E_alice" "op-1" apply-once!))
  (check "first call executes and returns its own result" r1 '(applied 1))
  (check "the thunk ran exactly once" calls 1)

  (define r2 ($ store 'check-or-record! "E_alice" "op-1" apply-once!))
  (check "a replay returns the SAME cached result" r2 '(applied 1))
  (check "the thunk did not run again" calls 1)

  (check-pred "seen? reports true for a recorded (aid, op-id)"
              ($ store 'seen? "E_alice" "op-1"))
  (check-pred "seen? reports false for an unrecorded op-id"
              (not ($ store 'seen? "E_alice" "op-2"))))

(display "\n── a different op-id, or a different aid, is not deduped ──\n")

(with-vat vat
  (define store (spawn-dedupe-store))
  (define calls 0)
  (define (apply-once!) (set! calls (+ calls 1)) (list 'applied calls))

  ($ store 'check-or-record! "E_alice" "op-1" apply-once!)
  (define r-other-op  ($ store 'check-or-record! "E_alice" "op-2" apply-once!))
  (define r-other-aid ($ store 'check-or-record! "E_bob"   "op-1" apply-once!))
  (check "a different op-id under the same aid runs its own thunk" r-other-op '(applied 2))
  (check "the same op-id under a different aid runs its own thunk" r-other-aid '(applied 3))
  (check "three distinct (aid, op-id) pairs ran three times" calls 3))

(display "\n── an interrupted-then-retried flush stays deduped across a restart ──\n")

(let* ((dir (string-append (or (getenv "TMPDIR") "/tmp")
                           "/dedupe-store-test-" (number->string (current-time)))))
  (with-vat vat
    (define store (spawn-dedupe-store #:durable-dir dir))
    (define applied '())
    (define (apply-write! label) (lambda () (set! applied (cons label applied)) 'ok))

    ;; A flush of three queued ops; the "gateway" restarts after the second.
    ($ store 'check-or-record! "E_alice" "op-1" (apply-write! 'op-1))
    ($ store 'check-or-record! "E_alice" "op-2" (apply-write! 'op-2))
    (check "two writes applied before the simulated restart" (length applied) 2))

  ;; Simulated restart: a FRESH store over the same durable-dir, no shared
  ;; in-memory state with the one above.
  (with-vat vat
    (define store2 (spawn-dedupe-store #:durable-dir dir))
    (define applied '())
    (define (apply-write! label) (lambda () (set! applied (cons label applied)) 'ok))

    ;; The retried flush replays ALL THREE ops from the start (op-1 and
    ;; op-2 are replays; op-3 is genuinely new).
    (define r1 ($ store2 'check-or-record! "E_alice" "op-1" (apply-write! 'op-1)))
    (define r2 ($ store2 'check-or-record! "E_alice" "op-2" (apply-write! 'op-2)))
    (define r3 ($ store2 'check-or-record! "E_alice" "op-3" (apply-write! 'op-3)))

    (check "op-1's replay returns its original cached result, post-restart" r1 'ok)
    (check "op-2's replay returns its original cached result, post-restart" r2 'ok)
    (check "op-3 is genuinely new and actually applies" r3 'ok)
    (check "only the genuinely new op (op-3) re-ran its thunk after the restart"
           applied '(op-3)))

  ;; cleanup
  (system* "rm" "-rf" dir))

(test-summary!)
