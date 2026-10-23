;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; farm-commune-seed.scm — ONE generic seeder for a live farm/garden commune, placed in
;;; a bioregion under earth. seed-berlin-commune! and seed-bay-area-commune! are now thin
;;; config wrappers over this: a farm is DATA — its crops, where it sits in the containment
;;; tree, its scarce land/water/labour — and the mechanism (specs, grow recipes, commune +
;;; worker, the placement that inherits the shed's futures + limits) is shared.
;;;
;;; Loaded before the per-region wrappers; every `$` is a near-call,
;;; so call within the scope-root's vat.

;; crops: ((name . (summer-water-ML/ha . yield-kg/ha)) …). `tree` = the SpatialThings ABOVE
;; the farm (biosphere → shed → [city]), already built with make-spatial-thing; the farm
;; hangs under `parent`. All ids derive from `place`, so two communes never collide.
(define-module (playnet knowledge recipes farm-commune-seed)
  #:use-module ((playnet utils units) #:select (%count-unit %effort-unit))
  #:use-module (playnet vf schemas)
  #:use-module (playnet knowledge dsl shorthand)
  #:use-module (playnet knowledge dsl world)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet knowledge recipes transport) #:select (recipe-hold seed-baseline-modes!))
  #:use-module ((playnet knowledge catalogues subsistence) #:select (shed-rain-mm-day))
  #:export (farm-world seed-farm-commune! seed-holds! seed-farm-holds!))

;; ── a seeded stock reaches tomorrow: the ground HOLDS it ─────────────────────
;; A solve lays its stocks at period 0; what carries into a later day is what
;; the scope's own knowledge says carries (live.scm scope-resource-specs) —
;; storability is a fact about what the scope HAS, never a keyword a caller
;; remembers. So a seed that wants its land, water and pits to be there on
;; day two of a multi-day horizon says so the way any store does: a HOLD
;; recipe per stock (transport.scm recipe-hold — pick it up, `use` a
;; container, drop it off), through a container the seed registers
;; keep-in-place. The engine reads the arc off that flag (proc-temporal?),
;; so the pair tiles along the TIME edge and the stock is there tomorrow.
;;
;; A recipe is location-agnostic: the engine tiles it at every cell where its
;; inputs stand. So there is ONE keep-in-place spec per scope — `ground` —
;; and one hold recipe per good ("Keep pit in place", once), and what makes
;; the hold available at a place is the ground resource STANDING there: a
;; `use` draws the container's Svc| hours at the cell its resource occupies,
;; and a service the scope holds nothing of has no hours to draw (engine
;; svc-held?). An earlier seed minted a spec per place and a recipe per
;; (good, place) — twelve "Keep pit in place" on the recipes face, differing
;; only by which ground they used; a durable store sheds those on the boot
;; that introduces the one spec: the per-place recipes are retired and each
;; place's ground resource re-pointed (seed-resource replaces by id). The
;; per-place specs themselves linger unused — the store has no spec-removal
;; door — and nothing reads them.
;; The ground is not scarce: no capacity is seeded for the container, so its
;; Svc| draw is unbounded and the hold costs the plan nothing but its
;; existence. Idempotent by id.
(define %ground-spec "ground")
;; the land is a durable the grow USES through the period (keep-in-place, as the sky over
;; it is): stated once, seeded by farm-world and re-registered by the boot door so a
;; durable store's land carries the flag
(define %land-spec (spec* "land" "Land" "ha" #:keep-in-place #t))
(define* (seed-holds! rs obs place specs #:key (container %ground-spec)
                                              (container-name "The ground") (holder #f))
  "What the scope HAS, so that its stocks are there tomorrow: CONTAINER as the
   scope's keep-in-place spec (registered when absent) and one of it standing at
   PLACE on OBS, named CONTAINER-NAME, held by HOLDER. Storage itself is
   mechanism — live.scm composes the keep of every good through every
   keep-in-place durable the scope holds — so nothing is classified and no recipe
   enters the library; SPECS names the stocks whose earlier hold recipes are
   retired. A spec named in SPECS that the store lacks is registered with its
   unit, so the good exists to be kept."
  (unless ($ rs 'get-resource-spec container)
    ($ rs 'add-resource-spec
       (make-resource-specification #:id container #:name container-name #:default-unit-of-resource %count-unit
                                    #:keep-in-place #t)))
  (let* ((rid (string-append container "-" place))
         (standing ($ obs 'get-resource rid)))
    (unless (and standing (equal? (economic-resource-conforms-to standing) container))
      ($ obs 'record-resource
         (make-economic-resource #:id rid #:name container-name #:conforms-to container #:classified-as '()
                                 #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit)
                                 #:current-location place #:primary-accountable holder))))
  (for-each
   (lambda (su)
     (let ((id (car su)))
       (unless ($ rs 'get-resource-spec id)
         ($ rs 'add-resource-spec (make-resource-specification #:id id #:name id
                                                               #:default-unit-of-resource (cdr su))))
       (for-each (lambda (old) (when ($ rs 'get-recipe-process old)
                                 (format (current-error-port) "  [holds] retiring ~a — storage is mechanism, not a recipe~%" old)
                                 ($ rs 'retire-recipe-process old)))
                 (list (string-append "hold-" id) (string-append "hold-" id "-" place)))))
   specs)
  (let ((old (string-append "keep-" container)))
    (when ($ rs 'get-recipe-process old)
      (format (current-error-port) "  [holds] retiring ~a — storage is mechanism, not a recipe~%" old)
      ($ rs 'retire-recipe-process old))))

(define (%unattributed r)                     ; the same record, held by nobody in particular — a seed's tenure
  (let* ((rtd <economic-resource>) (fields (record-type-fields rtd)))
    (apply (record-constructor rtd)
           (map (lambda (f) (if (eq? f 'primary-accountable) #f ((record-accessor rtd f) r))) fields))))
(define* (seed-farm-holds! scope place #:key (holder #f))
  "The farm's stocks reach tomorrow: the ground standing at PLACE, on a scope
   that already carries the farm — the boot door for a DURABLE commune.
   Idempotent by id. A durable store seeded when the farm's land, water and
   ground were attributed to the `commune-<place>` organization — an id the
   solve's tenure view does not read as the commune — has them re-seeded
   unattributed on this boot, so they enter the plan; and its land spec is
   restated as the durable the grow uses (%land-spec), so a store seeded when
   land was spent per run carries the flag on this boot."
  (let ((obs ($ scope 'observer)) (org (string-append "commune-" place)))
    ($ ($ scope 'recipe-store) 'add-resource-spec %land-spec)
    (for-each (lambda (rid)
                (let ((r ($ obs 'get-resource rid)))
                  (when (and r (equal? (economic-resource-primary-accountable r) org))
                    (format (current-error-port) "  [tenure] ~a held by ~a — re-seeded unattributed, the commune's own~%" rid org)
                    ($ obs 'record-resource (%unattributed r)))))
              (list (string-append "land-" place) (string-append "water-" place)
                    (string-append %ground-spec "-" place)))
    (seed-holds! ($ scope 'recipe-store) obs place '(("water" . "ML")) #:holder holder)))

(define* (farm-world #:key (crops '()) (place "farm") (place-name "Farm")
                           (lat 0.0) (lon 0.0) (parent "biosphere") (tree '())
                           (skill "farming") (skill-label "Farm labour")
                           (skill-hours 400.0) (worker-name "Grower")
                           (commune-name "Commune")
                           (land-ha 2.0) (water 6.0) (labour-h 2.0)
                           ;; the worker's classifiedAs tags. The skills a
                           ;; travel mode asks ("walk", "cycle", …) can sit
                           ;; here: a shed with modes reads them off the
                           ;; person (workers->riders!'s mobility-skills),
                           ;; folded into the SAME skills list the worker's
                           ;; work-skill ("farming") already rides in.
                           (worker-tags '())
                           ;; what the shed's record says falls on the fields in a day of the
                           ;; season (catalogues/subsistence.scm shed-rain-mm-day, off PARENT when
                           ;; it names a shed with a record); the land then rains into the
                           ;; commune's water, in megalitres, and the stock renews as the sky does
                           (rain-mm-day (shed-rain-mm-day parent)))
  "A farm commune as data: CROPS is ((name . (summer-water-ML/ha . yield-kg/ha)) …),
   TREE the SpatialThings ABOVE the farm (biosphere → shed → [city]), the farm
   hanging under PARENT. All ids derive from PLACE, so two communes never collide."
  (let ((commune (string-append "commune-" place)) (worker (string-append "worker-" place))
        (win (map (lambda (d) (cons d (cons 0 24))) '("mon" "tue" "wed" "thu" "fri" "sat" "sun"))))
    ;; light, water and air on every grow, and the land rains into the commune's water (world.scm)
    (define (under-the-sky w) (world-sky w #:lat lat #:rain-mm-day rain-mm-day))
    (under-the-sky
    (world
     ;; the resource specs the crops trade in — food + the three scarce inputs
     #:specs (list (spec* "food" "Food (produce)" "kg") %land-spec
                   (spec* "water" "Summer water" "ML") (spec* skill skill-label %effort-unit))
     ;; one grow recipe per crop: labour + a hectare USED through the period + its water
     ;; demand → produce food at its yield. The land is the durable ground the grow
     ;; stands on (keep-in-place, as the sky over it is): a run occupies a hectare for
     ;; the period, whatever its length, and the land is there tomorrow, so the acreage caps how many
     ;; runs a period carries and nothing spends the field. The work flow is what makes
     ;; the live labour model fire the process (a farm needs farmers); labour is kept
     ;; ample so WATER stays the binding constraint (the drought story).
     #:procs (map (lambda (cw) (rp* (string-append "grow-" (car cw)) (string-append "Grow " (car cw)) 0.1)) crops)
     #:flows (append-map
              (lambda (cw)
                (let ((pid (string-append "grow-" (car cw))) (waterd (cadr cw)) (yield (cddr cw)))
                  (list (wk* (string-append pid "-work") skill labour-h pid)
                        ;; a hectare held for the whole period, however long the period is: a
                        ;; band of three hours or a day (use with no duration reads as the period)
                        (use* (string-append pid "-land") "land" pid #f #:qty 1.0 #:unit "ha")
                        (consume* (string-append pid "-water") "water" waterd pid "ML")
                        (out* (string-append pid "-food") "food" yield pid))))
              crops)
     #:recipes (map (lambda (cw) (let ((pid (string-append "grow-" (car cw))))
                                   (make-recipe #:id (string-append "r-" pid)
                                                #:name (string-append "Grow " (car cw))
                                                #:primary-output "food"
                                                #:recipe-processes (list pid))))
                    crops)
     ;; containment: the tree above (biosphere ⊃ shed ⊃ …), then the farm under `parent`.
     ;; Placing the farm in the shed is what makes the live solve inherit the shed's futures
     ;; + limits by the containment walk.
     #:spatials (append tree (list (make-spatial-thing #:id place #:name place-name #:lat lat
                                                       #:long lon #:contained-in parent)))
     ;; the commune (keeps the land + water) and a worker who works the fields
     #:agents (list (make-agent #:id commune #:type 'organization #:name commune-name
                                #:primary-location place #:classified-as '())
                    (make-agent #:id worker  #:type 'person       #:name worker-name
                                #:primary-location place #:classified-as worker-tags
                                #:availability-window win))
     ;; the commune's own stocks, UNATTRIBUTED — the tenure the solve's view
     ;; reads (socialization commune-resource-view): a resource enters iff the
     ;; commune holds it as owner or custodian BY ITS AID, is labour, or is a
     ;; bare seed with neither field. The organization above is not the
     ;; commune's AID — that is minted when the scope is spawned — so a stock
     ;; attributed to it was dropped from every solve: Berlin's farm, SF's and
     ;; Oakland's gardens planned landless and waterless (measured live: the
     ;; view held the skills and the pits and nothing the farm owns).
     #:resources (list (er (string-append "land-" place) "land" #f #:name "commune land"
                           #:place place #:qty land-ha #:unit "ha")
                       (er (string-append "water-" place) "water" #f #:name "commune water"
                           #:place place #:qty water #:unit "ML")
                       (er (string-append "skill-" place) skill worker #:name "the worker's hours"
                           #:place #f #:qty skill-hours #:unit %effort-unit))))))

(define* (seed-farm-commune! scope . args)
  "The farm (farm-world, same keywords) into SCOPE's stores, its water held so it
   is there tomorrow (the land is a durable and stands of itself). Returns the
   place id."
  (let ((place (or (and=> (memq #:place args) cadr) "farm")))
    (seed-world! scope (apply farm-world args))
    (seed-baseline-modes! ($ scope 'recipe-store))               ; every scope can walk, ride a bike and drive
    ;; the water is there tomorrow: the ground holds it (above); an earlier seed's
    ;; hold of the land is retired by the name it carried
    (seed-holds! ($ scope 'recipe-store) ($ scope 'observer) place '(("water" . "ML") ("land" . "ha")))
    place))
