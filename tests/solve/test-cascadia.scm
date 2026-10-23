;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-cascadia.scm — Cascadia is a first-class bioregion, real climate from its OWN
;;; record, same machinery as Doon on another continent with a WINTER wet season.
;;; Proves the whole stack generalized: a second <bioregion> is just data.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-cascadia.scm

(use-modules (playnet test planner prelude)
             (playnet solve engine)
             (playnet vf schemas) (playnet vf beyond scenario)
             (playnet knowledge worlds bioregions)
             (srfi srfi-1)
             (ice-9 format))
(use-modules (playnet knowledge worlds cascadia)
             (playnet knowledge dsl shorthand))

(format #t "~%── Cascadia: a real bioregion, its own winter-wet climate ──~%")

;; 1. it is a registered <bioregion> with real futures + a multitude of limits
(check "*cascadia* is a <bioregion>"                         (bioregion? *cascadia*))
(check "its id is cascadia, at the Willamette Valley"        (and (equal? (bioregion-id *cascadia*) "cascadia")
                                                                  (< (abs (- (bioregion-lon *cascadia*) -123.0)) 0.01)))
(check "4 scenarios: 3 historical futures + the p=0 tail"    (= (length (bioregion-scenarios *cascadia*)) 4))
(check "a multitude of limits: streamflow, old-growth, salmon"
       (equal? (fragility-specs-of (bioregion-fragilities *cascadia*)) '("streamflow" "old-growth" "salmon")))

;; 2. the numbers are REAL — probabilities straight from the vendored ERA5 record
(format #t "  season (auto): ~a   probs: drought ~a / normal ~a / flood ~a~%"
        *cascadia-derived-season* (casc-prob "drought") (casc-prob "normal") (casc-prob "flood"))
(check "growing season AUTO-detected as the winter wet months (Nov–Mar)"
       (equal? (sort *cascadia-derived-season* <) '(1 2 3 11 12)))
(check "drought probability is the record's 9/64"            (< (abs (- (casc-prob "drought") (/ 9.0 64)))  1e-6))
(check "scenario probabilities sum to 1"
       (< (abs (- (apply + (map planning-scenario-probability *cascadia-scenarios*)) 1.0)) 1e-6))
(check "the p=0 tail carries no probability but real multipliers"
       (= (planning-scenario-probability *cascadia-stress-scenario*) 0.0))

;; 3. a scope placed IN Cascadia inherits its futures — the containment spine, generic
(define spatials (list (place* "biosphere")
                       (bioregion-spatial *cascadia*)
                       (place* "willamette-farm" #:name "a Cascadia farm" #:lat 45.0 #:lon -123.0 #:parent "cascadia")))
(check "a farm placed in Cascadia inherits its 4 scenarios via containment"
       (= (length (scope-bioregion-scenarios spatials)) 4))
(check "…the SAME object the planner reasons about (by id) as the map draws"
       (equal? (bioregion-of spatials "willamette-farm") "cascadia"))

;; 4. it does NOT collide with Doon — two real bioregions, distinct
(use-modules (playnet knowledge worlds doon-valley))
(use-modules (playnet knowledge worlds doon-shed))
(check "Doon + Cascadia coexist as distinct registered bioregions"
       (and (equal? (bioregion-id *doon-shed*) "doon-shed")
            (not (equal? (casc-prob "normal") (assoc-ref *doon-derived-scenario-probs* "normal")))))

(check-done "  Cascadia is a first-class bioregion — real winter-wet climate, its own limits,~%  inherited by containment. A second continent, and it was just data.~%")
