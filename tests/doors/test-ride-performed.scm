;;; test-ride-performed.scm — a planned ride is performed, and the books answer.
;;;
;;; Where a person is belongs to the position machinery (set-position, the live fix,
;;; agent-position-predicate), and a VF flow is the wrong tool for it: a person is an
;;; Agent, and a presence is neither made at one place nor used up at another. So the
;;; plan commits what VF has verbs for: the rider's hours (`work`), the vehicle's
;;; service (`use` of the vehicle's specification), the fuel (`consume`). These
;;; properties hold:
;;;
;;;   PLACEMENT  no commitment and no event of a plan names a presence (`Pres|…`)
;;;   USE        a vehicle's service is a `use` row of the vehicle's own specification,
;;;              an input of the ride, with no stock behind it
;;;   SELF       the rider's own hours on the way are a work commitment of the rider
;;;   WHOLE      enacting the plan leaves no row waiting and creates no phantom resource
;;;   TRIP       a trip performed through the journey door is filed under the scope's
;;;              mode for it, and a performed trip moves the next solve's arc hours
;;;   POSITION   arriving states no position: where a person is stays what they declared
;;;              or share (the live fix), and a trip never speaks for them
;;;
;;; Run: guile --no-auto-compile -q -L module tests/doors/test-ride-performed.scm

(use-modules ((playnet vf formulas flows) #:select (row-figure))
             (playnet test harness)
             (playnet test books)
             (playnet knowledge recipes berlin-commune-seed) (playnet knowledge recipes berlin-transit) (playnet knowledge recipes transport) (playnet solve compile) (playnet vf schemas) (srfi srfi-1) (srfi srfi-11)
             (playnet scope live)
             (playnet doors service) (playnet doors position)
             (playnet solve engine) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas)
             ((playnet vf facts person-facts) #:select (position-key))
             (playnet knowledge dsl shorthand)
             ((playnet knowledge recipes transport) #:select (mode-recipe seed-baseline-modes!))
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (srfi srfi-13))

;; Dana, a doctor who holds "walk", at A; a car and its driver at A; patients wait at B
(define WALK (mode-recipe "walk" #:skill "walk" #:pace 0.15))
(define RIDE (mode-recipe "ride" #:pace 0.02 #:uses '(("car" . 0.01)) #:work '("driving" . 0.05)))
(declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.045)) #:periods '(0)
                #:templates (compile-recipe (list (rp "treat" "Treat"))
                                            (list (out "t1" "treated" 1.0 "treat") (wk* "t2" "doctor" 1.0 "treat")))
                #:riders (list (list "Dana" "A" '("doctor" "walk") 40.0))
                #:mode-recipes (list WALK RIDE))
(hash-set! *cap* (lg "Svc|car" (cell "A" 0)) 1.0)
(hash-set! *cap* (lab-good "driving" (cell "A" 0)) 40.0)
(hash-set! *demand* (lg "treated" (cell "B" 0)) 20.0)

(define E (resolve-module '(playnet solve engine)))
(define planned
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x0 ((module-ref E 'located-warm) cols ncol idx))
             (x (call-with-values (lambda () (solve-native forms labform x0)) (lambda (x . _) x))))
        ((module-ref E 'plan->material) x cols idx)))))
(define (row m)
  `((id . ,(commitment-id m)) (action . ,(commitment-action m)) (conforms-to . ,(commitment-resource-conforms-to m))
    (quantity . ,(row-figure m))
    (at-location . ,(commitment-at-location m)) (input-of . ,(commitment-input-of m)) (output-of . ,(commitment-output-of m))
    (classified-as . ,(commitment-resource-classified-as m)) (note . ,(commitment-note m))))
(define rows (map row planned))
(define (rows-of prefix) (filter (lambda (r) (string-prefix? prefix (assq-ref r 'conforms-to))) rows))

(display "\n── PLACEMENT, USE: the plan's ride rows are what VF has verbs for ──\n")
(check "no row of the plan names a presence"
       (filter (lambda (r) (string-contains (assq-ref r 'conforms-to) "Pres|")) rows) '())
(check "the car's service is a `use` row of the car's own specification"
       (map (lambda (r) (list (assq-ref r 'action) (assq-ref r 'conforms-to) (assq-ref r 'input-of)))
            (filter (lambda (r) (equal? "car" (assq-ref r 'conforms-to))) rows))
       '((use "car" "ride.Dana.ride")))
(check "…and no row consumes a service as if it were stock"
       (filter (lambda (r) (string-contains (assq-ref r 'conforms-to) "Svc|")) rows) '())

(display "\n── SELF: the rider's own hours on the way are work the plan commits ──\n")
(define self-work
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x0 ((module-ref E 'located-warm) cols ncol idx))
             (x (call-with-values (lambda () (solve-native forms labform x0)) (lambda (x . _) x))))
        (call-with-values (lambda () ((module-ref E 'plan->work) x cols idx))
          (lambda (ints coms . rest)
            (filter (lambda (c) (string-prefix? "ride.Dana." (or (commitment-input-of c) ""))) coms)))))))
(check-pred "the plan commits the rider's hours on a ride to her"
            (and (pair? self-work) (every (lambda (c) (equal? "Dana" (commitment-provider c))) self-work)))
(check-pred "…in the hours the budget charges (the ride's level times its arc's transit time)"
            (every (lambda (c) (> (measure-has-numerical-value (commitment-effort-quantity c)) 0.05)) self-work))

(display "\n── WHOLE: the rows record with no stock behind them ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let* ((obs ($ scope 'observer))
           (r   (enact-rows scope rows)))
      (check "no row is left waiting" (cdr r) '())
      (check "no phantom resource of a presence or a service appears"
             (filter (lambda (id) (or (string-contains id "Pres|") (string-contains id "Svc|"))) (resource-ids obs)) '())
      (check "the `use` row is fulfilled by a `use` event that names no resource"
             (let* ((ur (car (filter (lambda (r) (eq? 'use (assq-ref r 'action))) rows)))
                    (evs ($ obs 'fulfilled-by (assq-ref ur 'id))))
               (and (pair? evs)
                    (eq? 'use (economic-event-action (car evs)))
                    (not (economic-event-resource-inventoried-as (car evs)))))
             #t))))

(display "\n── TRIP: a trip performed through the journey door is filed under its mode ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let* ((obs ($ scope 'observer))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "org:t" scope))))
      (seed-baseline-modes! ($ scope 'recipe-store))
      ($ svc 'set-position "org:t" "Dana" 0 "A")                ; Dana declared she is at A
      (let* ((began ($ svc 'journey-begin "org:t" "Dana" "A" "B" "pedestrian"))
             (cid (assq-ref (cdr began) 'commitment)))
        (check "the journey begins" (car began) 'ok)
        (check "its trip is based on the scope's walking mode"
               (process-based-on (car ($ obs 'all-processes))) "pspec-walk")
        (sleep 1)
        (check "arrival is accepted" (car ($ svc 'journey-end "org:t" "Dana" cid "A" "B" "pedestrian")) 'ok)
        (check "one trip is observed, and the table can learn from it" (length ($ obs 'arc-observations)) 1)
        (check "arriving at B leaves her declared position where she put it"
               (assq-ref ($ ($ scope 'plan-store) 'get-meta (position-key "Dana" 0)) 'place) "A")))))

(define live-arc-table (@@ (playnet scope live) live-arc-table))
(display "\n── LOOP: a performed trip moves the next solve's arc hours; with none, nothing moves ──\n")
;; The arc table is the routing priors folded with the trips the federation performed.
;; With no trip it is the priors alone (here: none), and the solve reads geometry; a
;; trip performed through the journey door is a measurement of its arc, under the
;; manner of the mode it was filed under.
(let-values (((vat scope) (fresh-scope "Berlin")))
  (with-vat vat
    (seed-berlin-commune! scope #:transit? #t))
  (with-vat vat
    (let* ((obs ($ scope 'observer))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "org:t" scope)))
           (arc "berlin-commune-farm|berlin-markthalle|pedestrian")
           (table (lambda () (live-arc-table obs '() #:manner-of (trip-manner-of scope))))
           (arc-hours-after-solve
            (lambda ()
              (plan-scope->alist scope #:manners berlin-transit-manners
                                 #:demand (list (cons "food#berlin-commune-farm@0" 20000.0)))
              (hash-ref *arc-hours* arc #f))))
      (check "with no trip performed, the table holds no measurement of the arc" (assoc-ref (table) arc) #f)
      (check "…and the solve reads none" (arc-hours-after-solve) #f)
      (let* ((began ($ svc 'journey-begin "org:t" "agent-ana" "berlin-commune-farm" "berlin-markthalle" "pedestrian"))
             (cid (assq-ref (cdr began) 'commitment)))
        (sleep 1)
        ($ svc 'journey-end "org:t" "agent-ana" cid "berlin-commune-farm" "berlin-markthalle" "pedestrian"))
      (check-pred "a performed walk measures its arc" (let ((h (assoc-ref (table) arc))) (and h (> h 0.0))))
      (check-pred "…and the next solve reads the measured hours" (let ((h (arc-hours-after-solve))) (and h (> h 0.0)))))))

(test-summary!)
