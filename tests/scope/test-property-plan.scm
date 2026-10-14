;;; test-property-plan.scm — what must not change a plan does not, and what must scale scales.
;;;
;;; Eight seeded bread chains (grow → mill → bake; one to three citizens; stock scarce
;;; against demand, so the plan rations). Laws of a plan that no fixture would think
;;; to state, each tried against the solve itself:
;;;   scaling    twice the people, the stock and the demand is twice the bread and
;;;              twice the hours;
;;;   monotone   more stock never meets less of the demand, less stock never more;
;;;   order      the order the agents, resources, processes and recipes are handed over
;;;              in changes neither the bread nor the hours;
;;;   split      one future carried as two identical half-probability futures is the
;;;              same plan.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/scope/test-property-plan.scm
(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness) (playnet test scope)
             (playnet vf schemas) (playnet scope live)
             (playnet vf beyond scenario)
             (goblins) (goblins utils hashmap) (srfi srfi-1) (ice-9 format))
(define N 8)
(define SEED0 1)
(define PLACE "town")
(define (rnd st n) (random n st))

(define (world st)
  ;; a chain: grow (grain) -> mill (flour) -> bake (bread); random coefficients
  (let* ((g-lab (+ 0.2 (* 0.1 (rnd st 6)))) (m-in (+ 1.0 (* 0.1 (rnd st 5)))) (m-lab (+ 0.1 (* 0.1 (rnd st 4))))
         (b-in (+ 0.5 (* 0.1 (rnd st 6)))) (b-lab (+ 0.2 (* 0.1 (rnd st 5)))))
    `((g-lab . ,g-lab) (m-in . ,m-in) (m-lab . ,m-lab) (b-in . ,b-in) (b-lab . ,b-lab)
      (npersons . ,(+ 1 (rnd st 3))) (stock . ,(+ 2.0 (* 1.0 (rnd st 8)))) (demand . ,(+ 8.0 (rnd st 14))))))

(define (build w mult order-seed)
  (let* ((procs (list (make-recipe-process #:id "grow" #:name "Grow") (make-recipe-process #:id "mill" #:name "Mill")
                      (make-recipe-process #:id "bake" #:name "Bake")))
         (kg (lambda (q) (make-measure q "kg"))) (hr (lambda (q) (make-measure q %effort-unit)))
         (flows (list
                 (make-recipe-flow #:id "gw" #:action 'work #:resource-conforms-to "skill" #:effort-quantity (hr (assq-ref w 'g-lab)) #:recipe-input-of "grow")
                 (make-recipe-flow #:id "go" #:action 'produce #:resource-conforms-to "grain" #:resource-quantity (kg 1.0) #:recipe-output-of "grow" #:is-primary #t)
                 (make-recipe-flow #:id "mw" #:action 'work #:resource-conforms-to "skill" #:effort-quantity (hr (assq-ref w 'm-lab)) #:recipe-input-of "mill")
                 (make-recipe-flow #:id "mi" #:action 'consume #:resource-conforms-to "grain" #:resource-quantity (kg (assq-ref w 'm-in)) #:recipe-input-of "mill")
                 (make-recipe-flow #:id "mo" #:action 'produce #:resource-conforms-to "flour" #:resource-quantity (kg 1.0) #:recipe-output-of "mill" #:is-primary #t)
                 (make-recipe-flow #:id "bw" #:action 'work #:resource-conforms-to "skill" #:effort-quantity (hr (assq-ref w 'b-lab)) #:recipe-input-of "bake")
                 (make-recipe-flow #:id "bi" #:action 'consume #:resource-conforms-to "flour" #:resource-quantity (kg (assq-ref w 'b-in)) #:recipe-input-of "bake")
                 (make-recipe-flow #:id "bo" #:action 'produce #:resource-conforms-to "bread" #:resource-quantity (kg 1.0) #:recipe-output-of "bake" #:is-primary #t)))
         (recipes (list (make-recipe #:id "bread-r" #:name "Bread" #:primary-output "bread" #:recipe-processes (list "grow" "mill" "bake"))))
         (win (all-week-window "00:00" "23:59"))
         (agents (map (lambda (i) (make-agent #:id (format #f "p~a" i) #:type 'person #:name (format #f "P~a" i)
                                              #:primary-location PLACE #:classified-as '() #:availability-window win))
                      (iota (assq-ref w 'npersons))))
         (resources (append
                     (map (lambda (a) (make-economic-resource #:id (string-append "sk-" (agent-id a)) #:conforms-to "skill"
                                         #:classified-as '() #:accounting-quantity (make-measure 1.0 "kg") #:onhand-quantity (make-measure 1.0 "kg")
                                         #:current-location PLACE #:primary-accountable (agent-id a)))
                          agents)
                     (list (make-economic-resource #:id "seed-grain" #:conforms-to "grain" #:classified-as '()
                              #:accounting-quantity (kg (* mult (assq-ref w 'stock))) #:onhand-quantity (kg (* mult (assq-ref w 'stock)))
                              #:current-location PLACE #:primary-accountable "commune"))))
         (spatials (list (make-spatial-thing #:id PLACE #:lat 40.0 #:long -74.0)))
         (shuffle (lambda (l) (if (= order-seed 0) l
                                  (let ((st (seed->random-state order-seed)))
                                    (map cdr (sort (map (lambda (x) (cons (random 1000000 st) x)) l) (lambda (a b) (< (car a) (car b)))))))))
         (agents* (shuffle agents)) (resources* (shuffle resources)) (procs* (shuffle procs)) (recipes* (shuffle recipes)))
    (list procs* flows recipes* agents* resources* spatials)))

(define vat (spawn-vat #:name "meta"))
(define (solve w mult order-seed demand-mult . extra)
  (let ((b (build w mult order-seed)))
    (with-vat vat
      (let* ((procs (list-ref b 0)) (flows (list-ref b 1)) (recipes (list-ref b 2))
             (obs (spawn ^mock `((all-resources . ,(lambda () (list-ref b 4))) (record-event . ,(lambda (e) "ok")))))
             (as  (spawn ^mock `((all-agents . ,(lambda () (list-ref b 3))))))
             (sts (spawn ^mock `((all-locations . ,(lambda () (list-ref b 5))))))
             (rs (mock-recipe-store #:recipes recipes #:procs procs #:flows flows #:split? #t))
             (root (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs)))
        (apply plan-scope->alist root #:demand `(("bread#town@0" . ,(* demand-mult (assq-ref w 'demand))))
               #:backend 'native-c #:reproduce? #f extra)))))

(define (produced r spec)
  (fold (lambda (m a) (if (and (eq? (assq-ref m 'action) 'produce) (equal? (assq-ref m 'conforms-to) spec))
                          (+ a (abs (or (assq-ref m 'quantity) 0))) a))
        0.0 (or (assq-ref r 'material) '())))
(define (hours r) (fold (lambda (m a) (+ a (or (assq-ref m 'effort) 0))) 0.0 (or (assq-ref r 'work) '())))
(define (met r) (or (assq-ref r 'met) 0))
(define (near? a b tol) (< (abs (- a b)) (* tol (max 1.0 (abs a) (abs b)))))

(define bad 0)
(define (verdict seed name ok . detail)
  (check name (and ok #t) #t)
  (unless ok (set! bad (+ bad 1)) (format #t "    seed ~a: ~s~%" seed detail)))

(for-each
 (lambda (k)
   (let* ((seed (+ SEED0 k)) (st (seed->random-state seed)) (w (world st)))
     (catch #t
       (lambda ()
         (let* ((base (solve w 1.0 0 1.0))
                (dbl  (solve (map (lambda (kv) (if (eq? (car kv) 'npersons) (cons 'npersons (* 2 (cdr kv))) kv)) w) 2.0 0 2.0))   ; scale people, stock and demand
                (more (solve w 1.5 0 1.0))                       ; more stock, same demand
                (less (solve w 0.5 0 1.0))
                (shuf (solve w 1.0 (+ 7 seed) 1.0))             ; permuted order
                (split (solve w 1.0 0 1.0 #:scenarios (list (make-planning-scenario "a" #f 0.5 '() #f)
                                                            (make-planning-scenario "b" #f 0.5 '() #f)))))
           ;; scaling: a linear program with no whole counts scales
           (verdict seed "scaling: 2x stock, 2x demand => 2x bread" (near? (* 2 (produced base "bread")) (produced dbl "bread") 0.02)
                    (list (produced base "bread") (produced dbl "bread")))
           (verdict seed "scaling: 2x labour hours" (near? (* 2 (hours base)) (hours dbl) 0.03) (list (hours base) (hours dbl)))
           ;; monotone in stock
           (verdict seed "monotone: more stock never meets less" (>= (+ (met more) 1e-3) (met base)) (list (met less) (met base) (met more)))
           (verdict seed "monotone: less stock never meets more" (<= (met less) (+ (met base) 1e-3)) (list (met less) (met base)))
           ;; order invariance
           (verdict seed "order: shuffled inputs, same bread" (near? (produced base "bread") (produced shuf "bread") 0.01)
                    (list (produced base "bread") (produced shuf "bread")))
           ;; scenario splitting: one future carried as two identical halves is the same plan
           (verdict seed "split: two identical half-probability futures, same bread" (near? (produced base "bread") (produced split "bread") 0.01)
                    (list (produced base "bread") (produced split "bread")))
           (verdict seed "split: …same hours" (near? (hours base) (hours split) 0.02) (list (hours base) (hours split)))
           (verdict seed "split: …same met" (near? (met base) (met split) 0.01) (list (met base) (met split)))
           (verdict seed "order: shuffled inputs, same hours" (near? (hours base) (hours shuf) 0.02) (list (hours base) (hours shuf)))))
       (lambda (key . args) (set! bad (+ bad 1)) (check (format #f "seed ~a: the world plans" seed) #f #t))))
   )
 (iota N))
(test-summary!)
