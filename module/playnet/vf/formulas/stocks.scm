;;; stocks.scm — REGENERATING STOCKS: a resource whose CONDITION is a carried
;;; LEVEL, drawn down by production and restored by regeneration, threaded from
;;; each period to the next. The one dynamic behind soil fertility, tool wear,
;;; pasture, an aquifer, a fishery, a forest — a stock you can MINE or TEND:
;;;
;;;   S[t+1]  =  S[t]  −  draw(production at t)  +  restore(regeneration at t),
;;;   S[t] ≥ 0   (you cannot draw a condition you have spent)
;;;
;;; This is `navdanya-farm.scm`'s "soil-condition recurrence … generalised". It is
;;; NOT a new solver and NOT a bespoke soil model — it is the durable-CONDITION
;;; pattern the engine already names (planner.scm: "a durable's CONDITION is a
;;; stock GOOD; wear is a `consume`, maintenance a `produce`; made *storable* it
;;; carries the health forward"), lifted into a first-class, reusable declaration.
;;; A stock is just a *storable* good with a starting *init*; production `consume`s
;;; it, regeneration `produce`s it, and the per-period ≥0 balance + the temporal
;;; carry arc give the recurrence for free.
;;;
;;; The REGENERATIVE PAYOFF falls out of the arithmetic, not a special rule: a
;;; season that mines the stock earns more now but leaves less standing; a season
;;; that tends it (compost, a legume that FIXES fertility — a `produce` with no
;;; drawdown) costs now and pays later. With a floor due EVERY period, the planner
;;; that must keep producing is driven to hold the stock up — so crop rotation and
;;; soil-building EMERGE as the cheapest way to stay feasible across deep time.
;;;
;;; Loaded from planner.scm core (beside solve/robust.scm/bioregions.scm) — generic
;;; MECHANISM, no data. Knowledge files `register-regenerating-stock!` a real one
;;; (soil fertility from SoilGrids, a machine's condition, a basin's water table).

;; A regenerating stock: the condition IS a good's level. ONE object carries where
;; it sits and how much stands there, so a scope gets the resource, the storable
;; carry, and the draw/restore flow-builders from a single declaration.
;; (make-record-type, matching <bioregion>/<spatial-thing> — the planner is
;; primitive-loaded without srfi-9's define-record-type in scope.)
(define-module (playnet vf formulas stocks)
  #:use-module ((playnet utils records) #:select (define-vf-record vf-record-type vf-record-constructor vf-record-predicate vf-record-accessor vf-record-modifier vf-record-type-name vf-record-type-fields))
  #:use-module (srfi srfi-1)
  #:use-module (playnet vf schemas)
  #:export (%make-regenerating-stock
            make-regenerating-stock
            *regenerating-stocks*
            register-regenerating-stock!
            regenerating-stock-ref
            clear-regenerating-stocks!
            regenerating-stock->resource
            regenerating-stock-resources
            regenerating-stock-storables
            stock-draw-flow
            stock-restore-flow))


;; a type is its name — the same object on both sides of the load seam

(define-vf-record <regenerating-stock> RegeneratingStock
  (spec name place init unit)
  #:prefix rstock)
  ;; the good whose LEVEL is the condition (e.g. "soil-fertility")
  ;; human label
  ;; where the stock stands (the land, the workshop, the basin)
  ;; starting level S0 — a real measurement   ; the level's unit (a stock index, kg N, m of head, tonnes)
(define %make-regenerating-stock (vf-record-constructor <regenerating-stock>))
;; unit optional — a bare index needs no unit.
(define* (make-regenerating-stock spec name place init #:optional (unit "unit"))
  (%make-regenerating-stock spec name place init unit))

;; The registry — seeded config, like the bioregion/SpatialThing tables. reset!
;; leaves it (a stock is a fact about the world, not per-solve state).
(define *regenerating-stocks* '())
(define (register-regenerating-stock! rs)
  (set! *regenerating-stocks*
        (cons rs (filter (lambda (o) (not (equal? (rstock-spec o) (rstock-spec rs))))
                         *regenerating-stocks*)))
  rs)
(define (regenerating-stock-ref spec) (find (lambda (rs) (equal? (rstock-spec rs) spec)) *regenerating-stocks*))
(define (clear-regenerating-stocks!) (set! *regenerating-stocks* '()))

;; ── projection into plan-from-records inputs ────────────────────────────────
;; The stock as an EconomicResource: its onhand IS the starting level, and because
;; the good is produced by a regeneration recipe, the onhand routes to *init* (a
;; starting stock of a producible good) — the planner's own rule. Stationary, so it
;; never travels; it only persists through the storable carry.
(define (regenerating-stock->resource rs)
  (make-economic-resource
   #:id (string-append "stock-" (rstock-spec rs) "-" (rstock-place rs))
   #:name (rstock-name rs) #:conforms-to (rstock-spec rs) #:classified-as (list "stationary")
   #:accounting-quantity (make-measure (rstock-init rs) (rstock-unit rs))       ; accounting quantity
   #:onhand-quantity (make-measure (rstock-init rs) (rstock-unit rs))       ; onhand → *init* (the starting level)
   #:current-location (rstock-place rs)))

;; Everything a caller needs, derived from the registry (or a supplied subset):
(define* (regenerating-stock-resources #:optional (stocks *regenerating-stocks*))
  (map regenerating-stock->resource stocks))
(define* (regenerating-stock-storables #:optional (stocks *regenerating-stocks*))
  (map rstock-spec stocks))                                ; the #:storable list — condition carries in time

;; ── the two flows that MOVE a stock (add to production / regeneration recipes) ──
;; DRAW: a production process spends `qty` of the condition per run — the crop that
;; mines fertility, the run that wears the tool, the pump that lowers the table.
(define* (stock-draw-flow id spec qty proc #:optional (note #f) (unit "unit"))
  (make-recipe-flow #:id id #:action 'consume #:resource-conforms-to spec
                    #:resource-quantity (make-measure qty unit) #:recipe-input-of proc #:note note))
;; RESTORE: a regeneration process REBUILDS `qty` of the condition per run — the
;; compost/biofertiliser, the maintenance shift, the fallow, the recharge; a legume
;; whose grow recipe carries a restore flow FIXES fertility as it produces food.
(define* (stock-restore-flow id spec qty proc #:optional (note #f) (unit "unit"))
  (make-recipe-flow #:id id #:action 'produce #:resource-conforms-to spec
                    #:resource-quantity (make-measure qty unit) #:recipe-output-of proc #:note note))
