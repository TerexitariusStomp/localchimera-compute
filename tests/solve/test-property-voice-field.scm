;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-property-voice-field.scm — the voice field's bound, on closed-form rows.
;;;
;;; The twin of docs/planning/voice/voice-in-lean.md, file 1 (VoiceField.lean):
;;; each check below is named after the theorem it runs, over the same
;;; definitions (module/playnet/solve/voice-field.scm mirrors "The objects").
;;; Randomised with a fixed seed where the statement is universal; the doc's
;;; own worked numbers (50 hours a column, one full dislike, τ = 0.3 → 107.5
;;; against 92.5, 200 in all) where it gives them. The rules the design REFUSES
;;; — a mean across parts, one global hand — are run as counterexamples: the
;;; refused rule fails the property the kept rule holds.
;;;
;;; Run:  guile -q -L module tests/solve/test-property-voice-field.scm

(use-modules (playnet test harness) (srfi srfi-1) (ice-9 format)
             (playnet vf facts parts) (playnet solve voice-field)
             ((playnet test scope) #:select (push-on)))

(define %state (seed->random-state 20260922))
(define (rnd lo hi) (+ lo (* (- hi lo) (random:uniform %state))))
(define (~= a b . tol) (< (abs (- a b)) (if (pair? tol) (car tol) 1e-9)))
(define (part-str π) (part->string π))

;; ── a small world: two chains of bread, cells = (process place window) ──────
(define W1 (cons "2026-01-05T00:00:00Z" "2026-01-05T23:59:59Z"))
(define W2 (cons "2026-01-06T00:00:00Z" "2026-01-06T23:59:59Z"))
(define (cell process place win) `((process . ,process) (place . ,place) (window . ,win)))
(define C-MILL1 (cell "mill1" "farm" W1)) (define C-BAKE1 (cell "bake1" "town" W1))
(define C-MILL2 (cell "mill2" "coop" W2)) (define C-BAKE2 (cell "bake2" "town" W2))
;; columns: the same four cells, each delivering its good; both chains end in bread
(define TERMS
  (vector (append C-MILL1 '((delivers . (("flour1" . 1.0))) (consumes . (("grain" . 1.0)))))
          (append C-BAKE1 '((delivers . (("bread" . 1.0)))  (consumes . (("flour1" . 1.0)))))
          (append C-MILL2 '((delivers . (("flour2" . 1.0))) (consumes . (("grain" . 1.0)))))
          (append C-BAKE2 '((delivers . (("bread" . 1.0)))  (consumes . (("flour2" . 1.0)))))))
(define P-MILL1 (make-part #:process "mill1")) (define P-BAKE1 (make-part #:process "bake1"))
(define P-MILL2 (make-part #:process "mill2")) (define P-BAKE2 (make-part #:process "bake2"))
(define P-TOWN  (make-part #:place "town"))    (define P-ALL (make-part))
(define P-CHAIN1-DAY (make-part #:window W1))  ; both steps of chain 1 fall on day 1

;; validated hours: ((owner . cell) . hours), read through THE one reader
;; hours-of : part [owner] → hours (the shape voice-fold.scm hands the engine)
(define (hours-table rows)
  (lambda (π . owner)
    (fold (lambda (r a) (if (and (or (null? owner) (equal? (caar r) (car owner))) (covers? π (cdar r))) (+ a (cdr r)) a))
          0.0 rows)))
(define (cells-table rows)
  (lambda (owner) (filter-map (lambda (r) (and (equal? (caar r) owner) (cdar r))) rows)))
(define (field rows hands tau) ; the whole pipeline, as the fold runs it
  (let* ((portions (hand-portions hands (cells-table rows)))
         (pushes (pushes-of (stance-masses portions (hours-table rows)) (hours-table rows)))
         (worked (worked-of-columns TERMS (hours-table rows)))
         (raw (raw-on-columns pushes TERMS))
         (into (into-matrix TERMS worked '("bread")))
         (lam (lambda-of raw worked into)))
    (values pushes raw worked (centred-stances raw into lam))))

;; 50 hours a column: ada mills and bakes chain 1, ben mills chain 2, cy bakes chain 2
(define ROWS `((("ada" . ,C-MILL1) . 50.0) (("ada" . ,C-BAKE1) . 50.0)
               (("ben" . ,C-MILL2) . 50.0) (("cy" . ,C-BAKE2) . 50.0)))

(display "\n── the doc's worked example: centred on the good, whole chains ──\n")
(call-with-values (lambda () (field ROWS `(("ada" ,P-MILL1 -1.0)) 0.3))
  (lambda (pushes raw worked s)
    (check "ada alone works mill1: her full dislike is the part's push" (~= (push-on pushes P-MILL1) -1.0))
    (check "raw = the push on that column, nothing on the others" (equal? (vector->list raw) '(-1.0 0.0 0.0 0.0)))
    (check "the reference is the hours-weighed mean over all the bread (5b output_centring_misses_chain)"
           (and (~= (vector-ref s 0) -0.75) (~= (vector-ref s 1) 0.25) (~= (vector-ref s 2) 0.25) (~= (vector-ref s 3) 0.25)))
    (let* ((felt (map (lambda (j) (warp 50.0 (vector-ref s j) 0.3)) '(0 1 2 3)))
           (chain1 (+ (car felt) (cadr felt))) (chain2 (+ (caddr felt) (cadddr felt))))
      (check "chain 1 feels 107.5 hours, chain 2 92.5 — the plan leans to the other chain" (and (~= chain1 107.5) (~= chain2 92.5)))
      (check "200 in all, as on the clock (5c felt_equals_clock_at_worked_mix)" (~= (+ chain1 chain2) 200.0)))))

(display "\n── 5a what_statement_cancels: a push on every way of a good is nothing ──\n")
(call-with-values (lambda () (field ROWS `(("ada" ,P-ALL -1.0) ("ben" ,P-ALL -1.0) ("cy" ,P-ALL -1.0)) 0.3))
  (lambda (pushes raw worked s)
    (check "\"less bread\" from everyone: every stance is zero" (every (lambda (j) (~= (vector-ref s j) 0.0)) '(0 1 2 3)))
    (check "…and the field adds no labform entry" (null? (field-delta TERMS (vector 1 1 1 1) pushes (hours-table ROWS) '("bread") #:tau 0.3)))))

(display "\n── the bound ──\n")
(define (random-hand owner parts)
  (map (lambda (π) (list owner π (rnd -1.0 1.0))) parts))
(define PARTS (list P-MILL1 P-BAKE1 P-MILL2 P-BAKE2 P-TOWN P-ALL P-CHAIN1-DAY))
(let loop ((k 0) (ok-push #t) (ok-warp #t) (ok-person #t))
  (if (= k 40)
      (begin
        (check "2 abs_push_le_one: |push| ≤ 1 under any hands (40 random draws)" ok-push)
        (check "3 warp_mem: every warped weight lies in [(1−τ)w, (1+τ)w] and stays positive" ok-warp)
        (check "1 person_push_le: one person's raw on a column ≤ Σ |portion|·share over the parts covering it" ok-person))
      (let* ((hands (append (random-hand "ada" PARTS) (random-hand "ben" PARTS) (random-hand "cy" PARTS)))
             (tau (rnd 0.0 0.99))
             (portions (hand-portions hands (cells-table ROWS)))
             (pushes (pushes-of (stance-masses portions (hours-table ROWS)) (hours-table ROWS)))
             (raw (raw-on-columns pushes TERMS))
             (into (into-matrix TERMS (worked-of-columns TERMS (hours-table ROWS)) '("bread")))
             (s (centred-stances raw into (lambda-of raw (worked-of-columns TERMS (hours-table ROWS)) into)))
             ;; ada alone: her raw on column 0 (mill1) against the bound
             (ada-only (pushes-of (stance-masses (filter (lambda (r) (equal? (car r) "ada")) portions) (hours-table ROWS)) (hours-table ROWS)))
             (ada-raw (vector-ref (raw-on-columns ada-only TERMS) 0))
             (ada-bound (fold (lambda (r a)
                                (if (and (equal? (car r) "ada") (covers? (cadr r) (vector-ref TERMS 0)))
                                    (+ a (* (abs (caddr r))
                                            (/ ((hours-table ROWS) (cadr r) "ada") ((hours-table ROWS) (cadr r)))))
                                    a))
                              0.0 portions)))
        (loop (+ k 1)
              (and ok-push (every (lambda (pp) (<= (abs (cdr pp)) (+ 1.0 1e-9))) pushes))
              (and ok-warp (every (lambda (j) (let ((w (warp 50.0 (vector-ref s j) tau)))
                                                (and (> w 0.0) (<= (* 50.0 (- 1 tau)) (+ w 1e-9)) (<= w (+ (* 50.0 (+ 1 tau)) 1e-9)))))
                                  '(0 1 2 3)))
              (and ok-person (<= (abs ada-raw) (+ ada-bound 1e-9)))))))

(display "\n── the hand, held hour by hour ──\n")
(let ((h (hand-portions `(("ada" ,P-MILL1 0.4) ("ada" ,P-BAKE1 -0.5)) (cells-table ROWS))))
  (check "6 hand_signed_rescale: a hand within the bound is left as written"
         (and (~= (caddr (first h)) 0.4) (~= (caddr (second h)) -0.5))))
(let ((h (hand-portions `(("ada" ,P-MILL1 1.0) ("ada" ,P-CHAIN1-DAY 1.0) ("ada" ,P-ALL -1.0)) (cells-table ROWS))))
  (check "6 hand_signed_rescale: three full stances on one cell are scaled to sum to one there"
         (~= (fold + 0.0 (map (lambda (r) (abs (caddr r))) h)) 1.0)))
;; a rotator: six cells, six disjoint parts, a full stance on each
(define ROT-CELLS (map (lambda (i) (cell (format #f "p~a" i) "town" W1)) (iota 6)))
(define ROT-ROWS (map (lambda (c) (cons (cons "rho" c) 10.0)) ROT-CELLS))
(define ROT-HAND (map (lambda (i) (list "rho" (make-part #:process (format #f "p~a" i)) 1.0)) (iota 6)))
(let ((h (hand-portions ROT-HAND (cells-table ROT-ROWS))))
  (check "6′ rotation_costs_nothing: hours that share no part speak separately — six full hands"
         (every (lambda (r) (~= (caddr r) 1.0)) h))
  (check "6″ global_hand_penalises_rotation (refused): one simplex over all six would leave 1/6 each"
         (~= (/ 1.0 (fold + 0.0 (map (lambda (r) (abs (caddr r))) ROT-HAND))) (/ 1.0 6))))

(display "\n── 4 fixed_group_no_gain: one part or many, the same push on a column ──\n")
(call-with-values (lambda () (field ROWS `(("ada" ,P-MILL1 1.0)) 0.3))
  (lambda (p1 raw1 w1 s1)
    (call-with-values (lambda () (field ROWS `(("ada" ,P-MILL1 1.0) ("ada" ,(make-part #:process "mill1" #:place "farm") 1.0)) 0.3))
      (lambda (p2 raw2 w2 s2)
        (check "ada through one part or two parts over the same cell: the same raw on mill1"
               (~= (vector-ref raw1 0) (vector-ref raw2 0)))))))

(display "\n── 5 stance_lipschitz, 5′ mean_dilutes ──\n")
(call-with-values (lambda () (field ROWS `(("ada" ,P-MILL1 -1.0)) 0.3))
  (lambda (p1 raw1 w1 s1)
    (call-with-values (lambda () (field ROWS `(("ada" ,P-MILL1 -1.0) ("ben" ,P-ALL 0.05)) 0.3))
      (lambda (p2 raw2 w2 s2)
        (check "a faint stance added on the broad part moves every raw by at most its own amount"
               (every (lambda (j) (<= (abs (- (vector-ref raw2 j) (vector-ref raw1 j))) (+ 0.05 1e-9))) '(0 1 2 3)))
        (check "raw is the SUM over covering parts: ben's faint like adds, it does not halve ada's dislike (5′ refused)"
               (~= (vector-ref raw2 0) (+ -1.0 (push-on p2 P-ALL))))))))

(display "\n── 8 no_carried_hours ──\n")
(call-with-values (lambda () (field ROWS `(("cy" ,P-MILL1 -1.0) ("cy" ,P-BAKE2 -1.0)) 0.3))
  (lambda (pushes raw worked s)
    (check "cy never worked mill1: no push there, whatever cy says" (~= (push-on pushes P-MILL1) 0.0))
    (check "…and cy's full hand on bake2, which cy alone works" (~= (push-on pushes P-BAKE2) -1.0))))
(let ((pushes (pushes-of (stance-masses (hand-portions `(("dee" ,P-MILL1 1.0)) (cells-table ROWS)) (hours-table ROWS)) (hours-table ROWS))))
  (check "a person with no validated hours at all moves nothing" (null? pushes)))

(display "\n── the labform entries, and their price ──\n")
(call-with-values (lambda () (field ROWS `(("ada" ,P-MILL1 -1.0)) 0.3))
  (lambda (pushes raw worked s)
    (let* ((ell (vector 2.0 1.0 2.0 1.0))
           (delta (field-delta TERMS ell pushes (hours-table ROWS) '("bread") #:tau 0.3)))
      (check "field-delta = −τ·s_j·ℓ_j per column with a stance and labour"
             (and (= 4 (length delta))
                  (every (lambda (jd) (~= (cdr jd) (- (* 0.3 (vector-ref s (car jd)) (vector-ref ell (car jd)))))) delta)))
      (check "τ = 0 adds nothing" (null? (field-delta TERMS ell pushes (hours-table ROWS) '("bread") #:tau 0.0)))
      (check "merge-by-index folds a same-index entry into one coefficient"
             (equal? (merge-by-index '((1 . -0.5)) '((0 . 2.0) (1 . 1.0))) '((0 . 2.0) (1 . 0.5))))
      (let ((x (vector 10.0 10.0 10.0 10.0)))
        (check "20 attribution_exact: a part's marginal price is −τ·Σ ℓ_j·x_j over the columns it covers"
               (let ((m (voice-marginal (list P-MILL1 P-TOWN) TERMS ell x 0.3)))
                 (and (~= (cdr (first m)) (- (* 0.3 2.0 10.0)))
                      (~= (cdr (second m)) (- (* 0.3 (+ 10.0 10.0)))))))))))

(test-summary!)
