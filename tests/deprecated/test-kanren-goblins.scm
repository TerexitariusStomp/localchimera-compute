;;; test-kanren-goblins.scm — vat-spanning interleaved streams
;;;
;;; Four scenarios:
;;;   1. Single-stream wrap — sanity check that the actor protocol
;;;      preserves pull order.
;;;   2. Cross-vat interleaving of two infinite streams — both vats
;;;      contribute, neither is starved.
;;;   3. Equivalence on finite streams — the answer set matches what a
;;;      local union would produce.
;;;   4. Exhausted + infinite — an empty stream drops from the queue
;;;      and the other keeps producing, no deadlock.

(setvbuf (current-output-port) 'line)

(use-modules (playnet test harness)
             (playnet deprecated kanren-goblins)
             (goblins) (goblins vat)
             (fibers) (fibers conditions)
             (ice-9 atomic)
             (ice-9 format)
             (srfi srfi-1))


;;; ── await-vow ──────────────────────────────────────────────────────────────
;;; Drive a vow to completion from outside a vat. Same pattern as
;;; tests/org/test-async-federation.scm.

(define (await-vow vat vow-thunk)
  (let ((box (make-atomic-box #f))
        (err (make-atomic-box #f))
        (done (make-condition)))
    (with-vat vat
      (catch #t
        (lambda ()
          (on (vow-thunk)
              (lambda (v)
                (atomic-box-set! box v)
                (signal-condition! done))
              #:catch
              (lambda (e)
                (atomic-box-set! err e)
                (signal-condition! done))))
        (lambda args
          (atomic-box-set! err args)
          (signal-condition! done))))
    (wait done)
    (let ((e (atomic-box-ref err)))
      (cond
       ((pair? e) (apply throw e))
       (e (raise-exception e))
       (else (atomic-box-ref box))))))


;;; ── Stream helpers ──────────────────────────────────────────────────────────
;;; A stream is one of: '(), (cons head tail), or (lambda () ...).

(define (nats-from n)
  (lambda () (cons n (nats-from (+ n 1)))))

(define (step-from n d)
  (lambda () (cons n (step-from (+ n d) d))))

(define (finite-stream lst)
  (if (null? lst) '()
      (lambda () (cons (car lst) (finite-stream (cdr lst))))))


;;; ════════════════════════════════════════════════════════════════════════════

(run-fibers
 (lambda ()

   ;;; ── 1. Single-stream wrap ─────────────────────────────────────────────
   (display "\n── 1. Single-stream wrap ──\n")

   (let* ((vat (spawn-vat #:name "single"))
          (sref (with-vat vat (stream->actor (nats-from 1)))))
     (let ((result (await-vow vat
                              (lambda () (run-dist-interleave 5 (list sref))))))
       (check "single stream pulls 5 nats" result '(1 2 3 4 5))))


   ;;; ── 2. Cross-vat interleaving of two infinite streams ─────────────────
   (display "\n── 2. Cross-vat interleaving ──\n")

   (let* ((vat-A (spawn-vat #:name "A"))
          (vat-B (spawn-vat #:name "B"))
          (vat-C (spawn-vat #:name "C"))
          (sA (with-vat vat-A (stream->actor (step-from 0 2))))   ; 0,2,4,...
          (sB (with-vat vat-B (stream->actor (step-from 1 2)))))  ; 1,3,5,...
     (let* ((result (await-vow vat-C
                               (lambda ()
                                 (run-dist-interleave 10 (list sA sB)))))
            (evens (filter even? result))
            (odds  (filter odd?  result)))
       (check "pulled 10 answers" (length result) 10)
       (check "evens contributed" (pair? evens))
       (check "odds contributed" (pair? odds))
       (check "neither starved — evens ≥ 3" (>= (length evens) 3))
       (check "neither starved — odds ≥ 3"  (>= (length odds) 3))))


   ;;; ── 3. Equivalence to local union on finite streams ───────────────────
   (display "\n── 3. Finite-stream equivalence ──\n")

   (let* ((vat-A (spawn-vat #:name "eqA"))
          (vat-B (spawn-vat #:name "eqB"))
          (vat-C (spawn-vat #:name "eqC"))
          (sA (with-vat vat-A (stream->actor (finite-stream '(1 3 5)))))
          (sB (with-vat vat-B (stream->actor (finite-stream '(2 4 6))))))
     (let ((result (await-vow vat-C
                              (lambda ()
                                (run-dist-interleave 99 (list sA sB))))))
       (check "finite interleave yields all 6" (length result) 6)
       (check "answer set equals local union" (sort result <) '(1 2 3 4 5 6))))


   ;;; ── 4. Empty + infinite ───────────────────────────────────────────────
   ;;; Exhausted stream must drop out so the infinite one keeps producing.
   (display "\n── 4. Empty + infinite ──\n")

   (let* ((vat-A (spawn-vat #:name "emptyA"))
          (vat-B (spawn-vat #:name "infB"))
          (vat-C (spawn-vat #:name "consumerC"))
          (sA (with-vat vat-A (stream->actor '())))
          (sB (with-vat vat-B (stream->actor (nats-from 100)))))
     (let ((result (await-vow vat-C
                              (lambda ()
                                (run-dist-interleave 5 (list sA sB))))))
       (check "infinite produces past exhausted peer"
              result '(100 101 102 103 104))))


   ;; test-summary! calls `exit`, which inside fibers raises 'quit in a
   ;; fiber — the main process keeps running because vat event-loop fibers
   ;; are still alive. primitive-exit terminates immediately, bypassing
   ;; the exception machinery. Same pattern other fibers-based tests
   ;; need; keeping it local here rather than touching the shared harness.
   (format #t "~%=== Results: ~a passed, ~a failed ===~%" pass-count fail-count)
   (primitive-exit (if (zero? fail-count) 0 1))))

