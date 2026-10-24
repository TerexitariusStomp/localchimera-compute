;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-doon-valley-robust.scm — robust planning for a REAL bioregion.
;;;
;;; Doon Valley / Uttarakhand (the Navdanya region), with REAL data
;;; (knowledge/doon-valley.scm): Uttarakhand crop yields, IMD monsoon
;;; drought/flood frequencies, and literature drought-sensitivities. Four kharif
;;; crops on one hectare, a subsistence floor, run through plan-from-records
;;; #:scenarios (Phase 3 entry).
;;;
;;; The naive (mean-yield) planner bets the whole hectare on RICE — the highest
;;; expected yield — and starves when the monsoon fails. The robust planner, told
;;; the three real futures, shifts most of the land to drought-tolerant FINGER
;;; MILLET (ragi) to guarantee the floor in a drought, keeping some rice for
;;; good-year surplus. Vandana Shiva's biodiversity-as-resilience thesis, DERIVED.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-doon-valley-robust.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (localchimera solve engine) (localchimera solve plan)
             (localchimera vf schemas) (localchimera vf beyond scenario)
             (localchimera knowledge dsl shorthand))
;; solve/robust.scm arrives with the engine — (localchimera solve engine) loads it into
;; itself and exports its names, so the load that stood here was a second copy
;; of the same text into this module (retired with the engine-as-module arc).
(use-modules (localchimera knowledge worlds doon-valley))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

;; ── the kharif farm as records (proc-id = crop, so scenario multipliers key on it) ──
(define crops '("rice" "maize" "ragi" "pulses"))
(define (yield-of c) (assoc-ref *doon-valley-crop-yields* c))
(define spatials (list (place* "farm" #:lat 30.3 #:lon 78.0)))  ; Dehradun-ish
(define resources
  (list (er "land1" "land" #f #:place "farm" #:qty 1.0 #:unit "ha")))
(define procs (map (lambda (c) (rp* c (string-append "Grow " c))) crops))
(define flows
  (append-map (lambda (c)
                (list (consume* (string-append c "L") "land" 1.0 c "ha")
                      (out* (string-append c "F") "food" (yield-of c) c)))
              crops))
(define floor-kg 1400.0)                              ; subsistence floor on food (kg/season)
(define demand       `(("food#farm@0" . 4000.0)))    ; surplus wanted → rewards rice's high normal yield
(define repro-floors `(("food#farm@0" . ,floor-kg)))

(define (plan scenarios)
  (call-with-values
    (lambda () (plan-from-records resources '() spatials procs flows
                 #:scenarios scenarios #:first-stage-procs crops
                 #:repro-floors repro-floors #:demand demand #:per-agent? #f))
    (lambda (ints coms material fill cols x idx ntot report)
      (or (assoc-ref report 'first-stage-plan) '()))))          ; ((crop . ha) …)

;; food delivered by a plan under a given scenario = Σ_crop ha·baseline·multiplier
(define (food-under plan-alist s)
  (fold (lambda (c a) (+ a (* (or (assoc-ref plan-alist c) 0.0) (yield-of c)
                              (or (assoc-ref (planning-scenario-yield-multipliers s) c) 1.0))))
        0.0 crops))
(define (ha plan-alist c) (or (assoc-ref plan-alist c) 0.0))

(define det (plan (list (certainty-equivalent-scenario *doon-valley-scenarios*))))
(define rob (plan *doon-valley-scenarios*))

(define (show tag p)
  (format #t "~%~a plan (ha):  rice ~,2f  maize ~,2f  ragi ~,2f  pulses ~,2f~%"
          tag (ha p "rice") (ha p "maize") (ha p "ragi") (ha p "pulses"))
  (for-each (lambda (s)
              (let ((f (food-under p s)))
                (format #t "    ~10a food = ~6,0f kg  (floor ~,0f)  ~a~%"
                        (planning-scenario-id s) f floor-kg (if (< f (* 0.99 floor-kg)) "*** BELOW FLOOR ***" "ok"))))
            *doon-valley-scenarios*))
(show "DETERMINISTIC (mean-yield)" det)
(show "ROBUST (3 real scenarios)" rob)

(define drought (cadr *doon-valley-scenarios*))
(format #t "~%── assertions ──~%")
(check "naive plan bets the hectare on RICE (rice > 0.85 ha)"          (> (ha det "rice") 0.85))
(check "naive plan STARVES in a drought (drought food < floor)"        (< (food-under det drought) (* 0.99 floor-kg)))
(check "robust DROPS the drought-fragile rice bet (rice < 0.1 ha)"     (< (ha rob "rice") 0.1))
(check "robust grows drought-tolerant FINGER MILLET (ragi > 0.3 ha)"   (> (ha rob "ragi") 0.3))
(check "robust DIVERSIFIES — no single crop takes the field (max < 0.85 ha)"
       (< (apply max (map (lambda (c) (ha rob c)) crops)) 0.85))
(check "robust fills the hectare with resilient crops (maize+ragi > 0.9 ha)"
       (> (+ (ha rob "maize") (ha rob "ragi")) 0.9))
(check "robust HOLDS the floor in the normal year"   (>= (food-under rob (car *doon-valley-scenarios*))   (* 0.99 floor-kg)))
(check "robust HOLDS the floor in the DROUGHT year"  (>= (food-under rob drought)                         (* 0.99 floor-kg)))
(check "robust HOLDS the floor in the FLOOD year"    (>= (food-under rob (caddr *doon-valley-scenarios*)) (* 0.99 floor-kg)))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — a robust plan for a REAL bioregion (Doon Valley):~%  the resilient traditional crop (finger millet) is DERIVED from defending~%  the subsistence floor across real monsoon futures.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
