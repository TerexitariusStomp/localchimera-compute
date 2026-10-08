;;; federated-fixtures.scm — the one place a federated test economy is built.
;;;
;;; Shared by tests/planner/test-decomposed-optimality.scm and
;;; module/playnet/planner/bench/bench-decomp.scm. It exists because three
;;; copies of "an S-scope chain" drifted apart, and two of the three were wrong
;;; in ways that looked like real findings:
;;;
;;;   • An UNLINKED taking column is a FREE SOURCE. Scope 0 has nothing
;;;     upstream, so a taking column there is grain from nowhere — and no
;;;     fixture built on that shape can be scarce. A deliberately starved
;;;     16-scope chain reported 99.9% met.
;;;
;;;   • PINNING that column to zero with opposing log-barriers (x ≥ 0 and
;;;     −x ≥ 0) is worse: both slacks sit at zero, where the barrier diverges.
;;;     The solve degrades for reasons indistinguishable from a topology effect,
;;;     and a "federated trails monolithic by 40 points" result came out of it.
;;;     There is no such gap.
;;;
;;; So a scope gets only the columns it actually has, and the fixture carries its
;;; own honesty check: at S = 2 a CHAIN and a STAR are the same graph, so they
;;; must report the same numbers. `(federated-fixture-self-check)` asserts it.
;;;
;;; The economy: scope 0 is a granary; every other scope is land-poor and wants
;;; DEM bread. Grain is the only tradeable. `soil-mult` scales all land, so one
;;; shape gives an AMPLE economy (demand servable) or a STARVED one.
;;;
;;;   CHAIN — 0 → 1 → … → S−1, diameter S−1. Grain hops.
;;;   STAR  — 0 supplies every scope directly, diameter 2 for any S.
;;;
;;; Same demand, same land, same grain crossing boundaries. Only the cover
;;; differs — which is the whole point: the cover is a governance choice with a
;;; computational pull, and this is where that pull is measured.

(define fx-DEM 100.0)

;; ── CHAIN ───────────────────────────────────────────────────────────────────
;; Columns exist only where the scope has the corresponding flow: scope 0 has no
;; taking column, the last scope no giving one. Structural, never pinned.
(define* (fx-chain-scope s S #:key (soil-mult 1.2))
  (let* ((first? (= s 0)) (last? (= s (- S 1)))
         (imp  (and (not first?) 0))
         (exp  (and (not last?)  (if first? 0 1)))
         (gi   (cond ((and imp exp) 2) ((or imp exp) 1) (else 0)))
         (bi   (+ gi 1)) (n (+ bi 1))
         (soil (if first? (* fx-DEM S soil-mult) (* 35.0 soil-mult)))
         (A    (if first? (* fx-DEM S 0.5) 90.0)))
    (list (cons 'forms
                (append (map (lambda (i) (mk-bar 0.0 (list (cons i 1.0)))) (iota n))
                        (list (mk-bar soil (list (cons gi -1.0)))
                              (mk-bar A (list (cons gi -0.3) (cons bi -0.5)))
                              (mk-bar 0.0 (append (list (cons gi 1.0) (cons bi -1.0))
                                                  (if imp (list (cons imp 1.0)) '())
                                                  (if exp (list (cons exp -1.0)) '())))
                              (mk-des (mk-bar 0.0 (list (cons bi 1.0))) fx-DEM 1000.0))))
          (cons 'labform (list (cons gi 0.3) (cons bi 0.5)))
          (cons 'x0 (make-vector n 0.1))
          ;; what it gives goes down the chain, what it takes comes from up it
          (cons 'crossings (append (if exp (list (cons* exp (format #f "L~a" s) 1 0)) '())
                                   (if imp (list (cons* imp (format #f "L~a" (- s 1)) -1 0)) '()))))))

(define* (fx-chain S #:key (soil-mult 1.2))
  (map (lambda (s) (fx-chain-scope s S #:soil-mult soil-mult)) (iota S)))

;; ── STAR ────────────────────────────────────────────────────────────────────
;; granary columns: 0…S−2 one giving column per satellite, then grain, then bread.
(define* (fx-star-granary S #:key (soil-mult 1.2))
  (let* ((ne (- S 1)) (gi ne) (bi (+ ne 1)) (n (+ ne 2))
         (soil (* fx-DEM S soil-mult)) (A (* fx-DEM S 0.5)))
    (list (cons 'forms
                (append (map (lambda (i) (mk-bar 0.0 (list (cons i 1.0)))) (iota n))
                        (list (mk-bar soil (list (cons gi -1.0)))
                              (mk-bar A (list (cons gi -0.3) (cons bi -0.5)))
                              (mk-bar 0.0 (cons* (cons gi 1.0) (cons bi -1.0)
                                                 (map (lambda (i) (cons i -1.0)) (iota ne))))
                              (mk-des (mk-bar 0.0 (list (cons bi 1.0))) fx-DEM 1000.0))))
          (cons 'labform (list (cons gi 0.3) (cons bi 0.5)))
          (cons 'x0 (make-vector n 0.1))
          (cons 'crossings (map (lambda (i) (cons* i (format #f "L~a" (+ i 1)) 1 0)) (iota ne))))))

(define* (fx-star-satellite s #:key (soil-mult 1.2))
  (let ((n 3))                                   ; 0 = taking, 1 = grain, 2 = bread
    (list (cons 'forms
                (append (map (lambda (i) (mk-bar 0.0 (list (cons i 1.0)))) (iota n))
                        (list (mk-bar (* 35.0 soil-mult) (list (cons 1 -1.0)))
                              (mk-bar 90.0 (list (cons 1 -0.3) (cons 2 -0.5)))
                              (mk-bar 0.0 (list (cons 0 1.0) (cons 1 1.0) (cons 2 -1.0)))
                              (mk-des (mk-bar 0.0 (list (cons 2 1.0))) fx-DEM 1000.0))))
          (cons 'labform (list (cons 1 0.3) (cons 2 0.5)))
          (cons 'x0 (make-vector n 0.1))
          (cons 'crossings (list (cons* 0 (format #f "L~a" s) -1 0))))))

(define* (fx-star S #:key (soil-mult 1.2))
  (cons (fx-star-granary S #:soil-mult soil-mult)
        (map (lambda (s) (fx-star-satellite s #:soil-mult soil-mult)) (cdr (iota S)))))

;; ── the honesty check ───────────────────────────────────────────────────────
(define* (federated-fixture-self-check #:key (report #t))
  "At S = 2 a chain and a star are the SAME coupling graph — one source, one
   satellite, one link. If they disagree the fixture is lying, and any topology
   conclusion drawn from it is an artefact. Returns #t when they agree."
  (let* ((c (call-with-values (lambda () (solve-decomposed (fx-chain 2) #:accel #t)) list))
         (s (call-with-values (lambda () (solve-decomposed (fx-star 2)  #:accel #t)) list))
         (ok (< (abs (- (cadr c) (cadr s))) 0.5)))
    (when report
      (format #t "  fixture self-check (S=2, chain ≡ star): ~,2f%% vs ~,2f%%  → ~a~%"
              (cadr c) (cadr s) (if ok "agree" "DISAGREE — fixture is broken")))
    ok))
