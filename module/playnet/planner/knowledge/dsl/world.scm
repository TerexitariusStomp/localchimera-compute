;;; world.scm — an economy as data, and the two doors that read it.
;;;
;;; A <world> is what a scope's stores hold: resource specs, recipe processes,
;;; their flows, the recipes, the places, the agents and the resources they
;;; hold. It is the unit a knowledge seeder exports (the bread town, a farm
;;; commune, the federation demo) and the unit a suite plans over, so the
;;; economy a test proves is the economy the gateway seeds — one record, no
;;; second copy to drift.
;;;
;;;   (world #:specs … #:procs … #:flows … #:recipes … #:spatials … #:agents … #:resources …)
;;;   (world-with w #:agents …)          the same economy, some tables replaced
;;;   (world-append a b …)               the union — a town and its transport arm
;;;   (seed-world! scope w)              into a scope-root's real stores; idempotent by id
;;;   (seed-world-recipes! rs w)         the chain alone into a recipe-store
;;;                                      (what `make lint-recipes` sweeps)
;;;   (world-flows-for w pid)            the flows naming process PID
;;;
;;; The mocked door — stores that answer with these tables and nothing else —
;;; is (playnet test scope) mock-world. Every `$` here is a near-call.

(define-module (playnet planner knowledge dsl world)
  #:use-module ((playnet utils units) #:select (%count-unit))
  #:use-module (playnet planner formulas actions)
  #:use-module (playnet planner vf schemas)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module ((playnet planner knowledge catalogues substances) #:select (food-energy-made light-needed water-needed rated-kw area-m2 %sunlight %rain %air water-drawn water-kept water-split oxygen-released carbon-for leaf-needed heat-drawn latent-heat-kwh-per-kg recipe-flows->derivation composition-of-scope water-form? litres-per-unit balance-flows flow-action flow-spec))
  #:use-module ((playnet planner knowledge dsl shorthand) #:select (rp* flow* use* out* consume* er))
  #:use-module ((playnet utils clock) #:select (month-now))   ; today's month, off the one clock
  #:export (world world? world-with world-append
            world-specs world-procs world-flows world-recipes
            world-spatials world-agents world-resources
            world-flows-for world-chain world-sunlit world-watered world-aired world-rooted world-sky
            seed-world! seed-world-recipes! store-flows store-derivations store-composition))

(define-record-type <world>
  (%make-world specs procs flows recipes spatials agents resources)
  world?
  (specs world-specs) (procs world-procs) (flows world-flows) (recipes world-recipes)
  (spatials world-spatials) (agents world-agents) (resources world-resources))

(define* (world #:key (specs '()) (procs '()) (flows '()) (recipes '())
                      (spatials '()) (agents '()) (resources '()))
  (%make-world specs procs flows recipes spatials agents resources))

(define* (world-with w #:key (specs (world-specs w)) (procs (world-procs w))
                           (flows (world-flows w)) (recipes (world-recipes w))
                           (spatials (world-spatials w)) (agents (world-agents w))
                           (resources (world-resources w)))
  (%make-world specs procs flows recipes spatials agents resources))

(define (world-append . ws)
  (define (all get) (append-map get ws))
  (%make-world (all world-specs) (all world-procs) (all world-flows) (all world-recipes)
               (all world-spatials) (all world-agents) (all world-resources)))

(define (world-flows-for w pid)
  "The flows that name process PID as their input or output."
  (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid)
                          (equal? (recipe-flow-recipe-output-of f) pid)))
          (world-flows w)))

(define (world-chain w rid)
  "The processes of recipe RID in declaration order — the ones it names, or,
   for a recipe that names none, every process in the world."
  (let* ((r (find (lambda (r) (equal? (recipe-id r) rid)) (world-recipes w)))
         (named (and r (recipe-recipe-processes r))))
    (if (and named (pair? named))
        (filter-map (lambda (pid) (find (lambda (p) (equal? (recipe-process-id p) pid)) (world-procs w)))
                    named)
        (world-procs w))))

;; THE SUN IN EVERY GROW, derived: a process whose products carry food energy that
;; its inputs lack makes it from light or from nothing, and the first law on the
;; energy leaf (vf-lint `photosynthesis`) refuses nothing. So each such process
;; consumes the sunlight growing its products needs (catalogues/substances.scm `sunlight-for`:
;; the kilocalories over the share a crop stores), and the sunlight spec stands
;; beside the world's own. A mill or a bake, whose inputs carry the energy, is left
;; alone, and so is a harvest that consumes nothing (fish, milk): the law is read
;; where substance enters. Sunlight is a boundless ambient flow (engine.scm
;; *ambient-flows*) wherever nothing makes it; where the world holds LAND (a spec
;; counted in an area unit) the land shines: one process per land spec uses a
;; unit of it through the period and produces the light that falls on it,
;; the land's rating times the season's hours (catalogues/substances.scm `rated-kw`: the
;; insolation by latitude and month over the day, times the area), and at that
;; cell sunlight is a good
;; the engine balances, so a field's yield is bounded by its area and its
;; season. A grow that compresses a season into one period states SEASON-DAYS.
;; what one land spec's shine brings the world: its process, flows, recipe, and
;; the sky over the land with the one of it that stands at the land's place
(define-record-type <shine> (make-shine proc flows recipe sky standing) shine?
  (proc shine-proc) (flows shine-flows) (recipe shine-recipe) (sky shine-sky) (standing shine-standing))
(define (world-spec w id)
  "W's resource specification ID, or #f."
  (find (lambda (s) (equal? id (resource-specification-id s))) (world-specs w)))
(define (spec-if-absent w id name unit)
  "The spec ID as a one-element list to append, or none when W already holds it."
  (if (world-spec w id) '() (list (make-resource-specification #:id id #:name name
                                                               #:default-unit-of-resource unit))))
(define (substance-flows w pid) (balance-flows (world-flows-for w pid)))   ; a process's flows of substance, each in its basis
(define (flow-stated? flows action spec)
  "Does FLOWS already carry a flow of ACTION on SPEC?"
  (any (lambda (f) (and (eq? action (flow-action f)) (equal? spec (flow-spec f)))) flows))
(define* (world-stating w action spec unit need #:key (on? (lambda (flows) #t)) (stated? (lambda (flows) (flow-stated? flows action spec))))
  "W with a flow of ACTION on SPEC stated on every process that has a consume (a
   process consuming nothing is a HARVEST at the boundary, the author's word until
   it names its stock), satisfies ON? and does not yet satisfy STATED? over its
   substance flows; NEED maps those flows to the quantity, in UNIT, and a need of
   nothing states nothing. A fixed point: what is stated is left as it is. The one
   shape behind the light, the water, the air and the vapour. Returns
   (values w-with-flows added-flows)."
  (let ((added (filter-map
                (lambda (p)
                  (let* ((pid (recipe-process-id p)) (flows (substance-flows w pid)))
                    (and (any (lambda (f) (input-action? (flow-action f))) flows)
                         (on? flows) (not (stated? flows))
                         (let ((q (need flows)))
                           (and (> q 1e-9)
                                (flow* (string-append pid "-" spec) action spec q pid unit))))))
                (world-procs w))))
    (values (if (null? added) w (world-with w #:flows (append (world-flows w) added))) added)))
(define (world-drawing w spec unit need stated?)
  "W with a consume of SPEC stated on every process that makes food energy and does
   not yet satisfy STATED? (world-stating): what the light, the water and the air
   are drawn for is a grow."
  (world-stating w 'consume spec unit need #:on? (lambda (flows) (> (food-energy-made flows) 1e-12)) #:stated? stated?))

(define* (world-sunlit w #:key (lat #f) (month #f) (season-days 1) (period-hours 24.0) (rain-mm-day #f))
  "W with the light its grows draw stated: for every process producing more food
   energy than it consumes, a consume of \"sunlight\" in kWh sized by sunlight-for;
   and for every land spec, the shine that bounds it. The shine's MEANS is the sky
   over the land: a derived keep-in-place spec, one standing at the land's place,
   used once through the period, so a shine runs once a period whatever the land
   is spent on below it, and is sized by all the land the world holds of the spec
   (one unit where it holds none). With RAIN-MM-DAY the shine also rains, into
   whatever the world's grows drink from: the water form some process consumes,
   in its own unit through the one bridge (a farm's megalitres), else \"rain\"
   in litres. The sky's two gifts fall on the one land through the one use."
  (call-with-values
    (lambda () (world-drawing w %sunlight "kWh"
                              light-needed
                              (lambda (flows) (any (lambda (f) (and (input-action? (flow-action f)) (equal? %sunlight (flow-spec f)))) flows))))
    (lambda (w lit)
      (let* ((has-sun? (world-spec w %sunlight))
             ;; the water the field drinks from: a water form some process consumes, else the rain
             (drinks (or (any (lambda (f) (and (memq (recipe-flow-action f) using-up-actions)
                                               (let ((sp (recipe-flow-resource-conforms-to f)))
                                                 (and sp (not (equal? sp %rain)) (water-form? sp) (world-spec w sp)))))
                              (world-flows w))
                         (world-spec w %rain)))
             (rain-spec (if drinks (resource-specification-id drinks) %rain))
             (rain-unit (if drinks (or (resource-specification-default-unit-of-resource drinks) "L") "L"))
             (rain-per-litre (/ 1.0 (or (litres-per-unit rain-spec rain-unit) 1.0)))   ; units of the form in a litre
             (shines? (lambda (pid) (any (lambda (p) (equal? pid (recipe-process-id p))) (world-procs w))))
             ;; latitude from the first place that states one, the month from today unless
             ;; stated, so the test stands on today like every fixture
             (lat* (or lat (any spatial-thing-lat (world-spatials w)) 0.0))
             (month* (or month (month-now)))
             (first-place (and (pair? (world-spatials w)) (spatial-thing-id (car (world-spatials w)))))
             ;; all the land the world holds of a spec, and where the first of it stands
             (holdings (lambda (land)
                         (let ((rs (filter (lambda (r) (equal? land (economic-resource-conforms-to r))) (world-resources w))))
                           (cons (apply + (map (lambda (r) (or (and=> (economic-resource-onhand-quantity r) measure-has-numerical-value) 0.0)) rs))
                                 (or (and (pair? rs) (economic-resource-current-location (car rs))) first-place)))))
             ;; the land shines where a grow draws light, where the sun is already a spec,
             ;; or where it is told its rain: a field the sky waters has its shine
             (shine (if (and (null? lit) (not has-sun?) (not rain-mm-day)) '()
                        (filter-map
                         (lambda (s)
                           (let ((m2-unit (area-m2 (resource-specification-default-unit-of-resource s))))
                             (and m2-unit (not (shines? (string-append "shine~" (resource-specification-id s))))
                                  (let* ((land (resource-specification-id s)) (pid (string-append "shine~" land))
                                         (sky (string-append "sky~" land))
                                         (held (holdings land))
                                         (units (if (> (car held) 0.0) (car held) 1.0))
                                         (m2 (* m2-unit units))
                                         ;; the land's RATING is the sun's (catalogues/substances.scm rated-kw): what a
                                         ;; unit of it passes per hour, over the season's hours, over all of it
                                         (kwh (* (rated-kw land #:unit (resource-specification-default-unit-of-resource s) #:lat lat* #:month month*)
                                                 period-hours season-days units)))
                                    ;; the light is a SUPPLY through the period, no step before the grow,
                                    ;; so the shine states no run length (the engine's within-band
                                    ;; coherence reads a duration-less process as making no temporal
                                    ;; claim); the sky over the land is used once for the period's hours
                                    ;; the shine IS the edge and says so: the sky speaking, judged by no balance
                                    (make-shine (rp* pid (string-append "The sky on " land) #:tags '("boundary"))
                                          (append
                                           (list (use* (string-append pid "-sky") sky pid period-hours #:qty 1.0 #:unit "each")
                                                 (out* (string-append pid "-light") %sunlight kwh pid "kWh"))
                                           ;; a millimetre on a square metre is a litre, landing in the field's own water, in
                                           ;; its unit: the sky's rain, drawn at the boundary, becomes the stock the field
                                           ;; drinks from, so the water's atoms and heat enter the books as what they are
                                           (if rain-mm-day
                                               (let ((litres (* rain-mm-day m2 season-days)))
                                                 (append (if drinks (list (consume* (string-append pid "-sky-rain") %rain litres pid "L")) '())
                                                         (list (out* (string-append pid "-rain") rain-spec (* litres rain-per-litre) pid rain-unit #:primary #f))))
                                               '()))
                                          (make-recipe #:id (string-append "r-" pid)
                                                       #:name (string-append "The sky on " land)
                                                       #:primary-output %sunlight
                                                       #:recipe-processes (list pid))
                                          (make-resource-specification #:id sky
                                                                       #:name (string-append "The sky over " land)
                                                                       #:default-unit-of-resource %count-unit
                                                                       #:keep-in-place #t)
                                          (er (string-append sky "@" (or (cdr held) "here")) sky #f #:name (string-append "the sky over " land)
                                              #:place (or (cdr held) "town") #:qty 1.0 #:unit %count-unit))))))
                         (world-specs w)))))
        (if (and (null? lit) (null? shine)) w
            (world-with w
                        #:specs (append (spec-if-absent w %sunlight "Sunlight" "kWh")
                                        (if (or (not rain-mm-day) (null? shine)) '() (spec-if-absent w %rain "Rain" "L"))
                                        (map shine-sky shine)
                                        (world-specs w))
                        #:procs (append (world-procs w) (map shine-proc shine))
                        #:flows (append (world-flows w) (append-map shine-flows shine))
                        #:recipes (append (world-recipes w) (map shine-recipe shine))
                        #:resources (append (world-resources w) (map shine-standing shine))))))))

;; THE WATER: the sun's pattern once more. A grow transpires at least its crop's
;; pathway's litres for every kilocalorie it stores (catalogues/substances.scm *pathways*,
;; water-for); a grow that names no water at all draws it as rain, boundless where
;; no land rains and bounded where the shine states its millimetres. A grow that
;; names its water (irrigation, a well) is the author's word, and the lint
;; `transpiration` judges it.
(define (world-watered w)
  "W with the water its grows draw stated: a consume of \"rain\" in litres, sized by
   water-for, on every process making food energy from inputs carrying no water;
   and on every process that draws water, the vapour it breathes out: what it drew
   less what its products keep, as \"h2o-g\", so the water it transpires leaves
   the books as the vapour it is."
  (call-with-values
    (lambda () (world-drawing w %rain "L"
                              water-needed
                              (lambda (flows) (> (water-drawn flows) 0.0))))
    (lambda (w added)
      ;; what a process drew of water and its products do not keep leaves the books as
      ;; what it is, on the produce side, for every process that draws water: as VAPOUR
      ;; as far as the heat the process draws can lift it (heat-drawn over the latent
      ;; heat: a grow's light, a mill's power, the sun on a salt pan), and as the LIQUID
      ;; it still is beyond that, drained to the ground (a field given more than its
      ;; sun can breathe out loses the rest to the soil, with no heat spent on it). So
      ;; the first law closes over the water either way, and the vapour never outruns
      ;; the power that made it.
      ;; A grow also SPLITS water: the hydrogen its dry matter holds came out of the
      ;; water it drew (water-split), which therefore left as neither vapour nor
      ;; liquid, its oxygen returned to the air (world-aired).
      (let* ((lost (lambda (flows) (max 0.0 (- (water-drawn flows) (water-kept flows)
                                               (if (> (food-energy-made flows) 1e-12) (water-split flows) 0.0)))))
             (breathed (lambda (flows) (min (lost flows) (/ (heat-drawn flows) (latent-heat-kwh-per-kg)))))
             (drained (lambda (flows) (- (lost flows) (breathed flows))))
             (draws? (lambda (flows) (> (water-drawn flows) 0.0))))
        (call-with-values
          (lambda () (world-stating w 'produce "h2o-g" "kg" breathed #:on? draws?))
          (lambda (w breath)
            (call-with-values
              (lambda () (world-stating w 'produce "h2o" "kg" drained #:on? draws?))
              (lambda (w drain)
                (if (and (null? added) (null? breath) (null? drain)) w
                    (world-with w
                                #:specs (append (if (null? added) '() (spec-if-absent w %rain "Rain" "L"))
                                                (if (null? breath) '() (spec-if-absent w "h2o-g" "Water vapour" "kg"))
                                                (if (null? drain) '() (spec-if-absent w "h2o" "Water, drained to the ground" "kg"))
                                                (world-specs w))))))))))))

;; THE AIR: a crop fixes its carbon from the air's carbon dioxide (catalogues/substances.scm
;; carbon-for); a grow that names no carbon source draws it as \"co2\", the
;; sky's third gift, boundless like the light and the rain where nothing bounds it.
(define (world-aired w)
  "W with the carbon dioxide its grows fix stated: a consume of \"co2\" in kg, sized
   by carbon-for, on every process making food energy that names no carbon dioxide;
   a grow whose carbon came in with its inputs (a feed, a soil row) draws none. And
   the oxygen they let go: a produce of \"o2\" in kg, what the grow drew of oxygen
   in its carbon dioxide and its water over what its harvest and its vapour hold
   (oxygen-released), so a leaf's books close on oxygen as a body's do, the other
   way round."
  (call-with-values
    (lambda () (world-drawing w %air "kg" carbon-for
                              (lambda (flows) (or (<= (carbon-for flows) 1e-9)
                                                  (any (lambda (f) (and (input-action? (flow-action f)) (equal? %air (flow-spec f)))) flows)))))
    (lambda (w added)
      (let ((w (if (null? added) w
                   (world-with w #:specs (append (spec-if-absent w %air "Carbon dioxide" "kg") (world-specs w))))))
        (call-with-values
          (lambda () (world-stating w 'produce "o2" "kg" oxygen-released
                                    #:on? (lambda (flows) (> (food-energy-made flows) 1e-12))))
          (lambda (w freed)
            (if (null? freed) w
                (world-with w #:specs (append (spec-if-absent w "o2" "Oxygen" "kg") (world-specs w))))))))))

;; THE SOIL: what a harvest carries of nitrogen, phosphorus and potassium over what
;; its inputs brought came out of the ground, so a grow draws it from the soil's
;; plant-available stores (catalogues/substances.scm soil-n, soil-p, soil-k), stated on every
;; grow that names no draw of that store, as the light, the water and the air are.
;; The store's size is the world's stock to state (a farm's, per hectare), and the
;; first law then refuses a harvest richer than its field.
(define %soil-stores '(("N" "soil-n" "Soil nitrogen") ("P" "soil-p" "Soil phosphorus") ("K" "soil-k" "Soil potassium")))
(define (world-rooted w)
  "W with the soil its grows draw stated: a consume of soil-n, soil-p and soil-k, in
   kg, sized by what the harvest carries over its inputs (leaf-needed), on every
   process making food energy that names no draw of that store."
  (fold (lambda (store w)
          (let ((leaf (car store)) (spec (cadr store)) (name (caddr store)))
            (call-with-values
              (lambda () (world-drawing w spec "kg" (lambda (flows) (leaf-needed flows leaf))
                                        (lambda (flows) (flow-stated? flows 'consume spec))))
              (lambda (w added)
                (if (null? added) w
                    (world-with w #:specs (append (spec-if-absent w spec name "kg") (world-specs w))))))))
        w %soil-stores))

;; THE SKY AND THE SOIL, once: light, water, air and the ground's stores on every grow, in that order
(define* (world-sky w #:key (lat #f) (month #f) (season-days 1) (period-hours 24.0) (rain-mm-day #f))
  "W sunlit, watered, aired and rooted: the one call a seeder makes, the sky above
   and the soil below."
  (world-rooted (world-aired (world-watered (world-sunlit w #:lat lat #:month month #:season-days season-days
                                                          #:period-hours period-hours #:rain-mm-day rain-mm-day)))))

;; WHAT A STORE STANDS ON. A recipe store's processes as the derivation reads them,
;; and the composition its recipes, its stated rows and the table give it
;; (catalogues/substances.scm composition-of-scope): the one reading the live door hands the
;; solve and the lint judges a recipe by.
(define (store-flows rs pid)
  "Process PID's flows on recipe store RS, each once: a store answers a process's
   flows in two sides, what flows into it and what flows out, and a flow that states
   both ends stands on both."
  (let ((io ($ rs 'flows-for-process pid)))
    (delete-duplicates (append (car io) (cdr io))
                       (lambda (a b) (or (eq? a b) (and (recipe-flow-id a) (equal? (recipe-flow-id a) (recipe-flow-id b))))))))
(define (store-derivations rs)
  "Recipe store RS's processes as ((pid consumed produced primary) …). Every recipe
   is asked for its chain, the one method every sweep over a recipe's processes
   uses, so a store that answers those answers this; a store with nothing to say
   gives '()."
  (append-map
   (lambda (r)
     (filter-map (lambda (rp) (recipe-flows->derivation (recipe-process-id rp) (store-flows rs (recipe-process-id rp))))
                 ($ rs 'get-process-chain (recipe-id r))))
   ($ rs 'all-recipes)))
(define (store-composition rs)
  "The composition recipe store RS stands on, in the shape the solve reads."
  (composition-of-scope (store-derivations rs)
                        #:stated (or (false-if-exception ($ rs 'stated-compositions)) '())
                        #:units (specs->units (or (false-if-exception ($ rs 'all-resource-specs)) '()))))

(define (seed-world-recipes! rs w)
  "The chain into RS: specs, processes, flows, recipes. Every add replaces by id."
  (for-each (lambda (s) ($ rs 'add-resource-spec s)) (world-specs w))
  (for-each (lambda (p) ($ rs 'add-recipe-process p)) (world-procs w))
  (for-each (lambda (f) ($ rs 'add-recipe-flow f)) (world-flows w))
  (for-each (lambda (r) ($ rs 'add-recipe r)) (world-recipes w))
  rs)

(define (seed-world! scope w)
  "The whole economy into SCOPE's stores. Returns W."
  (seed-world-recipes! ($ scope 'recipe-store) w)
  (let ((sts ($ scope 'spatial-thing-store)) (as ($ scope 'agent-store)) (obs ($ scope 'observer)))
    (for-each (lambda (st) ($ sts 'add-location st)) (world-spatials w))
    (for-each (lambda (a) ($ as 'add-agent a)) (world-agents w))
    (for-each (lambda (r) ($ obs 'record-resource r)) (world-resources w)))
  w)
