;;; test-federation-a.scm — Layer 1 A: ranked-alternatives federation
;;;
;;; Exercises:
;;;   - ^ranked-leaf returns ref-mode federation-results
;;;   - federate-ranked fans out via vows and aggregates
;;;   - greedy first-fit allocation honours inventory per leaf
;;;   - plan-refs survive aggregation; downstream can still reach plan content
;;;   - attenuation via spawn-plan-facet denies full/demand-pairs access
;;;   - resilient variant tolerates broken leaves
;;;
;;; Uses the same fibers + atomic-box await pattern as test-vat-federation.scm.
;;;
;;; Run:
;;;   guile --no-auto-compile -q -L module tests/deprecated/test-federation-a.scm

(setvbuf (current-output-port) 'line)

(use-modules (playnet test harness)
             (playnet deprecated federation-a)
             (playnet deprecated planner)
             (playnet deprecated vat-federation)
             (goblins) (goblins vat)
             (goblins actor-lib methods)
             (fibers) (fibers conditions)
             (ice-9 atomic)
             (srfi srfi-1))


(define (await-vow vat vow-thunk)
  "Block until VOW-THUNK's vow resolves. Returns the value or re-raises
   the break reason. Same shape as test-vat-federation.scm's helper."
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


(run-fibers
 (lambda ()

   ;; ── 1. ^ranked-leaf emits ref-mode results ─────────────────────────
   (display "\n── ^ranked-leaf emits ref-mode results ──\n")

   (let* ((vat-A (spawn-vat #:name "A"))
          (leaf-A (with-vat vat-A
                    (spawn-ranked-leaf 'commune-A '(("spec:bread" . 6)))))
          (results (with-vat vat-A
                     ($ leaf-A 'propose-for-demand '("spec:bread" 10)))))
     (check "leaf returns a single-element ranked list"
            (= 1 (length results)))

     (check "result has plan-ref, not inline plan"
            (let ((r (car results)))
              (and (assq-ref r 'plan-ref) (not (assq-ref r 'plan)))))

     (check "plan-ref is a live actor reachable via $"
            (with-vat vat-A
              (equal? 'commune-A
                      ($ (assq-ref (car results) 'plan-ref) 'scope))))

     (check "residual reflects local shortfall"
            (assq-ref (car results) 'residual) 4)

     (check "coherence = alloc / need"
            (assq-ref (car results) 'coherence) 6/10))


   ;; ── 2. federate-ranked: three leaves, demand fully met ────────────
   (display "\n── federate-ranked: parallel fan-out, demand met ──\n")

   (let* ((vA (spawn-vat #:name "vA"))
          (vB (spawn-vat #:name "vB"))
          (vC (spawn-vat #:name "vC"))
          (vCoord (spawn-vat #:name "coord"))
          (leaf-A (with-vat vA (spawn-ranked-leaf 'commune-A
                                                   '(("spec:bread" . 6)))))
          (leaf-B (with-vat vB (spawn-ranked-leaf 'commune-B
                                                   '(("spec:bread" . 4)))))
          (leaf-C (with-vat vC (spawn-ranked-leaf 'commune-C
                                                   '(("spec:bread" . 0)))))
          (result (await-vow vCoord
                             (lambda ()
                               (federate-ranked
                                 (list leaf-A leaf-B leaf-C)
                                 '("spec:bread" 10))))))
     (check "federation scope is federation-a"
            (assq-ref result 'scope) 'federation-a)

     (check "three allocations recorded"
            (length (assq-ref result 'allocations)) 3)

     (check "commune-A gives 6 (its full inventory)"
            (assq-ref (find (lambda (a) (eq? 'commune-A (assq-ref a 'scope)))
                            (assq-ref result 'allocations))
                      'alloc)
            6)

     (check "commune-B gives remaining 4"
            (assq-ref (find (lambda (a) (eq? 'commune-B (assq-ref a 'scope)))
                            (assq-ref result 'allocations))
                      'alloc)
            4)

     (check "commune-C gives 0 (demand already met)"
            (assq-ref (find (lambda (a) (eq? 'commune-C (assq-ref a 'scope)))
                            (assq-ref result 'allocations))
                      'alloc)
            0)

     (check "total residual is 0"
            (assq-ref result 'residual) 0)

     (check "federation coherence = 1 when demand fully met"
            (assq-ref result 'coherence) 1)

     ;; Plan-refs preserved through aggregation. The refs live in their
     ;; originating leaf vats; cross-vat access uses <- (vow), not $.
     (let* ((alloc-A (find (lambda (a) (eq? 'commune-A (assq-ref a 'scope)))
                           (assq-ref result 'allocations)))
            (pr (assq-ref alloc-A 'plan-ref))
            (scope-from-ref
              (await-vow vCoord (lambda () (<- pr 'scope)))))
       (check "commune-A plan-ref still answers 'scope' via <- across vats"
              scope-from-ref 'commune-A)))


   ;; ── 3. Attenuated plan-refs deny full plan access ─────────────────
   (display "\n── attenuation: summary-only facets ──\n")

   (let* ((v (spawn-vat #:name "attn"))
          (leaf-safe (with-vat v
                       (spawn-ranked-leaf 'commune-safe
                                          '(("spec:bread" . 3))
                                          #:attenuate? #t)))
          (results (with-vat v
                     ($ leaf-safe 'propose-for-demand '("spec:bread" 5)))))
     (check "attenuated plan-ref answers summary method 'scope'"
            (with-vat v
              (equal? 'commune-safe
                      ($ (assq-ref (car results) 'plan-ref) 'scope))))

     (check "attenuated plan-ref denies 'full' (raises)"
            (with-vat v
              (catch #t
                (lambda ()
                  ($ (assq-ref (car results) 'plan-ref) 'full)
                  #f)
                (lambda _args #t)))))


   ;; ── 4. Over-demand: residual surfaced at federation level ─────────
   (display "\n── over-demand leaves residual ──\n")

   (let* ((vA (spawn-vat)) (vB (spawn-vat)) (vCoord (spawn-vat))
          (leaf-A (with-vat vA (spawn-ranked-leaf 'commune-A
                                                   '(("spec:bread" . 6)))))
          (leaf-B (with-vat vB (spawn-ranked-leaf 'commune-B
                                                   '(("spec:bread" . 4)))))
          (result (await-vow vCoord
                             (lambda ()
                               (federate-ranked (list leaf-A leaf-B)
                                                '("spec:bread" 50))))))
     (check "residual = 40 when inventory covers only 10 of 50"
            (assq-ref result 'residual) 40)

     (check "federation deficit records the gap"
            (pair? (assq-ref result 'deficits))))


   ;; ── 5. Resilient variant tolerates a broken leaf ──────────────────
   (display "\n── federate-ranked-resilient ──\n")

   (let* ((vA (spawn-vat)) (vDead (spawn-vat))
          (vB (spawn-vat)) (vCoord (spawn-vat))
          (leaf-A (with-vat vA (spawn-ranked-leaf 'commune-A
                                                   '(("spec:bread" . 6)))))
          (leaf-dead (with-vat vDead
                       (spawn (lambda (bcom)
                                (methods
                                  ((propose-for-demand _)
                                   (error "boom — broken leaf"))
                                  ((describe) 'dead))))))
          (leaf-B (with-vat vB (spawn-ranked-leaf 'commune-B
                                                   '(("spec:bread" . 4)))))
          (result (await-vow vCoord
                             (lambda ()
                               (federate-ranked-resilient
                                 (list leaf-A leaf-dead leaf-B)
                                 '("spec:bread" 10))))))
     (check "resilient federation still resolves with broken leaf"
            (eq? 'federation-a (assq-ref result 'scope)))

     ;; Healthy leaves should have contributed 10 (6 + 4) between them.
     (let* ((allocs (assq-ref result 'allocations))
            (healthy-alloc
              (fold + 0
                    (map (lambda (a)
                           (let ((s (assq-ref a 'scope)))
                             (if (memq s '(commune-A commune-B))
                                 (assq-ref a 'alloc) 0)))
                         allocs))))
       (check "healthy leaves sum to 10 (full demand)"
              healthy-alloc 10)))


   ;; Bypass run-fibers shutdown (and any uncaught exceptions in dead-
   ;; peer fibers from the resilient-variant section) with primitive-exit,
   ;; same pattern as test-vat-federation.scm.
   (format #t "~%=== Results: ~a passed, ~a failed ===~%" pass-count fail-count)
   (primitive-exit (if (zero? fail-count) 0 1))))
