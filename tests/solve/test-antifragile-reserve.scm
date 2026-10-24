;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-antifragile-reserve.scm — bank the good years to survive the tail.
;;;
;;; Robustness survives shocks; ANTIFRAGILITY gains from them. The good years'
;;; volatility — their surplus — is not waste to sell off but the BUFFER that
;;; makes the tail survivable. A granary reserve (banked surplus, carried into
;;; the season) raises the ruin-robust carrying capacity: what the record
;;; over-promised and the single-season tail refused becomes a real guarantee.
;;;
;;; No new machinery: a reserve is just a starting on-hand stock of `food`
;;; (*init*) — the same mechanism reproduction floors already use, run the other
;;; way. (Multi-period endogenous banking via #:storable is the fuller form;
;;; here the reserve is exogenous to keep the lesson clean.)
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-antifragile-reserve.scm

(use-modules (localchimera solve plan) (srfi srfi-1) (ice-9 format))
(define (sibling f) (or (find file-exists? (filter-map (lambda (p) (and (string? p) (string-append (dirname p) "/" f)))
                                                       (cons (current-filename) (command-line))))
                        f))
(use-modules (localchimera solve engine)
             (localchimera vf schemas) (localchimera vf beyond scenario)
             (localchimera knowledge worlds bioregions))
;; solve/robust.scm arrives with the engine — (localchimera solve engine) loads it into
;; itself and exports its names, so the load that stood here was a second copy
;; of the same text into this module (retired with the engine-as-module arc).
(use-modules (localchimera knowledge worlds doon-valley))
(primitive-load (sibling "../../module/localchimera/knowledge/recipes/navdanya-farm.scm"))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define LAND 2.0) (define PEOPLE 28)
(define floor-kg (navdanya-food-floor PEOPLE))          ; 2520
(define RESERVE 1000.0)                                  ; kg banked from good years
(define (ha plan c) (or (assoc-ref plan c) 0.0))
(define (food plan reserve s)
  (+ reserve (fold (lambda (c a) (+ a (* (ha plan c) (assoc-ref *doon-valley-crop-yields* c)
                                         (or (assoc-ref (planning-scenario-yield-multipliers s) c) 1.0))))
                   0.0 *navdanya-staples*)))
(define (try reserve)
  (catch #t
    (lambda () (assoc-ref (plan-navdanya-farm #:land-ha LAND #:household PEOPLE
                            #:scenarios *doon-valley-scenarios/tail-robust* #:reserve reserve) 'first-stage-plan))
    (lambda _ 'infeasible)))

(define no-reserve (try 0.0))
(define with-reserve (try RESERVE))
(define stress *doon-valley-stress-scenario*)
(define normal (car *doon-valley-scenarios*))

(format #t "~%Farm: ~a ha, guaranteeing ~a people through EVERY future incl. the famine tail (floor ~,0f kg):~%"
        LAND PEOPLE floor-kg)
(format #t "  without a reserve:  ~a~%"
        (if (eq? no-reserve 'infeasible) "INFEASIBLE — planner refuses to over-promise" "(feasible?!)"))
(when (pair? with-reserve)
  (format #t "  with a ~,0f kg granary: FEASIBLE — plan: rice ~,2f maize ~,2f ragi ~,2f pulses ~,2f~%"
          RESERVE (ha with-reserve "rice") (ha with-reserve "maize") (ha with-reserve "ragi") (ha with-reserve "pulses"))
  (format #t "     tail food = ~,0f kg (production + granary)  ·  normal food = ~,0f kg~%"
          (food with-reserve RESERVE stress) (food with-reserve RESERVE normal)))

;; antifragility is AFFORDABLE: a single good year's surplus dwarfs the reserve.
(define surplus (and (pair? with-reserve) (- (food with-reserve 0.0 normal) floor-kg)))  ; normal production above the floor

(format #t "~%── assertions ──~%")
(check "single-season tail INFEASIBLE for 28 — the record over-promised"  (eq? no-reserve 'infeasible))
(check "a banked reserve makes 28 SURVIVABLE through the tail"            (pair? with-reserve))
(check "  reserve-fed plan clears the floor in the famine tail"           (>= (food with-reserve RESERVE stress) (* 0.99 floor-kg)))
(check "  and still feeds everyone in a normal year"                     (>= (food with-reserve RESERVE normal) (* 0.99 floor-kg)))
(check "ANTIFRAGILE: a good year's surplus dwarfs the reserve it costs"   (> surplus RESERVE))
(check "  → volatility (good-year surplus) BANKED as survival, not sold off" (> surplus 0.0))

(format #t "~%  (a good year yields ~,0f kg of surplus above the floor — banking ~,0f of it~%   is what turns the tail from famine into survival.)~%" surplus RESERVE)
(format #t "════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — antifragility: the farm BANKS good years' volatility~%  into a reserve that carries its community through a failure beyond any record.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
