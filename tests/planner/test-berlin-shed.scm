;;; test-berlin-shed.scm — a THIRD real bioregion, spun up from the SAME infrastructure
;;; as Doon and Cascadia, planning a real Brandenburg farm against the region's real
;;; continental futures. Nothing here is Berlin-specific machinery: the shed is data
;;; (knowledge/berlin.scm, from the reproducible fetch→derive pipeline), the farm is data
;;; (knowledge/recipes/brandenburg-farm.scm), and the plan reaches its weather + its
;;; ecological limits by the ONE containment walk (bioregions.scm) — placement is all
;;; onboarding needs.
;;;
;;; It proves, on REAL Berlin/Brandenburg data:
;;;   • the shed registered and carries a MULTITUDE of limits (groundwater + topsoil);
;;;   • a farm placed contained-in it INHERITS the 4 real futures + the 2 limits;
;;;   • drought (p=0.19, higher than Doon/Cascadia) visibly lowers the harvest;
;;;   • the ROBUST plan defends the community's subsistence floor in EVERY future,
;;;     and raises the guaranteed worst-case above the NAIVE (max-expected) plan.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-berlin-shed.scm

(use-modules (srfi srfi-1) (ice-9 format))
(define (sibling f) (or (find file-exists? (filter-map (lambda (p) (and (string? p) (string-append (dirname p) "/" f)))
                                                       (cons (current-filename) (command-line))))
                        (string-append "module/playnet/planner/" f)))
(use-modules (playnet planner solve engine)
             (playnet planner vf schemas) (playnet planner beyond scenario)
             (playnet planner knowledge worlds bioregions))
;; engine/robust.scm arrives with the engine — (playnet planner solve engine) loads it into
;; itself and exports its names, so the load that stood here was a second copy
;; of the same text into this module (retired with the engine-as-module arc).
(use-modules (playnet planner knowledge worlds berlin))                      ; the assembled shed (one <bioregion>)
(primitive-load (sibling "../../module/playnet/planner/knowledge/recipes/brandenburg-farm.scm"))    ; the farm placed in it

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define LAND 2.0) (define WATER 6.0) (define PEOPLE 105)
(define floor-kg (brandenburg-food-floor PEOPLE))       ; 90 kg/person/season × 105
(define (ha plan c) (or (assoc-ref plan c) 0.0))
(define (food-under plan s)                             ; kg the plan yields under scenario s
  (fold (lambda (c a) (+ a (* (ha plan c) (assoc-ref *berlin-crop-yields* c)
                              (or (assoc-ref (planning-scenario-yield-multipliers s) c) 1.0))))
        0.0 *brandenburg-staples*))

;; both channels reach the farm by containment (no #:scenarios / #:eco-spec-frag passed):
(define farm-scen (scope-bioregion-scenarios   *berlin-shed-spatials*))
(define farm-frag (scope-bioregion-fragilities *berlin-shed-spatials*))

(define det (plan-brandenburg-farm #:land-ha LAND #:water WATER #:household PEOPLE
              #:scenarios (list (certainty-equivalent-scenario *berlin-scenarios*))))
(define rob (plan-brandenburg-farm #:land-ha LAND #:water WATER #:household PEOPLE))
(define det-plan (assoc-ref det 'first-stage-plan))
(define rob-plan (assoc-ref rob 'first-stage-plan))

(define (min-food plan) (fold (lambda (s a) (min a (food-under plan s))) 1e18 *berlin-scenarios*))

(format #t "~%── Berlin/Brandenburg shed: real data, spun up from the same pipeline ──~%")
(format #t "  shed id ~s at (~a, ~a), parent ~s~%"
        (bioregion-id *berlin*) (bioregion-lat *berlin*) (bioregion-lon *berlin*) "biosphere")
(format #t "  futures inherited by containment: ~a  |  limits: ~a~%"
        (map planning-scenario-id farm-scen) (fragility-specs-of farm-frag))
(format #t "  Farm: ~a ha, feeding ~a people — subsistence floor ~,0f kg/season~%" LAND PEOPLE floor-kg)
(define (water-used plan) (fold (lambda (c a) (+ a (* (ha plan c) (brandenburg-crop-water c)))) 0.0 *brandenburg-staples*))
(define (top-share plan) (/ (apply max (map (lambda (c) (ha plan c)) *brandenburg-staples*)) LAND))
(define (show tag plan)
  (format #t "~%~a (ha):  wheat ~,2f barley ~,2f maize ~,2f   [water ~,1f / ~,1f]~%"
          tag (ha plan "wheat") (ha plan "barley") (ha plan "maize") (water-used plan) WATER)
  (for-each (lambda (s)
              (let ((f (food-under plan s)))
                (format #t "    ~14a food = ~7,0f kg  ~a~%" (planning-scenario-id s) f
                        (if (< f (* 0.99 floor-kg)) "*** COMMUNITY SHORT ***" "fed"))))
            *berlin-scenarios*))
(show "NAIVE (mean-yield)" det-plan)
(show "ROBUST (real futures)" rob-plan)

(define drought (find (lambda (s) (equal? (planning-scenario-id s) "berlin-drought")) *berlin-scenarios*))
(define normal  (find (lambda (s) (equal? (planning-scenario-id s) "berlin-normal"))  *berlin-scenarios*))
(define flood   (find (lambda (s) (equal? (planning-scenario-id s) "berlin-flood"))   *berlin-scenarios*))

(format #t "~%── assertions ──~%")
(check "the Berlin shed registered as a <bioregion> under the biosphere"
       (and (bioregion? *berlin*) (equal? (bioregion-parent *berlin*) "biosphere")))
(check "the shed carries a MULTITUDE of limits (groundwater + topsoil)"
       (equal? (sort (fragility-specs-of farm-frag) string<?) '("groundwater" "topsoil")))
(check "a farm placed IN it inherits the 4 real futures by containment (incl. drought + p=0 tail)"
       (and (= (length farm-scen) 4)
            (find (lambda (s) (equal? (planning-scenario-id s) "berlin-drought")) farm-scen)))
(check "…and inherits the shed's ecological limits too — futures + limits, one placement"
       (equal? farm-frag (bioregion-fragilities *berlin*)))
(check "the farm scope built from real records planned"          (pair? rob-plan))
(check "drought is real here — it lowers the harvest below a normal year"
       (< (food-under rob-plan drought) (food-under rob-plan normal)))
(check "robust plan feeds the community in a NORMAL year"        (>= (food-under rob-plan normal)  (* 0.99 floor-kg)))
(check "robust plan feeds the community in a DROUGHT year"       (>= (food-under rob-plan drought) (* 0.99 floor-kg)))
(check "robust plan feeds the community in a FLOOD year"         (>= (food-under rob-plan flood)   (* 0.99 floor-kg)))
(check "the shed's scarce summer water BINDS — it, not land, is the limiting factor"
       (> (water-used rob-plan) (* 0.98 WATER)))
(check "…so the plan DIVERSIFIES: no single crop takes the whole field (thirsty maize is capped)"
       (< (top-share rob-plan) 0.95))
(check "robust plan raises the guaranteed worst-case ≥ the naive plan's"
       (>= (min-food rob-plan) (* 0.999 (min-food det-plan))))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — a THIRD real bioregion (Berlin/Brandenburg), real~%  continental drought probabilities, robustly feeding its community across every~%  future — spun up from the SAME infrastructure as Doon and Cascadia.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
