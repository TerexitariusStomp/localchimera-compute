;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-standard-lift.scm — a ratified standard raises a floor, up to its ceiling.
;;;
;;; Three catalogues (nutrition, housing, rest) carry an L4 layer: the scope's
;;; ratified standard lifts the floors above bare adequacy. It has one rule,
;;; stated once (`ratified-standard`, `sub-lift` in catalogues/subsistence.scm):
;;;
;;;   • the standard only raises: below 1, absent or not a number, it is 1;
;;;   • a lift raises a floor as far as its own ceiling allows and stops there
;;;     (a floor lifted past its ceiling would be a plan no one can meet);
;;;   • a lift never lowers a floor, and never drops what else a row carries
;;;     (the body's store of a nutrient rides on the row);
;;;   • no stack of layers leaves a floor above its ceiling, in nutrition or in
;;;     housing: the invariant is one function applied at the end of each.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/knowledge/test-standard-lift.scm
(use-modules (playnet test harness)
             (playnet knowledge catalogues subsistence)
             (playnet knowledge catalogues housing)
             (srfi srfi-1))

(define (row prof n) (find (lambda (b) (equal? (sub-spec b) n)) prof))
(define (near? a b) (< (abs (- a b)) 1e-9))
(define base '((sex . "F") (age . 30)))

(display "\n── the standard only raises ──\n")
(check "above 1 it stands" (near? 1.5 (ratified-standard 1.5)))
(check "1 is bare adequacy" (near? 1 (ratified-standard 1)))
(check "below 1 reads as 1" (near? 1 (ratified-standard 0.5)))
(check "absent or not a number reads as 1"
       (and (near? 1 (ratified-standard #f)) (near? 1 (ratified-standard "3"))))

(display "\n── a lift stops at the ceiling ──\n")
(define rows (list (sub-nut "a" "g" "u" 18.0 26.0 1.0 99) (sub-nut "b" "g" "u" 10.0 #f 1.0) (sub-nut "c" "other" "u" 5.0 #f 1.0)))
(define lifted (sub-lift rows 1.5))
(check "a floor under its ceiling after the lift is raised by the factor" (near? 15.0 (sub-rda (row lifted "b"))))
(check "a floor the lift would carry past its ceiling is raised to the ceiling, not skipped"
       (near? 26.0 (sub-rda (row lifted "a"))))
(check "the ceiling is untouched" (near? 26.0 (sub-ul (row lifted "a"))))
(check "what else a row carries rides through the lift: its reserve"
       (equal? 99 (sub-reserve (row lifted "a"))))
(check "a lift names the rows it is for: only the gradient group"
       (let ((l (sub-lift rows 1.5 #:only (lambda (n) (equal? "other" (sub-group n))))))
         (and (near? 7.5 (sub-rda (row l "c"))) (near? 18.0 (sub-rda (row l "a"))))))
(check "a factor of 1 changes nothing" (equal? rows (sub-lift rows 1)))
(check "a lift never lowers a floor that already stands above its ceiling"
       (near? 30.0 (sub-rda (row (sub-lift (list (sub-nut "x" "g" "u" 30.0 26.0 1.0)) 1.5) "x"))))

(display "\n── the nutrition layer, through the catalogue ──\n")
(define (prof s) (subsistence-profile (cons (cons 'standard s) base)))
(check "a lifted iron floor stops at its limit of 45 instead of staying at 18"
       (near? 45.0 (sub-rda (row (prof 3) "iron"))))
(check "zinc, under its limit, is lifted whole" (near? (* 3 8.01) (sub-rda (row (prof 3) "zinc"))))
(check "a ratified standard keeps the body's store of energy and iron (45 and 120 days)"
       (and (equal? 45 (sub-reserve (row (prof 1.2) "energy"))) (equal? 120 (sub-reserve (row (prof 1.2) "iron")))))

(display "\n── the housing layer, through the catalogue ──\n")
(define (hprof s) (housing-profile (list (cons 'standard s) '(age . 30))))
(check "a warmth gradient of 18 against a ceiling of 26, lifted 1.5 times, is held at 26"
       (near? 26.0 (sub-rda (row (hprof 1.5) "hs-warmth"))))
(check "the area gradient is lifted whole: 9 to 13.5" (near? 13.5 (sub-rda (row (hprof 1.5) "hs-area"))))

(display "\n── no stack of layers leaves a floor above its ceiling ──\n")
(define conditions (map car *self-conditions*))
(define (subsets-up-to-3 l)
  (let ((singles (map list l)))
    (append '(()) singles
            (append-map (lambda (a) (filter-map (lambda (b) (and (string<? a b) (list a b))) l)) l)
            (append-map (lambda (a) (append-map (lambda (b) (filter-map (lambda (c) (and (string<? a b) (string<? b c) (list a b c))) l)) l)) l))))
(define all-ok?
  (every (lambda (sex)
           (every (lambda (age)
                    (every (lambda (std)
                             (every (lambda (selfs)
                                      (let ((p (subsistence-profile `((sex . ,sex) (age . ,age) (standard . ,std) (self . ,selfs)))))
                                        (every (lambda (n) (or (not (sub-ul n)) (<= (sub-rda n) (+ (sub-ul n) 1e-9)))) p)))
                                    (subsets-up-to-3 conditions)))
                           '(1 1.3 2 5)))
                  '(8 30 67)))
         '("F" "M")))
(check "nutrition: every floor at or under its ceiling, for every stack of up to three conditions, four standards, three ages, both sexes"
       all-ok?)
(check "housing: every floor at or under its ceiling, at every standard and age"
       (every (lambda (std) (every (lambda (age)
                                     (every (lambda (n) (or (not (sub-ul n)) (<= (sub-rda n) (+ (sub-ul n) 1e-9))))
                                            (housing-profile `((standard . ,std) (age . ,age)))))
                                   '(3 30 70)))
              '(1 1.5 3 10)))

(test-summary!)
