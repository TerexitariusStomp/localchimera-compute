;;; test-vat-federation.scm — vat-spanning federation substrate
;;;
;;; Three scenarios validating Phase 1:
;;;   1. Single leaf, demand fully met
;;;   2. Two leaves in separate vats, demand splits, parallel fan-out
;;;   3. Unsatisfiable demand — no exception, residual surfaces the gap

(setvbuf (current-output-port) 'line)

(use-modules (playnet test harness)
             (playnet deprecated vat-federation)
             (goblins) (goblins vat)
             (fibers) (fibers conditions)
             (ice-9 atomic)
             (ice-9 format)
             (srfi srfi-1))


;;; ── await-vow ──────────────────────────────────────────────────────────────
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


;;; ════════════════════════════════════════════════════════════════════════════

(run-fibers
 (lambda ()

   ;;; ── 1. Single leaf, demand fully met ──────────────────────────────────
   (display "\n── 1. Single leaf, demand fully met ──\n")

   (let* ((vat-A (spawn-vat #:name "A"))
          (vat-C (spawn-vat #:name "consumer"))
          (leaf-A (with-vat vat-A (spawn ^scope-leaf 'commune-A '((apple . 10)))))
          (result (await-vow vat-C
                             (lambda ()
                               (plan-federate (list leaf-A) '(apple 3))))))
     (check "residual is 0" (assq-ref result 'residual) 0)
     (check "coherence is 1" (assq-ref result 'coherence) 1)
     (check "deficits empty" (null? (assq-ref result 'deficits)))
     (check "A contributed 3"
            (assoc-ref (assq-ref (assq-ref result 'plan) 'commune-A) 'apple)
            3))


   ;;; ── 2. Two leaves in separate vats, split demand ──────────────────────
   (display "\n── 2. Two leaves, split demand (parallel fan-out) ──\n")

   (let* ((vat-A (spawn-vat #:name "vat-A"))
          (vat-B (spawn-vat #:name "vat-B"))
          (vat-C (spawn-vat #:name "consumer2"))
          (leaf-A (with-vat vat-A (spawn ^scope-leaf 'commune-A '((apple . 2)))))
          (leaf-B (with-vat vat-B (spawn ^scope-leaf 'commune-B '((apple . 5)))))
          (result (await-vow vat-C
                             (lambda ()
                               (plan-federate (list leaf-A leaf-B) '(apple 4))))))
     (check "residual is 0" (assq-ref result 'residual) 0)
     (check "coherence is 1" (assq-ref result 'coherence) 1)
     ;; Greedy first-fit: A gives 2 (all it has), B gives 2 (of its 5)
     (check "A contributed all 2 of its apples"
            (assoc-ref (assq-ref (assq-ref result 'plan) 'commune-A) 'apple)
            2)
     (check "B contributed the remaining 2"
            (assoc-ref (assq-ref (assq-ref result 'plan) 'commune-B) 'apple)
            2))


   ;;; ── 3. Unsatisfiable demand ──────────────────────────────────────────
   (display "\n── 3. Unsatisfiable demand ──\n")

   (let* ((vat-A (spawn-vat #:name "empty-A"))
          (vat-B (spawn-vat #:name "empty-B"))
          (vat-C (spawn-vat #:name "consumer3"))
          (leaf-A (with-vat vat-A (spawn ^scope-leaf 'a '())))
          (leaf-B (with-vat vat-B (spawn ^scope-leaf 'b '((pear . 3)))))
          (result (await-vow vat-C
                             (lambda ()
                               (plan-federate (list leaf-A leaf-B)
                                              '(apple 7))))))
     (check "residual is 7" (assq-ref result 'residual) 7)
     (check "coherence is 0" (assq-ref result 'coherence) 0)
     (check "deficit records the gap"
            (assq-ref (car (assq-ref result 'deficits)) 'qty)
            7))


   (format #t "~%=== Results: ~a passed, ~a failed ===~%" pass-count fail-count)
   (primitive-exit (if (zero? fail-count) 0 1))))
