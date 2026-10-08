;;; test-federation-b.scm — Layer 1 B: fragment-stream federation
;;;
;;; Exercises:
;;;   - ^fragment-leaf emits a ^stream-actor of tiny fragments
;;;   - federate-fragments fans out, pulls with fair interleaving,
;;;     stops when demand is met
;;;   - chunk-size controls fragment granularity
;;;   - coordinator aggregates per-scope allocations into an A-compatible
;;;     federation-result shape
;;;   - over-demand leaves residual
;;;   - resilient variant tolerates broken stream-setup and broken next
;;;
;;; Run:
;;;   guile --no-auto-compile -q -L module tests/playnet/test-federation-b.scm

(setvbuf (current-output-port) 'line)

(use-modules (playnet test harness)
             (playnet deprecated federation-b)
             (playnet deprecated kanren-goblins)
             (goblins) (goblins vat)
             (goblins actor-lib methods)
             (fibers) (fibers conditions)
             (ice-9 atomic)
             (srfi srfi-1))


(define (await-vow vat vow-thunk)
  (let ((box (make-atomic-box #f))
        (err (make-atomic-box #f))
        (done (make-condition)))
    (with-vat vat
      (catch #t
        (lambda ()
          (on (vow-thunk)
              (lambda (v) (atomic-box-set! box v) (signal-condition! done))
              #:catch
              (lambda (e) (atomic-box-set! err e) (signal-condition! done))))
        (lambda args
          (atomic-box-set! err args)
          (signal-condition! done))))
    (wait done)
    (let ((e (atomic-box-ref err)))
      (cond
        ((pair? e) (apply throw e))
        (e (raise-exception e))
        (else (atomic-box-ref box))))))


(run-fibers
 (lambda ()

   ;; ── 1. ^fragment-leaf emits a stream of unit fragments ────────────
   (display "\n── ^fragment-leaf: unit fragments ──\n")

   (let* ((vA (spawn-vat #:name "A"))
          (leaf (with-vat vA (spawn-fragment-leaf 'commune-A
                                                   '(("spec:bread" . 3))))))
     (let* ((stream (with-vat vA ($ leaf 'stream-for '("spec:bread" 10))))
            (c1 (with-vat vA ($ stream 'next))))
       (check "first pull returns a pair"
              (pair? c1))
       (check "first fragment qty is 1"
              (assq-ref (car c1) 'qty) 1)
       (check "first fragment scope is commune-A"
              (assq-ref (car c1) 'scope) 'commune-A)
       (let* ((c2 (with-vat vA ($ (cdr c1) 'next)))
              (c3 (with-vat vA ($ (cdr c2) 'next)))
              (c4 (with-vat vA ($ (cdr c3) 'next))))
         (check "second pull returns a pair"  (pair? c2))
         (check "third pull returns a pair"   (pair? c3))
         (check "fourth pull signals exhaustion (#f)"
                (not c4)))))


   ;; ── 2. chunk-size > 1 batches units ───────────────────────────────
   (display "\n── chunk-size batches units ──\n")

   (let* ((vA (spawn-vat))
          (leaf (with-vat vA
                  (spawn-fragment-leaf 'commune-A
                                        '(("spec:bread" . 7))
                                        #:chunk-size 3))))
     (let* ((stream (with-vat vA ($ leaf 'stream-for '("spec:bread" 10))))
            (c1 (with-vat vA ($ stream 'next)))
            (c2 (with-vat vA ($ (cdr c1) 'next)))
            (c3 (with-vat vA ($ (cdr c2) 'next)))
            (c4 (with-vat vA ($ (cdr c3) 'next))))
       (check "first chunk has qty 3"
              (assq-ref (car c1) 'qty) 3)
       (check "second chunk has qty 3"
              (assq-ref (car c2) 'qty) 3)
       (check "third chunk is the remaining 1"
              (assq-ref (car c3) 'qty) 1)
       (check "fourth pull exhausts"
              (not c4))))


   ;; ── 3. federate-fragments stops at demand-met ─────────────────────
   (display "\n── federate-fragments: demand met ──\n")

   (let* ((vA (spawn-vat #:name "vA"))
          (vB (spawn-vat #:name "vB"))
          (vC (spawn-vat #:name "vC"))
          (vCoord (spawn-vat #:name "coord"))
          (leaf-A (with-vat vA (spawn-fragment-leaf 'commune-A
                                                     '(("spec:bread" . 6)))))
          (leaf-B (with-vat vB (spawn-fragment-leaf 'commune-B
                                                     '(("spec:bread" . 4)))))
          (leaf-C (with-vat vC (spawn-fragment-leaf 'commune-C
                                                     '(("spec:bread" . 0)))))
          (result (await-vow vCoord
                             (lambda ()
                               (federate-fragments
                                 (list leaf-A leaf-B leaf-C)
                                 '("spec:bread" 10))))))
     (check "federation scope is federation-b"
            (assq-ref result 'scope) 'federation-b)

     (check "total allocation = 10"
            (fold + 0 (map (lambda (a) (assq-ref a 'alloc))
                           (assq-ref result 'allocations)))
            10)

     (check "residual = 0 when demand fully met"
            (assq-ref result 'residual) 0)

     (check "coherence = 1 when demand fully met"
            (assq-ref result 'coherence) 1)

     (check "fragments list preserves pull order, sums to 10"
            (fold + 0 (map (lambda (f) (assq-ref f 'qty))
                           (assq-ref result 'fragments)))
            10)

     ;; Fair interleaving: commune-A (6 inv) and commune-B (4 inv) both
     ;; contribute non-zero. commune-C (0 inv) drops from queue immediately.
     (let ((sids (delete-duplicates
                   (map (lambda (f) (assq-ref f 'scope))
                        (assq-ref result 'fragments)))))
       (check "both A and B contributed fragments (interleaving worked)"
              (and (memq 'commune-A sids) (memq 'commune-B sids) #t))))


   ;; ── 4. Over-demand: residual surfaces ─────────────────────────────
   (display "\n── over-demand leaves residual ──\n")

   (let* ((vA (spawn-vat)) (vB (spawn-vat)) (vCoord (spawn-vat))
          (leaf-A (with-vat vA (spawn-fragment-leaf 'a
                                                     '(("spec:bread" . 3)))))
          (leaf-B (with-vat vB (spawn-fragment-leaf 'b
                                                     '(("spec:bread" . 2)))))
          (result (await-vow vCoord
                             (lambda ()
                               (federate-fragments (list leaf-A leaf-B)
                                                   '("spec:bread" 20))))))
     (check "residual = 15 when inventory covers 5 of 20"
            (assq-ref result 'residual) 15)

     (check "federation deficit records the gap"
            (pair? (assq-ref result 'deficits)))

     (check "total alloc = 5 (all available)"
            (fold + 0 (map (lambda (a) (assq-ref a 'alloc))
                           (assq-ref result 'allocations)))
            5))


   ;; ── 5. Resilient: broken stream-setup ─────────────────────────────
   (display "\n── federate-fragments-resilient: broken stream-setup ──\n")

   (let* ((vA (spawn-vat)) (vDead (spawn-vat))
          (vB (spawn-vat)) (vCoord (spawn-vat))
          (leaf-A (with-vat vA (spawn-fragment-leaf 'a
                                                     '(("spec:bread" . 3)))))
          (leaf-dead
            (with-vat vDead
              (spawn (lambda (bcom)
                       (methods
                         ((stream-for _)
                          (error "boom — stream-setup broken"))
                         ((describe) 'dead))))))
          (leaf-B (with-vat vB (spawn-fragment-leaf 'b
                                                     '(("spec:bread" . 2)))))
          (result (await-vow vCoord
                             (lambda ()
                               (federate-fragments-resilient
                                 (list leaf-A leaf-dead leaf-B)
                                 '("spec:bread" 5))))))
     (check "resilient federation still resolves with broken setup"
            (eq? (assq-ref result 'scope) 'federation-b))

     (check "healthy leaves sum to 5"
            (fold + 0 (map (lambda (a) (assq-ref a 'alloc))
                           (assq-ref result 'allocations)))
            5)

     (check "no dead-peer scope in allocations"
            (not (find (lambda (a) (eq? 'dead (assq-ref a 'scope)))
                       (assq-ref result 'allocations)))))


   ;; ── 6. Resilient: stream breaks mid-pull ──────────────────────────
   (display "\n── federate-fragments-resilient: broken next ──\n")

   (let* ((vA (spawn-vat)) (vBrk (spawn-vat))
          (vB (spawn-vat)) (vCoord (spawn-vat))
          (leaf-A (with-vat vA (spawn-fragment-leaf 'a
                                                     '(("spec:bread" . 3)))))
          ;; A stream actor whose next raises on the 2nd call.
          (flaky-stream
            (with-vat vBrk
              (spawn (lambda (bcom)
                       (let ((n 0))
                         (methods
                           ((next)
                            (set! n (+ n 1))
                            (if (= n 1)
                                (cons `((scope . flaky) (spec . "spec:bread")
                                        (qty . 1) (cost . 0))
                                      (with-vat vBrk
                                        (spawn (lambda (b)
                                                 (methods
                                                   ((next) (error "boom"))))
                                                )))
                                (error "boom after first"))))))))
            )
          (flaky-leaf
            (with-vat vBrk
              (spawn (lambda (bcom)
                       (methods
                         ((stream-for _) flaky-stream))))))
          (leaf-B (with-vat vB (spawn-fragment-leaf 'b
                                                     '(("spec:bread" . 4)))))
          (result (await-vow vCoord
                             (lambda ()
                               (federate-fragments-resilient
                                 (list leaf-A flaky-leaf leaf-B)
                                 '("spec:bread" 8))))))
     (check "resilient federation tolerates flaky mid-stream break"
            (eq? (assq-ref result 'scope) 'federation-b))

     ;; flaky contributes 1, A has 3, B has 4 → total 8, demand met
     (check "total allocation = 8 despite flaky leaf"
            (fold + 0 (map (lambda (a) (assq-ref a 'alloc))
                           (assq-ref result 'allocations)))
            8)

     (check "flaky scope contributed exactly its 1 successful fragment"
            (let ((flaky-entry
                    (find (lambda (a) (eq? 'flaky (assq-ref a 'scope)))
                          (assq-ref result 'allocations))))
              (and flaky-entry (= 1 (assq-ref flaky-entry 'alloc))))))


   ;; Bypass run-fibers shutdown (dead-peer fibers emit stderr chatter).
   (format #t "~%=== Results: ~a passed, ~a failed ===~%" pass-count fail-count)
   (primitive-exit (if (zero? fail-count) 0 1))))
