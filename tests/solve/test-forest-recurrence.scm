;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-forest-recurrence.scm — a FOREST as a regenerating stock (item 4 of the
;;; raw→stock migration): the same recurrence as soil, on a second natural resource,
;;; retiring another "barriered-free draw" (cf. frag-cascade, where forest is a
;;; single-period frag-capped raw) in favour of an ACCOUNTED stock carried in time.
;;;
;;; A standing forest is a CONDITION — a level, drawn down by logging and rebuilt by
;;; natural regrowth (bounded per period). It obeys the stock recurrence
;;;
;;;   forest[t+1] = forest[t] − logged[t] + regrowth[t],   forest ≥ 0,
;;;
;;; carried season to season by the storable spine. With a timber floor due EVERY
;;; season, REGENERATIVE FORESTRY emerges: the planner that must keep supplying timber
;;; LEANS ON regrowth to slow the drawdown and outlast a clearcut — rather
;;; than clear-cutting early and starving the later seasons. Sustainable forestry is
;;; not a rule we impose; it is what staying feasible across deep time costs.
;;;
;;; Starting stock anchored to a real cover figure (ESA WorldCover, Cascades ~98%
;;; tree cover; data/process-forest.scm). Per-unit timber VOLUME (m³/ha) is the same
;;; external-data follow-on as the per-crop yields; the mechanism here is exact.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-forest-recurrence.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve plan)
             (playnet vf schemas)
             (playnet vf formulas stocks)
             (playnet knowledge dsl shorthand))
;; solve/robust.scm arrives with the engine — (playnet solve engine) loads it into
;; itself and exports its names, so the load that stood here was a second copy
;; of the same text into this module (retired with the engine-as-module arc).

(define SEASONS '(0 1 2 3 4 5 6 7))
(define place "cascades")
(define FOREST0 98.0)                        ; standing-forest index — ESA WorldCover Cascades tree cover %
(define REGROW  14.0)                        ; natural regrowth per season (bounded — the sustainable rate)
(define FLOOR   14.0)                        ; timber demanded every season (at the sustainable rate)

;; forest condition as a regenerating stock (the generic declaration).
(define spatials (list (place* place #:name "Cascades forest" #:lat 44.3 #:lon -122.0)))

;; log: draw 1 forest → 1 timber.   regrow: a bounded natural recharge → 1 forest.
;; regrowth is rate-limited by a per-period cap on `regrowth-capacity` (land/time/
;; light — the bounded capacity of the forest to come back), a genuinely ambient,
;; per-period-capped input; NOT the forest stock itself.
(define log-proc    (rp* "log"    "Log timber"))
(define regrow-proc (rp* "regrow" "Natural regrowth"))
(define log-flows
  (list (stock-draw-flow "l-f" "forest" 1.0 "log" "logging draws the standing forest" "idx")
        (out* "l-t" "timber" 1.0 "log" "m3")))
(define regrow-flows
  (list (consume* "r-c" "regrowth-capacity" 1.0 "regrow" "idx")
        (stock-restore-flow "r-f" "forest" 1.0 "regrow" "natural regrowth restores the forest" "idx")))

(define (run regrow?)                        ; regrow? ⇒ natural regrowth available
  (clear-regenerating-stocks!)
  (register-regenerating-stock! (make-regenerating-stock "forest" "Standing forest (cover index)" place FOREST0 "idx"))
  (let* ((procs (if regrow? (list log-proc regrow-proc) (list log-proc)))
         (flows (append log-flows (if regrow? regrow-flows '())))
         ;; regrowth-capacity: an ambient per-period cap = the sustainable regrowth rate.
         (cap-res (er "rcap" "regrowth-capacity" #f #:place place #:qty REGROW #:unit "idx"
                      #:tags (list "stationary")))
         (resources (cons cap-res (regenerating-stock-resources)))
         (storables (regenerating-stock-storables))                 ; ("forest") — carries in time; timber does NOT
         ;; regrowth-capacity recharges each season → a per-period cap on its Svc-less raw draw.
         (eco-caps (map (lambda (t) (cons (format #f "regrowth-capacity#~a@~a" place t) REGROW)) SEASONS))
         (floors   (map (lambda (t) (cons (format #f "timber#~a@~a" place t) FLOOR)) SEASONS)))
    (call-with-values
      (lambda () (plan-from-records resources '() spatials procs flows
                   ;; The mine-only arm is MEANT to have no answer: with a floor due every
                   ;; season, spending the stock down is not a plan, and that impossibility is
                   ;; the finding. Declared, so PLANNER_INVARIANTS can treat every undeclared
                   ;; infeasible solve in the suite as the bug it usually is.
                   #:allow-infeasible? #t
                   #:periods SEASONS #:storable storables #:eco-caps eco-caps #:repro-floors floors #:per-agent? #f))
      (lambda (ints coms material fill cols x idx ntot report)
        (define (vof k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))
        (define logged (map (lambda (t) (vof (format #f "p|log|~a@~a" place t))) SEASONS))
        (define regrew (map (lambda (t) (vof (format #f "p|regrow|~a@~a" place t))) SEASONS))
        (define timber logged)                                     ; 1 timber per log
        ;; forest level at the START of each season = FOREST0 − Σ logged<t + Σ regrew<t
        (define traj
          (let loop ((ts SEASONS) (lvl FOREST0) (acc '()))
            (if (null? ts) (reverse acc)
                (let ((l (list-ref logged (car ts))) (r (list-ref regrew (car ts))))
                  (loop (cdr ts) (+ lvl (- l) r) (cons lvl acc))))))
        (list logged regrew timber traj
              (length (filter (lambda (tb) (>= tb (* 0.98 FLOOR))) timber)))))))

(define mine (run #f))
(define sust (run #t))
(define (fed r) (list-ref r 4))
(define (traj r) (cadddr r))
(define (decline r) (- (car (traj r)) (last (traj r))))           ; forest lost over the 8 seasons
(define (rate r) (/ (decline r) (- (length SEASONS) 1)))          ; index lost per season
;; forest-life: seasons of logging still standing before the forest is gone, at
;; this decline rate. A clearcut has few; a sustained cut, effectively unbounded.
(define (forest-life r) (if (< (rate r) 0.5) 999.0 (/ (last (traj r)) (rate r))))

(format #t "~%── a timber floor of ~,0f/season, 8 seasons; standing forest starts ~,0f (ESA WorldCover), regrowth ≤ ~,0f/season ──~%"
        FLOOR FOREST0 REGROW)
(format #t "  CLEARCUT (no regrowth):  logged/season = ~a~%" (map (lambda (l) (/ (round (* 10 l)) 10.0)) (car mine)))
(format #t "                           forest        = ~a~%" (map (lambda (s) (/ (round (* 10 s)) 10.0)) (traj mine)))
(format #t "                           loses ~,1f over 8 seasons → ~,0f seasons of forest-life left~%" (decline mine) (forest-life mine))
(format #t "                           seasons supplied (≥ floor): ~a of 8~%" (fed mine))
(format #t "  SUSTAINED (regrowth on): logged = ~a~%" (map (lambda (l) (/ (round (* 10 l)) 10.0)) (car sust)))
(format #t "                           regrew = ~a  → the regrowth the planner leans on~%" (map (lambda (r) (/ (round (* 10 r)) 10.0)) (cadr sust)))
(format #t "                           forest = ~a~%" (map (lambda (s) (/ (round (* 10 s)) 10.0)) (traj sust)))
(format #t "                           loses only ~,1f → ~a forest-life~%" (decline sust)
        (if (>= (forest-life sust) 999.0) "effectively UNBOUNDED" (format #f "~,0f seasons" (forest-life sust))))
(format #t "                           seasons supplied (≥ floor): ~a of 8~%" (fed sust))

(define *pass* 0) (define *fail* 0)
(define (check name ok) (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
                            (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(format #t "~%── assertions ──~%")
(check "clearcut DRAWS the forest down steadily (a falling trajectory)"
       (and (> (decline mine) 20.0)
            (> (car (traj mine)) (cadr (traj mine))) (> (cadr (traj mine)) (caddr (traj mine)))))
(check "the forest never goes NEGATIVE (you cannot log what is not standing)"
       (>= (apply min (traj mine)) -1e-6))
(check "clearcut STARVES later seasons once the forest is spent (< 8 fed)"
       (< (fed mine) 8))
(check "the planner LEANS ON regrowth when it is available (regrew > 0 — the payoff)"
       (> (apply + (cadr sust)) 10.0))
(check "regrowth SLOWS the depletion (sustained mines at a fraction of the clearcut's rate)"
       (< (rate sust) (* 0.6 (rate mine))))
(check "…banking far more forest-life and feeding more seasons than the clearcut"
       (and (> (forest-life sust) (* 1.5 (forest-life mine))) (>= (fed sust) (fed mine))))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  Forest as a regenerating stock: the regrowth-fed cut outlasts the clearcut.~%  All ~a checks passed.~%" *pass*)
    (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)))
(format #t "════════════════════════════════════════════~%")
(when (> *fail* 0) (exit 1))
