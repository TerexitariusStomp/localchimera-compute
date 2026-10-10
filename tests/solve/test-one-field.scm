;;; test-one-field.scm — worker, soil, and tool: ONE field, ONE solve.
;;;
;;; social-means.typ §"One field: worker, soil, and tool" claims the three
;;; reproductions — of LABOUR-POWER (a body's nutrient floor), of the LAND (a
;;; soil's regenerative envelope), and of the MEANS (a tool's condition) — are the
;;; SAME convex barrier at three scales, held together in ONE harmony solve. The
;;; single-barrier tests each prove one scale (reproduction-diet · soil-recurrence ·
;;; wear-maintenance); NONE exercised all three at once. This does.
;;;
;;; One chain couples all three: feeding people (the WORKER floor) needs MEAL; meal
;;; is baked from GRAIN, and baking WEARS the oven (the TOOL condition); grain is
;;; grown, and growing DRAWS the soil (the SOIL envelope). Each reproduction has its
;;; own restoring recipe competing for the same grain:
;;;   • soil is restored by a LEGUME (grows grain while fixing fertility),
;;;   • the oven is restored by MAINTENANCE (spends grain on upkeep).
;;; Soil fertility and oven condition are the SAME object — a `regenerating-stock`
;;; (planner/formulas/stocks.scm): drawn by production/wear, restored by regeneration, carried
;;; season to season. The worker floor is the meal `repro-floor`. Three barriers,
;;; one convex program, four seasons.
;;;
;;; The proof of "one field" is COUPLING: the full plan holds all three and feeds
;;; every season; drop the LEGUME and the soil cannot be reproduced — the drawable
;;; fertility, spread optimally across the horizon, no longer sustains floor-level
;;; food; drop MAINTENANCE and the worn oven cannot be reproduced, the same way.
;;; Each reproduction is necessary to clear the worker's floor, and the one solve
;;; defends all three together. (The plan has foresight, so a missing reproduction
;;; under-feeds the whole horizon evenly rather than collapsing only at the end.)
;;;
;;; Run:  guile -L module/playnet/planner tests/solve/test-one-field.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand)
             (playnet vf formulas stocks))

(define SEASONS '(0 1 2 3))
(define place    "farm")
(define FLOOR    3.0)     ; meals due EVERY season — the reproduction of labour-power
(define LAND     2.0)     ; hectares croppable per season — bounds growing (grow vs legume compete)
(define SOIL0    5.0)     ; drawable soil fertility (over the degradation floor)
(define OVEN0    5.0)     ; drawable oven condition  (over the breakdown floor)

(define (M q u) (make-measure q u))
(define (rf id act spec rq ef inof outof)   ; a recipe-flow: input-of when consuming/using, output-of when producing
  (make-recipe-flow #:id id #:action act #:resource-conforms-to spec
                    #:resource-quantity (and rq (M rq "u")) #:effort-quantity (and ef (M ef "u"))
                    #:recipe-input-of inof #:recipe-output-of outof))

;; processes
(define procs
  (list (rp* "grow"     "Grow grain (heavy feeder)")
        (rp* "legume"   "Grow legume (restores soil)")
        (rp* "bake"     "Bake meal (wears oven)")
        (rp* "maintain" "Maintain oven")))

;; flows — parameterised so the counterfactuals just drop a process's flows
(define (flows legume? maintain?)
  (append
   ;; grow: use 1 ha land → grain 4, draws soil 2
   (list (rf "gr-l" 'use "land" 1.0 #f "grow" #f)
         (rf "gr-o" 'produce "grain" 4.0 #f #f "grow")
         (stock-draw-flow "gr-s" "soil-fertility" 2.0 "grow" "cropping draws fertility" "u"))
   ;; bake: grain 1 → meal 1, wears oven 1
   (list (rf "bk-i" 'consume "grain" 1.0 #f "bake" #f)
         (rf "bk-o" 'produce "meal"  1.0 #f #f "bake")
         (stock-draw-flow "bk-w" "oven-condition" 1.0 "bake" "baking wears the oven" "u"))
   ;; legume: use 1 ha land → grain 1, RESTORES soil 2   (only when available)
   (if legume?
       (list (rf "lg-l" 'use "land" 1.0 #f "legume" #f)
             (rf "lg-o" 'produce "grain" 1.0 #f #f "legume")
             (stock-restore-flow "lg-s" "soil-fertility" 2.0 "legume" "legume fixes nitrogen" "u"))
       '())
   ;; maintain: grain 1 → RESTORES oven 4   (only when available)
   (if maintain?
       (list (rf "mn-i" 'consume "grain" 1.0 #f "maintain" #f)
             (stock-restore-flow "mn-o" "oven-condition" 4.0 "maintain" "upkeep restores condition" "u"))
       '())))

(define spatials (list (place* place #:name "The farm-kitchen" #:lat 30.0 #:lon 78.0)))
(define land-res (er "land" "land" #f #:place place #:qty 100.0 #:unit "ha" #:tags (list "stationary")))

(define (run legume? maintain?)
  (clear-regenerating-stocks!)
  ;; soil AND tool condition are the SAME object — a regenerating stock.
  (register-regenerating-stock! (make-regenerating-stock "soil-fertility" "Topsoil fertility" place SOIL0 "u"))
  (register-regenerating-stock! (make-regenerating-stock "oven-condition"  "Oven condition"   place OVEN0 "u"))
  (let* ((ps (filter (lambda (p) (let ((id (recipe-process-id p)))
                                   (and (or legume?   (not (equal? id "legume")))
                                        (or maintain? (not (equal? id "maintain")))))) procs))
         (resources (cons land-res (regenerating-stock-resources)))
         (storables (regenerating-stock-storables))          ; both conditions carry in time; grain/meal do NOT
         (eco-caps  (map (lambda (t) (cons (format #f "Svc|land#~a@~a" place t)
                                           (stock->flow LAND t)))   ; capacity is a FLOW: ha × the season's hours
                          SEASONS))
         (floors    (map (lambda (t) (cons (format #f "meal#~a@~a" place t) FLOOR)) SEASONS)))
    (call-with-values
      (lambda () (plan-from-records resources '() spatials ps (flows legume? maintain?)
                   #:periods SEASONS #:storable storables #:eco-caps eco-caps
                   #:repro-floors floors #:per-agent? #f))
      (lambda (ints coms material fill cols x idx ntot report)
        (define (vof k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))
        (define (lvl proc) (map (lambda (t) (vof (format #f "p|~a|~a@~a" proc place t))) SEASONS))
        (let* ((meal   (lvl "bake"))
               (legume (lvl "legume"))
               (maint  (lvl "maintain"))
               (fed    (length (filter (lambda (m) (>= m (* 0.98 FLOOR))) meal))))
          (list meal fed (apply + legume) (apply + maint)))))))

(define full     (run #t #t))
(define no-legume(run #f #t))
(define no-maint (run #t #f))
(define (meal r)(first r))(define (fed r)(second r))(define (legume-used r)(third r))(define (maint-used r)(fourth r))

(format #t "~%── worker (meal floor ~a) · soil (regen stock) · tool (oven condition) — 4 seasons ──~%" FLOOR)
(format #t "  ~18a ~26a ~10a~%" "scenario" "meal / season" "seasons fed")
(format #t "  ~18a ~26a ~2a / 4~%" "full (both reprod.)" (meal full)     (fed full))
(format #t "  ~18a ~26a ~2a / 4~%" "no legume (soil)"    (meal no-legume)(fed no-legume))
(format #t "  ~18a ~26a ~2a / 4~%" "no maintain (tool)"  (meal no-maint) (fed no-maint))

(let* ((c1 (= 4 (fed full)))                                  ; all three held ⇒ every season fed
       (c2 (> (legume-used full) 0.0))                        ; the SOIL reproduction is actually invoked
       (c3 (> (maint-used full) 0.0))                         ; the TOOL reproduction is actually invoked
       (c4 (< (fed no-legume) 4))                             ; drop soil-restore ⇒ mines out ⇒ starve
       (c5 (< (fed no-maint) 4))                              ; drop tool-restore  ⇒ wears out ⇒ starve
       (ok (and c1 c2 c3 c4 c5)))
  (format #t "~%  [~a] full plan feeds every season — all three barriers held in one solve  (~a/4)~%" (if c1 "✓" "✗") (fed full))
  (format #t "  [~a] the SOIL reproduction (legume) is invoked                             (~,1f ha)~%" (if c2 "✓" "✗") (legume-used full))
  (format #t "  [~a] the TOOL reproduction (maintenance) is invoked                        (~,1f)~%"    (if c3 "✓" "✗") (maint-used full))
  (format #t "  [~a] drop the legume ⇒ soil unreproduced ⇒ floor unmet across the horizon (~a/4 fed)~%" (if c4 "✓" "✗") (fed no-legume))
  (format #t "  [~a] drop maintenance ⇒ oven unreproduced ⇒ floor unmet across the horizon (~a/4 fed)~%" (if c5 "✓" "✗") (fed no-maint))
  (format #t "~%  ~a worker, soil, and tool are ONE field — three reproductions the one solve defends together~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
