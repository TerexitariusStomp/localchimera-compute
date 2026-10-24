;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-stock-ingest.scm — the planner reads the observer's stock by ONE identity.
;;;
;;; A holding is a lot of a specification, in a stage and a state, somewhere
;;; (ValueFlows: EconomicResource.conformsTo / stage / state / currentLocation /
;;; containedIn). The solve's stock row for a lot is its `stock-key`, and three
;;; properties hold for every holding the observer states:
;;;
;;;   NAME      a stage or a state qualifies the spec only where some recipe flow
;;;             names that qualified good; any other stage is a record of history
;;;             the plan has no use for, and the holding stays the bare spec's.
;;;             The state separator is its own character, never the owner's.
;;;   NUMBER    a holding adds its signed quantity, counted in the unit its
;;;             specification counts in; the lot's sum is then floored at zero.
;;;             A quantity in a unit that does not convert is refused and named.
;;;   PLACE     a holding sits where it is, or where its container is, or (a
;;;             container stating no place) in the container itself; a consumable
;;;             exists only in the periods its availability window offers hours.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/solve/test-stock-ingest.scm

(use-modules (localchimera solve ingest))
(use-modules (localchimera test harness)
             (localchimera knowledge dsl shorthand)
             (localchimera solve engine) (localchimera solve world)
             (localchimera solve compile)
             (localchimera vf schemas)
             (srfi srfi-1))

(define (near? a b) (< (abs (- a b)) 1e-6))

;; a recipe whose flows are the given goods: inputs and outputs by name
(define (tpl id ins outs)
  (list id (map (lambda (g) (cons g 1.0)) ins) (map (lambda (g) (cons g 1.0)) outs)
        0.0 '() '() '() '() '()))

(define (world! . tpls)
  (declare-world! #:spans '((0 "2026-03-03" "2026-03-03"))   ; one Tuesday
                  #:templates tpls))

(define* (holding id spec qty #:key (unit "x") (place "town") stage state contained-in window)
  (copy-economic-resource
   (er id spec #f #:place place #:qty qty #:unit unit #:contained-in contained-in #:window window)
   #:stage stage #:state state))

(define (held good . place)                      ; what the solve is told is on hand of GOOD
  (let ((g (lg good (cell (if (pair? place) (car place) "town") 0))))
    (+ (hash-ref *init* g 0.0) (hash-ref *cap* g 0.0))))

(display "\n── NAME: a stage names the stock only where a recipe names that stage ──\n")
(world! (tpl "bake" '("dough") '("bread")))
(ingest-stock! (list (holding "d1" "dough" 5.0 #:stage "proof")))     ; "proof" is a process's name
(check "stock stamped with a stage no recipe names is the bare spec's" (held "dough") 5.0)
(check "…and is not a good of its own"                                 (held (qualified-good "dough" "proof" #f)) 0.0)

(world! (tpl "proof" '("flour") '("dough/proofed")) (tpl "bake" '("dough/proofed") '("bread")))
(ingest-stock! (list (holding "d1" "dough" 5.0 #:stage "proofed")
                     (holding "d2" "dough" 3.0)))
(check "stock at the stage a recipe names is that stage's good"  (held "dough/proofed") 5.0)
(check "…and the unstaged dough is a different lot"             (held "dough") 3.0)

(let ((clean (qualified-good "flask" #f "clean")))
  (world! (tpl "fill" (list clean) '("wine")))
  (ingest-stock! (list (holding "f1" "flask" 4.0 #:state "clean")
                       (holding "f2" "flask" 2.0 #:state "dirty")))
  (check "stock in a state a recipe names is that state's good"   (held clean) 4.0)
  (check "stock in a state no recipe names is the bare spec's"    (held "flask") 2.0)
  (check "a state never reads as an owner"                        (spec-owner clean) #f)
  (check "…and an owner still reads as one"                       (spec-owner (owned-spec "flask" "ada")) '("flask" . "ada")))

(display "\n── NUMBER: signed, in the spec's unit, then floored ──\n")
(world! (tpl "wash" '("water") '("clean")))
(ingest-stock! (list (holding "n1" "water" 10.0) (holding "n2" "water" -4.0)))
(check "+10 and -4 of one lot are 6"                 (held "water") 6.0)
(world! (tpl "wash" '("water") '("clean")))
(ingest-stock! (list (holding "n2" "water" -4.0)))
(check "a lot whose sum is negative holds nothing"   (held "water") 0.0)

(world! (tpl "wash" '("water") '("clean")))
(ingest-stock! (list (holding "z1" "water" 0.0)))
(check "a holding of nothing adds no row, so a raw it names stays unbounded"
       (hash-ref *cap* (lg "water" (cell "town" 0)) #f) #f)

(world! (tpl "wash" '("water") '("clean")))
(ingest-stock! (list (holding "w1" "water" 10.0 #:unit "litre")
                     (holding "w2" "water" 10.0 #:unit "ml")
                     (holding "w3" "water" 10.0 #:unit "m3")
                     (holding "w4" "water" 10.0 #:unit "kg"))
               #:spec-units '(("water" . "litre")))
(check "litres, millilitres and cubic metres add in the spec's litres"
       (held "water") 10010.01)
(check "a quantity in a unit that does not convert is refused, and named"
       (map car (refused-stock)) '("w4"))
(world! (tpl "wash" '("water") '("clean")))
(ingest-stock! (list (holding "w1" "water" 7.0 #:unit "bags")))
(check "with no unit stated for the spec, the holding's quantity stands" (held "water") 7.0)

(display "\n── PLACE: where it is, or where its container is; a window gates a consumable ──\n")
(world! (tpl "wash" '("water") '("clean")))
(ingest-stock! (list (holding "box" "crate" 1.0 #:place #f)
                     (holding "c1" "water" 10.0 #:place #f #:contained-in "box")))
(check "a holding in a container that states no place is refused, and named"
       (sort (map car (refused-stock)) string<?) '("box" "c1"))
(world! (tpl "wash" '("water") '("clean")))
(ingest-stock! (list (holding "box" "crate" 1.0 #:place "dock")
                     (holding "c1" "water" 10.0 #:place #f #:contained-in "box")))
(check "…and where the container is, when it states one"                    (list (held "water" "dock") (refused-stock)) '(10.0 ()))

(world! (tpl "wash" '("water") '("clean")))
(ingest-stock! (list (holding "a1" "water" 10.0 #:window (weekday-window "09:00" "17:00" '(saturday)))))
(check "a consumable exists in no period its window offers no hours"        (held "water") 0.0)
(world! (tpl "wash" '("water") '("clean")))
(ingest-stock! (list (holding "a1" "water" 10.0 #:window (all-week-window))))
(check "…and in every period it does"                                       (held "water") 10.0)

(test-summary!)
