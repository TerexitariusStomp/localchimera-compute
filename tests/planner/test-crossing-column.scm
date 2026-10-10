;;; test-crossing-column.scm — one column for a good that crosses either way.
;;;
;;; A scope's crossing column is its draw on the good, measured from G, the
;;; most the scope can give: x′ = G + draw ≥ 0, so the flow out of the scope
;;; is G − x′ and its sign is the plan's to say (solver.scm, "a column
;;; measured from what can be given"). Held here:
;;;
;;;   1. `offset-column` is a change of origin and nothing else: every term of
;;;      the offset program at x + G·e is the original's at x, for every kind
;;;      of form; the column's wall stands where it stood; what rides behind a
;;;      form rides on; a method tension stays one.
;;;   2. `give-bound` reads G off the scope's own program: what it holds, less
;;;      what a floor has taken, plus what it can make under its labour; and
;;;      says which column leaves it without bound.
;;;   3. `detach-column` gives back the scope's own program.
;;;   4. The offset program solves to the original's plan, moved by G.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/planner/test-crossing-column.scm

(use-modules (playnet test harness)
             (playnet solve solver)
             ((playnet solve engine) #:select (make-boundary-oracle))
             (srfi srfi-1) (ice-9 format))

;; a seeded stream, so a failure is a program someone can build again
(define next! (make-rng 20260928))
(define (uniform lo hi) (+ lo (* (- hi lo) (/ (next!) 2147483648.0))))
(define (pick . xs) (list-ref xs (modulo (next!) (length xs))))

(define (random-coeffs n col)
  ;; the column under test and two others, the column sometimes named twice
  (let ((others (list (modulo (+ col 1 (modulo (next!) (- n 1))) n) (modulo (next!) n))))
    (append (list (cons col (uniform -3.0 3.0)))
            (map (lambda (j) (cons j (uniform -3.0 3.0))) others)
            (if (zero? (modulo (next!) 3)) (list (cons col (uniform -1.0 1.0))) '()))))
(define (random-form n col)
  (let ((c (uniform -50.0 50.0)) (cs (random-coeffs n col)))
    ((pick (lambda () (mk-bar c cs))
           (lambda () (mk-des (mk-bar c cs) (uniform 1.0 80.0) (uniform 1.0 1000.0)))
           (lambda () (mk-device (mk-bar c cs) 1.0 (uniform 1.0 10.0)))
           (lambda () (mk-qc c cs (uniform 0.1 4.0)))
           (lambda () (mk-frag c cs (uniform 0.1 4.0)))
           (lambda () (mk-held (mk-bar c cs) (uniform 1.0 80.0) (uniform 1.0 100.0)))
           (lambda () (mk-cap (mk-bar c cs) (uniform 1.0 10.0) (uniform 1.0 5.0)))
           (lambda () (mk-method (mk-qc c cs (uniform 0.1 4.0))))
           (lambda () (mk-method (mk-bar c cs)))))))

(define (terms forms x) (vector->list (term-values (flatten forms) x)))
(define (close? a b) (<= (abs (- a b)) (* 1e-12 (max 1.0 (abs a) (abs b)))))

;; ── 1. a change of origin ────────────────────────────────────────────────────
(display "\n── 1. the offset is a change of origin ──\n")
(let ((worst 0.0) (shape-kept #t) (walls-kept #t) (n 5))
  (do ((trial 0 (+ trial 1))) ((= trial 200))
    (let* ((col (modulo (next!) n))
           (G (uniform 0.5 400.0))
           (wall (mk-bar 0.0 (list (cons col 1.0))))
           (forms (cons wall (map (lambda (_) (random-form n col)) (iota 8))))
           (off (offset-column forms col G))
           (x (list->vector (map (lambda (_) (uniform 0.0 60.0)) (iota n))))
           (x* (let ((v (vector-copy x))) (vector-set! v col (+ (vector-ref x col) G)) v)))
      ;; the wall is left out of the comparison: it is the one form that stays put
      (for-each (lambda (a b) (set! worst (max worst (/ (abs (- a b)) (max 1.0 (abs a) (abs b))))))
                (cdr (terms forms x)) (cdr (terms off x*)))
      (unless (equal? (car off) wall) (set! walls-kept #f))
      (unless (every (lambda (f g)
                       (and (eq? (method-form? f) (method-form? g))
                            (let ((f (form-body f)) (g (form-body g)))
                              (and (eq? (f-kind f) (f-kind g))
                                   (equal? (f-coeffs f) (f-coeffs g))
                                   (equal? (cdddr f) (cdddr g))))))   ; weights, the ask, the device's mark
                     forms off)
        (set! shape-kept #f))))
  (format #t "   200 programs of every kind: the worst term differs by ~,2e of its size~%" worst)
  (check "every term of the offset program at x + G·e is the original's at x" (< worst 1e-12))
  (check "the column's wall stands where it stood" walls-kept)
  (check "each form keeps its kind, its columns, and what rides behind them" shape-kept))
(let ((forms (list (mk-bar 0.0 '((0 . 1.0))) (mk-bar 5.0 '((0 . 1.0) (1 . -1.0))))))
  (check "measured from nothing, the program is itself" (eq? (offset-column forms 0 0.0) forms))
  (check "a cap on the column moves with it; only the wall below stays"
         (offset-column (list (mk-bar 0.0 '((0 . 1.0))) (mk-bar 7.0 '((0 . -1.0)))) 0 10.0)
         (list (mk-bar 0.0 '((0 . 1.0))) (mk-bar 17.0 '((0 . -1.0))))))

;; ── 2. what a scope can give ─────────────────────────────────────────────────
(display "\n── 2. G, read off the scope's own program ──\n")
;; columns: 0 the draw, 1 what uses the good, 2 what makes it
(define (walls n) (map (lambda (i) (mk-bar 0.0 (list (cons i 1.0)))) (iota n)))
(define (G-of forms n . crossing)
  (call-with-values (lambda () (if (null? crossing) (give-bound forms n 0) (give-bound forms n 0 #:crossing (car crossing))))
    (lambda (G culprit) G)))
(define (culprit-of forms n)
  (call-with-values (lambda () (give-bound forms n 0)) (lambda (G culprit) culprit)))
(define (balance on-hand . more) (mk-bar on-hand (append '((0 . 1.0) (1 . -1.0)) more)))

(check "a scope that holds 300 can give 300" (G-of (append (walls 2) (list (balance 300.0))) 2) 300.0)
(check "one that holds none and makes none can give nothing" (G-of (append (walls 2) (list (balance 0.0))) 2) 0.0)
(check "a floor already taken off the good lowers what it can give by as much"
       (G-of (append (walls 2) (list (balance (- 300.0 50.0)))) 2) 250.0)
(check "a floor beyond what it holds leaves nothing to give"
       (G-of (append (walls 2) (list (balance (- 30.0 50.0)))) 2) 0.0)
(check "what it can make under its labour is its to give as well: 300 on hand, 20 more from 10 hours at half an hour each"
       (G-of (append (walls 3) (list (mk-bar 10.0 '((2 . -0.5))) (balance 300.0 '(2 . 1.0)))) 3) 320.0)
(check "several walls on the good: the tightest says"
       (G-of (append (walls 2) (list (balance 300.0) (mk-frag 120.0 '((0 . 1.0) (1 . -1.0)) 1.0))) 2) 120.0)
(check "a want held as a wall on the good takes nothing from what it can give"
       (G-of (append (walls 2) (list (balance 300.0) (mk-bar 40.0 '((0 . -1.0) (1 . 1.0))))) 2) 300.0)
(check "a method tension is no wall of the scope's"
       (G-of (append (walls 2) (list (balance 300.0) (mk-method (mk-bar 10.0 '((0 . 1.0) (1 . -1.0)))))) 2) 300.0)
(let ((free (append (walls 3) (list (balance 300.0 '(2 . 1.0))))))
  (check "a good the scope makes without bound has no measure" (G-of free 3) +inf.0)
  (check "and the column nothing bounds is named" (culprit-of free 3) 2))
(let ((two (append (walls 4)
                   ;; good A: draw 0, use 1; good B: draw 3, and column 2 makes A out of B
                   (list (mk-bar 10.0 '((2 . -0.5)))
                         (balance 300.0 '(2 . 1.0))
                         (mk-bar 5.0 '((3 . 1.0) (2 . -1.0)))))))
  (check "with another good crossing, what is made of that good stays within the scope's labour"
         (G-of two 4 '(0 3)) 320.0))

;; the floors a program states are lower bounds, and what a floor holds back from the
;; good is not there to give
(display "\n── 2b. floors tighten G, and G stays valid ──\n")
(check "a floor on the column that uses the good is held back: 300 on hand, 50 owed to it"
       (G-of (append (walls 2) (list (mk-bar -50.0 '((1 . 1.0))) (balance 300.0))) 2) 250.0)
(check "a floor on what a maker feeds: the maker's 20 count, the user's 50 do not"
       (G-of (append (walls 3) (list (mk-bar -50.0 '((1 . 1.0))) (mk-bar 10.0 '((2 . -0.5)))
                                     (balance 300.0 '(2 . 1.0)))) 3) 270.0)
(check "a floor that reaches the user through a row: x1 ≥ x3 and x3 ≥ 30"
       (G-of (append (walls 4) (list (mk-bar -30.0 '((3 . 1.0))) (mk-bar 0.0 '((1 . 1.0) (3 . -1.0)))
                                     (balance 300.0))) 4) 270.0)
(check "a floor below the barrier changes nothing"
       (G-of (append (walls 2) (list (mk-bar 20.0 '((1 . 1.0))) (balance 300.0))) 2) 300.0)
(check "column-upper-bounds with LOWER? never reads a bound looser than without"
       (let* ((forms (append (walls 3) (list (mk-bar -50.0 '((1 . 1.0))) (mk-bar 10.0 '((2 . -0.5)))
                                             (balance 300.0 '(2 . 1.0)) (mk-bar 400.0 '((1 . -1.0) (2 . -1.0))))))
              (C (flatten forms))
              (a (column-upper-bounds C 3))
              (b (column-upper-bounds C 3 #f 12 #:lower? #t)))
         (every <= (vector->list b) (vector->list a))))

;; Validity, on programs nobody picked: sample points of a random program with
;; the draw column free to go below nothing; wherever the point is feasible the
;; draw is no lower than −G. A bound that cut a feasible point would be a G that
;; changed the program's solutions.
(define (feasible? forms x)
  (every (lambda (v) (>= v -1e-9)) (vector->list (term-values (flatten forms) x))))
(define (random-program n)
  (let ((rows (map (lambda (_)
                     (mk-bar (uniform -20.0 60.0)
                             (filter (lambda (ic) (not (zero? (cdr ic))))
                                     (map (lambda (j) (cons j (pick -2.0 -1.0 0.0 1.0 2.0))) (iota n)))))
                   (iota 5))))
    (append (map (lambda (i) (mk-bar 0.0 (list (cons i 1.0)))) '(1 2 3))
            (list (mk-bar (uniform 0.0 100.0) '((0 . 1.0) (1 . -1.0))))
            rows)))
(define (random-point)
  (list->vector (cons (uniform -150.0 50.0) (map (lambda (_) (uniform 0.0 80.0)) '(1 2 3)))))
;; → (values feasible-samples violations) for one program and its G
(define (sample-below-G forms G)
  (let loop ((k 0) (feasible 0) (violations 0))
    (if (= k 400)
        (values feasible violations)
        (let ((x (random-point)))
          (if (feasible? forms x)
              (loop (+ k 1) (+ feasible 1)
                    (if (< (vector-ref x 0) (- (+ G 1e-6))) (+ violations 1) violations))
              (loop (+ k 1) feasible violations))))))
(let loop ((trial 0) (finite 0) (feasible 0) (violations 0))
  (if (< trial 300)
      (let* ((forms (random-program 4))
             (G (call-with-values (lambda () (give-bound forms 4 0)) (lambda (G culprit) G))))
        (if (< G +inf.0)
            (call-with-values (lambda () (sample-below-G forms G))
              (lambda (f v) (loop (+ trial 1) (+ finite 1) (+ feasible f) (+ violations v))))
            (loop (+ trial 1) finite feasible violations)))
      (begin
        (format #t "   300 random programs, ~a with a finite G, ~a feasible samples: ~a below −G~%"
                finite feasible violations)
        (check "some samples were feasible, so the test looked at something" (> feasible 50))
        (check "no feasible point lies below −G" (zero? violations)))))

;; ── 3. out of the crossing ───────────────────────────────────────────────────
(display "\n── 3. a column taken out of the crossing ──\n")
(let* ((own (list (mk-bar 300.0 '((1 . -1.0))) (mk-des (mk-bar 0.0 '((1 . 1.0))) 40.0 1000.0)))
       (with (append (walls 2) (list (mk-bar 300.0 '((0 . 1.0) (1 . -1.0)))
                                     (mk-des (mk-bar 0.0 '((1 . 1.0))) 40.0 1000.0))))
       (off (offset-column with 0 300.0))
       (out (detach-column off 0 300.0)))
  (check "the forms that held it are the scope's own again"
         (filter (lambda (f) (not (column-wall? f 0))) (filter (lambda (f) (not (column-wall? f 1))) (drop-right out 1)))
         own)
  (check "the column stays under its wall and a cap at nothing"
         (and (any (lambda (f) (column-wall? f 0)) out)
              (equal? (last out) (mk-bar 1e-9 '((0 . -1.0)))))))

;; ── 4. the same plan, from another origin ────────────────────────────────────
(display "\n── 4. the offset program's plan is the original's, moved by G ──\n")
;; a granary-and-bakery whose grain comes through the column, held to a centre
;; as a round holds it; the offset program carries the same centre moved
(define (scope G centre)
  (let* ((forms (append (walls 3)
                        (list (mk-bar 42.0 '((1 . -1.0)))
                              (mk-bar 90.0 '((1 . -0.3) (2 . -0.5)))
                              (mk-bar 0.0 '((0 . 1.0) (1 . 1.0) (2 . -1.0)))
                              (mk-des (mk-bar 0.0 '((2 . 1.0))) 100.0 1000.0)
                              (mk-method (mk-qc (- centre) '((0 . 1.0)) 2.0)))))
         (rec (list (cons 'forms (offset-column forms 0 G))
                    (cons 'labform '((1 . 0.3) (2 . 0.5)))
                    (cons 'x0 (vector (+ 0.1 G) 0.1 0.1))
                    (cons 'crossings '())))
         (o (make-boundary-oracle rec)))
    (o 'solve! '() 1.0)
    (o 'plan)))
(let* ((x (scope 0.0 30.0)) (x* (scope 250.0 30.0)))
  (format #t "   from nothing ~a~%   from 250     ~a~%" x x*)
  (check "the column stands G further on" (< (abs (- (vector-ref x* 0) (vector-ref x 0) 250.0)) 1e-3))
  (check "every other column stands where it stood"
         (every (lambda (j) (< (abs (- (vector-ref x* j) (vector-ref x j))) 1e-3)) '(1 2))))
(test-summary!)
