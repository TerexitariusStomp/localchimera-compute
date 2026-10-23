;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-navdanya-farm.scm — a robust plan for a REAL bounded scope.
;;;
;;; A 2-hectare Navdanya-style smallholding in the Doon Valley (knowledge/recipes/
;;; navdanya-farm.scm) must feed a ~28-person community through the region's REAL
;;; monsoon futures (probabilities derived from Dehradun's own 1960–2023 record,
;;; knowledge/data/). The naive plan maximises expected yield and starves the
;;; community when the monsoon fails; the robust plan guarantees the subsistence
;;; floor in every future by diversifying off drought-fragile rice.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-navdanya-farm.scm

(use-modules (playnet solve plan) (srfi srfi-1) (ice-9 format))
(define (sibling f) (or (find file-exists? (filter-map (lambda (p) (and (string? p) (string-append (dirname p) "/" f)))
                                                       (cons (current-filename) (command-line))))
                        f))
(use-modules (playnet solve engine)
             (playnet vf schemas) (playnet vf beyond scenario)
             (playnet knowledge worlds bioregions))
;; solve/robust.scm arrives with the engine — (playnet solve engine) loads it into
;; itself and exports its names, so the load that stood here was a second copy
;; of the same text into this module (retired with the engine-as-module arc).
(use-modules (playnet knowledge worlds doon-valley))
(primitive-load (sibling "../../module/playnet/knowledge/recipes/navdanya-farm.scm"))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define LAND 2.0) (define PEOPLE 28)
(define floor-kg (navdanya-food-floor PEOPLE))          ; 90 kg/person/season × 28
(define (ha plan c) (or (assoc-ref plan c) 0.0))
(define (food-under plan s)                             ; kg the plan yields under scenario s
  (fold (lambda (c a) (+ a (* (ha plan c) (assoc-ref *doon-valley-crop-yields* c)
                              (or (assoc-ref (planning-scenario-yield-multipliers s) c) 1.0))))
        0.0 *navdanya-staples*))

(define det (plan-navdanya-farm #:land-ha LAND #:household PEOPLE
              #:scenarios (list (certainty-equivalent-scenario *doon-valley-scenarios*))))
(define rob (plan-navdanya-farm #:land-ha LAND #:household PEOPLE))
(define det-plan (assoc-ref det 'first-stage-plan))
(define rob-plan (assoc-ref rob 'first-stage-plan))

(format #t "~%Farm: ~a ha, feeding ~a people — subsistence floor ~,0f kg/season~%" LAND PEOPLE floor-kg)
(define (show tag plan)
  (format #t "~%~a (ha):  rice ~,2f maize ~,2f ragi ~,2f pulses ~,2f wheat ~,2f~%"
          tag (ha plan "rice") (ha plan "maize") (ha plan "ragi") (ha plan "pulses") (ha plan "wheat"))
  (for-each (lambda (s)
              (let ((f (food-under plan s)))
                (format #t "    ~12a food = ~6,0f kg  ~a~%" (planning-scenario-id s) f
                        (if (< f (* 0.99 floor-kg)) "*** COMMUNITY GOES HUNGRY ***" "fed"))))
            *doon-valley-scenarios*))
(show "NAIVE (mean-yield)" det-plan)
(show "ROBUST (real monsoon futures)" rob-plan)

(define drought (find (lambda (s) (equal? (planning-scenario-id s) "doon-drought")) *doon-valley-scenarios*))
(format #t "~%── assertions ──~%")
(check "the farm scope built from real records planned"                (pair? rob-plan))
(check "naive plan leans hard on rice (rice > 1.5 of 2 ha)"            (> (ha det-plan "rice") 1.5))
(check "naive plan STARVES the community in a drought"                 (< (food-under det-plan drought) (* 0.99 floor-kg)))
(check "robust plan HEDGES the rice bet (rice < 1.9 ha, not the whole field)" (< (ha rob-plan "rice") 1.9))
(check "robust plan adds a drought buffer of resilient crops (> 0.3 ha)"
       (> (- LAND (ha rob-plan "rice")) 0.3))
(check "robust plan feeds the community in a NORMAL year"    (>= (food-under rob-plan (car   *doon-valley-scenarios*)) (* 0.99 floor-kg)))
(check "robust plan feeds the community in a DROUGHT year"   (>= (food-under rob-plan drought)                         (* 0.99 floor-kg)))
(check "robust plan feeds the community in a FLOOD year"     (>= (food-under rob-plan (caddr *doon-valley-scenarios*)) (* 0.99 floor-kg)))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — a REAL farm scope (Navdanya smallholding, Doon Valley),~%  real monsoon probabilities, robustly feeding its community across every future.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
