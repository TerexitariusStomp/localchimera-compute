;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-externality.scm — the scope-free externality pattern, on fakes.
;;;
;;; solve/externality.scm imports no solver, so it is tested here the way it is
;;; meant to be used: SOLVE, GRANTED and PULL-OF injected. The fake world is
;;; a purse M split in proportion to declared weight — closed-form, so exact
;;; leave-one-out and dual-marginal displacements are both checkable by hand:
;;;   grant_i = M · w_i / Σw   ⇒ withdrawing row j hands the others
;;;   M·w_j/Σw · (their share of the rest) — and the "dual" of the purse is
;;;   1 (every euro withdrawn is a euro granted), so marginal ≈ exact for a
;;;   small row and the two diverge as the row grows: the envelope claim.
;;;
;;; Run:  guile --no-auto-compile -L module tests/solve/test-externality.scm

(use-modules (localchimera test harness) (srfi srfi-1) (ice-9 format)
             (localchimera solve externality))

(define (~= a b tol) (< (abs (- a b)) tol))

;; the fake: rows (owner weight), purse 100, grants ∝ weight
(define M 100.0)
(define (solve rows)
  (let ((tw (fold + 0.0 (map cadr rows))))
    (map (lambda (r) (list (car r) (if (> tw 0) (* M (/ (cadr r) tw)) 0.0))) rows)))
(define (granted result owner)
  (fold + 0.0 (filter-map (lambda (g) (and (not (equal? (car g) owner)) (cadr g)))
                          result)))

(define ROWS '(("a" 6.0) ("b" 3.0) ("c" 1.0)))
(define BASE (solve ROWS))

(format #t "~%=== solve/externality.scm on a closed-form fake ===~%")

;; withdrawing c's row (weight 1 of 10, granted 10) hands the others 10
(let ((p (withdrawal-displacement solve granted BASE ROWS
                           (lambda (r) (not (equal? (car r) "c"))) "c")))
  (check "withdrawal-displacement = the withdrawn row's own grant (10)" (~= p 10.0 1e-9)))

;; withdrawing a big row (a: 60 of 100) likewise
(let ((p (withdrawal-displacement solve granted BASE ROWS
                           (lambda (r) (not (equal? (car r) "a"))) "a")))
  (check "a big row displaces its full grant (60)" (~= p 60.0 1e-9)))

;; withdrawing nothing displaces nothing
(let ((p (withdrawal-displacement solve granted BASE ROWS (lambda (r) #t) "b")))
  (check "an empty withdrawal is free" (~= p 0.0 1e-9)))

;; the marginal reader: every euro of grant displaces one euro (dual = 1)
(check "marginal-displacement values an ask at the duals"
       (~= (marginal-displacement (lambda (g) 1.0) '(("x" . 10.0))) 10.0 1e-9))
(check "goods with no pull are skipped, the others summed"
       (~= (marginal-displacement (lambda (g) (and (equal? g "x") 2.0))
                           '(("x" . 3.0) ("y" . 99.0)))
           6.0 1e-9))
;; envelope: marginal (grant valued at dual 1) EQUALS exact here because the
;; fake is linear; the family test pins the convex case where they differ.
(let ((exact (withdrawal-displacement solve granted BASE ROWS
                               (lambda (r) (not (equal? (car r) "c"))) "c"))
      (marg  (marginal-displacement (lambda (g) 1.0)
                             (list (cons "c" (cadr (assoc "c" BASE)))))))
  (check "linear world: marginal = exact" (~= exact marg 1e-9)))

;; ── the burn-meter: marginal-rows → note-solve → moved-summary ─────────────
;; Same discipline: closed-form data, properties asserted — the display rows
;; carry exactly μ·q, a kept history bounds itself, and the summary's means
;; are the arithmetic they claim.

(format #t "~%=== the burn-meter folds ===~%")

(let* ((pull-of (lambda (g) (assoc-ref '(("bread" . 2.0) ("milk" . 0.5)) g)))
       (rows (marginal-rows '(("bread" . 3.0) ("milk" . 4.0) ("no-pull" . 9.0)) pull-of)))
  (check "asks with no pull are skipped" (= (length rows) 2))
  (check "moved = μ·q on every row"
         (every (lambda (r) (~= (assq-ref r 'moved)
                                (* (assq-ref r 'mu) (assq-ref r 'qty)) 1e-12))
                rows)))

(let* ((pull-of (lambda (g) 2.0))
       (rows1 (marginal-rows '(("bread" . 1.0)) pull-of))
       (rows3 (marginal-rows '(("bread" . 3.0)) pull-of))
       (h (note-solve (note-solve '() rows1 #:at "t1") rows3 #:at "t2")))
  (check "history is newest first" (equal? (assq-ref (car h) 'at) "t2"))
  (check "a snapshot's total is its rows' Σ moved"
         (~= (assq-ref (car h) 'total) 6.0 1e-12))
  (let ((s (moved-summary h)))
    (check "summary counts the kept solves" (= (assq-ref s 'solves) 2))
    (check "mean-total averages the snapshots"       ; (6 + 2) / 2
           (~= (assq-ref s 'mean-total) 4.0 1e-12))
    (let ((b (find (lambda (r) (equal? (assq-ref r 'spec) "bread"))
                   (assq-ref s 'specs))))
      (check "per-spec mean-moved is the arithmetic mean"
             (~= (assq-ref b 'mean-moved) 4.0 1e-12))
      (check "last-mu is the newest solve's dual" (~= (assq-ref b 'last-mu) 2.0 1e-12))))
  ;; the bound: a history never outgrows KEEP, and it is the NEWEST that stay
  (let loop ((n 0) (h '()))
    (if (< n 70)
        (loop (+ n 1) (note-solve h (marginal-rows '(("bread" . 1.0)) pull-of)
                                  #:at (number->string n) #:keep 64))
        (begin
          (check "history bounds itself to keep" (= (length h) 64))
          (check "…dropping the oldest" (equal? (assq-ref (car h) 'at) "69"))))))

;; ── the one difference, whatever the reading ──────────────────────────────
;; paired-difference takes the minus: a number's `-`, or a bill's row-wise net —
;; so regret, the three bills and what voice displaces are one operator.
(format #t "~%=== paired-difference: one operator, the reading's own minus ===~%")
(let* ((solved '())
       (solve-at (lambda (setting)
                   (set! solved (cons setting solved))
                   (case setting ((tau) '((hours . 12.0) (bill . (("r1" 5.0 2.5) ("r2" 1.0 1.0)))))
                                 (else  '((hours . 10.0) (bill . (("r1" 2.0 1.0))))))))
       (hours (lambda (r) (assq-ref r 'hours)))
       (bill  (lambda (r) (assq-ref r 'bill)))
       (row-net (lambda (a b)                 ; a bill net of a residue, by row
                  (filter-map (lambda (r) (let* ((base (assoc (car r) b))
                                                 (q (- (cadr r) (if base (cadr base) 0.0))))
                                            (and (> q 1e-9) (list (car r) q))))
                              a))))
  (check "voice-displacement is the paired difference of the hours reading" (~= (voice-displacement solve-at hours 'tau) 2.0 1e-12))
  (check "both settings were solved, once each" (equal? (sort (map (lambda (x) (format #f "~a" x)) solved) string<?) '("0.0" "tau")))
  (check "a row-wise minus nets a bill against the residue"
         (equal? (paired-difference solve-at bill 'tau 0.0 #:minus row-net) '(("r1" 3.0) ("r2" 1.0)))))

(test-summary!)
