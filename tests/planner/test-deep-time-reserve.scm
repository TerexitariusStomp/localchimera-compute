;;; test-deep-time-reserve.scm — the granary banked across a SEQUENCE of seasons.
;;;
;;; The fuller antifragility the paper called "the next section" — and it needs NO
;;; new machinery. Land is a RENEWABLE per-period capacity (`use`d, its service
;;; Svc|land returning each season — a stationary durable), food is storable across
;;; years, and a weather sequence sets each year's usable land. With the
;;; reproduction floor due EVERY year, the plan banks the good years of its own
;;; accord to carry the drought — endogenous banking across deep time, on the
;;; durable-capacity + storage + floor machinery already in the engine.
;;;
;;; A ten-person household, three seasons: good, good, then a drought that leaves
;;; only a fifth of the land workable. The drought year cannot feed itself; the
;;; plan grows a surplus in the good years and rations it forward.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-deep-time-reserve.scm

(use-modules (srfi srfi-1) (ice-9 format))
(define (sibling f) (or (find file-exists? (filter-map (lambda (p) (and (string? p) (string-append (dirname p) "/" f)))
                                                       (cons (current-filename) (command-line))))
                        (string-append "module/playnet/planner/" f)))
(use-modules (playnet planner solve engine)
             (playnet planner vf schemas)
             (playnet planner knowledge worlds bioregions))
;; engine/robust.scm arrives with the engine — (playnet planner solve engine) loads it into
;; itself and exports its names, so the load that stood here was a second copy
;; of the same text into this module (retired with the engine-as-module arc).
(use-modules (playnet planner knowledge worlds doon-valley))
(primitive-load (sibling "../../module/playnet/planner/knowledge/recipes/navdanya-farm.scm"))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define PEOPLE 10)
(define floor-kg (navdanya-food-floor PEOPLE))            ; 900 kg/season
(define weather '(2.0 2.0 0.2))                           ; ha usable: good, good, DROUGHT
(define grown (plan-navdanya-years #:household PEOPLE #:weather weather))  ; kg grown each year
(define y0 (first grown)) (define y1 (second grown)) (define y2 (third grown))
(define total (+ y0 y1 y2))

(format #t "~%A ~a-person household, three seasons (usable land: ~a ha):~%" PEOPLE weather)
(for-each (lambda (t g) (format #t "  season ~a: grew ~6,0f kg   ~a~%" t g
                          (cond ((< g (* 0.9 floor-kg)) "← below its own floor (drought — draws the granary)")
                                ((> g (* 1.5 floor-kg)) "← surplus banked forward") (else ""))))
          '(0 1 2) grown)
(format #t "  floor each season = ~,0f kg; total grown over the horizon = ~,0f kg~%" floor-kg total)

(format #t "~%── assertions ──~%")
(check "renewable land: the farm grows in EVERY season, not just the first"  (and (> y0 0.0) (> y1 0.0) (> y2 0.0)))
(check "the DROUGHT season cannot feed itself (grows < its floor)"           (< y2 floor-kg))
(check "the good seasons grow a SURPLUS above their own floor"               (and (> y0 floor-kg) (> y1 floor-kg)))
(check "the whole horizon is fed — total ≥ every season's floor (banking held)"
       (>= total (* 0.99 (* floor-kg (length weather)))))
(check "so the plan BANKED the good years to carry the drought (endogenously)"
       (> (- (+ y0 y1) (* 2 floor-kg)) (* 0.5 (- floor-kg y2))))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — antifragility across DEEP TIME: the plan banks good~%  seasons to carry a drought, on machinery the engine already had. Edge closed.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
