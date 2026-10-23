;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-emphasis.scm — the spec's law for social desire, on closed-form rows.
;;;
;;; What the module claims and this suite holds: an owner's masses sum to
;;; scale × their voice whatever they wrote (the simplex); rescaling an
;;; owner's attachments changes nothing; a coalition's mass on a key is
;;; linear in its members' voices however they split it (the
;;; collusion-neutrality lemma, truth-telling.md); no voice reads as equal;
;;; the default for an unweighted key is the mean of the weighted ones.
;;;
;;; Run:  guile --no-auto-compile -L module tests/solve/test-emphasis.scm

(use-modules (playnet test harness) (srfi srfi-1) (ice-9 format) (playnet solve emphasis))

(define (~= a b) (< (abs (- a b)) 1e-9))
(define (mass-of ms owner key)
  (fold + 0.0 (filter-map (lambda (m) (and (equal? (car m) owner) (equal? (cadr m) key) (caddr m))) ms)))
(define (owner-total ms owner)
  (fold + 0.0 (filter-map (lambda (m) (and (equal? (car m) owner) (caddr m))) ms)))
(define (key-total ms key)
  (fold + 0.0 (filter-map (lambda (m) (and (equal? (cadr m) key) (caddr m))) ms)))

(format #t "~%=== emphasis-masses: the simplex, scaled by voice ===~%")

(define equal-voice (lambda (_) 1.0))
(define ROWS '(("ada" "bread" 464) ("ada" "milk" 5) ("ada" "silent" 0)
               ("ben" "bread" 10) ("ben" "milk" 10)))

(let ((ms (emphasis-masses ROWS equal-voice 1000.0)))
  (check "an owner's masses sum to scale × voice, whatever they wrote"
         (and (~= (owner-total ms "ada") 1000.0) (~= (owner-total ms "ben") 1000.0)))
  (check "shares follow the attachments" (~= (mass-of ms "ada" "bread") (* 1000.0 (/ 464.0 469.0))))
  (check "an even hand spreads evenly" (~= (mass-of ms "ben" "bread") 500.0))
  (check "a row stating nothing carries nothing" (= 0 (length (filter (lambda (m) (equal? (cadr m) "silent")) ms))))
  (check "a key's mass is the sum over citizens"
         (~= (key-total ms "bread") (+ (* 1000.0 (/ 464.0 469.0)) 500.0))))

(let ((a (emphasis-masses ROWS equal-voice 1000.0))
      (b (emphasis-masses (map (lambda (r) (list (car r) (cadr r) (* 7 (caddr r)))) ROWS) equal-voice 1000.0)))
  (check "rescaling every attachment changes nothing (the simplex)"
         (every (lambda (m n) (and (equal? (car m) (car n)) (~= (caddr m) (caddr n)))) a b)))

(let* ((voice (lambda (o) (assoc-ref '(("ada" . 2.0) ("ben" . 0.5)) o)))
       (ms (emphasis-masses ROWS voice 1000.0)))
  (check "voice scales the whole hand" (and (~= (owner-total ms "ada") 2000.0) (~= (owner-total ms "ben") 500.0))))

;; linearity: a coalition's mass on a key equals what one member with the
;; coalition's whole voice and the same shares would place — split-invariance
(let* ((two (emphasis-masses '(("x" "bread" 1) ("y" "bread" 1))
                             (lambda (o) (assoc-ref '(("x" . 0.7) ("y" . 1.3)) o)) 100.0))
       (one (emphasis-masses '(("xy" "bread" 1)) (lambda (_) 2.0) 100.0)))
  (check "a coalition's mass is linear in its members' voices, however split"
         (~= (key-total two "bread") (key-total one "bread"))))

(check "no voice reads as an equal citizen"
       (~= (owner-total (emphasis-masses '(("new" "bread" 3)) (lambda (_) #f) 1000.0) "new") 1000.0))

(format #t "~%=== fill-default: the aggregate stands where nobody weighted ===~%")
(let ((w (fill-default '("a" "b" "c") '(("a" . 100.0) ("c" . 300.0)))))
  (check "stated keys keep their weight" (and (~= (assoc-ref w "a") 100.0) (~= (assoc-ref w "c") 300.0)))
  (check "an unweighted key inherits the mean of the stated" (~= (assoc-ref w "b") 200.0))
  (check "every key answers" (= (length w) 3)))
(check "nothing stated → nothing filled (the caller's default is the information)"
       (null? (fill-default '("a" "b") '())))

(test-summary!)
