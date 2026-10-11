;;; test-horizon-read.scm — the solve's own horizon read, and the escalation
;;; door that reads it: which processes defend a floor, each branch's chain
;;; reshaping, and an unbound floor named — never silently.
;;;
;;; docs/planning/solve/commitment-horizon.md. Fixture: (playnet test planner bread).

(use-modules (playnet test scope))
(use-modules (playnet test harness)
             (playnet vf schemas) (playnet vf beyond scenario) (srfi srfi-1)
             (playnet scope live)
             (playnet plan accepts)
             (playnet plan store)
             (playnet test planner bread)
             ((playnet solve engine) #:select (set-period-span! time->period)) ((playnet solve ingest) #:select (declared-partition))
             ((playnet utils clock) #:select (now instant->unix instant->civil))
             (goblins) (goblins vat)
             (srfi srfi-1))

(define today (substring (instant->civil (inexact->exact (round (now)))) 0 10))


(display "\n── 1. the solve caches its own horizon read for the gate ──\n")

(define vat (spawn-vat #:name "horizon-read"))
(define-values (scope ps als) (with-vat vat (spawn-bread-scope)))
;; The floor stands TOMORROW. A world that declares no partition stands on the
;; standing one, laid from today (engine standing-partition), so period 0 began
;; at last midnight: a floor there has its forcing point behind it at any hour
;; this suite runs (section 3 reads exactly that). Period 1 begins at the next
;; midnight — the forcing point is ahead, whatever the clock says now.
(with-vat vat (plan-scope->alist scope
                #:periods '(0 1) #:storable bread-storable   ; today's soil is tomorrow's: the stock stands at period 0
                #:demand '(("bread#town@1" . 4.0))
                #:repro-floors '(("bread#town@1" . 1.0))
                #:scenarios (list (make-planning-scenario "slow" #f 0.5 '((duration "bake" 4.0)) #f)
                                  ;; a DROUGHT: bake yields half — no duration datum
                                  ;; anywhere, the chain lengthens anyway
                                  (make-planning-scenario "drought" #f 0.5 '(("bake" . 0.5)) #f))
                #:reproduce? #f #:backend 'native-c))
(define hd (with-vat vat ($ ps 'get-meta "horizon-derived")))
(check "the meta row stands after the solve" (pair? hd))
(check "bake defends the bread floor — branches-served, current-solution support"
       (and (member "bake" (or (assq-ref hd 'floor-procs) '())) #t))
(check "…the floor's whole upstream chain defends with it (mill, grow)"
       (let ((fp (or (assq-ref hd 'floor-procs) '()))) (and (member "mill" fp) (member "grow" fp) #t)))
(check "…and the branch's duration shock rides along for the gate's branch-max"
       (equal? '(("bake" . 4.0)) (assoc-ref (or (assq-ref hd 'duration-factors) '()) "slow")))
(check "a yield shock DERIVES a duration factor: bake at half yield ⇒ a 2× chain"
       (let ((d (assoc-ref (or (assq-ref hd 'duration-factors) '()) "drought")))
         (and d (< (abs (- (or (assoc-ref d "bake") 0) 2.0)) 1e-9))))
(check "the dial's data: floors->wire projects the sweep's own rung, reach and branch stretch"
       (let ((rows (with-vat vat (floors->wire ps))))
         (and (pair? rows)
              (let ((bake (find (lambda (r) (equal? "bake" (assq-ref r 'proc))) rows)))
                (and bake
                     (eq? 'floor-unaccepted (assq-ref bake 'rung))
                     (assq 'days-to-forcing bake)
                     ;; both branches stretched bake's chain: the explicit 4×, the derived 2×
                     (= 2 (length (assq-ref bake 'branch-factors))))))))


(display "\n── 2. the escalation door: an unbound floor is never silent ──\n")

(define (floor-alerts kind)
  (with-vat vat (filter (lambda (a) (equal? "bake" (assq-ref a 'proc))) ($ als 'of-kind kind))))
(check "the coverage gap surfaced: floor-unaccepted names bake on the rail"
       (= 1 (length (floor-alerts 'floor-unaccepted))))
(with-vat vat (plan-scope->alist scope #:periods '(0 1) #:storable bread-storable #:demand '(("bread#town@1" . 4.0))
                #:repro-floors '(("bread#town@1" . 1.0)) #:reproduce? #f #:backend 'native-c))
(check "…named ONCE — a second solve does not re-alert the same rung"
       (= 1 (length (floor-alerts 'floor-unaccepted))))
(check "the rung is a READING of the continuous quantity: days-to-forcing rides the derived row"
       (let ((d (with-vat vat ($ ps 'get-meta "horizon-derived"))))
         (and (assq 'days-to-forcing d) (assq 'rungs d)
              (assoc "bake" (assq-ref d 'rungs))
              ;; tomorrow's floor, an undurated chain: the forcing point is the
              ;; next midnight — ahead, and within the day
              (let ((days (assoc-ref (assq-ref d 'days-to-forcing) "bake")))
                (and (real? days) (> days 0) (<= days 1))))))

(check "sub-day bands address by clock: noon lands in the 09–17 band"
       (with-vat vat
         (let ((spans (declared-partition bread-resources bread-agents `((,today . ,today)) #f)))
           (let ((i 0))
             (for-each (lambda (sp) (set-period-span! i (car sp) (cdr sp)) (set! i (+ i 1))) spans))
           (and (= 3 (length spans))
                (= 1 (time->period (string-append today "T12:00:00")))))))

;; a floor whose forcing point already passed (today's span, undurated
;; chain, later than midnight), unbound, no reserve — the governance event.
;; A CLOCKLESS scope: 00:00–24:00 windows declare no interior boundary, so
;; the day stays one period and the floor stands whole.
(define win24 (all-week-window "00:00" "24:00"))
(define vat2 (spawn-vat #:name "floor-esc"))
(define-values (scope2 ps2 als2)
  (with-vat vat2 (spawn-bread-scope
                  #:agents (list (make-agent #:id "farmer" #:type 'person #:primary-location "town"
                                             #:classified-as '() #:availability-window win24)
                                 (make-agent #:id "ada" #:type 'person #:primary-location "town"
                                             #:classified-as '() #:availability-window win24)))))
(with-vat vat2 (plan-scope->alist scope2
                 #:demand '(("bread#town@0" . 4.0)) #:repro-floors '(("bread#town@0" . 1.0))
                 #:period-spans `((,today . ,today)) #:reproduce? #f #:backend 'native-c))
(check "past the forcing point with no reserve: floor-unbound-infeasible"
       (= 1 (with-vat vat2 (length (filter (lambda (a) (equal? "bake" (assq-ref a 'proc)))
                                           ($ als2 'of-kind 'floor-unbound-infeasible))))))

(test-summary!)
