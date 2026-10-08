;;; test-frag-certificate.scm — a frag problem resolves cleanly as a CONVEX program, with a certificate.
;;;
;;; Closes gap 6: nothing checked that a fragility barrier solves convexly with a duality-gap
;;; certificate. Here we (a) confirm the frag term's curvature φ″ = w/s² is strictly POSITIVE (convex);
;;; (b) solve a desire-vs-frag problem with solve-native/cert and assert the duality-gap bound m·t is
;;; small at the t-floor (the interior-point certificate the planner already issues for the swept bars,
;;; unaffected by the fixed-weight frag term); (c) confirm the recovered point is strictly feasible
;;; (every bar slack and the frag slack > 0 — the limit is never crossed).
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner tests/planner/test-frag-certificate.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve solver))

(define s-tip 10.0)
;; desire wants x0 → 20 (past the tip); a frag cap (tip 10, fixed w 50) holds it; x ≥ 0.
(define forms (list (mk-des (mk-bar 0.0 '((0 . 1.0))) 20.0 1000.0)   ; desire
                    (mk-frag s-tip (list (cons 0 -1.0)) 50.0)        ; fragility cap, slack = 10 − x
                    (mk-bar 0.0 '((0 . 1.0)))))                       ; x ≥ 0
(define C (flatten forms))

;; (a) the frag term's curvature is strictly positive — convex
(define curv (term-coeffs C 0.02 (term-values C (vector 5.0))))   ; φ″ per form at x=5
(define frag-curv (vector-ref curv 1))

;; (b)+(c) solve with the duality-gap certificate
(define-values (x cert) (solve-native/cert forms '() (vector 0.5)))
(define x0 (vector-ref x 0))
(define t   (cdr (assq 'barrier-t cert)))
(define m   (cdr (assq 'm-constraints cert)))
(define gap (cdr (assq 'duality-gap-bound cert)))
(define sv  (term-values C x))
(define bar-min (let ((nt (cnt C)) (mn +inf.0))   ; smallest HARD slack (bar=0, frag=3) at the optimum
                  (do ((i 0 (+ i 1))) ((= i nt) mn)
                    (let ((k (vector-ref (ckind C) i)))
                      (when (or (= k 0) (= k 3)) (set! mn (min mn (vector-ref sv i))))))))

(format #t "~%── a frag problem as a convex program, certificated ──~%")
(format #t "  frag curvature φ″(x=5) = ~,4f  (= 50/(10−5)² = 2.0)~%" frag-curv)
(format #t "  solve: x0 ~,4f   barrier-t ~a   m ~a   duality-gap ≤ ~,4f~%" x0 t m gap)
(format #t "  smallest hard slack at optimum: ~,4f  (> 0 ⇒ strictly feasible, tip never crossed)~%" bar-min)

(let* ((c1 (> frag-curv 0.0))                          ; convex: φ″ > 0
       (c2 (< (abs (- frag-curv 2.0)) 1e-6))           ; …and exactly w/s² = 50/25 = 2
       (c3 (<= t 0.02))                                ; the central path reached the t-floor (converged)
       (c4 (and (= gap (* m t)) (< gap 0.05)))         ; the duality-gap bound is m·t and small
       (c5 (> bar-min 1e-9))                           ; strictly feasible — the frag limit is never crossed
       (c6 (< x0 s-tip))                               ; eased off below the tip
       (ok (and c1 c2 c3 c4 c5 c6)))
  (format #t "~%  [~a] the fragility term is convex (φ″ = ~,2f > 0, exactly w/s²)~%" (if (and c1 c2) "✓" "✗") frag-curv)
  (format #t "  [~a] solves to the t-floor with a small duality-gap certificate (≤ ~,4f = m·t)~%" (if (and c3 c4) "✓" "✗") gap)
  (format #t "  [~a] the recovered point is strictly feasible — the tip is never crossed (slack ~,3f)~%" (if c5 "✓" "✗") bar-min)
  (format #t "  [~a] and the plan eased off below the tip (~,3f < ~a)~%" (if c6 "✓" "✗") x0 s-tip)
  (format #t "~%  ~a a fragility barrier resolves cleanly as a convex program with the planner's duality-gap certificate~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
