;;; test-means-gateway.scm — the UC gateway loop: the consensus row, run live.
;;;
;;; patchwork §5 item 1. Every part existed — capacity-bars for the bar,
;;; live-willingness-of for ceilings, #:init for warm starts, #:eco-caps for
;;; landing — and this pins the caller that turns them: the ^planner-service
;;; `means-plan` verb. Two sovereign scopes, worlds built from their OWN
;;; stores inside with-scope, one shared bar, ceilings binding, and the
;;; allocations LANDING: the next `solve` for each scope carries its share as
;;; a standing eco-cap, and the next `means-plan` warm-starts from it.

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet scope root) (playnet vf schemas) (srfi srfi-1))
(use-modules (playnet scope live))
(use-modules (playnet doors service))
(use-modules (goblins) (goblins utils hashmap))
(use-modules (srfi srfi-1))

(define vat (spawn-vat))

(define (seed-scope! sr place)
  ;; the scope's place, so the located build has coordinates to stand on
  ($ ($ sr 'spatial-thing-store) 'add-location
     (make-spatial-thing #:id place #:name place #:lat 40.0 #:long -74.0))
  ;; one recipe: a thing takes 1 unit of the shared means m + a little work
  (let ((rs ($ sr 'recipe-store)))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-make" #:name "Make" #:process-conforms-to "pspec-make"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-use" #:action 'use #:resource-conforms-to "m"
                         #:resource-quantity (make-measure 1 "unit") #:recipe-input-of "rp-make"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-work" #:action 'work #:resource-conforms-to "general"
                         #:effort-quantity (make-measure 0.2 %effort-unit) #:recipe-input-of "rp-make"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-out" #:action 'produce #:resource-conforms-to "thing"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-make"))
    ($ rs 'add-recipe (make-recipe #:id "recipe-thing" #:name "Thing" #:primary-output "thing"
                                   #:recipe-processes (list "rp-make")))))

(define-values (svc-ref sa-ref sb-ref)
  (with-vat vat
    (let* ((sa (spawn-scope-root "Scope A"))
           (sb (spawn-scope-root "Scope B"))
           (svc (spawn ^planner-service
                       (hashmap-set (hashmap-set (hashmap) "sa" sa) "sb" sb))))
      (seed-scope! sa "a") (seed-scope! sb "b")
      (values svc sa sb))))

(define (dem place qty) (list (cons (string-append "thing#" place "@0") qty)))

(display "\n── the standing reaches the means world: a gated recipe draws no bar ──\n")
;; The SAME two scopes, a service spawned with a standing-of that quarantines
;; scope B's only recipe (the seventh injection, beside plan-fn and debts).
;; gather runs through the one door, so B's subproblem has nothing to make
;; and the consensus hands it none of the bar; A takes what it wants.
(with-vat vat
  (let* ((gate (lambda (root sid)
                 (and (equal? sid "sb")
                      `((proc-frag . ()) (admit? . ,(lambda (r) #f))))))
         (svc (spawn ^planner-service
                     (hashmap-set (hashmap-set (hashmap) "sa" sa-ref) "sb" sb-ref)
                     plain-plan-fn #f (list (cons 'standing gate))))
         (r ($ svc 'means-plan "m" 30.0
               (list (list "sa" "a" (dem "a" 12.0))
                     (list "sb" "b" (dem "b" 12.0)))
               '())))
    (check "means-plan answers ok under a standing" (car r) 'ok)
    (let* ((al (assq-ref (cdr r) 'allocations))
           (aa (assoc-ref al "sa")) (ab (assoc-ref al "sb")))
      (check-pred "B, its recipe gated, draws (nearly) none of the bar"
                  (< ab 0.5))
      (check-pred "A is unaffected: it takes what its want needs"
                  (> aa 10.0)))))

(with-vat vat
  (let ((svc svc-ref))
    (display "\n── the loop turns: one bar, two sovereign scopes ──\n")
    (let ((r ($ svc 'means-plan "m" 30.0
                (list (list "sa" "a" (dem "a" 12.0))
                      (list "sb" "b" (dem "b" 12.0)))
                '())))
      (check "means-plan answers ok" (car r) 'ok)
      (let* ((al (assq-ref (cdr r) 'allocations))
             (aa (assoc-ref al "sa")) (ab (assoc-ref al "sb")))
        (check-pred "equal wants split the bar evenly (±5%)"
                    (< (abs (- aa ab)) 1.5))
        (check-pred "the row holds exactly"
                    (< (abs (- (+ aa ab) 30.0)) 1e-6))))

    (display "\n── the ceiling binds through the verb ──\n")
    (let ((r ($ svc 'means-plan "m" 30.0
                (list (list "sa" "a" (dem "a" 12.0))
                      (list "sb" "b" (dem "b" 12.0)))
                '(("sb" . 10.0)))))
      (let* ((al (assq-ref (cdr r) 'allocations))
             (ab (assoc-ref al "sb")))
        (check-pred "sb never granted more than it offered" (<= ab 10.0001))))

    (display "\n── the allocation LANDS: the next solve is bounded by it ──\n")
    ;; sb's standing cap is now 10 unit-hours → at 24 h/unit-period an untimed
    ;; use supports at most 10/24 ≈ 0.42 things; a solve asking for 12 gets
    ;; capped by the LANDED allocation, not by its own wishes.
    (let ((r ($ svc 'solve "sb" `((demand . (("thing" "b" 0 12.0)))))))
      (check "solve answers ok" (car r) 'ok)
      (let ((made (fold (lambda (m a)
                          (+ a (if (equal? "thing" (assq-ref m 'conforms-to))
                                   (assq-ref m 'quantity) 0)))
                        0.0 (assq-ref (cdr r) 'material))))
        (check-pred "production is capped by the UC allocation (≤ 10/24 + ε)"
                    (<= made 0.5))))

    (display "\n── the bar comes off the STANDING means fold (total 'auto) ──\n")
    ;; register through add-scope! — the one door — so each scope's ^means-pool
    ;; wires under the UC root; then each scope holds 15 h/day of m, and the
    ;; fold's total IS the consensus bar nobody has to conjure.
    (let ((cap (lambda (rid loc)
                 (make-economic-resource
                  #:id rid #:conforms-to "m"
                  #:accounting-quantity (make-measure 15 "hours/day") #:onhand-quantity (make-measure 15 "hours/day")
                  #:current-location loc #:primary-accountable "commune"))))
      ($ ($ sa-ref 'observer) 'seed-resource (cap "m-a" "a"))
      ($ ($ sb-ref 'observer) 'seed-resource (cap "m-b" "b")))
    ($ svc 'add-scope! "sa" sa-ref)
    ($ svc 'add-scope! "sb" sb-ref)
    (check "the standing fold reads the bar: 30 unit-hours"
           ($ svc 'means-total "m") 30.0)
    (let ((r ($ svc 'means-plan "m" 'auto
                (list (list "sa" "a" (dem "a" 12.0))
                      (list "sb" "b" (dem "b" 12.0)))
                '())))
      (check "means-plan with 'auto answers ok" (car r) 'ok)
      (check "and the row it held is the fold's own total"
             (assq-ref (cdr r) 'total) 30.0))

    (display "\n── the fold hears its writers: declare-means moves the bar, no rebuild ──\n")
    ($ svc 'declare-means "sa" "EAlice" "m" 5 "hours/day" "a")
    (check "a declared means climbs to the UC bar at once: 35"
           ($ svc 'means-total "m") 35.0)
    ($ svc 'retire-means "sa" "EAlice" "m")
    (check "and retiring it withdraws the same 5: back to 30"
           ($ svc 'means-total "m") 30.0)))

(display "\n── the standing is read once per scope per request ──\n")
;; The gate, the settings and the snapshot of one request share one read of
;; the record (service.scm standing-memo): a reader that counts its calls
;; hears each scope once.
(define standing-reads 0)
(with-vat vat
  (let* ((counting (lambda (root sid) (set! standing-reads (+ standing-reads 1)) '()))
         (svc (spawn ^planner-service
                     (hashmap-set (hashmap-set (hashmap) "sa" sa-ref) "sb" sb-ref)
                     plain-plan-fn #f (list (cons 'standing counting)))))
    ($ svc 'means-plan "m" 30.0
       (list (list "sa" "a" (dem "a" 12.0)) (list "sb" "b" (dem "b" 12.0))) '())
    (check "a means plan over two scopes reads two standings" standing-reads 2)
    (set! standing-reads 0)
    ($ svc 'scope-snapshot "sa" #f)
    (check "a snapshot reads its scope's standing once" standing-reads 1)
    (set! standing-reads 0)
    ($ svc 'scope-snapshot "sa" #f)
    (check "…and the next request reads afresh: nothing is kept between requests" standing-reads 1)))

(test-summary!)
