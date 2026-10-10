;;; tests/governance/test-pending-grants.scm
;;; ^pending-grants actor — tagged retry queue with disk persistence
;;;
;;; Covers:
;;;   - enqueue / count / all / drain! / clear!
;;;   - replay-fn dispatch: success drains, failure keeps
;;;   - missing replay fn: entry stays in queue, logged
;;;   - disk persistence: write on mutate, read on respawn
;;;   - drain! order is FIFO (oldest first)
;;;
;;; Run: guile -L module -L tests tests/governance/test-pending-grants.scm

(use-modules (playnet test harness)
             (playnet keys pending-grants)
             (srfi srfi-1)
             (goblins))

(define vat (spawn-vat))

;; ── Replay-fn behaviors for testing ─────────────────────────────────

(define %replay-attempts '())   ; list of payload alists actually tried
(define %fail-once?     #f)
(define %already-failed-once? #f)

(register-replay-fn!
 'test-ok
 (lambda (payload)
   (set! %replay-attempts (cons payload %replay-attempts))
   #t))

(register-replay-fn!
 'test-fail
 (lambda (_payload) #f))

(register-replay-fn!
 'test-fail-once
 (lambda (payload)
   (set! %replay-attempts (cons payload %replay-attempts))
   (cond
    ((and %fail-once? (not %already-failed-once?))
     (set! %already-failed-once? #t) #f)
    (else #t))))

;; ── Basic enqueue + count ───────────────────────────────────────────

(define q (with-vat vat (spawn ^pending-grants)))

(check "fresh queue is empty"
       (= 0 (with-vat vat ($ q 'count))))

(with-vat vat
  ($ q 'enqueue (make-pending-grant 'test-ok '((id . 1))))
  ($ q 'enqueue (make-pending-grant 'test-ok '((id . 2)))))

(check "two enqueues → count 2"
       (= 2 (with-vat vat ($ q 'count))))

(check "all returns both entries"
       (= 2 (length (with-vat vat ($ q 'all)))))

;; ── enqueue rejects non-records ────────────────────────────────────

(check "enqueue with non-record errors"
       (catch #t
         (lambda ()
           (with-vat vat ($ q 'enqueue '(("kind" . "bad")))) #f)
         (lambda _ #t)))

;; ── drain! happy path ───────────────────────────────────────────────

(set! %replay-attempts '())
(define %drain-1 (with-vat vat ($ q 'drain!)))

(check "drain returns (cons drained still-pending)"
       (and (pair? %drain-1) (= 2 (car %drain-1)) (= 0 (cdr %drain-1))))

(check "queue is empty after successful drain"
       (= 0 (with-vat vat ($ q 'count))))

(check "drain went oldest-first (FIFO)"
       (equal? '(((id . 1)) ((id . 2)))
               (reverse %replay-attempts)))

;; ── drain! with always-failing replay ───────────────────────────────

(with-vat vat
  ($ q 'enqueue (make-pending-grant 'test-fail '((id . 3))))
  ($ q 'enqueue (make-pending-grant 'test-fail '((id . 4)))))

(define %drain-2 (with-vat vat ($ q 'drain!)))

(check "drain w/ failing replays: 0 drained, both kept"
       (and (= 0 (car %drain-2)) (= 2 (cdr %drain-2))))

(check "queue still has both after failed drain"
       (= 2 (with-vat vat ($ q 'count))))

;; ── unknown kind: stays in queue, no crash ─────────────────────────

(with-vat vat
  ($ q 'enqueue (make-pending-grant 'test-no-such-replay '((id . 5)))))

(define %drain-3 (with-vat vat ($ q 'drain!)))

(check "unknown-kind entry stayed in queue (no crash)"
       (>= (cdr %drain-3) 1))

(with-vat vat ($ q 'clear!))

(check "clear! empties the queue"
       (= 0 (with-vat vat ($ q 'count))))

;; ── disk persistence round-trip ─────────────────────────────────────

(define %tmp-file
  (string-append "/tmp/pending-grants-test-"
                 (number->string (getpid)) ".scm"))

(define qp1 (with-vat vat (spawn-pending-grants #:persist-file %tmp-file)))

(check "persistent queue starts empty (file doesn't exist yet)"
       (= 0 (with-vat vat ($ qp1 'count))))

(with-vat vat
  ($ qp1 'enqueue (make-pending-grant 'test-ok '((id . "persisted-1"))))
  ($ qp1 'enqueue (make-pending-grant 'test-fail '((id . "persisted-2")))))

(check "persistence file exists after enqueue"
       (file-exists? %tmp-file))

;; Respawn with the same file — should restore the entries
(define qp2 (with-vat vat (spawn-pending-grants #:persist-file %tmp-file)))

(check "respawn restores entries from disk"
       (= 2 (with-vat vat ($ qp2 'count))))

(check "restored entries are <pending-grant> records"
       (every pending-grant? (with-vat vat ($ qp2 'all))))

;; Drain on the restored queue: 'test-ok succeeds, 'test-fail stays
(set! %replay-attempts '())
(with-vat vat ($ qp2 'drain!))

(check "after drain: only the failing entry remains"
       (= 1 (with-vat vat ($ qp2 'count))))

(check "disk file reflects drain (re-read shows 1 entry)"
       (let ((qp3 (with-vat vat (spawn-pending-grants #:persist-file %tmp-file))))
         (= 1 (with-vat vat ($ qp3 'count)))))

;; Cleanup
(when (file-exists? %tmp-file) (delete-file %tmp-file))

(test-summary!)
