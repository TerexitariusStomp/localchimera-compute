;;; test-inspection-dual-closure.scm — the recert cadence is READ OFF the plan.
;;;
;;; Slice 4 (test-inspection-credential.scm) closed the loop CONCEPTUALLY:
;;; reliance → a* → valid-until → custody-cred-live?. But it took the reliance D as a
;;; hand-passed constant. This test closes it NUMERICALLY: the reliance is the load the
;;; plan itself routes through the conformance edge, read off the same solve that
;;; schedules the inspection. Nothing is hand-fed but the demand.
;;;
;;; We run the in-plan program (the Slice-1 freshness recurrence + confidence barrier
;;; −w·log(V−Q) + demand + inspection labour, with a SUBSTITUTE path), read the peak
;;; throughput Q the plan puts on the edge, and take reliance = edge-reliance(Q) = D
;;; = φH. That drives reliance->valid-until, so the recert interval falls out of the
;;; plan's own reliance structure, and the whole chain
;;;   solve → edge load (dual) → a* → valid-until → custody-cred-live?
;;; runs on the demand alone.
;;;
;;; Reliance = the THROUGHPUT, not the barrier's slack-dual w/s: the inspection FOC
;;; pins that slack at s ≈ wρ/(κℓ), nearly independent of demand (it measures the check
;;; cost, not the reliance). The load the plan routes through the edge is what a silent
;;; miss would cost — see edge-reliance in vf/formulas/cadence.scm.
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner \
;;;         tests/solve/test-inspection-dual-closure.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve solver))               ; mk-bar/mk-frag/mk-des/solve-native/*kappa*
(use-modules (playnet vf formulas cadence) (playnet vf facts validity))   ; edge-reliance/reliance->valid-until/custody-cred-live?
(use-modules (playnet knowledge catalogues conformance)) ; the GOVERNED confidence-barrier steepness

(set! *kappa* 1.0)
(define WCONF (conformance-frag-weight))   ; confidence barrier steepness — read from the governed profile

;; Solve one T-period in-plan program; return (values Vs Qs Ss) — freshness, edge
;; throughput, and substitute throughput per period at the optimum.
(define* (solve-plan T #:key (delta 0.3) (D 0.6) (ell 1.0) (rho 1.0) (W 10.0)
                            (Vinit 1.0) (c-s 100.0))
  (define n (* 4 T))
  (define (Q t) (* 4 t)) (define (V t) (+ (* 4 t) 1))
  (define (A t) (+ (* 4 t) 2)) (define (S t) (+ (* 4 t) 3))
  (define forms '()) (define lab '())
  (define (add! f) (set! forms (cons f forms)))
  (do ((t 0 (+ t 1))) ((= t T))
    (add! (mk-bar (if (= t 0) (* (- 1.0 delta) Vinit) 0.0)
                  (append (if (= t 0) '() (list (cons (V (- t 1)) (- 1.0 delta))))
                          (list (cons (A t) rho) (cons (V t) -1.0)))))
    (add! (mk-frag 0.0 (list (cons (V t) 1.0) (cons (Q t) -1.0)) WCONF))       ; confidence: s = V−Q
    (add! (mk-des (mk-bar 0.0 (list (cons (Q t) 1.0) (cons (S t) 1.0))) D W))   ; demand via edge OR substitute
    (add! (mk-bar 0.0 (list (cons (A t) 1.0)))) (add! (mk-bar 1.0 (list (cons (A t) -1.0))))
    (add! (mk-bar 0.0 (list (cons (Q t) 1.0)))) (add! (mk-bar 0.0 (list (cons (S t) 1.0))))
    (set! lab (cons (cons (A t) ell) (cons (cons (S t) c-s) lab))))
  (define x0 (make-vector n 0.05))
  (do ((t 0 (+ t 1))) ((= t T)) (vector-set! x0 (V t) Vinit))
  (call-with-values (lambda () (solve-native forms lab x0))
    (lambda (x . _)
      (values (map (lambda (t) (vector-ref x (V t))) (iota T))
              (map (lambda (t) (vector-ref x (Q t))) (iota T))
              (map (lambda (t) (vector-ref x (S t))) (iota T))))))

;; the reliance the plan puts on the edge = its PEAK throughput, read off the solve.
(define* (plan-reliance D #:key (c-s 100.0))
  (call-with-values (lambda () (solve-plan 8 #:D D #:c-s c-s))
    (lambda (Vs Qs Ss) (edge-reliance (fold max 0.0 Qs)))))

(define NOW 1000000) (define DAY 86400.0) (define ELL 1.0) (define K 1.0)
(define (days v) (if v (format #f "~,2f" (/ (- v NOW) DAY)) "OPEN"))

(format #t "~%── the recert cadence is READ OFF the plan: reliance = the edge's own load, not passed in ──~%")

;; C1 — heavier demand ⇒ the plan routes more through the edge ⇒ more reliance.
(define Ds '(0.5 1.5 2.5))
(define rels (map plan-reliance Ds))
(format #t "  demand D = 0.5 1.5 2.5  →  peak edge load (reliance) = ~a~%"
        (map (lambda (r) (format #f "~,3f" r)) rels))
(define c1 (and (< (car rels) (cadr rels)) (< (cadr rels) (caddr rels))))
(format #t "  [~a] C1 more production ⇒ more reliance — the edge's load, endogenous in the solve~%" (if c1 "✓" "✗"))

;; C2 — that reliance drives the recert interval: below the floor ⇒ OPEN; above ⇒ sooner as it rises.
(define vus (map (lambda (r) (reliance->valid-until r ELL K NOW DAY)) rels))
(format #t "~%  → valid-until (days out) = ~a~%" (map days vus))
(define c2 (and (not (car vus))                                   ; D=0.5 (below floor ℓ/κ=1) ⇒ open
                (cadr vus) (caddr vus) (> (cadr vus) (caddr vus)))) ; D=1.5,2.5 interior, sooner as reliance rises
(format #t "  [~a] C2 recert follows the plan: barely-leaned edge OPEN, heavier-leaned recertified sooner~%" (if c2 "✓" "✗"))

;; C3 — SUBSTITUTION relaxes recert: a cheap substitute splits the load, the edge's
;; reliance falls, and its credential's recert interval lengthens — co-determined in ONE solve.
(define rel-sole (plan-reliance 2.5 #:c-s 100.0))   ; no usable substitute
(define rel-sub  (plan-reliance 2.5 #:c-s 0.5))     ; cheap substitute takes part of the load
(define vu-sole (reliance->valid-until rel-sole ELL K NOW DAY))
(define vu-sub  (reliance->valid-until rel-sub  ELL K NOW DAY))
(format #t "~%  demand 2.5: sole-source reliance ~,3f (recert ~a d)  vs  substituted ~,3f (recert ~a)~%"
        rel-sole (days vu-sole) rel-sub (days vu-sub))
(define c3 (and (< rel-sub rel-sole) (or (not vu-sub) (> vu-sub vu-sole))))
(format #t "  [~a] C3 a substitute splits the reliance ⇒ the edge recertifies less — closure & cadence co-determine~%" (if c3 "✓" "✗"))

;; C4 — the WHOLE chain end to end: solve → load → a* → valid-until → custody-cred-live?.
(define rel-hi (plan-reliance 2.5))
(define vu-hi (reliance->valid-until rel-hi ELL K NOW DAY))
(define cred (cred-with-valid-until
              '((said . "EConf1") (revoked? . #f) (claims . ((skill . "baker"))))
              vu-hi))
(define live-now (custody-cred-live? cred NOW))
(define dead-after (custody-cred-live? cred (+ vu-hi 1)))
(format #t "~%  end-to-end (demand 2.5): reliance ~,3f → a* ~,3f → valid-until ~a d → live@now ~a, dead@expiry ~a~%"
        rel-hi (inspection-intensity rel-hi ELL K) (days vu-hi) live-now (not dead-after))
(define c4 (and vu-hi live-now (not dead-after)))
(format #t "  [~a] C4 the chain runs on the plan alone — demand is the only input; the credential's expiry is derived~%" (if c4 "✓" "✗"))

(define ok (and c1 c2 c3 c4))
(for-each (lambda (tag k) (format #t "  [~a] ~a~%" (if k "✓" "✗") tag))
          '("C1 reliance = the edge's endogenous load"
            "C2 recert follows it (open below floor, sooner above)"
            "C3 substitution relaxes recert (co-determined)"
            "C4 solve → a* → valid-until → gate, on demand alone")
          (list c1 c2 c3 c4))
(format #t "~%  ~a the loop is closed NUMERICALLY: the recert cadence is a dual of the plan —~%" (if ok "✓" "✗"))
(format #t "    social-means §1091's reliance φH is the edge's own load, and a* falls out of the solve~%~%")
(exit (if ok 0 1))
