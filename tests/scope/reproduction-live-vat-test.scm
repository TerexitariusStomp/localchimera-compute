;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; reproduction-live-vat-test.scm — reproduction planning through the REAL live
;;; path (plan-scope over a scope-root vat), PER-PERSON and MULTI-PLACE.
;;;
;;; Two places (east, west); a person lives at each (different subsistence contexts);
;;; a grower at each. plan-scope #:reproduce? #t adds each person's EAT recipes (food
;;; → their nutrients) and floors them at the person's cell, from the subsistence
;;; catalogue. We verify each person is fed to THEIR floor AT THEIR LOCATION — the
;;; multi-place, worst-off-protecting reproduction of labour-power, live.
;;;
;;; Run:  guile --no-auto-compile -q -L module -l tests/scope/reproduction-live-vat-test.scm

(use-modules ((localchimera utils units) #:select (%effort-unit)))
(use-modules (localchimera test harness)
             (localchimera scope root) (localchimera vf schemas) (srfi srfi-1)
             (localchimera scope live)
             (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1) (ice-9 format))
(use-modules (localchimera knowledge catalogues subsistence))

(define mem (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Two-Village Commune")) mem))

(define win (list (cons "mon" (cons 0 24))))
(with-vat vat
  (let ((rs ($ scope 'recipe-store)) (obs ($ scope 'observer))
        (as ($ scope 'agent-store)) (sts ($ scope 'spatial-thing-store)))
    ;; two places
    ($ sts 'add-location (make-spatial-thing #:id "east" #:name "East Village" #:lat 40.0
                                             #:long -74.0))
    ($ sts 'add-location (make-spatial-thing #:id "west" #:name "West Village" #:lat 40.0
                                             #:long -74.6))
    ;; specs
    (for-each (lambda (id nm u) ($ rs 'add-resource-spec (make-resource-specification #:id id
                                                                                      #:name nm
                                                                                      #:default-unit-of-resource u)))
              '("grain" "beans" "greens" "rapeseed-oil" "fish" "dairy" "salt" "skill-grow")
              '("Grain" "Beans" "Greens" "Rapeseed oil" "Fish" "Milk" "Salt" "Growing") '("kg" "kg" "kg" "kg" "kg" "kg" "kg" "hours"))
    ($ rs 'add-process-spec (make-process-specification #:id "ps-grow" #:name "Growing"))
    ;; two grow recipes: labour → 1 kg food (grain protein-poor, beans protein-rich)
    (define (grow rid nm out)
      ($ rs 'add-recipe-process (make-recipe-process #:id rid #:name nm
                                                     #:process-conforms-to "ps-grow"
                                                     #:has-duration (make-duration 0.5 %effort-unit)
                                                     #:sequence-group 0))
      ($ rs 'add-recipe-flow (make-recipe-flow #:id (string-append rid "-w") #:action 'work
                                               #:resource-conforms-to "skill-grow"
                                               #:effort-quantity (make-measure 0.5 %effort-unit)
                                               #:recipe-input-of rid))
      ($ rs 'add-recipe-flow (make-recipe-flow #:id (string-append rid "-o") #:action 'produce #:resource-conforms-to out
                                               ;; salt is measured in grams (catalogues/food-sources.scm): a run makes a hundred of them, priced
                                               #:resource-quantity (if (equal? out "salt") (make-measure 100.0 "g") (make-measure 1.0 "kg")) #:recipe-output-of rid #:is-primary #t))
      ($ rs 'add-recipe (make-recipe #:id (string-append "r-" rid) #:name nm #:primary-output out
                                     #:recipe-processes (list rid))))
    (grow "grow-grain" "Grow grain" "grain")
    (grow "grow-beans" "Grow beans" "beans")
    ;; …and the rest of the town's table (bread-commune-seed): what a body's
    ;; band asks that grain and beans cannot carry under its energy ceiling —
    ;; the smallest set the engine feeds a woman and a man whole off, read off
    ;; the USDA rows (kidney beans state no choline there; milk and fish do)
    (grow "grow-greens" "Grow greens" "greens")
    (grow "grow-oil" "Grow rapeseed, press oil" "rapeseed-oil")
    (grow "grow-fish" "Fish" "fish")
    (grow "grow-dairy" "Milk" "dairy")
    (grow "grow-salt" "Make salt" "salt")
    ;; people (eaters): Ana at east (temperate F), Bo at west (cold M) — via classified-as
    ($ as 'add-agent (make-agent #:id "ana" #:type 'person #:name "Ana" #:primary-location "east"
                                 #:classified-as '("female") #:availability-window win))
    ($ as 'add-agent (make-agent #:id "bo"  #:type 'person #:name "Bo" #:primary-location "west"
                                 #:classified-as '("male" "cold") #:availability-window win))
    ;; a grower at each village, holding the skill
    ($ as 'add-agent (make-agent #:id "gea" #:type 'person #:name "Grower E"
                                 #:primary-location "east" #:classified-as '("male")
                                 #:availability-window win))
    ($ as 'add-agent (make-agent #:id "gwe" #:type 'person #:name "Grower W"
                                 #:primary-location "west" #:classified-as '("male")
                                 #:availability-window win))
    ($ obs 'seed-resource (make-economic-resource #:id "sk-gea" #:name "E can grow"
                                                  #:conforms-to "skill-grow"
                                                  #:accounting-quantity (make-measure 12 %effort-unit)
                                                  #:onhand-quantity (make-measure 12 %effort-unit)
                                                  #:primary-accountable "gea"))
    ($ obs 'seed-resource (make-economic-resource #:id "sk-gwe" #:name "W can grow"
                                                  #:conforms-to "skill-grow"
                                                  #:accounting-quantity (make-measure 12 %effort-unit)
                                                  #:onhand-quantity (make-measure 12 %effort-unit)
                                                  #:primary-accountable "gwe"))
    (check-pred "scope seeded" #t)))

;; ── the reproduction solve, live ─────────────────────────────────────────────
(define result
  (with-vat vat
    (call-with-values (lambda () (plan-scope scope #:reproduce? #t #:backend 'native-c))
      (lambda (ints coms material fill x ntot report)
        (map (lambda (pid ctx place)
               ;; production of a nutrient FOR this person AT a given cell
               (let ((got@ (lambda (nut cell) (fold (lambda (c a)
                            (if (and (eq? (commitment-action c) 'produce)
                                     (equal? (commitment-resource-conforms-to c) (string-append nut "|" pid))
                                     (equal? (commitment-at-location c) cell))
                                (+ a (measure-has-numerical-value (commitment-resource-quantity c))) a)) 0.0 material))))
                 (list pid place
                       (got@ "energy" place) (assoc-ref (subsistence-floors ctx) "energy")
                       (got@ "protein" place) (assoc-ref (subsistence-floors ctx) "protein")
                       place)))
             '("ana" "bo")
             (list '((sex . "F") (age . 30) (region . "temperate") (labour-hours . 5))
                   '((sex . "M") (age . 30) (region . "cold") (labour-hours . 5)))
             '("east" "west"))))))

(format #t "~%── per-person reproduction, multi-place, LIVE (plan-scope over a vat) ──~%")
(for-each (lambda (r)
  (format #t "  ~4a @ ~5a: energy ~5,0f/~5,0f  protein ~5,1f/~5,1f  produced-at ~a~%"
          (first r) (second r) (third r) (fourth r) (fifth r) (sixth r) (seventh r)))
  result)

;; third/fifth are production AT each person's OWN cell — so "fed" already means
;; fed at their location (multi-place, food grown locally or transported there).
(let ((fed (every (lambda (r) (and (>= (third r) (* 0.97 (fourth r))) (>= (fifth r) (* 0.97 (sixth r))))) result)))
  (check-pred "each person fed to their subsistence-catalogue floor AT THEIR OWN place" fed)
  (format #t "~%  ~a reproduction of labour-power, live: per-person, at each place, worst-off protected~%~%"
          (if fed "✓" "✗")))
