;;; test-shape-by-side.scm — the shape of a wall follows from its SIDE, and it is
;;; forced, not habit.
;;;
;;; A reproduction band holds a good's level between two walls (planner.scm
;;; *band*). Both walls are "a wall, a range, and a point in it" — but the ceiling
;;; is a fixed-weight `frag` and the floor a `held`, and this test is why. Every
;;; tension kind is defined on an affine slack, so each shape can be put on either
;;; side of ONE rig and read at the optimum:
;;;
;;;   FLOOR   thrift pushes the level DOWN, the barrier pushes it UP. A log barrier
;;;           (frag) meets thrift where the weights say — at wall + w/(κ·cost), a
;;;           number about weights that wanders with the labour price. `held`
;;;           sits at the tip whatever the price: it says "this much, no more".
;;;   CEILING thrift and the barrier push the same way, so a log barrier settles;
;;;           frag never enters the precautionary zone past the tip however loud
;;;           the want, and eases off BEFORE it. `held` as a ceiling is a different
;;;           promise: free to the tip, then the plan BUYS its way into the zone.
;;;
;;; So α means the same on both sides — where the defended point sits in the
;;; wall's uncertainty range [lo,hi] — while what the point DOES differs: on a
;;; ceiling it is where the plan may never go, on a floor where it is at ease.
;;; See docs/planning/solve/reproduction-bands.md.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-shape-by-side.scm

(use-modules (playnet test planner prelude)
             (playnet planner solve solver)
             (srfi srfi-1)
             (ice-9 format))

(define (solve1 forms lab x0)
  (call-with-values (lambda () (solve-native-c forms lab (vector x0)))
    (lambda (x . _) (vector-ref x 0))))

;; ── FLOOR: wall 100, margin to 120, tip 110, w 5; the labour price varied 50× ──
(define (floor-frag wall w)     (mk-frag (- wall) '((0 . 1.0)) w))
(define (floor-held wall tip w) (mk-held (mk-bar (- wall) '((0 . 1.0))) (- tip wall) w))
(define costs '(0.02 0.05 0.2 1.0))
(define frag-floors (map (lambda (k) (solve1 (list (floor-frag 100.0 5.0)) `((0 . ,k)) 150.0)) costs))
(define held-floors (map (lambda (k) (solve1 (list (floor-held 100.0 110.0 5.0)) `((0 . ,k)) 150.0)) costs))
(format #t "~%FLOOR (wall 100, tip 110):~%")
(for-each (lambda (k f h) (format #t "  labour cost ~5,3f   frag → ~9,2f   held → ~7,2f~%" k f h)) costs frag-floors held-floors)

;; ── CEILING: range [2000,2300], tip 2150 (α=.5), w 5; a taste toward 5000, rising ──
(define (taste D w)      (mk-des (mk-bar 0.0 '((0 . 1.0))) D w))
(define (ceil-frag tip w)   (mk-frag tip '((0 . -1.0)) w))
(define (ceil-held hi tip w) (mk-held (mk-bar hi '((0 . -1.0))) (- hi tip) w))
(define wants '(50.0 500.0 5000.0 50000.0))
(define frag-ceils (map (lambda (tw) (solve1 (list (taste 5000.0 tw) (ceil-frag 2150.0 5.0)) '() 1500.0)) wants))
(define held-ceils (map (lambda (tw) (solve1 (list (taste 5000.0 tw) (ceil-held 2300.0 2150.0 5.0)) '() 1500.0)) wants))
(format #t "~%CEILING (range [2000,2300], tip 2150):~%")
(for-each (lambda (tw f h) (format #t "  taste w ~7,0f   frag → ~8,2f   held → ~8,2f~%" tw f h)) wants frag-ceils held-ceils)

(format #t "~%── assertions ──~%")
(check "F1 a frag FLOOR lands at wall + w/(κ·cost): it moves with the labour price (>10× across the sweep)"
       (> (/ (car frag-floors) (last frag-floors)) 10.0))
(check "F2 a held FLOOR sits at the tip whatever the price (within 0.2 across the sweep)"
       (every (lambda (h) (< (abs (- h 110.0)) 0.2)) held-floors))
(check "F3 a frag floor over-makes: every reading is above the held tip"
       (every (lambda (f) (> f 110.0)) frag-floors))
(check "C1 a frag CEILING never enters the zone past the tip, however loud the want"
       (every (lambda (f) (< f 2150.0)) frag-ceils))
(check "C2 a frag ceiling is felt BEFORE the tip: a weaker want stops further from it"
       (apply < frag-ceils))
(check "C3 a held CEILING lets the want buy its way INTO the zone (past the tip, below hi)"
       (every (lambda (h) (and (> h 2150.0) (< h 2300.0))) held-ceils))
(check "C4 …and deeper as the want grows"
       (apply < held-ceils))

(check-done "shape by side")
