;;; test-plan-schedules-obtain.scm — closing the back-chaining loop.
;;;
;;; Until now compliance was a GATE: the observer-aware decorate prunes a vend
;;; column when the permit isn't already HELD (test-food-distribution). This test
;;; closes the other half — the plan SCHEDULING the registration itself, within
;;; ONE solve. The permit is modelled as a produced input GOOD:
;;;   VEND        consumes 1 "Food Establishment Permit" → produces a public meal
;;;   OBTAIN      works admin labour + a fee            → produces 1 permit
;;; gather-recipes puts every recipe's processes in one LP, and `consume` goes
;;; through material balance, so demand for a public meal back-chains: meal → VEND
;;; → needs a permit → OBTAIN → needs administration labour. The plan allocates
;;; admin hours to REGISTER, with no permit granted up front and no planner edit.
;;;
;;; The witness is a trio: the public meal is fed IFF the obtain-permit recipe is
;;; available AND an admin worker exists to run it — proving the plan actually
;;; schedules obtain-permit as real work, not a bypass. Pure solver ⇒ no blake3.
;;;
;;; Run: guile -L module tests/scope/test-plan-schedules-obtain.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness) (playnet knowledge recipes store) (playnet vf schemas) (playnet scope live)
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1) (ice-9 format))

;; tests run from the repository root (each file's own Run: line); the root is
;; resolved by its marker rather than by current-filename, which is #f or
;; -L-relative depending on how the file was loaded — both wrong for paths.
(define root (or (and (file-exists? "module/playnet/solve/engine.scm") (getcwd))
                 (error "run this test from the repository root")))
(use-modules (playnet legal crossings))
(use-modules (playnet legal registry))
(use-modules (playnet knowledge recipes compliance-processes))

(define (empty-rs)
  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))
(define win (all-week-window "00:00" "23:59"))
;; VEND at foodville consumes a permit; nothing is granted up front.
(define (seed-vend rs)
  (for-each (lambda (s) ($ rs 'add-resource-spec s))
            (list (make-resource-specification #:id "produce" #:name "Produce"
                                               #:resource-classified-as '()
                                               #:default-unit-of-resource "kg")
                  (make-resource-specification #:id "public-meal" #:name "Public Meal"
                                               #:resource-classified-as '()
                                               #:default-unit-of-resource "meal")
                  (make-resource-specification #:id "fd-cook" #:name "Cook"
                                               #:resource-classified-as '()
                                               #:default-unit-of-resource %effort-unit)))
  ($ rs 'add-recipe-process (make-recipe-process #:id "rp-vend" #:name "Vend Meal to Public"
                                                 #:has-duration (make-duration 0.5 %effort-unit)))
  ($ rs 'add-recipe-flow (make-recipe-flow #:id "vf-produce" #:action 'consume
                                           #:resource-conforms-to "produce"
                                           #:resource-quantity (make-measure 1.0 "kg")
                                           #:recipe-input-of "rp-vend"))
  ($ rs 'add-recipe-flow (make-recipe-flow #:id "vf-cook" #:action 'work
                                           #:resource-conforms-to "fd-cook"
                                           #:effort-quantity (make-measure 0.5 %effort-unit)
                                           #:recipe-input-of "rp-vend"))
  ($ rs 'add-recipe-flow (make-recipe-flow #:id "vf-permit" #:action 'consume
                                           #:resource-conforms-to "Food Establishment Permit"
                                           #:resource-quantity (make-measure 1.0 "cert")
                                           #:recipe-input-of "rp-vend"))
  ($ rs 'add-recipe-flow (make-recipe-flow #:id "vf-out" #:action 'produce
                                           #:resource-conforms-to "public-meal"
                                           #:resource-quantity (make-measure 1.0 "meal")
                                           #:recipe-output-of "rp-vend" #:is-primary #t))
  ($ rs 'add-recipe (make-recipe #:id "recipe-vend" #:name "Vend Meal to Public"
                                 #:primary-output "public-meal" #:recipe-processes (list "rp-vend"))))

;; a run: does the obtain-permit recipe exist? is there an admin worker to run it?
(define (run obtain? admin?)
  (define v (spawn-vat))
  (with-vat v
    (let ((rs (empty-rs)))
      (seed-compliance-process-catalogue rs)
      (seed-vend rs)
      (when obtain?
        (seed-obtain-permit-recipe rs #:permit-spec "Food Establishment Permit"
                                   #:authority "auth:foodville-health" #:fee 1 #:admin-hours 1.0))
      (let* ((resources
              (append
               (list (er "pr" "produce" "a" #:place "foodville" #:qty 100.0)
                     (er "money" "spec-state-money" "a" #:place "foodville" #:qty 100.0)
                     (er "form" "filing" "a" #:place "foodville" #:qty 100.0)
                     (er "ck" "fd-cook" "w-cook" #:place "foodville" #:qty 1.0))
               (if admin? (list (er "adm" "spec-admin" "w-admin" #:place "foodville" #:qty 1.0)) '())))
             (agents (append (list (make-agent #:id "w-cook" #:type 'person
                                               #:primary-location "foodville" #:classified-as '()
                                               #:availability-window win))
                             (if admin? (list (make-agent #:id "w-admin" #:type 'person
                                                          #:primary-location "foodville"
                                                          #:classified-as '()
                                                          #:availability-window win)) '())))
             (spatials (list (make-spatial-thing #:id "foodville" #:lat 40.0 #:long -74.0)))
             (obs (spawn ^mock `((all-resources . ,(lambda () resources))
                                 (skill-hours-of . ,(lambda (a) '())) (record-event . ,(lambda (e) "ok")))))
             (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
             (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
             (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs)))
        ;; a permit is NOT a free raw good — with no producer and no stock its
        ;; balance is 0, so VEND can only run if the plan PRODUCES one (obtain).
        (call-with-values
          (lambda () (plan-scope scope #:demand (list (cons "public-meal#foodville@0" 1.0))
                                 #:backend 'native-c #:never-raw '("Food Establishment Permit")))
          (lambda (i c m fill x n r) fill))))))

(define fill-full     (run #t #t))   ; obtain recipe + admin worker → the plan can register
(define fill-no-admin (run #t #f))   ; obtain recipe but NO admin worker → cannot register
(define fill-no-recipe(run #f #t))   ; admin worker but NO obtain recipe → no way to make a permit

(display "\n── closing the loop: the plan schedules obtain-permit to feed the public ──\n")
(format #t "  fill  [obtain+admin]=~,3f   [no admin worker]=~,3f   [no obtain recipe]=~,3f\n"
        fill-full fill-no-admin fill-no-recipe)
(check-pred "with the obtain recipe AND an admin worker, the plan REGISTERS and feeds the public"
            (> fill-full 0.95))
(check-pred "remove the admin worker → the plan cannot run obtain-permit → the public goes unfed"
            (< fill-no-admin 0.05))
(check-pred "remove the obtain recipe → no way to make a permit → the public goes unfed"
            (< fill-no-recipe 0.05))
(check-pred "so feeding the public here REQUIRED the plan to schedule the registration"
            (and (> fill-full 0.95) (< fill-no-admin 0.05) (< fill-no-recipe 0.05)))

(display "\n")
(test-summary!)
