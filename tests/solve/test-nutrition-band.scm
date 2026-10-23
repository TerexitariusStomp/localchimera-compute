;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-nutrition-band.scm — a nutrient band has TWO edges, and the plan holds both.
;;;
;;; The subsistence catalogue carries each nutrient as a band (rda … ul, weight w).
;;; The deficiency edge reaches the solve as #:repro-floors (a deficit on the
;;; nutrient's on-hand held by its ≥0 balance). The toxicity edge reaches it as
;;; #:repro-caps — a fixed-weight `frag` on the nutrient's delivered net (planner.scm,
;;; build-located, "REPRODUCTION CEILING"). Two smooth one-sided terms on one good:
;;; the band the fragility dial draws, convex, Newton-safe, no new tension kind.
;;;
;;; The rig: a kitchen where a meal is wanted for its own sake (a taste — a `des`
;;; on the meal), and every meal carries 800 mg sodium. Wanting five meals means
;;; 4000 mg — past the 2300 mg UL. Nothing but the ceiling opposes that on the
;;; sodium axis: a floor cannot (it only says "at least"), and there is no labour
;;; cost on eating. So:
;;;   T1  no band          → intake ≥ 4000 and UNBOUNDED above: past satiation the
;;;                          taste is flat, and with nothing opposing on the sodium
;;;                          axis the plan drifts along that flat direction — the
;;;                          exact number is arbitrary; only an edge pins it
;;;   T2  floor only       → the same (a floor guards the bottom, not the top)
;;;   T3  floor + ceiling  → 1500 ≤ intake < 2300, and the taste YIELDS to the edge
;;;   T4  the catalogue exports the ceiling edge, only for nutrients that have one
;;;   T5  the ceiling is felt BEFORE UL: a steeper w leaves more headroom
;;;   T6  a ceiling given as a RANGE (lo hi α) places its tip inside it — the eco
;;;       *frag-cap* reading, on a nutrient
;;;
;;; Run: guile --no-auto-compile -q -L module tests/solve/test-nutrition-band.scm

(use-modules (playnet test planner prelude)
             (playnet solve engine) (playnet solve plan)
             (playnet vf schemas)
             (srfi srfi-1)
             (ice-9 format))
(use-modules (playnet knowledge catalogues subsistence))

(define RDA 1500.0) (define UL 2300.0) (define PER-MEAL 800.0) (define WANT 5.0)

(define spatials (list (make-spatial-thing #:id "kitchen" #:lat 52.5 #:long 13.4)))
;; cook: a meal's ingredients from nothing (the point is the SODIUM axis; the
;; kitchen's own labour and stock are not what this test is about).
;; eat: one meal → one "meal|p" (the taste's good) + 800 mg "sodium|p" (the band's good).
(define procs (list (make-recipe-process #:id "cook" #:name "Cook")
                    (make-recipe-process #:id "eat"  #:name "Eat")))
(define flows
  (list (make-recipe-flow #:id "c>"  #:action 'produce #:resource-conforms-to "salty"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-output-of "cook"
                          #:is-primary #t)
        (make-recipe-flow #:id "e<"  #:action 'consume #:resource-conforms-to "salty"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of "eat")
        (make-recipe-flow #:id "e>m" #:action 'produce #:resource-conforms-to "meal|p"
                          #:resource-quantity (make-measure 1.0 "unit") #:recipe-output-of "eat"
                          #:is-primary #t)
        (make-recipe-flow #:id "e>s" #:action 'produce #:resource-conforms-to "sodium|p"
                          #:resource-quantity (make-measure PER-MEAL "mg") #:recipe-output-of "eat"
                          #:is-primary #t)))

(define* (run #:key (floor? #f) (cap #f) (w 5.0))
  (call-with-values
    (lambda ()
      (plan-from-records '() '() spatials procs flows
        #:periods '(0) #:per-agent? #f
        #:demand `(("meal|p#kitchen@0" . ,WANT))
        #:repro-floors (if floor? `(("sodium|p#kitchen@0" . ,RDA)) '())
        #:repro-caps   (if cap `(("sodium|p#kitchen@0" . (,cap . ,w))) '())))
    (lambda (i c material fill cols x idx nt rep)
      (let ((eat (vector-ref x (hash-ref idx "p|eat|kitchen@0"))))
        (cons eat (* PER-MEAL eat))))))     ; (meals . sodium mg)

(define none  (run))
;; the same band handed WHOLE, as the catalogue row plan-scope passes (#:bands)
(define whole
  (call-with-values
    (lambda ()
      (plan-from-records '() '() spatials procs flows
        #:periods '(0) #:per-agent? #f
        #:demand `(("meal|p#kitchen@0" . ,WANT))
        #:bands `(("sodium|p#kitchen@0" ,RDA ,UL 5.0))))
    (lambda (i c material fill cols x idx nt rep)
      (let ((eat (vector-ref x (hash-ref idx "p|eat|kitchen@0")))) (cons eat (* PER-MEAL eat))))))
(define floor (run #:floor? #t))
(define both  (run #:floor? #t #:cap UL))
(define steep (run #:floor? #t #:cap UL #:w 20.0))

(format #t "~%A taste for ~a meals × ~a mg sodium each; RDA ~a, UL ~a:~%" WANT PER-MEAL RDA UL)
(format #t "  no band          → ~,2f meals, ~,0f mg~%" (car none) (cdr none))
(format #t "  floor only       → ~,2f meals, ~,0f mg~%" (car floor) (cdr floor))
(format #t "  floor + ceiling  → ~,2f meals, ~,0f mg   (w=5)~%" (car both) (cdr both))
(format #t "  floor + ceiling  → ~,2f meals, ~,0f mg   (w=20)~%" (car steep) (cdr steep))

(format #t "~%── assertions ──~%")
(check "T1 no band: the taste is served and UL is passed"
       (and (> (cdr none) UL) (> (car none) (- WANT 0.05))))
(check "T2 floor only: a floor guards the bottom, not the top — UL still passed"
       (> (cdr floor) UL))
(check "T3 floor + ceiling: intake inside the band, RDA ≤ intake < UL"
       (and (>= (cdr both) (- RDA 1.0)) (< (cdr both) UL)))
(check "T3' the taste yields to the toxicity edge (fewer meals than wanted)"
       (< (car both) (- WANT 0.5)))
(check "T3'' the whole band as one row (#:bands) is the same solve as the two edges"
       (< (abs (- (cdr whole) (cdr both))) 1e-6))
(define ranged (run #:floor? #t #:cap (list 2000.0 UL 0.5)))     ; the wall with a RANGE, tip 2150 at α=.5
(check "T6 a ceiling with a range: the tip is placed inside it, intake stays below the tip"
       (and (< (cdr ranged) 2150.0) (>= (cdr ranged) (- RDA 1.0)) (< (cdr ranged) (cdr both))))
(check "T5 felt before UL: steeper w leaves more headroom"
       (< (cdr steep) (cdr both)))

;; the catalogue side: the ceiling edge, only where a UL exists
(define caps (subsistence-caps '()))
(define sod  (assoc-ref caps "sodium"))
(check "T4 subsistence-caps carries sodium as (ul . w) = (2300 . 5)"
       (and sod (= (car sod) 2300) (= (cdr sod) 5)))
(check "T4' a floor-only nutrient (protein, ul #f) has no ceiling row"
       (not (assoc-ref caps "protein")))
;; energy states no ceiling by hand: the catalogue's energy-ceiling rule writes
;; it last, the EER at its very active coefficient over the low-active floor —
;; a body can take only so much, and a plan cannot reach another floor by
;; feeding a body past what it burns
(define en (assoc-ref caps "energy"))
(check "T4-energy energy carries a ceiling above its floor, the equation's own ratio (about 1.27 for the reference woman)"
       (and en (< (abs (- (/ (car en) (assoc-ref (subsistence-floors '()) "energy")) (energy-ceiling-ratio '()))) 1e-9)
            (> (car en) (assoc-ref (subsistence-floors '()) "energy"))))
(check "T4'' every ceiling row's nutrient also has a floor row (one band, two edges)"
       (every (lambda (c) (assoc-ref (subsistence-floors '()) (car c))) caps))

(check-done "nutrition band")
