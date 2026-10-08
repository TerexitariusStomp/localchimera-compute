;;; test-federation-result.scm — coinductive federation-result shape
;;;
;;; Verifies ^federation-result actor + dual-shape fr-* accessors:
;;;   1. Actor round-trip: alist → actor → alist preserves fields
;;;   2. Dual-shape equivalence: fr-* returns the same value whether
;;;      given an alist or an actor
;;;   3. Promise handling: retraction-candidates as (delay ...) forces
;;;      uniformly through actor and accessors
;;;   4. Plan field: works for inline plans AND ^plan-actor refs

(setvbuf (current-output-port) 'line)

(use-modules (playnet test harness)
             (playnet deprecated planner)
             (goblins) (goblins vat))

(define vat (spawn-vat))


;;; ── Fixtures ──────────────────────────────────────────────────────────────

(define sample-plan
  '((((spec-id . "apple") (quantity . 5))
     (satisfied "apple" 5 (("res-1" 5))))
    (((spec-id . "bread") (quantity . 4))
     (unmet "bread" 4))))

(define sample-alist
  `((scope . commune-alpha)
    (plan . ,sample-plan)
    (deficits . (((scope-id . commune-alpha) (spec-id . "bread") (qty . 4))))
    (surpluses . ())
    (retraction-candidates . (((scope-id . commune-alpha) (spec-id . "apple") (qty . 5))))
    (residual . 4)
    (coherence . 5/9)))


;;; ── Tests ──────────────────────────────────────────────────────────────

(with-vat vat

  (display "\n── 1. Actor round-trip ──\n")
  (let* ((actor (federation-result->actor sample-alist))
         (roundtripped ($ actor 'as-alist)))
    (check "scope survives roundtrip"
           (assq-ref roundtripped 'scope) 'commune-alpha)
    (check "coherence survives roundtrip"
           (assq-ref roundtripped 'coherence) 5/9)
    (check "plan survives roundtrip"
           (assq-ref roundtripped 'plan) sample-plan)
    (check "deficits survive roundtrip"
           (assq-ref roundtripped 'deficits)
           '(((scope-id . commune-alpha) (spec-id . "bread") (qty . 4))))
    (check "residual survives roundtrip"
           (assq-ref roundtripped 'residual) 4)
    (check "harmony-less result has no harmony key"
           (assq-ref roundtripped 'harmony) #f))


  (display "\n── 2. Dual-shape accessor equivalence ──\n")
  (let ((actor (federation-result->actor sample-alist)))
    (check "fr-scope: alist == actor"
           (fr-scope sample-alist) (fr-scope actor))
    (check "fr-coherence: alist == actor"
           (fr-coherence sample-alist) (fr-coherence actor))
    (check "fr-deficits: alist == actor"
           (fr-deficits sample-alist) (fr-deficits actor))
    (check "fr-surpluses: alist == actor"
           (fr-surpluses sample-alist) (fr-surpluses actor))
    (check "fr-residual: alist == actor"
           (fr-residual sample-alist) (fr-residual actor))
    (check "fr-plan: alist == actor (inline plan)"
           (fr-plan sample-alist) (fr-plan actor))
    (check "fr-harmony: alist == actor (both #f)"
           (fr-harmony sample-alist) (fr-harmony actor))
    (check "fr-retraction-candidates: alist == actor"
           (fr-retraction-candidates sample-alist)
           (fr-retraction-candidates actor)))


  (display "\n── 3. Promise handling ──\n")
  ;; retraction-candidates as (delay ...) — force should work uniformly
  (let* ((alist-with-promise
           `((scope . alpha)
             (coherence . 1)
             (deficits . ())
             (surpluses . ())
             (plan . ())
             (retraction-candidates
               . ,(delay '(((scope-id . alpha) (spec-id . "x") (qty . 2)))))
             (residual . 0)))
         (actor (federation-result->actor alist-with-promise)))
    (check "fr-retraction-candidates forces promise (alist)"
           (fr-retraction-candidates alist-with-promise)
           '(((scope-id . alpha) (spec-id . "x") (qty . 2))))
    (check "fr-retraction-candidates forces promise (actor)"
           (fr-retraction-candidates actor)
           '(((scope-id . alpha) (spec-id . "x") (qty . 2))))
    (check "actor's retraction-candidates method returns forced list"
           ($ actor 'retraction-candidates)
           '(((scope-id . alpha) (spec-id . "x") (qty . 2)))))


  (display "\n── 4. Plan field: inline vs ^plan-actor ref ──\n")
  ;; Build an alist where plan is a ^plan-actor ref instead of inline.
  (let* ((plan-ref (spawn ^plan-actor sample-plan 'commune-beta #f))
         (alist-with-ref `((scope . commune-beta)
                           (coherence . 5/9)
                           (deficits . ())
                           (surpluses . ())
                           (plan . ,plan-ref)
                           (retraction-candidates . ())
                           (residual . 0)))
         (actor (federation-result->actor alist-with-ref)))
    (check "fr-plan forces through ref (alist shape)"
           (fr-plan alist-with-ref) sample-plan)
    (check "fr-plan forces through ref (actor shape)"
           (fr-plan actor) sample-plan)
    (check "fr-plan-ref returns the ref (alist shape)"
           (eq? (fr-plan-ref alist-with-ref) plan-ref))
    (check "fr-plan-ref returns the ref (actor shape)"
           (eq? (fr-plan-ref actor) plan-ref))
    (check "fr-plan-ref returns #f when plan is inline"
           (fr-plan-ref sample-alist) #f))


  (display "\n── 5. spawn-federation-result kwargs ──\n")
  ;; Direct constructor without going through an alist.
  (let ((actor (spawn-federation-result
                 #:scope 'commune-gamma
                 #:coherence 1
                 #:deficits '()
                 #:residual 0)))
    (check "spawn kwargs: scope"
           ($ actor 'scope) 'commune-gamma)
    (check "spawn kwargs: coherence default"
           ($ actor 'coherence) 1)
    (check "spawn kwargs: deficits default"
           ($ actor 'deficits) '())
    (check "spawn kwargs: residual"
           ($ actor 'residual) 0)
    (check "spawn kwargs: plan defaults to '()"
           ($ actor 'plan) '())))


(format #t "~%=== Results: ~a passed, ~a failed ===~%" pass-count fail-count)
(exit (if (zero? fail-count) 0 1))
