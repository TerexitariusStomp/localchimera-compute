;;; test-means-fold.scm — capacity folds like labour and demand do.
;;;
;;; The fourth column of the federation fold (fold-node.scm names it in its own
;;; header): a scope's standing service rises as a TOTAL per (spec, span-place),
;;; members stay keyed so refederation is two exact messages, and the fact shape
;;; read off the total is the one svc-eco-caps already consumes. The span half:
;;; a live span declaration moves the KEY a capacity rises under — the fold and
;;; the pool-builder read the same rule, so they cannot disagree.

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness))
(use-modules (playnet planner formulas capacity) (playnet planner vf schemas) (srfi srfi-1))
(use-modules (playnet governance means-fold))
(use-modules (goblins))
(use-modules (srfi srfi-1))

(define (res id spec qty unit at inside)
  (make-economic-resource #:id id #:conforms-to spec #:classified-as '()
    #:accounting-quantity (make-measure qty unit) #:onhand-quantity (make-measure qty unit)
    #:current-location at #:contained-in inside))

(define (fact spec place facts)
  (and=> (find (lambda (f) (and (equal? spec (car f)) (equal? place (cadr f)))) facts)
         caddr))

(display "\n── 1. capacity-cells: the pure core ──\n")

(let* ((lathe (res "lathe-1" "lathe" 40.0 "hours/day" "workshop-a" #f))
       (press (res "press-1" "press" 16.0 "hours/day" #f "lathe-1"))   ; place inherited
       (bread (res "bread-1" "bread" 30.0 %count-unit      "workshop-a" #f)); a stock, not a rate
       (facts (capacity-facts (capacity-cells (list lathe press bread)))))
  (check-pred "a time-rate holding contributes its unit-hours/day"
              (= 40.0 (fact "lathe" "workshop-a" facts)))
  (check-pred "a contained means inherits its container's place"
              (= 16.0 (fact "press" "workshop-a" facts)))
  (check-pred "a count-denominated stock stays out of this slice"
              (not (fact "bread" "workshop-a" facts))))

(display "\n── 2. two of a kind in one place rise as one number ──\n")

(let* ((l1 (res "lathe-1" "lathe" 40.0 "hours/day" "workshop-a" #f))
       (l2 (res "lathe-2" "lathe" 24.0 "hours/day" "workshop-a" #f))
       (facts (capacity-facts (capacity-cells (list l1 l2)))))
  (check-pred "capacities sum per (spec, place) — no machine survives into the key"
              (= 64.0 (fact "lathe" "workshop-a" facts))))

(display "\n── 3. the key follows the SPAN, not the location ──\n")

(let* ((lathe (res "lathe-1" "lathe" 40.0 "hours/day" "workshop-a" #f))
       (plain (capacity-facts (capacity-cells (list lathe))))
       (spanned (capacity-facts
                 (capacity-cells (list lathe) #:span-of '(("lathe-1" . "town"))))))
  (check-pred "no declaration: keyed at the holding place"
              (= 40.0 (fact "lathe" "workshop-a" plain)))
  (check-pred "declared span: keyed at the span place"
              (= 40.0 (fact "lathe" "town" spanned)))
  (check-pred "…and nothing remains at the holding place"
              (not (fact "lathe" "workshop-a" spanned))))

(define vat (spawn-vat))

(display "\n── 4. the node: own ⊕ children, and refederation is two messages ──\n")

(with-vat vat
  (let* ((uc       (spawn ^means-pool (quote ()) (quote ())))
         (fed-a    (spawn ^means-pool (quote ()) (quote ())))
         (fed-b    (spawn ^means-pool (quote ()) (quote ())))
         (own-a    (capacity-cells (list (res "lathe-1" "lathe" 40.0 "hours/day" "workshop-a" #f))))
         (own-b    (capacity-cells (list (res "kiln-1"  "kiln"  12.0 "hours/day" "yard-b" #f)))))
    ;; two federations under one UC, one scope's worth of capacity in each
    ($ fed-a 'set-id "fed-a") ($ fed-b 'set-id "fed-b")
    ($ fed-a 'set-parent uc "fed-a") ($ fed-b 'set-parent uc "fed-b")
    ($ fed-a 'set-own own-a) ($ fed-b 'set-own own-b)
    (let ((facts (capacity-facts ($ uc 'fold-total))))
      (check-pred "the UC total carries both federations' capacity"
                  (and (= 40.0 (fact "lathe" "workshop-a" facts))
                       (= 12.0 (fact "kiln" "yard-b" facts)))))
    ;; fed-b leaves: drop + (nothing) — its capacity vanishes from the UC exactly
    ($ uc 'drop-child "fed-b")
    (let ((facts (capacity-facts ($ uc 'fold-total))))
      (check-pred "a departed member's capacity is gone, exactly"
                  (and (= 40.0 (fact "lathe" "workshop-a" facts))
                       (not (fact "kiln" "yard-b" facts)))))
    ;; the read every consumer uses
    (check-pred "capacity-facts is the node's own read too"
                (= 40.0 (fact "lathe" "workshop-a" ($ uc 'capacity-facts))))))

(display "\n── 5. the pull agrees with the push: facts feed svc-eco-caps ──\n")

(let* ((facts (capacity-facts
               (capacity-cells (list (res "lathe-1" "lathe" 40.0 "hours/day" "workshop-a" #f)))))
       (caps  (svc-eco-caps facts '(0 1))))
  (check-pred "the fact shape projects onto a solve's periods unchanged"
              (and (= 2 (length caps))
                   (every (lambda (c) (= 40.0 (cdr c))) caps))))

(display "\n── 6. reach − span: the withholding figure ──\n")

;; town ⊃ workshop-a, workshop-b — the coverage test's tree
(define town (make-spatial-thing #:id "town" #:name "Town"))
(define wa   (make-spatial-thing #:id "workshop-a" #:name "A" #:contained-in "town"))
(define wb   (make-spatial-thing #:id "workshop-b" #:name "B" #:contained-in "town"))
(define spatials (list town wa wb))
(define lathe (res "lathe-1" "lathe" 40.0 "hours/day" "workshop-a" #f))
(define (reach-town rid) (and (equal? rid "lathe-1") "town"))

(let ((w (means-withholding (list lathe) spatials #:reach-of reach-town)))
  (check-pred "pool at the workshop, reach the town: 40 unit-hours/day withheld"
              (and (= 1 (length w))
                   (equal? '("lathe" "workshop-a" "town" 40.0) (car w)))))

(check-pred "span declared at the town: nothing withheld"
            (null? (means-withholding (list lathe) spatials
                                      #:span-of '(("lathe-1" . "town"))
                                      #:reach-of reach-town)))

(check-pred "reach equal to the pool: nothing withheld"
            (null? (means-withholding (list lathe) spatials
                                      #:reach-of (lambda (rid) "workshop-a"))))

(check-pred "a pool WIDER than reach covers it: nothing withheld"
            (null? (means-withholding (list lathe) spatials
                                      #:span-of '(("lathe-1" . "town"))
                                      #:reach-of (lambda (rid) "workshop-b"))))

(check-pred "no reach stated: no figure — the fold does not invent physics"
            (null? (means-withholding (list lathe) spatials)))

(display "\n── 7. the default span flips with the property form ──\n")

(let* ((common-lathe (res "commons-1" "lathe" 40.0 "hours/day" "workshop-a" #f))
       (owned-lathe  (res "lathe-1"   "lathe" 40.0 "hours/day" "workshop-a" #f))
       (rights (lambda (rid) (if (equal? rid "commons-1") 'common "EWorkshopScope")))
       (defaults (common-span-defaults (list common-lathe owned-lathe) spatials rights)))
  (check-pred "a COMMON means defaults to the WIDEST span — the containment root"
              (equal? "town" (assoc-ref defaults "commons-1")))
  (check-pred "an owned means gets no default here — its holding place stands"
              (not (assoc-ref defaults "lathe-1")))
  (check-pred "the default feeds the fold: common capacity rises keyed at the root"
              (= 40.0 (fact "lathe" "town"
                            (capacity-facts
                             (capacity-cells (list common-lathe) #:span-of defaults))))))

(display "\n── 8. the fold feeds the consensus row ──\n")

(let* ((facts '(("lathe" "workshop-a" 40.0) ("lathe" "town" 24.0) ("kiln" "yard-b" 12.0)))
       (bars  (capacity-bars facts)))
  (check-pred "one bar per spec, places collapsed — the consensus row's TOTAL"
              (and (= 64.0 (assoc-ref bars "lathe"))
                   (= 12.0 (assoc-ref bars "kiln")))))

(display "\n── 9. the wheel's read: withholding-snapshot ──\n")

(let* ((recs (means-withholding (list lathe) spatials #:reach-of reach-town))
       (ctls (withholding-snapshot recs))
       (c    (car ctls)))
  (check-pred "one kind:withheld control per record — the wheel's sector shape"
              (and (= 1 (length ctls))
                   (equal? "withheld" (assq-ref c 'kind))
                   (equal? "lathe" (assq-ref c 'control))))
  (check-pred "the figure is the withheld unit-hours/day; tip is the whole rate"
              (and (= 40.0 (assq-ref c 'current))
                   (= 40.0 (assq-ref c 'tip))))
  (check-pred "span→reach ride along for the hover detail"
              (and (equal? "workshop-a" (assq-ref c 'span))
                   (equal? "town" (assq-ref c 'reach))))
  (check-pred "slack sits at the wall — the whole rate pools out of reach"
              (<= (assq-ref c 's) 1e-3)))

(check-pred "no records: no controls — old snapshots render unchanged"
            (null? (withholding-snapshot '())))

(display "\n── 9. count-denominated durables, admitted by the recipe store's own fact ──\n")

(let* ((ovens (res "oven-2" "oven" 3.0 %count-unit "workshop-a" #f))
       (bread (res "bread-2" "bread" 30.0 %count-unit "workshop-a" #f))
       (used? (lambda (spec) (equal? spec "oven")))   ; the store: some recipe `use`s oven
       (facts (capacity-facts (capacity-cells (list ovens bread) #:durable? used?))))
  (check-pred "three ovens render 72 unit-hours/day — the stock reading"
              (= 72.0 (fact "oven" "workshop-a" facts)))
  (check-pred "a consumable stays out even with the predicate supplied"
              (not (fact "bread" "workshop-a" facts)))
  (check-pred "without the predicate, the time-rate-only slice stands unchanged"
              (not (fact "oven" "workshop-a"
                         (capacity-facts (capacity-cells (list ovens)))))))

(test-summary!)
