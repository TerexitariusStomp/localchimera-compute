;;; test-elegance-wins.scm — facet attenuation, promise pipelining
;;;
;;; Exercises the Goblins-native elegance helpers added on top of the
;;; coinductive boundary pattern:
;;;   1. spawn-plan-facet        — attenuated plan-ref (method whitelist)
;;;   2. spawn-federation-result-facet — same for federation-results
;;;   3. Promise pipelining      — chained <- calls across vat boundary
;;;                                without intermediate await
;;;
;;; Resilient federation (vow-allsettled / federate-demand-resilient)
;;; is exercised in test-resilient-federation.scm.

(setvbuf (current-output-port) 'line)

(use-modules (playnet test harness)
             (playnet deprecated planner)
             (goblins) (goblins vat)
             (fibers) (fibers conditions)
             (ice-9 atomic))

(define vat (spawn-vat))


(define (await-vow-local v)
  "Drive a vow to completion from within the same vat.
   (Local synchronous resolution; the vow is typically already fulfilled.)"
  (let ((box (make-atomic-box #f))
        (err (make-atomic-box #f)))
    (on v
        (lambda (x) (atomic-box-set! box (cons 'ok x)))
        #:catch (lambda (e) (atomic-box-set! err (cons 'err e))))
    ;; in practice local vows often resolve in the same turn; in
    ;; this simple test we just read the box.
    (or (atomic-box-ref box) (atomic-box-ref err))))


;;; ── Fixtures ──────────────────────────────────────────────────────────────

(define sample-plan
  '((((spec-id . "apple") (quantity . 5))
     (satisfied "apple" 5 (("res-1" 5))))
    (((spec-id . "bread") (quantity . 4))
     (unmet "bread" 4))))


;;; ════════════════════════════════════════════════════════════════════════════

(with-vat vat

  (display "\n── 1. Plan-actor facet: summary preset ──\n")
  (let* ((raw ($ (spawn ^plan-actor sample-plan 'commune-alpha #f)
                 'scope))
         (raw-ref (spawn ^plan-actor sample-plan 'commune-alpha #f))
         (summary-facet (spawn-plan-facet raw-ref)))
    (check "facet forwards scope"
           ($ summary-facet 'scope) 'commune-alpha)
    (check "facet forwards coherence"
           ($ summary-facet 'coherence) 5/9)
    (check "facet forwards deficits"
           (length ($ summary-facet 'deficits)) 1)
    (check "facet forwards residual"
           ($ summary-facet 'residual) 4)
    (check "facet forwards retraction-candidates"
           (length ($ summary-facet 'retraction-candidates)) 1)
    (check-error "facet denies 'full"
                 (lambda () ($ summary-facet 'full)))
    (check-error "facet denies 'subplan-of"
                 (lambda ()
                   (let ((term (cadr (car sample-plan))))
                     ($ summary-facet 'subplan-of term))))
    (check-error "facet denies 'demand-pairs"
                 (lambda () ($ summary-facet 'demand-pairs))))


  (display "\n── 2. Plan-actor facet: readable preset ──\n")
  (let* ((raw-ref (spawn ^plan-actor sample-plan 'commune-alpha #f))
         (readable (spawn-plan-facet raw-ref *plan-methods-readable*)))
    (check "readable facet exposes 'full"
           ($ readable 'full) sample-plan)
    (check "readable facet exposes 'demand-pairs"
           (length ($ readable 'demand-pairs)) 2))


  (display "\n── 3. Plan-actor facet: custom whitelist ──\n")
  ;; Only coherence — nothing else. Models "capability to learn the
  ;; goodness-metric but not anything else about the plan."
  (let* ((raw-ref (spawn ^plan-actor sample-plan 'commune-beta #f))
         (coh-only (spawn-plan-facet raw-ref '(coherence))))
    (check "custom facet exposes coherence"
           ($ coh-only 'coherence) 5/9)
    (check-error "custom facet denies scope"
                 (lambda () ($ coh-only 'scope)))
    (check-error "custom facet denies deficits"
                 (lambda () ($ coh-only 'deficits))))


  (display "\n── 4. Federation-result facet: summary preset ──\n")
  (let* ((result-ref (spawn-federation-result
                       #:scope 'commune-gamma
                       #:coherence 1
                       #:deficits '()
                       #:surpluses '()
                       #:plan sample-plan
                       #:residual 0))
         (f (spawn-federation-result-facet result-ref)))
    (check "fr-facet exposes scope"
           ($ f 'scope) 'commune-gamma)
    (check "fr-facet exposes coherence"
           ($ f 'coherence) 1)
    (check "fr-facet exposes residual"
           ($ f 'residual) 0)
    (check-error "fr-facet denies 'plan"
                 (lambda () ($ f 'plan)))
    (check-error "fr-facet denies 'as-alist"
                 (lambda () ($ f 'as-alist))))


  (display "\n── 5. Federation-result facet: readable preset ──\n")
  (let* ((result-ref (spawn-federation-result
                       #:scope 'commune-delta
                       #:coherence 1/2
                       #:deficits '()
                       #:surpluses '()
                       #:plan sample-plan
                       #:residual 2))
         (f (spawn-federation-result-facet
              result-ref *federation-result-methods-readable*)))
    (check "readable fr-facet exposes plan"
           ($ f 'plan) sample-plan)
    (check "readable fr-facet exposes as-alist"
           (assq-ref ($ f 'as-alist) 'scope) 'commune-delta))


  (display "\n── 6. Layered attenuation: facet wrapping a facet ──\n")
  ;; A federation-result whose 'plan field is ITSELF a plan-facet.
  ;; Consumer of the outer facet gets scope/coherence/etc AND a
  ;; plan-ref that can only tell them coherence (nothing else).
  (let* ((raw-plan-ref (spawn ^plan-actor sample-plan 'layered #f))
         (attenuated-plan (spawn-plan-facet raw-plan-ref '(coherence)))
         (result-ref (spawn-federation-result
                       #:scope 'layered
                       #:coherence 5/9
                       #:plan attenuated-plan
                       #:deficits '()
                       #:surpluses '()
                       #:residual 4))
         (outer (spawn-federation-result-facet
                  result-ref *federation-result-methods-readable*)))
    (let ((inner ($ outer 'plan)))
      (check "layered: inner plan ref is live"
             (live-refr? inner))
      (check "layered: inner exposes coherence"
             ($ inner 'coherence) 5/9)
      (check-error "layered: inner denies 'scope"
                   (lambda () ($ inner 'scope))))))


;;; ── 7. Promise pipelining validation ──────────────────────────────────────
;;;
;;; Chained `<-` calls — (<- (<- ref 'a) 'b) — should return a working
;;; vow for b that resolves with the correct value. The underlying
;;; optimization (Miller/E promise pipelining) bundles messages into
;;; one round-trip; we don't have a way to directly observe the packet
;;; count in this test, but we can confirm the CHAIN is correctly
;;; composable — which is the API property the optimization requires.

(display "\n── 7. Promise pipelining (chained <-) ──\n")

(define vat-a (spawn-vat #:name "pipeline-a"))
(define vat-b (spawn-vat #:name "pipeline-b"))
(define plan-ref-remote
  (with-vat vat-a (spawn ^plan-actor sample-plan 'pipeline-test #f)))

(define (await-vow-xvat consumer-vat vow-thunk)
  (let ((box (make-atomic-box #f))
        (err (make-atomic-box #f))
        (done (make-condition)))
    (with-vat consumer-vat
      (on (vow-thunk)
          (lambda (x)
            (atomic-box-set! box x)
            (signal-condition! done))
          #:catch
          (lambda (e)
            (atomic-box-set! err e)
            (signal-condition! done))))
    (wait done)
    (or (atomic-box-ref err)
        (atomic-box-ref box))))

(run-fibers
 (lambda ()

   ;; Sequential reference: get the ref, then query coherence in a
   ;; separate call.
   (let ((first-ref
           (await-vow-xvat vat-b
             (lambda ()
               (<- plan-ref-remote 'subplan-of
                   (cadr (cadr sample-plan))))))
         (direct-coh
           (await-vow-xvat vat-b
             (lambda () (<- plan-ref-remote 'coherence)))))
     (check "cross-vat coherence fetch works" direct-coh 5/9)
     ;; subplan-of with an unmet term returns #f
     (check "subplan-of returns #f for unmet term" first-ref #f))

   ;; Pipelined: chain the calls. (<- (<- ref 'full) 'length-equivalent)
   ;; isn't easily testable without a method returning a ref we can
   ;; re-query. Instead verify that chained <- on a method-returning-ref
   ;; still composes correctly (the key API property).
   ;;
   ;; We use ^plan-actor's own subplan-of, which returns a plan-ref.
   ;; Chain: (<- (<- plan-ref 'subplan-of produce-term) 'coherence)
   (let* ((produce-term '(produce "pie" "recipe-pie" 3
                           ((((spec-id . "flour") (quantity . 3))
                             (satisfied "flour" 3 (("res-2" 3))))
                            (((spec-id . "apple") (quantity . 3))
                             (satisfied "apple" 3 (("res-1" 3)))))))
          (plan-with-produce
            (list (car sample-plan)
                  (list '(((spec-id . "pie") (quantity . 3)))
                        produce-term)))
          (plan-ref-2
            (with-vat vat-a
              (spawn ^plan-actor plan-with-produce 'pipe-test-2 #f)))
          (chained-coh
            (await-vow-xvat vat-b
              (lambda ()
                (<- (<- plan-ref-2 'subplan-of produce-term)
                    'coherence)))))
     (check "chained <- composes: sub-plan coherence over network"
            chained-coh 1))  ; sub-plan is fully satisfied internally


   (format #t "~%=== Results: ~a passed, ~a failed ===~%" pass-count fail-count)
   (primitive-exit (if (zero? fail-count) 0 1))))
