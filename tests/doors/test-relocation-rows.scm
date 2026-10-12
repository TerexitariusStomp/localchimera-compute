;;; test-relocation-rows.scm — a relocation is a pickup and a dropoff on one Process.
;;;
;;; VF's `move` binds to no Process and a Commitment names no destination (`toLocation`
;;; belongs to the Event), so a planned relocation is what ex-complex.md shows: a Process
;;; whose input is a `pickup` at the origin and whose output is a `dropoff` at the
;;; destination, the pair chaining through the resource it carries. Each run of a haul
;;; (or a bare move between two places) is its own Process, so a pickup finds its dropoff
;;; by the process they share. These properties hold:
;;;
;;;   BARE      stock a plan moves between two places is a pickup and a dropoff on one run;
;;;             no row is a `move`, and no row carries a destination in its note
;;;   HAUL      a freight recipe's cargo is a pickup and a dropoff on its run, and the
;;;             recipe's own `use` row is an input of that same run
;;;   RUNS      the plan states which recipe each run is an instance of
;;;   CARRY     confirming the pair relocates the stock exactly (origin down, destination
;;;             up, the spec's total unchanged), the pickup naming the destination lot and
;;;             the dropoff the lot it arrives in, each row fulfilled by its own event
;;;   TRIP      a pickup and a dropoff stamped at a point in time are no measured trip
;;;
;;; Run: guile --no-auto-compile -q -L module tests/doors/test-relocation-rows.scm

(use-modules (playnet solve ingest))
(use-modules (playnet solve report))
(use-modules ((playnet vf formulas flows) #:select (row-figure))
             (playnet test harness)
             (playnet test books)
             ((playnet utils keyed-id) #:select (keyed-id))
             (playnet knowledge recipes berlin-commune-seed) (playnet knowledge recipes berlin-transit) (playnet knowledge recipes transport) (playnet vf formulas capacity) (playnet scope root) (playnet solve compile) (playnet vf schemas) (srfi srfi-1) (srfi srfi-11)
             (playnet scope live)
             (playnet doors service)
             (playnet solve engine) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand)
             (playnet observation observer)
             (playnet knowledge recipes berlin-transit)
             ((playnet knowledge recipes transport) #:select (car-ride seed-baseline-modes!))
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (srfi srfi-13))

(define E (resolve-module '(playnet solve engine)))
(define (row m)
  `((id . ,(commitment-id m)) (action . ,(commitment-action m)) (conforms-to . ,(commitment-resource-conforms-to m))
    (quantity . ,(row-figure m))
    (at-location . ,(commitment-at-location m)) (input-of . ,(commitment-input-of m)) (output-of . ,(commitment-output-of m))
    (classified-as . ,(commitment-resource-classified-as m)) (note . ,(commitment-note m))))

(display "\n── BARE: stock a plan moves between places ──\n")
(declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.045)) #:periods '(0)
                #:templates '() #:movable '("bread") #:riders '() #:mode-recipes (list car-ride))
(hash-set! *init* (lg "bread" (cell "A" 0)) 10.0)
(hash-set! *demand* (lg "bread" (cell "B" 0)) 5.0)
(define bare-rows
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x0 ((module-ref E 'located-warm) cols ncol idx))
             (x (call-with-values (lambda () (solve-native forms labform x0)) (lambda (x . _) x))))
        (map row ((@ (playnet solve report) plan->material) x cols idx))))))
(define (acts rows) (map (lambda (r) (assq-ref r 'action)) rows))
(check "no row of the plan is a move" (filter (lambda (a) (eq? a 'move)) (acts bare-rows)) '())
(check "no row carries a destination in its note" (filter (lambda (r) (assq-ref r 'note)) bare-rows) '())
(define pick-a (find (lambda (r) (and (eq? 'pickup (assq-ref r 'action)) (equal? "A" (assq-ref r 'at-location)))) bare-rows))
(define drop-b (and pick-a (find (lambda (r) (and (eq? 'dropoff (assq-ref r 'action))
                                                   (equal? (assq-ref r 'output-of) (assq-ref pick-a 'input-of))))
                                 bare-rows)))
(check-pred "the bread leaves A as a pickup that is an input of a run" (and pick-a (string? (assq-ref pick-a 'input-of))))
(check-pred "…and arrives at B as a dropoff that is an output of the same run"
            (and drop-b (equal? "B" (assq-ref drop-b 'at-location))))
(check-pred "…carrying the same quantity of the same spec"
            (and drop-b (equal? (assq-ref pick-a 'conforms-to) (assq-ref drop-b 'conforms-to))
                 (< (abs (- (assq-ref pick-a 'quantity) (assq-ref drop-b 'quantity))) 1e-9)))
(check "…and the run is an instance of the mode the material manner rides"
       (and pick-a (assoc-ref ((module-ref E 'plan-runs)) (assq-ref pick-a 'input-of))) "rp-ride")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (seed-baseline-modes! ($ scope 'recipe-store))
    (let ((obs ($ scope 'observer)))
      ($ obs 'seed-resource (res "R" "bread" 10.0 "A" #:acct "commune"))
      (enact-rows scope (list (flow-row "pu" 'pickup "bread" 5.0 "A" #:in "run1")
                              (flow-row "do" 'dropoff "bread" 5.0 "B" #:out "run1"))
                  #:runs '(("run1" . "rp-ride")))
      (check "…and once carried, its Process is based on that mode's specification"
             ($ obs 'process-spec "run1") "pspec-car"))))

(display "\n── HAUL: a freight recipe's cargo is carried on a run of that recipe ──\n")
(define hvat (spawn-vat #:name "relocation-haul"))
(define hroot (with-vat hvat (spawn-scope-root "Berlin")))
(with-vat hvat
  (seed-berlin-commune! hroot #:transit? #t)
  ($ ($ hroot 'observer) 'seed-resource
     (make-economic-resource #:id "crates" #:name "crates" #:conforms-to "spec-bt-freight" #:classified-as '()
       #:accounting-quantity (make-measure 500.0 "kg") #:onhand-quantity (make-measure 500.0 "kg") #:current-location "berlin-commune-farm"
       #:primary-accountable "commune-berlin-commune-farm")))
(define haul-plan
  (with-vat hvat
    (let ((held ($ ($ hroot 'observer) 'all-resources)))
      (plan-scope->alist hroot #:manners berlin-transit-manners
        #:eco-caps (append (map (lambda (kv) (cons (car kv) (* 50.0 (cdr kv))))
                                (held-svc-caps held '(0) #:hours-of resource-window-hours
                                               #:specs '("spec-bt-transit-pass" "spec-bt-cargo-bike")))
                           (svc-eco-caps (map (lambda (spec) (list spec "berlin-commune-farm" 200.0))
                                              '("spec-bt-ubahn" "spec-bt-sbahn" "spec-bt-tram" "spec-bt-bus"))
                                         '(0)))
        #:demand (list (cons "spec-bt-freight#berlin-markthalle@0" 400.0))))))
(define haul-rows (assq-ref haul-plan 'material))
(define (freight-rows act)
  (filter (lambda (m) (and (eq? act (assq-ref m 'action)) (equal? "spec-bt-freight" (assq-ref m 'conforms-to)))) haul-rows))
(check "no freight is consumed or produced: it is carried"
       (append (freight-rows 'consume) (freight-rows 'produce)) '())
(define pickups (freight-rows 'pickup))
(check-pred "the cargo is picked up at the farm and dropped off at the market"
            (and (pair? pickups)
                 (every (lambda (m) (equal? "berlin-commune-farm" (assq-ref m 'at-location))) pickups)
                 (every (lambda (m) (equal? "berlin-markthalle" (assq-ref m 'at-location))) (freight-rows 'dropoff))))
(check "…and every freight row states the unit its spec counts in"
       (delete-duplicates (map (lambda (m) (assq-ref m 'unit)) (append pickups (freight-rows 'dropoff)))) '("kg"))
(check-pred "…each pickup has its dropoff on the same run"
            (every (lambda (m) (any (lambda (d) (and (eq? 'dropoff (assq-ref d 'action))
                                                     (equal? (assq-ref d 'output-of) (assq-ref m 'input-of))
                                                     (equal? (assq-ref d 'conforms-to) (assq-ref m 'conforms-to))))
                                    haul-rows))
                   pickups))
(check-pred "…and the run's own vehicle service is an input of that run"
            (every (lambda (m)
                     (any (lambda (u) (and (eq? 'use (assq-ref u 'action)) (equal? (assq-ref m 'input-of) (assq-ref u 'input-of))))
                          haul-rows))
                   pickups))
(display "\n── RUNS: the plan says which recipe each run is an instance of ──\n")
(check-pred "every run names a recipe process of the scope"
            (every (lambda (m) (let ((r (assoc (assq-ref m 'input-of) (assq-ref haul-plan 'runs))))
                                 (and r (string? (cdr r)) (string-prefix? "rp-bt-" (cdr r)))))
                   pickups))

(display "\n── CARRY: the cargo exists the whole way ──\n")
(define (pair-rows q)
  (list (flow-row "pu" 'pickup "crates" q "A" #:in "run1")
        (flow-row "do" 'dropoff "crates" q "B" #:out "run1")))
(define carried-id (keyed-id "carry" "run1" "crates"))
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let* ((obs ($ scope 'observer)) (rows (pair-rows 30.0)))
      ($ obs 'seed-resource (res "R" "crates" 100.0 "A" #:acct "commune"))
      (confirm scope (car rows))
      (check "after the pickup alone the spec's total is unchanged: nothing has been lost on the way"
             (spec-total obs "crates") 100.0)
      (check "…the origin holds what was left"        (spec-total obs "crates" #:place "A") 70.0)
      (check "…and the cargo is a lot of its own, in transit (at no place)"
             (list (onhand-of obs carried-id) (spec-total obs "crates" #:place "B")) '(30.0 0.0))
      (confirm scope (cadr rows))
      (check "after the dropoff the cargo has landed" (list (spec-total obs "crates" #:place "A") (spec-total obs "crates" #:place "B")) '(70.0 30.0))
      (check "…the spec's total is still unchanged"   (spec-total obs "crates") 100.0)
      (check "…and nothing is left on the way"        (onhand-of obs carried-id) 0.0)
      (let ((pu (car ($ obs 'fulfilled-by "pu"))) (dr (car ($ obs 'fulfilled-by "do"))))
        (check "each row is fulfilled by an event of its own action"
               (list (economic-event-action pu) (economic-event-action dr)) '(pickup dropoff))
        (check "the pickup takes from the origin lot into the carried lot"
               (list (economic-event-resource-inventoried-as pu) (economic-event-to-resource-inventoried-as pu))
               (list "R" carried-id))
        (check "the dropoff takes from the carried lot into the destination's"
               (list (economic-event-resource-inventoried-as dr) (economic-event-to-resource-inventoried-as dr))
               (list carried-id "res|crates|B"))
        (check "both are events of the one agent that holds the stock"
               (list (economic-event-provider pu) (economic-event-receiver pu)
                     (economic-event-provider dr) (economic-event-receiver dr))
               '("commune" "commune" "commune" "commune"))))))

(display "\n── ENACT: a whole pair at once ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let* ((obs ($ scope 'observer)))
      ($ obs 'seed-resource (res "R" "crates" 100.0 "A" #:acct "commune"))
      (let ((r (enact-rows scope (pair-rows 30.0))))
        (check "no row is left waiting" (cdr r) '())
        (check "the stock stands where the plan carried it"
               (list (spec-total obs "crates" #:place "A") (spec-total obs "crates" #:place "B") (spec-total obs "crates")) '(70.0 30.0 100.0))))))

(display "\n── CHAIN: nothing arrives that has not been picked up ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let* ((obs ($ scope 'observer)) (rows (pair-rows 30.0)))
      ($ obs 'seed-resource (res "R" "crates" 100.0 "A" #:acct "commune"))
      ($ obs 'seed-resource (res "D" "crates" 20.0 "B" #:acct "commune"))
      (check-pred "a dropoff before its pickup is refused"
                  (catch #t (lambda () (confirm scope (cadr rows)) #f) (lambda _ #t)))
      (check "…and the books are as they were" (list (spec-total obs "crates" #:place "A") (spec-total obs "crates" #:place "B")) '(100.0 20.0))
      (confirm scope (car rows))
      (confirm scope (flow-row "do1" 'dropoff "crates" 10.0 "B" #:out "run1"))
      (check "part of the cargo lands, the rest is still on the way" (list (onhand-of obs "D") (onhand-of obs carried-id)) '(30.0 20.0))
      (confirm scope (flow-row "do2" 'dropoff "crates" 20.0 "B" #:out "run1"))
      (check "a destination that already holds the cargo's spec takes it in" (onhand-of obs "D") 50.0)
      (check "…and the origin gave it up" (onhand-of obs "R") 70.0)
      (check-pred "…and no more arrives than was picked up"
                  (catch #t (lambda () (confirm scope (flow-row "do3" 'dropoff "crates" 1.0 "B" #:out "run1")) #f)
                    (lambda _ #t))))))

(display "\n── AMBIENT: a flow with no stock behind it makes no lot ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let* ((obs ($ scope 'observer))
           (row `((id . "amb.do") (action . dropoff) (conforms-to . "sunlight") (quantity . 5.0)
                  (at-location . "B") (input-of . #f) (output-of . "run9") (classified-as . ("ambient")) (note . #f))))
      ($ obs 'seed-resource (res "R" "crates" 100.0 "A" #:acct "commune"))
      (let ((before (resource-ids obs)))
        (confirm scope row)
        (check "an ambient dropoff names no lot and the books hold the lots they held"
               (resource-ids obs) before)))))

(display "\n── RESOLVE: stock on the way is counted where the plan lands it ──\n")
;; The books keep the cargo at no place until its dropoff says it has arrived, so a solve
;; that read only places would not see it and would haul the same stock again. The solve is
;; given the previous plan's rows, and the cargo counts at the place its open dropoff lands it.
(define (replan resources demand-q)
  (declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.045)) #:periods '(0)
                  #:templates (compile-recipe (list (rp "bake" "Bake"))
                                              (list (out "b1" "bread" 1.0 "bake") (wk* "b2" "baker" 1.0 "bake")))
                  #:movable '("bread") #:tau 0.01 #:riders '())
  (ingest-stock! resources)
  (hash-set! *demand* (lg "bread" (cell "B" 0)) demand-q)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x0 ((module-ref E 'located-warm) cols ncol idx))
             (x (call-with-values (lambda () (solve-native forms labform x0)) (lambda (x . _) x))))
        (map row ((@ (playnet solve report) plan->material) x cols idx))))))
(define (hauled rows)                  ; the quantity the plan picks up at A
  (fold + 0.0 (map (lambda (r) (assq-ref r 'quantity))
                   (filter (lambda (r) (and (eq? 'pickup (assq-ref r 'action)) (equal? "A" (assq-ref r 'at-location)))) rows))))
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let* ((obs ($ scope 'observer))
           (plan1 (begin ($ obs 'seed-resource (res "R" "bread" 100.0 "A" #:acct "commune"))
                         (replan ($ obs 'all-resources) 30.0)))
           (pu (find (lambda (r) (and (eq? 'pickup (assq-ref r 'action)) (equal? "A" (assq-ref r 'at-location)))) plan1))
           ;; what the plan hauls: a want of 30 against a carry priced at τ·km lands
           ;; a little under 30, and the books keep the plan's own figure
           (q  (assq-ref pu 'quantity))
           (run (assq-ref pu 'input-of)))
      (check-pred "the first plan hauls the bread to B" (> (hauled plan1) 29.0))
      (let ((do-row (find (lambda (r) (and (eq? 'dropoff (assq-ref r 'action)) (equal? run (assq-ref r 'output-of))
                                           (equal? "B" (assq-ref r 'at-location)))) plan1)))
        ;; the pickup is confirmed, the dropoff is not yet
        (enact-rows scope (list pu))
        (check "the haul is on the way, at no place" (list (onhand-of obs (keyed-id "carry" run "bread")) (spec-total obs "bread" #:place "B")) (list q 0.0))
        (check "the lot on the way counts at the place its dropoff lands it"
               (map (lambda (r) (list (economic-resource-id r) (economic-resource-current-location r)
                                      (mq (economic-resource-onhand-quantity r))))
                    (filter (lambda (r) (equal? "B" (economic-resource-current-location r)))
                            (arriving-lots obs plan1 ($ obs 'all-resources))))
               (list (list (keyed-id "carry" run "bread") "B" q)))
        (let ((blind (replan (arriving-lots obs '() ($ obs 'all-resources)) 30.0))
              (seen  (replan (arriving-lots obs plan1 ($ obs 'all-resources)) 30.0)))
          (check-pred "a solve that sees only places hauls the on-the-way bread again" (> (hauled blind) 20.0))
          ;; THE LIVE SHAPE: plan-scope under a world READER whose custody view stands on
          ;; its own (the commune's ignores what it is handed): the arrivals must land on
          ;; that view, or cargo on its way is invisible in production (measured
          ;; 2026-10-12: the view discarded them, and the bread on its way was hauled
          ;; again). The view holds the books as they stand, the bread on its way at no
          ;; place among them; told the plan's open dropoff, the solve finds it landing
          ;; at B and hauls that much less.
          (let* ((rs ($ scope 'recipe-store))
                 (raw ($ obs 'all-resources))
                 (through (lambda (arriving)
                            (call-with-values
                                (lambda () (plan-scope scope #:demand (list (cons (lg "bread" (cell "B" 0)) 30.0))
                                                       #:periods '(0) #:movable '("bread")
                                                       #:resource-view (lambda (_) raw) #:arriving arriving))
                              (lambda (ints coms material . _) (hauled (map row material)))))))
            ;; a recipe that MAKES bread, so a lot of it is stock the plan may draw on
            ;; (a good no recipe makes is a raw, drawn by a process alone); it draws a
            ;; flour nobody holds, so baking is never the answer
            ($ rs 'add-recipe (make-recipe #:id "r-bread" #:name "Bread" #:primary-output "bread" #:recipe-processes (list "bake")))
            ($ rs 'add-recipe-process (rp "bake" "Bake"))
            ($ rs 'add-recipe-flow (out "b1" "bread" 1.0 "bake"))
            ($ rs 'add-recipe-flow (in "b0" "flour" 1.0 "bake"))
            (let ((blind* (through '())) (seen* (through plan1)))
              (check-pred "under a reader, the plan's arrivals land on the view it stands on: far less is hauled"
                          (< seen* (- blind* 10.0)))))
          (check-pred "a solve told what the plan lands plans as if it had landed"
                      (begin (enact-rows scope (list do-row))
                             (< (abs (- (hauled seen) (hauled (replan ($ obs 'all-resources) 30.0)))) 1e-6)))
          (check-pred "…and that is far less than the blind solve hauls" (< (hauled seen) (/ (hauled blind) 2)))
          #t)))))

(display "\n── TRIP: a point in time measures no duration ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      ($ obs 'seed-resource (res "R" "crates" 100.0 "A" #:acct "commune"))
      (enact-rows scope (pair-rows 30.0))
      (check "a pair of point-in-time events is no trip for the arc table" ($ obs 'arc-observations) '()))))

(test-summary!)
