;;; bread-commune-seed.scm — the bread town, as a <world>.
;;;
;;; The grow→mill→bake chain in one town is the economy the live suites share
;;; ((playnet test planner bread)) and the economy the dev gateway's demo
;;; commune plans over (server/gateway.scm, PLAYNET_SEED_DEMO). Both read the
;;; one world below: the fixture mocks stores that answer with its tables
;;; ((playnet test scope) mock-world) or seeds it into a real scope-root, the
;;; seeder writes it into the demo commune's stores. One record, so a test
;;; that proves the chain, the demo a fresh dial lands on, and the preset a
;;; scope starts from cannot drift apart a skill or a window at a time.
;;;
;;;   bread-world        grow (soil→grain, 0.5 h/run), mill (1.2 grain→flour, 0.3 h/run),
;;;                      bake (flour→bread, 0.5 h/run); soil, grain, flour, bread in kg and
;;;                      the three skills in hours; 1000 soil; farmer's skill-farm, ada's
;;;                      skill-bake + skill-mill, bob's skill-bake + skill-fish; one place,
;;;                      "town"; farmer, ada, bob every day 09:00–17:00 (a declared clock,
;;;                      so every day refines into bands). And the REST OF THE TABLE: a
;;;                      town that plans its people's reproduction feeds them the whole
;;;                      band the subsistence catalogue states, and grain alone cannot —
;;;                      no meal under a body's energy ceiling reaches its vitamin K, E,
;;;                      D or calcium from wheat. So the town also grows beans, greens
;;;                      and rapeseed (pressed to oil at the mill), fishes, and milks:
;;;                      the smallest table off which the engine feeds a woman, a man, a
;;;                      pregnant woman, an elder and a child under every floor and
;;;                      ceiling (vitamin D from food asks fish; calcium under the iron
;;;                      ceiling asks milk; vitamin E asks an oil; a child's sodium
;;;                      floor asks salt, else bread carries it and its selenium with it,
;;;                      so the town also makes salt from the sea). A suite that asks
;;;                      only for bread sees these processes stand idle.
;;;   bread-plain-world  the SECOND configuration of the same economy — one worker per
;;;                      skill (f / m / b), no clock, so every day stays one period
;;;   bread-world-at     the plain world over SOIL kg of soil
;;;   seed-bread-recipes!  the chain into a recipe-store (`make lint-recipes` sweeps every
;;;                        seed-* the umbrella exports)
;;;   seed-bread-commune!  the town into a scope's stores; #:world picks the configuration
;;;
;;; The record lists (bread-procs, bread-flows, …) are the world's own tables,
;;; exported for the suites that read one table. Every `$` is a near-call.

(define-module (playnet knowledge recipes bread-commune-seed)
  #:use-module ((playnet utils units) #:select (%count-unit %effort-unit))
  #:use-module ((playnet utils host) #:select (define-lazy))
  #:use-module (playnet vf schemas)
  #:use-module (playnet knowledge dsl shorthand)
  #:use-module (playnet knowledge dsl world)
  #:use-module (goblins)
  #:export (bread-world bread-plain-world bread-world-at
            bread-procs bread-flows bread-recipes bread-specs
            bread-resources bread-stores bread-storable bread-agents bread-spatials bread-window
            bread-plain-resources bread-plain-agents bread-resources-at
            seed-bread-recipes! seed-bread-commune!))

(define bread-procs
  (list (rp* "grow" "Grow") (rp* "mill" "Mill") (rp* "bake" "Bake")
        ;; the rest of the table (see the header): what a body's band asks that grain cannot carry
        (rp* "grow-beans" "Grow beans") (rp* "grow-greens" "Grow greens")
        (rp* "grow-rapeseed" "Grow rapeseed") (rp* "press" "Press oil")
        (rp* "fish" "Fish") (rp* "milk" "Milk") (rp* "make-salt" "Make salt")
        ;; the sea and the meadow, regrowing the stocks the harvests draw
        (rp* "regrow-fish" "The sea regrows") (rp* "regrow-fodder" "The meadow regrows")))
(define bread-flows
  (list (out* "f1" "grain" 1.0 "grow") (consume* "f2" "soil" 1.0 "grow") (wk* "f3" "skill-farm" 0.5 "grow")
        ;; the mill's other output: what of the grain is not flour leaves as bran, so no
        ;; matter, heat or entropy vanishes at the mill (the second law reads it)
        ;; and the stones turn on power: the mill's heat and its vapour are paid for
        (out* "f4" "flour" 1.0 "mill") (consume* "f5" "grain" 1.2 "mill") (out* "f4b" "bran" 0.17 "mill" #:primary #f)
        (consume* "f5e" "spec-sp-electricity" 0.08 "mill" "kWh") (wk* "f6" "skill-mill" 0.3 "mill")
        ;; a loaf is a third water and the oven is hot: the bake draws its water and its
        ;; power, and breathes out what the crust gave up (world.scm world-watered)
        (out* "f7" "bread" 1.0 "bake") (consume* "f8" "flour" 0.75 "bake") (consume* "f8w" "water" 0.45 "bake" "L")
        (consume* "f8e" "spec-sp-electricity" 0.3 "bake" "kWh") (wk* "f9" "skill-bake" 0.5 "bake")
        ;; each food spec is a *food-nutrition* row (knowledge/catalogues/substances.scm), so
        ;; the live door's eat recipes read its composition off the one table
        (out* "m1" "beans" 1.0 "grow-beans") (consume* "m2" "soil" 1.0 "grow-beans") (wk* "m3" "skill-farm" 0.8 "grow-beans")
        (out* "m4" "greens" 1.0 "grow-greens") (consume* "m5" "soil" 0.5 "grow-greens") (wk* "m6" "skill-farm" 0.5 "grow-greens")
        (out* "m7" "rapeseed" 1.0 "grow-rapeseed") (consume* "m8" "soil" 1.0 "grow-rapeseed") (wk* "m9" "skill-farm" 0.6 "grow-rapeseed")
        ;; the press leaves the cake: what of the seed is not oil is meal, and it keeps its
        ;; energy; parting the oil from the seed is work, and the screw turns on power
        (out* "m10" "rapeseed-oil" 1.0 "press") (consume* "m11" "rapeseed" 2.5 "press") (out* "m10m" "rapeseed-meal" 1.5 "press" #:primary #f)
        (consume* "m11e" "spec-sp-electricity" 0.2 "press" "kWh") (wk* "m12" "skill-mill" 0.4 "press")
        ;; a harvest MOVES a stock and makes nothing: fishing draws the sea's fish (the
        ;; same food, in the sea), milking feeds the herd; the first law on food energy
        ;; then reads both, and the stocks are what an ecology bounds
        (out* "m13" "fish" 1.0 "fish") (consume* "m13s" "fish-stock" 1.0 "fish") (wk* "m14" "skill-fish" 1.0 "fish")
        ;; …and the herd is a body: it drinks, breathes and dungs, so the milk's books
        ;; close over the fodder (physics.md §6: a harvest names its stock, a body its outputs)
        (out* "m15" "dairy" 1.0 "milk") (consume* "m15f" "fodder" 1.5 "milk") (consume* "m15w" "water" 1.0 "milk" "L")
        (consume* "m15o" "o2" 0.8 "milk") (out* "m15c" "co2" 0.8 "milk" #:primary #f) (out* "m15x" "excreta" 0.2 "milk" #:primary #f)
        (wk* "m16" "skill-farm" 0.3 "milk")
        ;; and the stocks REGROW: the sea and the meadow yield through the period, the
        ;; shine's shape (world.scm) — one unit of the water or the land used for the
        ;; day, a day's growth out — so a harvest is bounded by what its stock renews
        (use* "m19" "sea" "regrow-fish" 24.0 #:qty 1.0 #:unit %count-unit) (out* "m20" "fish-stock" 1000.0 "regrow-fish")
        (use* "m21" "meadow" "regrow-fodder" 24.0 #:qty 1.0 #:unit %count-unit) (out* "m22" "fodder" 2000.0 "regrow-fodder")
        ;; salt is measured in GRAMS (catalogues/food-sources.scm): a day's salt is four to six
        ;; of them, and a run makes a hundred for half an hour of raking the pans —
        ;; PRICED per gram, since a barrier settles a costless direction mid-face
        ;; the pans: the salt comes out of the water, and the sun takes the water
        (out* "m17" "salt" 100.0 "make-salt" "g") (consume* "m17w" "water" 3.0 "make-salt" "L")
        (consume* "m17s" "sunlight" 2.5 "make-salt" "kWh") (wk* "m18" "skill-fish" 0.5 "make-salt")))
;; each recipe names its processes: a real recipe-store's get-process-chain
;; sorts exactly these
(define bread-recipes
  (list (make-recipe #:id "bread-recipe"  #:name "Bread" #:primary-output "bread"       
                     #:recipe-processes '("grow" "mill" "bake") #:recipe-exchanges '())
        (make-recipe #:id "beans-recipe"  #:name "Beans" #:primary-output "beans"       
                     #:recipe-processes '("grow-beans") #:recipe-exchanges '())
        (make-recipe #:id "greens-recipe" #:name "Greens" #:primary-output "greens"      
                     #:recipe-processes '("grow-greens") #:recipe-exchanges '())
        (make-recipe #:id "oil-recipe"    #:name "Oil" #:primary-output "rapeseed-oil"
                     #:recipe-processes '("grow-rapeseed" "press") #:recipe-exchanges '())
        (make-recipe #:id "fish-recipe"   #:name "Fish" #:primary-output "fish"        
                     #:recipe-processes '("fish") #:recipe-exchanges '())
        (make-recipe #:id "milk-recipe"   #:name "Milk" #:primary-output "dairy"       
                     #:recipe-processes '("milk") #:recipe-exchanges '())
        (make-recipe #:id "salt-recipe"   #:name "Salt" #:primary-output "salt"        
                     #:recipe-processes '("make-salt") #:recipe-exchanges '())
        (make-recipe #:id "sea-recipe"    #:name "The sea regrows" #:primary-output "fish-stock"
                     #:recipe-processes '("regrow-fish") #:recipe-exchanges '())
        (make-recipe #:id "meadow-recipe" #:name "The meadow regrows" #:primary-output "fodder"    
                     #:recipe-processes '("regrow-fodder") #:recipe-exchanges '())))
(define bread-specs
  (list (spec* "soil" "Soil" "kg") (spec* "grain" "Grain" "kg")
        (spec* "water" "Water" "L") (spec* "spec-sp-electricity" "Electricity" "kWh")
        (spec* "flour" "Flour" "kg") (spec* "bread" "Bread" "kg")
        (spec* "bran" "Bran" "kg")   ; grain by another name: its row, formation and entropy are the grain's (catalogues/substances.scm *composition-aliases*)
        (spec* "beans" "Beans" "kg") (spec* "greens" "Greens" "kg")
        (spec* "rapeseed" "Rapeseed" "kg") (spec* "rapeseed-oil" "Rapeseed oil" "kg") (spec* "rapeseed-meal" "Rapeseed meal" "kg")
        (spec* "o2" "Oxygen" "kg") (spec* "co2" "Carbon dioxide" "kg") (spec* "excreta" "Dung" "kg")
        (spec* "fish" "Fish" "kg") (spec* "dairy" "Milk" "kg") (spec* "salt" "Salt" "g")
        ;; a harvest names its stock: the sea's fish, the herd's feed (physics.md §6)
        (spec* "fish-stock" "Fish in the sea" "kg") (spec* "fodder" "Fodder" "kg")
        ;; …and the stock's ground, a durable used through the day as it regrows
        (spec* "sea" "The sea" %count-unit) (spec* "meadow" "The meadow" %count-unit)
        (spec* "skill-farm" "Farm labour" %effort-unit) (spec* "skill-mill" "Mill labour" %effort-unit)
        (spec* "skill-bake" "Bake labour" %effort-unit) (spec* "skill-fish" "Fishing labour" %effort-unit)))

;; the town's standing stocks beside its soil: the ground's stores the grows root in
;; (world.scm world-rooted), the well and the line. One list, read by every
;; configuration of the town and by a test that lays its own.
(define bread-stores
  (list (er "soil-n-1" "soil-n" #f #:qty 100.0) (er "soil-p-1" "soil-p" #f #:qty 100.0) (er "soil-k-1" "soil-k" #f #:qty 100.0)
        (er "well" "water" #f #:qty 1.0e5 #:unit "L") (er "line" "spec-sp-electricity" #f #:qty 1.0e4 #:unit "kWh")))
(define bread-storable '("soil" "soil-n" "soil-p" "soil-k" "water" "spec-sp-electricity"))   ; what of the town's stock waits from one day to the next
(define bread-resources
  (append
   (list (er "soil-1" "soil" #f #:qty 1000.0))
   bread-stores
   (list
        (er "sea" "fish-stock" #f #:qty 1.0e6) (er "hay" "fodder" #f #:qty 1.0e6)   ; the stocks the harvests draw, ample
        (er "the-sea" "sea" #f #:qty 1.0 #:unit %count-unit) (er "the-meadow" "meadow" #f #:qty 1.0 #:unit %count-unit)
        (er "sk1" "skill-farm" "farmer")
        (er "sk2" "skill-bake" "ada") (er "sk3" "skill-mill" "ada")
        (er "sk4" "skill-bake" "bob") (er "sk5" "skill-fish" "bob"))))

;; EVERY day of the week: a world that declares no partition stands on the
;; standing one, laid from TODAY (engine standing-partition), so a weekday-only
;; window makes every suite over this fixture read a different economy on a
;; Saturday — nobody at work, no `w|` column, no work to emit.
(define bread-window (all-week-window "09:00" "17:00"))
(define bread-agents
  (list (make-agent #:id "farmer" #:type 'person #:primary-location "town" #:classified-as '()
                    #:availability-window bread-window)
        (make-agent #:id "ada"    #:type 'person #:primary-location "town" #:classified-as '()
                    #:availability-window bread-window)
        (make-agent #:id "bob"    #:type 'person #:primary-location "town" #:classified-as '()
                    #:availability-window bread-window)))
(define bread-spatials (list (make-spatial-thing #:id "town" #:lat 40.0 #:long -74.0)))

(define-lazy bread-world
  ;; under the sky: each grow states the light its crop stores, the water it transpires
  ;; and the air it fixes its carbon from (world.scm world-sky). Built on first
  ;; reach, not at load: the sky stands on today's month, read off the clock,
  ;; which the browser build's compiler has no clock to read (utils/host.scm)
  (world-sky
   (world #:specs bread-specs #:procs bread-procs #:flows bread-flows #:recipes bread-recipes
          #:spatials bread-spatials #:agents bread-agents #:resources bread-resources)))

;; the plain variant: one worker per skill, no clock
(define (bread-resources-at soil)
  (append
   (list (er "soil-1" "soil" #f #:qty soil))
   bread-stores
   (list
        (er "sea" "fish-stock" #f #:qty 1.0e6) (er "hay" "fodder" #f #:qty 1.0e6)
        (er "the-sea" "sea" #f #:qty 1.0 #:unit %count-unit) (er "the-meadow" "meadow" #f #:qty 1.0 #:unit %count-unit)
        (er "s1" "skill-farm" "f") (er "s2" "skill-mill" "m") (er "s3" "skill-bake" "b") (er "s4" "skill-fish" "b"))))
(define bread-plain-resources (bread-resources-at 1000.0))
(define bread-plain-agents
  (list (make-agent #:id "f" #:type 'person #:primary-location "town" #:classified-as '())
        (make-agent #:id "m" #:type 'person #:primary-location "town" #:classified-as '())
        (make-agent #:id "b" #:type 'person #:primary-location "town" #:classified-as '())))
(define (bread-world-at soil)
  (world-with bread-world #:agents bread-plain-agents #:resources (bread-resources-at soil)))
(define-lazy bread-plain-world (bread-world-at 1000.0))

(define (seed-bread-recipes! rs)
  "The chain into RS: its specs, processes, flows and the one recipe."
  (seed-world-recipes! rs bread-world))

(define* (seed-bread-commune! scope #:key (world bread-world))
  "WORLD into SCOPE's real stores (the live town by default; bread-plain-world
   for the clockless one). Returns the place id, so the demand reads
   (cons \"bread#town@0\" qty)."
  (seed-world! scope world)
  "town")
