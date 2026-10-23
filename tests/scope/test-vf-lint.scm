;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/scope/test-vf-lint.scm — (playnet knowledge dsl vf-lint): one lint, two inputs
;;;
;;; What this pins:
;;;   RECIPE STORE  a well-formed recipe is clean; each rule fires on the shape it
;;;                 is for — an action outside ValueFlows, a flow pointing the wrong
;;;                 way, a spec the store lacks, a quantity at zero, a `use` with no
;;;                 length anywhere, two primary outputs, a unit the spec does not
;;;                 count in — and a process duration alone satisfies the `use` rule;
;;;   RECORDS       wire records (string keys, as JSON parses) are judged the same
;;;                 way: action, spec against the scope's list, quantity, unit
;;;                 against the scope's, a need's arcs;
;;;   READERS       findings sort by severity, errors-only filters, the wire shape
;;;                 is JSON-ready, and findings->reason is the numbered, capped
;;;                 error list a model is asked again with.
;;;
;;; Run: guile -L module tests/scope/test-vf-lint.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness)
             (playnet scope root) (playnet vf schemas) (srfi srfi-1) (playnet vf schemas)
             (playnet knowledge dsl vf-lint) (playnet knowledge dsl findings)
             ((playnet knowledge catalogues substances) #:select (thermal-form base-at-ambient-row))
             ((playnet knowledge catalogues substances) #:select (nuclide? sunlight-for water-for rated-kw))
             (goblins) (srfi srfi-1) (srfi srfi-13))

(define vat (spawn-vat #:name "vf-lint"))
(define root (with-vat vat (spawn-scope-root "vf-lint")))
(define rs (with-vat vat ($ root 'recipe-store)))

(define (spec! id unit)
  ($ rs 'add-resource-spec (make-resource-specification #:id id #:name id
                                                        #:default-unit-of-resource unit)))
(define (process! id hours)
  ($ rs 'add-recipe-process (make-recipe-process #:id id #:name id
                                                 #:has-duration (and hours (make-duration hours %effort-unit)))))
(define* (flow! id action spec pid #:key (qty 1.0) (unit "kg") effort (primary #f) (out? #f))
  ($ rs 'add-recipe-flow
     (make-recipe-flow #:id id #:action action #:resource-conforms-to spec #:resource-quantity (and qty (make-measure qty unit)) #:effort-quantity effort
                       #:recipe-input-of (if out? #f pid) #:recipe-output-of (if out? pid #f) #:is-primary primary)))
(define (recipe! id primary pids) ($ rs 'add-recipe (make-recipe #:id id #:name id
                                                                 #:primary-output primary
                                                                 #:recipe-processes pids)))
(define (kinds fs) (map finding-kind fs))
(define (has? fs kind) (and (memq kind (kinds fs)) #t))

(display "\n── a well-formed recipe is clean ──\n")
(with-vat vat
  (spec! "flour" "kg") (spec! "bread" "kg") (spec! "oven" %count-unit) (spec! "baker" %effort-unit) (spec! "spec-water" "liters")
  (process! "bake" 2)
  (flow! "f1" 'consume "flour" "bake" #:qty 5)
  (flow! "f1w" 'consume "spec-water" "bake" #:qty 1.5 #:unit "liters")     ; the water the loaves hold came from somewhere
  (flow! "f2" 'use "oven" "bake" #:qty 1 #:unit %count-unit #:effort (make-measure 2 %effort-unit))
  (flow! "f3" 'work "baker" "bake" #:qty #f #:effort (make-measure 2 %effort-unit))
  (flow! "f4" 'produce "bread" "bake" #:qty 4 #:primary #t #:out? #t)
  (recipe! "r-bread" "bread" '("bake")))
(define clean (with-vat vat (lint-recipe-store rs)))
(check "no error or warning" (filter (lambda (f) (memq (finding-severity f) '(error warning))) clean) '())
(check-pred "flour, consumed and made by nothing, is an info line" (has? clean 'unproduced-input))

(display "\n── each rule fires on its shape ──\n")
(with-vat vat
  (spec! "milk" "liters") (spec! "cheese" "kg") (spec! "vat" %count-unit)
  (process! "curdle" #f)
  (flow! "g1" 'squeeze "milk" "curdle")                                    ; not a VF action
  (flow! "g2" 'consume "milk" "curdle" #:qty 10 #:unit "kg")                ; milk is counted in liters
  (flow! "g3" 'consume "ghost" "curdle")                                    ; no such spec
  (flow! "g4" 'consume "milk" "curdle" #:qty 0 #:unit "liters")             ; nothing
  (flow! "g5" 'use "vat" "curdle" #:qty 1 #:unit %count-unit)                    ; no length anywhere
  (flow! "g6" 'produce "cheese" "curdle" #:qty 1 #:primary #t #:out? #t)
  (flow! "g7" 'produce "cheese" "curdle" #:qty 1 #:primary #t #:out? #t)    ; two primaries
  ;; (a produce pointing IN is refused by the store itself at add time, so the
  ;; wrong-direction rule is exercised on wire records below)
  (recipe! "r-cheese" "cheese" '("curdle"))
  (recipe! "r-empty" "cheese" '("no-such-process")))
(define bad (with-vat vat (lint-recipe-store rs)))
(for-each (lambda (k) (check-pred (format #f "~a is reported" k) (has? bad k)))
          '(unknown-action unit-mismatch unknown-spec nonpositive-quantity untimed-use
            many-primary-outputs empty-recipe))

(display "\n── a reading is a count of a stock: intensive units and the two heat frames ──\n")
(with-vat vat
  (spec! "room" %count-unit) (spec! "warm-room" %count-unit) (spec! "ch4" "kg") (spec! "o2" "kg") (spec! "co2" "kg") (spec! "h2o" "kg") (spec! "spec-bn-heat" "kWh")
  (process! "heat-room" 1)
  (flow! "t1" 'consume "room" "heat-room" #:qty 20 #:unit "degC")            ; degrees move nothing
  (flow! "t2" 'produce "warm-room" "heat-room" #:qty 1 #:unit %count-unit #:primary #t #:out? #t)
  (recipe! "r-warm" "warm-room" '("heat-room"))
  ;; combustion into a heat CARRIER: the carrier bridges the frames, so no refusal
  (process! "burn" 1)
  (flow! "b1" 'consume "ch4" "burn" #:qty 0.016) (flow! "b2" 'consume "o2" "burn" #:qty 0.064)
  (flow! "b3" 'produce "co2" "burn" #:qty 0.044 #:out? #t) (flow! "b4" 'produce "h2o" "burn" #:qty 0.036 #:out? #t)
  (flow! "b5" 'produce "spec-bn-heat" "burn" #:qty 0.247 #:unit "kWh" #:primary #t #:out? #t)
  (recipe! "r-burn" "spec-bn-heat" '("burn")))
(define thermal (with-vat vat (lint-recipe-store rs)))
(check-pred "a flow in degrees is refused: a state is a form, a reading is a count" (has? thermal 'intensive-unit))
(check-pred "combustion into a heat carrier crosses no frame" (not (has? thermal 'frames-crossed)))

(display "\n── the second law as one inequality: entropy is produced ──\n")
(define-values (DOUGH+6 dough-row) (thermal-form "dough" 2.5 6))          ; 0.004167 kWh/kg of excess, 6 K
(define Q (/ (* 2.5 6) 3600.0))
(define (spec-row! id unit row)                                            ; a spec that STATES its composition
  ($ rs 'add-resource-spec (make-resource-specification #:id id #:name id
                                                        #:default-unit-of-resource unit
                                                        #:composition row)))
(with-vat vat
  (spec-row! "dough" "kg" (base-at-ambient-row "dough")) (spec-row! DOUGH+6 "kg" dough-row)
  (spec! "spec-sp-electricity" "kWh") (spec! "ambient-heat" "kWh")
  ;; a heat pump claiming a hundredfold: Carnot allows (293.15 + 6)/6 ≈ 49.9
  (process! "pump-100" 1)
  (flow! "p1" 'consume "dough" "pump-100" #:qty 1)
  (flow! "p2" 'consume "spec-sp-electricity" "pump-100" #:qty (/ Q 100) #:unit "kWh")
  (flow! "p3" 'consume "ambient-heat" "pump-100" #:qty (- Q (/ Q 100)) #:unit "kWh")
  (flow! "p4" 'produce DOUGH+6 "pump-100" #:qty 1 #:primary #t #:out? #t)
  (recipe! "r-pump-100" DOUGH+6 '("pump-100"))
  ;; an honest tenfold
  (process! "pump-10" 1)
  (flow! "q1" 'consume "dough" "pump-10" #:qty 1)
  (flow! "q2" 'consume "spec-sp-electricity" "pump-10" #:qty (/ Q 10) #:unit "kWh")
  (flow! "q3" 'consume "ambient-heat" "pump-10" #:qty (- Q (/ Q 10)) #:unit "kWh")
  (flow! "q4" 'produce DOUGH+6 "pump-10" #:qty 1 #:primary #t #:out? #t)
  (recipe! "r-pump-10" DOUGH+6 '("pump-10")))
  ;; ninety-fold: above the endpoint Carnot figure (49.9) yet below the reversible
  ;; bound for warming a batch from ambient, 1/(1 − ln(1+x)/x) ≈ 97.7 — the entropy
  ;; row knows the difference, a Carnot rule of thumb would not
(with-vat vat
  (process! "pump-90" 1)
  (flow! "s1" 'consume "dough" "pump-90" #:qty 1)
  (flow! "s2" 'consume "spec-sp-electricity" "pump-90" #:qty (/ Q 90) #:unit "kWh")
  (flow! "s3" 'consume "ambient-heat" "pump-90" #:qty (- Q (/ Q 90)) #:unit "kWh")
  (flow! "s4" 'produce DOUGH+6 "pump-90" #:qty 1 #:primary #t #:out? #t)
  (recipe! "r-pump-90" DOUGH+6 '("pump-90"))
  ;; a nuclear recipe that is no channel: 19 U-235 → Ba-141 + 47 Kr-92 balances on A and Z
  (spec! "U-235" "mol") (spec! "Ba-141" "mol") (spec! "Kr-92" "mol") (spec! "n" "mol")
  (process! "odd-fission" 1)
  (flow! "n1" 'consume "U-235" "odd-fission" #:qty 19 #:unit "mol")
  (flow! "n2" 'produce "Ba-141" "odd-fission" #:qty 1 #:unit "mol" #:primary #t #:out? #t)
  (flow! "n3" 'produce "Kr-92" "odd-fission" #:qty 47 #:unit "mol" #:out? #t)
  (recipe! "r-odd" "Ba-141" '("odd-fission"))
  (process! "fission" 1)
  (flow! "m1" 'consume "U-235" "fission" #:qty 1 #:unit "mol") (flow! "m2" 'consume "n" "fission" #:qty 1 #:unit "mol")
  (flow! "m3" 'produce "Ba-141" "fission" #:qty 1 #:unit "mol" #:primary #t #:out? #t)
  (flow! "m4" 'produce "Kr-92" "fission" #:qty 1 #:unit "mol" #:out? #t)
  (flow! "m5" 'produce "n" "fission" #:qty 3 #:unit "mol" #:out? #t)
  (recipe! "r-fission" "Ba-141" '("fission"))
  ;; the same channel yielding its heat as a carrier: the channel is read over the nuclides alone
  (spec! "spec-bn-heat" "kWh")
  (process! "fission-heat" 1)
  (flow! "h1" 'consume "U-235" "fission-heat" #:qty 1 #:unit "mol") (flow! "h2" 'consume "n" "fission-heat" #:qty 1 #:unit "mol")
  (flow! "h3" 'produce "Ba-141" "fission-heat" #:qty 1 #:unit "mol" #:primary #t #:out? #t)
  (flow! "h4" 'produce "Kr-92" "fission-heat" #:qty 1 #:unit "mol" #:out? #t)
  (flow! "h5" 'produce "n" "fission-heat" #:qty 3 #:unit "mol" #:out? #t)
  (flow! "h6" 'produce "spec-bn-heat" "fission-heat" #:qty 4.6e6 #:unit "kWh" #:out? #t)
  (recipe! "r-fission-heat" "Ba-141" '("fission-heat"))
  ;; uranium into heat and nothing else: mc² spent on no channel
  (process! "annihilate" 1)
  (flow! "x1" 'consume "U-235" "annihilate" #:qty 1 #:unit "mol")
  (flow! "x2" 'produce "spec-bn-heat" "annihilate" #:qty 5.0e9 #:unit "kWh" #:primary #t #:out? #t)
  (recipe! "r-annihilate" "spec-bn-heat" '("annihilate")))
(define carnot (with-vat vat (lint-recipe-store rs)))
(define (subjects kind) (map finding-subject (filter (lambda (f) (eq? (finding-kind f) kind)) carnot)))
(check-pred "a hundredfold across six kelvin would destroy entropy and is refused"
            (member "pump-100" (subjects 'second-law)))
(check-pred "a ninetyfold passes: the reversible bound for warming a batch is 2T₀/ΔT, near 97.7, above the endpoint Carnot 49.9"
            (not (member "pump-90" (subjects 'second-law))))
(check-pred "…and a tenfold passes" (not (member "pump-10" (subjects 'second-law))))
(check-pred "a nuclear recipe that balances on nucleons yet runs no channel is refused" (member "odd-fission" (subjects 'unknown-channel)))
(check-pred "…the channel nature runs passes" (not (member "fission" (subjects 'unknown-channel))))
(check-pred "…and passes with its heat named beside the nuclides" (not (member "fission-heat" (subjects 'unknown-channel))))
(check-pred "uranium into heat and nothing else runs no channel and is refused: mass becomes heat only by a channel's mass defect"
            (member "annihilate" (subjects 'unknown-channel)))
(check-pred "combustion into a heat carrier produces entropy and passes" (not (member "burn" (subjects 'second-law))))
(check-pred "a nuclear recipe that balances but is no channel is refused"
            (member "odd-fission" (subjects 'unknown-channel)))
(check-pred "…while thermal fission of U-235 is a channel" (not (member "fission" (subjects 'unknown-channel))))

(display "\n── the two heat frames, crossed ──\n")
(with-vat vat
  ;; methane burnt straight into the warmed dough: a molecule's formation frame
  ;; against a form's ambient frame, with no carrier between
  (process! "burn-into-dough" 1)
  (flow! "c1" 'consume "ch4" "burn-into-dough" #:qty 0.016) (flow! "c2" 'consume "o2" "burn-into-dough" #:qty 0.064)
  (flow! "c3" 'consume "dough" "burn-into-dough" #:qty 1)
  (flow! "c4" 'produce "co2" "burn-into-dough" #:qty 0.044 #:out? #t) (flow! "c5" 'produce "h2o" "burn-into-dough" #:qty 0.036 #:out? #t)
  (flow! "c6" 'produce DOUGH+6 "burn-into-dough" #:qty 1 #:primary #t #:out? #t)
  (recipe! "r-burn-dough" DOUGH+6 '("burn-into-dough")))
(define crossed (with-vat vat (lint-recipe-store rs)))
(check-pred "a molecule's enthalpy against a warmed form's excess is refused: two zeros"
            (member "burn-into-dough" (map finding-subject (filter (lambda (f) (eq? (finding-kind f) 'frames-crossed)) crossed))))
(check "the well-formed recipe stays clean beside the bad one"
       (filter (lambda (f) (string-prefix? "bake" (format #f "~a" (finding-subject f)))) (errors-only bad)) '())
(check "a missing spec is an info line when the store is known to be partial"
       (finding-severity (find (lambda (f) (eq? 'unknown-spec (finding-kind f)))
                               (with-vat vat (lint-recipe-store rs #:specs-complete? #f))))
       'info)
(check-pred "errors come first" (eq? 'error (finding-severity (car bad))))

(display "\n── the first law, per process, said where the recipe is written ──\n")
(with-vat vat
  (spec! "soil-n" "kg") (spec! "sludge" "kg") (spec! "scum" "kg")
  ;; a sludge made beside three tenths of a kilogram of soil nitrogen returned, on a
  ;; draw of a twentieth: the nitrogen it hands back was never drawn
  (process! "conjure-n" 1)
  (flow! "n1" 'consume "soil-n" "conjure-n" #:qty 0.05)
  (flow! "n2" 'produce "sludge" "conjure-n" #:qty 1 #:primary #t #:out? #t)
  (flow! "n3" 'produce "soil-n" "conjure-n" #:qty 0.3 #:out? #t)
  (recipe! "r-conjure-n" "sludge" '("conjure-n"))
  ;; the same return on a draw that covers it is a loss at most
  (process! "honest-n" 1)
  (flow! "o1" 'consume "soil-n" "honest-n" #:qty 0.5)
  (flow! "o2" 'produce "sludge" "honest-n" #:qty 1 #:primary #t #:out? #t)
  (flow! "o3" 'produce "soil-n" "honest-n" #:qty 0.3 #:out? #t)
  (recipe! "r-honest-n" "sludge" '("honest-n"))
  ;; two outputs of which neither is described: the recipes do not say which holds what
  (process! "split" 1)
  (flow! "s1" 'consume "soil-n" "split" #:qty 1)
  (flow! "s2" 'produce "scum" "split" #:qty 1 #:primary #t #:out? #t)
  (flow! "s3" 'produce "froth" "split" #:qty 1 #:out? #t)
  (recipe! "r-split" "scum" '("split")))
(define first-law (with-vat vat (lint-recipe-store rs #:specs-complete? #f)))
(define (of kind) (map finding-subject (filter (lambda (f) (eq? (finding-kind f) kind)) first-law)))
(check-pred "a process carrying out more nitrogen than it draws is refused by name" (member "conjure-n" (of 'creates)))
(check-pred "…and one that draws what its outputs hold is a loss at most" (not (member "honest-n" (of 'creates))))
(check-pred "an output nobody has described beside another leaves both undetermined, and the lint names them"
            (and (member "scum" (of 'undetermined-composition)) (member "froth" (of 'undetermined-composition))))
(check-pred "…and what is undetermined is unread: the process that makes them is refused for nothing"
            (not (member "split" (of 'creates))))

(display "\n── a process duration alone satisfies the use rule ──\n")
(with-vat vat
  (process! "press" 1)
  (flow! "h1" 'use "vat" "press" #:qty 1 #:unit %count-unit)
  (flow! "h2" 'produce "cheese" "press" #:qty 1 #:primary #t #:out? #t)
  (recipe! "r-press" "cheese" '("press")))
(check "no untimed-use on the timed process"
       (filter (lambda (f) (and (eq? 'untimed-use (finding-kind f))
                                (string-prefix? "press" (format #f "~a" (finding-subject f)))))
               (with-vat vat (lint-recipe-store rs)))
       '())

(display "\n── wire records ──\n")
(define recs
  (list '(("action" . "work") ("spec" . "baker") ("qty" . 2) ("unit" . "h"))
        '(("action" . "eat") ("spec" . "bread") ("qty" . 1) ("unit" . "kg"))
        '(("action" . "consume") ("spec" . "unicorn") ("qty" . 1) ("unit" . "kg"))
        '(("action" . "consume") ("spec" . "bread") ("qty" . "0") ("unit" . "kg"))
        '(("action" . "consume") ("spec" . "flour") ("qty" . 3) ("unit" . "liters"))
        '(("kind" . "need") ("spec" . "bread") ("qty" . 2) ("unit" . "kg")
          ("arcs" . #((("days" . #("Monday" "funday")) ("start" . "9:00") ("end" . "10:00")))))))
(define rf (lint-records recs #:specs '("baker" "bread" "flour") #:units '(("flour" . "kg"))))
(check "the good work record is clean" (filter (lambda (f) (equal? "records[0]" (finding-subject f))) rf) '())
(check-pred "an action outside ValueFlows" (has? rf 'unknown-action))
(check-pred "a spec the scope does not know" (has? rf 'unknown-spec))
(check-pred "a quantity of zero, even as a string" (has? rf 'nonpositive-quantity))
(check-pred "a unit the scope does not count in" (has? rf 'unit-mismatch))
(check-pred "a bad arc day" (has? rf 'bad-arc-day))
(check-pred "a bad arc time" (has? rf 'bad-arc-time))
(check-pred "a record in an intensive unit is refused"
            (has? (lint-records (list '(("kind" . "event") ("action" . "raise") ("spec" . "room") ("qty" . 4) ("unit" . "degC")))) 'intensive-unit))
(check "without a spec list the spec is taken on trust"
       (has? (lint-records recs) 'unknown-spec) #f)
(check "a vector of records reads like a list" (length (lint-records (list->vector recs))) (length (lint-records recs)))

(display "\n── the readers ──\n")
(define wire (findings->wire rf))
(check-pred "the wire shape is a vector of objects with four string fields"
            (and (vector? wire) (every (lambda (o) (= 4 (length o))) (vector->list wire))))
(define reason (findings->reason rf))
(check-pred "the reason numbers the errors" (string-prefix? "1. records[1]" reason))
(check-pred "…names the fact" (string-contains reason "outside ValueFlows"))
(check-pred "…and leaves warnings out" (not (string-contains reason "counts it in")))
(check "no errors ⇒ no reason" (findings->reason (lint-records (list (car recs)))) #f)
(check-pred "a long list is capped with a count of the rest"
            (string-contains (findings->reason (append rf rf rf) #:limit 3) "more of the same"))

(display "\n── photosynthesis: the first law on the food-energy leaf ──\n")
(with-vat vat
  (spec! "soil" "kg") (spec! "grain" "kg") (spec! "sunlight" "kWh")
  ;; grain from soil and no light: food energy from nothing
  (process! "grow-dark" 1)
  (flow! "d1" 'consume "soil" "grow-dark" #:qty 1)
  (flow! "d2" 'produce "grain" "grow-dark" #:qty 1 #:primary #t #:out? #t)
  (recipe! "r-dark" "grain" '("grow-dark"))
  ;; the light a kilogram needs at the stored share
  (process! "grow-lit" 1)
  (flow! "l1" 'consume "soil" "grow-lit" #:qty 1)
  (flow! "l2" 'consume "sunlight" "grow-lit" #:qty (sunlight-for "grain" 1.0) #:unit "kWh")
  (flow! "l3" 'produce "grain" "grow-lit" #:qty 1 #:primary #t #:out? #t)
  (recipe! "r-lit" "grain" '("grow-lit"))
  ;; twice the harvest from the same light: beats the leaf
  (process! "grow-greedy" 1)
  (flow! "y1" 'consume "soil" "grow-greedy" #:qty 1)
  (flow! "y2" 'consume "sunlight" "grow-greedy" #:qty (sunlight-for "grain" 1.0) #:unit "kWh")
  (flow! "y3" 'produce "grain" "grow-greedy" #:qty 2 #:primary #t #:out? #t)
  (recipe! "r-greedy" "grain" '("grow-greedy"))
  ;; a mill: the energy came in with the grain
  (process! "mill" 1)
  (flow! "k1" 'consume "grain" "mill" #:qty 1.2)
  (flow! "k2" 'produce "flour" "mill" #:qty 1 #:primary #t #:out? #t)
  (recipe! "r-mill" "flour" '("mill")))
(define lit (with-vat vat (lint-recipe-store rs)))
(define (lit-subjects kind) (map finding-subject (filter (lambda (f) (eq? (finding-kind f) kind)) lit)))
(check-pred "grain grown from soil with no light stated creates food energy and is refused" (member "grow-dark" (lit-subjects 'photosynthesis)))
(check-pred "the light a kilogram needs at the stored share passes" (not (member "grow-lit" (lit-subjects 'photosynthesis))))
(check-pred "twice the harvest from the same light beats the leaf and is refused" (member "grow-greedy" (lit-subjects 'photosynthesis)))
(check-pred "a mill passes: its energy came in with the grain" (not (member "mill" (lit-subjects 'photosynthesis))))

(display "\n── transpiration: the water a crop draws is tied to the energy it stores ──\n")
(with-vat vat
  (spec! "rain" "L")
  ;; grain from soil and light, and no water: a crop nothing watered
  (process! "grow-dry" 1)
  (flow! "w1" 'consume "soil" "grow-dry" #:qty 1)
  (flow! "w2" 'consume "sunlight" "grow-dry" #:qty (sunlight-for "grain" 1.0) #:unit "kWh")
  (flow! "w3" 'produce "grain" "grow-dry" #:qty 1 #:primary #t #:out? #t)
  (recipe! "r-dry" "grain" '("grow-dry"))
  ;; the water a kilogram transpires, as rain
  (process! "grow-wet" 1)
  (flow! "e1" 'consume "soil" "grow-wet" #:qty 1)
  (flow! "e2" 'consume "sunlight" "grow-wet" #:qty (sunlight-for "grain" 1.0) #:unit "kWh")
  (flow! "e3" 'consume "rain" "grow-wet" #:qty (water-for "grain" 1.0) #:unit "L")
  (flow! "e4" 'produce "grain" "grow-wet" #:qty 1 #:primary #t #:out? #t)
  (recipe! "r-wet" "grain" '("grow-wet"))
  ;; half the water for the same grain
  (process! "grow-thirsty" 1)
  (flow! "h1" 'consume "soil" "grow-thirsty" #:qty 1)
  (flow! "h2" 'consume "sunlight" "grow-thirsty" #:qty (sunlight-for "grain" 1.0) #:unit "kWh")
  (flow! "h3" 'consume "rain" "grow-thirsty" #:qty (* 0.5 (water-for "grain" 1.0)) #:unit "L")
  (flow! "h4" 'produce "grain" "grow-thirsty" #:qty 1 #:primary #t #:out? #t)
  (recipe! "r-thirsty" "grain" '("grow-thirsty"))
  ;; a crop the pathway table does not name, grown on the C3 figures: told so
  (spec! "flour" "kg")
  (process! "grow-unnamed" 1)
  (flow! "u1" 'consume "soil" "grow-unnamed" #:qty 1)
  (flow! "u2" 'consume "sunlight" "grow-unnamed" #:qty (sunlight-for "flour" 1.0) #:unit "kWh")
  (flow! "u3" 'consume "rain" "grow-unnamed" #:qty (water-for "flour" 1.0) #:unit "L")
  (flow! "u4" 'produce "flour" "grow-unnamed" #:qty 1 #:primary #t #:out? #t)
  (recipe! "r-unnamed" "flour" '("grow-unnamed")))
(define wt (with-vat vat (lint-recipe-store rs)))
(define (wt-subjects kind) (map finding-subject (filter (lambda (f) (eq? (finding-kind f) kind)) wt)))
(check-pred "a grown food the pathway table does not name is told its C3 reading is a default"
            (member "grow-unnamed" (wt-subjects 'pathway-unstated)))
(check-pred "…and a named crop is not" (not (member "grow-wet" (wt-subjects 'pathway-unstated))))
(check-pred "grain grown on no water is refused" (member "grow-dry" (wt-subjects 'transpiration)))
(check-pred "the water a kilogram transpires passes" (not (member "grow-wet" (wt-subjects 'transpiration))))
(check-pred "half of it is refused" (member "grow-thirsty" (wt-subjects 'transpiration)))
(check-pred "a mill passes: it makes no food energy" (not (member "mill" (wt-subjects 'transpiration))))
(check-pred "a kilogram of grain transpires near four hundred litres: C3, 0.12 L per kcal" (let ((l (water-for "grain" 1.0))) (and (> l 300) (< l 500))))

(display "\n── power: a means passes energy at its rating ──\n")
(with-vat vat
  (spec! "spec-hh-iron" %count-unit) (spec! "spec-sp-electricity" "kWh") (spec! "shirt" "kg")
  ;; half an hour of a one-kilowatt iron buys half a kilowatt-hour
  (process! "iron-ok" 0.5)
  (flow! "i1" 'use "spec-hh-iron" "iron-ok" #:qty 1 #:unit %count-unit #:effort (make-measure 0.5 %effort-unit))
  (flow! "i2" 'consume "spec-sp-electricity" "iron-ok" #:qty 0.5 #:unit "kWh")
  (flow! "i3" 'consume "shirt" "iron-ok" #:qty 1) (flow! "i4" 'produce "shirt" "iron-ok" #:qty 1 #:primary #t #:out? #t)
  (recipe! "r-iron" "shirt" '("iron-ok"))
  ;; five kilowatt-hours through the same iron in the same half hour
  (process! "iron-greedy" 0.5)
  (flow! "g1" 'use "spec-hh-iron" "iron-greedy" #:qty 1 #:unit %count-unit #:effort (make-measure 0.5 %effort-unit))
  (flow! "g2" 'consume "spec-sp-electricity" "iron-greedy" #:qty 5 #:unit "kWh")
  (flow! "g3" 'consume "shirt" "iron-greedy" #:qty 1) (flow! "g4" 'produce "shirt" "iron-greedy" #:qty 1 #:primary #t #:out? #t)
  (recipe! "r-greedy-iron" "shirt" '("iron-greedy"))
  ;; the hours read off the process when the use states none
  (process! "iron-timed" 0.5)
  (flow! "t1" 'use "spec-hh-iron" "iron-timed" #:qty 1 #:unit %count-unit)
  (flow! "t2" 'consume "spec-sp-electricity" "iron-timed" #:qty 2 #:unit "kWh")
  (flow! "t3" 'consume "shirt" "iron-timed" #:qty 1) (flow! "t4" 'produce "shirt" "iron-timed" #:qty 1 #:primary #t #:out? #t)
  (recipe! "r-timed-iron" "shirt" '("iron-timed"))
  ;; two irons pass twice the energy
  (process! "iron-pair" 0.5)
  (flow! "p1" 'use "spec-hh-iron" "iron-pair" #:qty 2 #:unit %count-unit #:effort (make-measure 0.5 %effort-unit))
  (flow! "p2" 'consume "spec-sp-electricity" "iron-pair" #:qty 1 #:unit "kWh")
  (flow! "p3" 'consume "shirt" "iron-pair" #:qty 1) (flow! "p4" 'produce "shirt" "iron-pair" #:qty 1 #:primary #t #:out? #t)
  (recipe! "r-pair-iron" "shirt" '("iron-pair")))
(define pw (with-vat vat (lint-recipe-store rs)))
(define (pw-subjects kind) (map finding-subject (filter (lambda (f) (eq? (finding-kind f) kind)) pw)))
(check-pred "a kilowatt for half an hour passes half a kilowatt-hour" (not (member "iron-ok" (pw-subjects 'power))))
(check-pred "five kilowatt-hours through it in that half hour are refused" (member "iron-greedy" (pw-subjects 'power)))
(check-pred "the hours are the process's when the use states none" (member "iron-timed" (pw-subjects 'power)))
(check-pred "two irons pass twice the energy" (not (member "iron-pair" (pw-subjects 'power))))
(check "a means with no rating passes any amount, land's rating is the sun's, a device's its plate"
       (list (rated-kw "oven" #:unit %count-unit) (and (rated-kw "field" #:unit "ha" #:lat 0.0 #:month 3) #t) (rated-kw "spec-hh-iron" #:unit %count-unit))
       '(#f #t 1.0))

(display "\n── motion: nothing moves for free ──\n")
(with-vat vat
  (spec! "porter" %effort-unit)
  ($ rs 'add-resource-spec (make-resource-specification #:id "shelf" #:name "shelf"
                                                        #:default-unit-of-resource %count-unit
                                                        #:keep-in-place #t))
  ;; grain moved through space by nothing
  (process! "teleport" #f)
  (flow! "m1" 'pickup "grain" "teleport" #:qty 1) (flow! "m2" 'dropoff "grain" "teleport" #:qty 1 #:out? #t)
  (recipe! "r-teleport" "grain" '("teleport"))
  ;; carried: the porter's work moves it
  (process! "carry" #f)
  (flow! "c1" 'pickup "grain" "carry" #:qty 1) (flow! "c2" 'dropoff "grain" "carry" #:qty 1 #:out? #t)
  (flow! "c3" 'work "porter" "carry" #:qty #f #:effort (make-measure 0.2 %effort-unit))
  (recipe! "r-carry" "grain" '("carry"))
  ;; driven: a charge burnt moves it
  (process! "drive" #f)
  (flow! "v1" 'pickup "grain" "drive" #:qty 1) (flow! "v2" 'dropoff "grain" "drive" #:qty 1 #:out? #t)
  (flow! "v3" 'consume "spec-sp-electricity" "drive" #:qty 0.1 #:unit "kWh")
  (recipe! "r-drive" "grain" '("drive"))
  ;; ridden: a network's seat-hour carries its traction from the boundary
  ($ rs 'add-resource-spec (make-resource-specification #:id "metro" #:name "metro"
                                                        #:resource-classified-as '("vf:vehicle" "vf:network")
                                                        #:default-unit-of-resource "hours/day"))
  (process! "ride" #f)
  (flow! "r1" 'pickup "grain" "ride" #:qty 1) (flow! "r2" 'dropoff "grain" "ride" #:qty 1 #:out? #t)
  (flow! "r3" 'use "metro" "ride" #:qty 1 #:unit %count-unit #:effort (make-measure 0.6 %effort-unit))
  (recipe! "r-ride" "grain" '("ride"))
  ;; held: through a keep-in-place container the arc is through time
  (process! "hold" #f)
  (flow! "h1" 'pickup "grain" "hold" #:qty 1) (flow! "h2" 'dropoff "grain" "hold" #:qty 1 #:out? #t)
  (flow! "h3" 'use "shelf" "hold" #:qty 1 #:unit %count-unit #:effort (make-measure 0.02 %effort-unit))
  (recipe! "r-hold" "grain" '("hold"))
  ;; a means lugged as a bare good: the metro is something the ride `use`s
  (process! "lug" #f)
  (flow! "l1" 'pickup "metro" "lug" #:qty 1 #:unit %count-unit) (flow! "l2" 'dropoff "metro" "lug" #:qty 1 #:unit %count-unit #:out? #t)
  (flow! "l3" 'work "porter" "lug" #:qty #f #:effort (make-measure 0.2 %effort-unit))
  (recipe! "r-lug" "metro" '("lug"))
  ;; the same means as its own mover: a mode — the `work` resolved from its pickup
  (process! "roll" #f)
  (flow! "o1" 'pickup "metro" "roll" #:qty 1 #:unit %count-unit) (flow! "o2" 'dropoff "metro" "roll" #:qty 1 #:unit %count-unit #:out? #t)
  ($ rs 'add-recipe-flow
     (make-recipe-flow #:id "o3" #:action 'work #:resource-conforms-to "metro"
                       #:effort-quantity (make-measure 0.2 %effort-unit) #:recipe-input-of "roll"
                       #:resolve-from-flow "o1"))
  (recipe! "r-roll" "metro" '("roll")))
(define mv (with-vat vat (lint-recipe-store rs)))
(define (mv-subjects kind) (map finding-subject (filter (lambda (f) (eq? (finding-kind f) kind)) mv)))
(check-pred "a relocation through space by nothing is refused" (member "teleport" (mv-subjects 'free-motion)))
(check-pred "the porter's work moves it" (not (member "carry" (mv-subjects 'free-motion))))
(check-pred "a charge burnt moves it" (not (member "drive" (mv-subjects 'free-motion))))
(check-pred "a network's seat-hour carries its traction from the boundary" (not (member "ride" (mv-subjects 'free-motion))))
(check-pred "through a keep-in-place container the arc is through time" (not (member "hold" (mv-subjects 'free-motion))))
(check-pred "a means relocated as a bare good is refused: the plan holds its capacity, not a lot"
            (member "lug" (mv-subjects 'haul-of-means)))
(check-pred "the same means as the mover of its own mode travels" (not (member "roll" (mv-subjects 'haul-of-means))))
(check-pred "cargo that is no means is carried as it was" (not (member "carry" (mv-subjects 'haul-of-means))))

(test-summary!)
