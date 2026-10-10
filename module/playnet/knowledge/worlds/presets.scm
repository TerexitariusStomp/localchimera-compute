;;; worlds/presets.scm — the worlds a scope can start from, listed once.
;;;
;;; Every economy the tree ships as data (a <world>, knowledge/world.scm) is a
;;; preset: the bread town the suites prove and the dev gateway seeds, a
;;; small garden starter, the federation demo's two communes. The
;;; planner's `presets` door lists them and `adopt-preset!` seeds one into a
;;; scope, so what a test plans over, what the demo shows and what a new
;;; commune starts from are one record read three ways.
;;;
;;; A preset is (id name doc . thunk) — the thunk builds the world, so a
;;; parameterised seeder (farm-world) enters at its default configuration.

(define-module (playnet knowledge worlds presets)
  #:use-module (playnet vf schemas)
  #:use-module (playnet knowledge dsl world)
  #:use-module (playnet knowledge recipes bread-commune-seed)
  #:use-module (playnet knowledge recipes farm-commune-seed)
  #:use-module (playnet knowledge recipes federation-demo)
  #:use-module ((playnet knowledge worlds demo-neighbourhood) #:select (demo-world-on %demo-scope))
  #:use-module (srfi srfi-1)
  #:export (%presets preset-list preset-ref adopt-preset!))

(define %presets
  (list
   (list "bread-town" "Bread town"
         "The grow→mill→bake chain in one town: soil, three skills held by three people on a daily clock. The economy the planner suites share."
         (lambda (scope) bread-world))
   (list "bread-plain" "Bread town, one worker per skill"
         "The same chain with a farmer, a miller and a baker and no clock, so every day is one period."
         (lambda (scope) bread-plain-world))
   (list "garden" "Playnet garden"
         "A small garden commune under the biosphere: greens and potatoes, a gardener, land and summer water. A starter for a new commune."
         (lambda (scope)
           (farm-world #:crops '(("greens" . (0.6 . 1500.0)) ("potatoes" . (0.9 . 3000.0)))
                       #:place "playnet-garden" #:place-name "Playnet garden" #:parent "biosphere"
                       #:tree (list (make-spatial-thing #:id "biosphere" #:name "The biosphere"
                                                        #:lat 0.0 #:long 0.0))
                       #:worker-name "Gardener" #:commune-name "Playnet")))
   (list "federation-granary" "Granary (federation demo)"
         "A flour-rich commune with a baker and a bake recipe, in a federation ⊃ commune ⊃ venue tree. Exports flour."
         (lambda (scope) (fed-world "fed" "commune-granary" "Granary" "venue-granary" 42.70 23.32 300.0)))
   (list "federation-table" "Table (federation demo)"
         "A flour-poor commune with a baker and a bake recipe, in the same federation. Imports flour and wants bread."
         (lambda (scope) (fed-world "fed" "commune-table" "Table" "venue-table" 42.75 23.40 0.0)))
   (list "neighbourhood" "Demo neighbourhood"
         "The neighbourhood the page shows offline: its places, its people, and the stocks its commons holds, laid around the origin and accounted to the scope that adopts it."
         (lambda (scope) (demo-world-on #f (or scope %demo-scope))))))

(define (preset-list)
  "Every preset as an alist of id, name and doc — the `presets` door's reply."
  (map (lambda (p) `((id . ,(first p)) (name . ,(second p)) (doc . ,(third p)))) %presets))

(define* (preset-ref id #:optional (scope #f))
  "The world preset ID names, built fresh for the scope id SCOPE (a world whose
   stocks are the adopting scope's accounts them to it), or #f."
  (let ((p (find (lambda (p) (equal? (first p) id)) %presets)))
    (and p ((fourth p) scope))))

(define* (adopt-preset! scope id #:optional (scope-id #f))
  "Seeds preset ID into SCOPE's stores, laid for the scope id SCOPE-ID. Returns
   the world; raises on an unknown id."
  (let ((w (preset-ref id scope-id)))
    (unless w (error "adopt-preset!: no such preset" id))
    (seed-world! scope w)))
