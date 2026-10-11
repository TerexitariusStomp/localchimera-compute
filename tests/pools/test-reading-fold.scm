;;; test-reading-fold.scm — ^reading-pool: the scope fold of readings.
;;;
;;; pools/reading-fold.scm is `^fold-node` with a reading's three pieces;
;;; its OWN is the pure function scope-own-readings over the observer's
;;; quantity-bearing events (observer `fold-by`) and the rail's standing
;;; contrary observations. What this suite pins:
;;;   • the monoid: reading-combine is associative and commutative on random
;;;     cells (fixed seed), so the tree folds in any order, and merge-by-key
;;;     with + is sum-by-key (hours fold unchanged by construction);
;;;   • node = fold: the node's cells, latest and contrary are the function's;
;;;   • every source apart: two adjustments of one spec by one technique in one
;;;     scope are one cell with n = 2; two techniques are two cells (datasetId);
;;;   • ValueFlows raise/lower are adjustments (actions.md): they fold signed as
;;;     the ledger's drift, and `latest` reads flows alone;
;;;   • anonymity: no cell names a person, and the scope is the source;
;;;   • the contrary observation folds at its cautious reading, so the node's
;;;     `contrary` rows give solve/robust.scm observed-shocks the same shocks as the
;;;     governance reader's rows, and a flattering reading moves nothing;
;;;   • two scopes under the UC: the parent keeps both apart, and a departing
;;;     scope's readings leave exactly.
;;;
;;; Run:  guile -q -L module tests/pools/test-reading-fold.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness) (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (playnet pools reading-fold)
             (playnet vf aggregation fold-node)
             ((playnet solve engine) #:select (observed-shocks))
             (goblins) (goblins utils hashmap) (srfi srfi-1))

(define (approx= a b) (< (abs (- a b)) 1e-9))

;; ── the monoid, on random cells ─────────────────────────────────────────────
(display "\n── the monoid ──\n")
(let* ((rng (seed->random-state 7))
       (rand-cell (lambda ()
                    (let ((q (exact->inexact (random 100 rng))))
                      (reading-cell q (format #f "2026-03-~2,'0dT08:00:00Z" (+ 1 (random 28 rng)))))))
       (keys '(("bread" "bake" produce "each" #f "s1") ("bread" "weigh" raise "kg" #f "s1")
               ("flour" "bake" consume "kg" #f "s2")))
       (rand-cells (lambda () (map (lambda (_) (cons (list-ref keys (random 3 rng)) (rand-cell))) (iota 6))))
       (m (monoid-combine reading-monoid))
       (same? (lambda (x y)
                (and (= (length x) (length y))
                     (every (lambda (c) (let ((d (assoc (car c) y)))
                                          (and d (equal? (list-head (cdr c) 1) (list-head (cdr d) 1))
                                               (approx= (cadr (cdr c)) (cadr (cdr d)))
                                               (equal? (cddr (cddr c)) (cddr (cddr d))))))
                            x)))))
  (check "associative on 40 random triples"
         (every (lambda (_)
                  (let ((a (rand-cells)) (b (rand-cells)) (c (rand-cells)))
                    (same? (m (m a b) c) (m a (m b c)))))
                (iota 40)))
  (check "commutative on 40 random pairs"
         (every (lambda (_) (let ((a (rand-cells)) (b (rand-cells))) (same? (m a b) (m b a))))
                (iota 40)))
  (check "the empty is a unit (a list with repeated keys folds to its own merge)"
         (let* ((a (rand-cells)) (a* (merge-by-key reading-combine '() a)))
           (and (same? (m '() a) a*) (same? (m a '()) a*))))
  (check "merge-by-key with + is the keyed sum"
         (equal? (merge-by-key + '((a . 1) (b . 2)) '((a . 3) (c . 4)))
                 (sum-by-key '((a . 1) (b . 2)) '((a . 3) (c . 4)))))
  (check "the later instant's reading is the freshest, and the extrema widen"
         (let ((c (reading-combine (reading-cell 5.0 "2026-03-01T08:00:00Z")
                                   (reading-cell 9.0 "2026-03-02T08:00:00Z"))))
           (equal? c '(2 14.0 5.0 9.0 "2026-03-02T08:00:00Z" 9.0)))))

;; ── a scope's readings ──────────────────────────────────────────────────────
(define* (reading! obs eid action spec qty unit #:key process (agent "ada") (at "2026-03-01T08:00:00Z") (scope "bakery"))
  ($ obs 'record-event
     (make-economic-event #:id eid #:action action #:input-of (and (memq action '(consume use)) process)
                          #:output-of (and (memq action '(produce raise lower)) process) #:resource-conforms-to spec #:provider agent #:receiver agent
                          #:resource-quantity (make-measure qty unit) #:has-point-in-time at #:created at #:note "reading" #:in-scope-of (list scope))))

(define vat (spawn-vat))
(define %later #f)
(with-vat vat
  (let* ((root (spawn-scope-root "bakery")) (obs ($ root 'observer)))
    ;; the bakers produce 40 kg; two counts on the scale find the ledger off by
    ;; +2 and −1 (VF raise/lower: the difference, never the count); one logs flour
    (reading! obs "r0" 'produce "bread" 40 "kg" #:process "bake" #:agent "cy")
    (reading! obs "r1" 'raise "bread" 2 "kg" #:process "weigh" #:agent "ada")
    (reading! obs "r2" 'lower "bread" 1 "kg" #:process "weigh" #:agent "bob" #:at "2026-03-02T08:00:00Z")
    (reading! obs "r3" 'produce "bread" 12 %count-unit #:process "bake" #:agent "cy" #:at "2026-03-02T09:00:00Z")
    (reading! obs "r4" 'consume "flour" 3 "kg" #:agent "ada")
    (let* ((observed (lambda (sid) `(("bread" "bake" produce 12.0 6.0 "2026-03-03T08:00:00Z" "said-1")
                                     ("bread" "bake" produce 12.0 20.0 "2026-03-03T09:00:00Z" "said-2")
                                     ("flour" "bake" consume 2.0 3.0 "2026-03-03T08:00:00Z" "said-3"))))
           (own (scope-own-readings root "bakery" observed))
           (node (spawn ^reading-pool '() '() "bakery")))
      (wire-reading-node! root node #:scope-id "bakery" #:observed-of observed)
      (display "\n── node = fold ──\n")
      (check "the node's total is the pure fold's own" (equal? ($ node 'cells) own))
      (check "latest agrees" (equal? ($ node 'latest "bread") (latest-of own "bread")))
      (check "drift agrees" (equal? ($ node 'drift "bread") (drift-of own "bread")))
      (check "the wire's rows are the cells, named by the fold itself"
             (equal? ($ node 'rows "bread") (map cell->alist (readings-of own "bread"))))
      (display "\n── the history: the rows before they fold ──\n")
      (let* ((events ($ obs 'all-events))
             (all (readings-between events "bread" #:scope-id "bakery"))
             (day1 (readings-between events "bread" #:since "2026-03-01T00:00:00Z" #:until "2026-03-02T00:00:00Z" #:scope-id "bakery"))
             (day2 (readings-between events "bread" #:since "2026-03-02T00:00:00Z" #:scope-id "bakery"))
             (weigh (readings-between events "bread" #:technique "weigh" #:scope-id "bakery")))
        (check "every reading of bread is a row, in time order, one reading each"
               (and (= 4 (length all)) (every (lambda (r) (= 1 (car (cdr r)))) all)
                    (equal? (map (lambda (r) (list-ref (cdr r) 4)) all) (sort (map (lambda (r) (list-ref (cdr r) 4)) all) string<?))))
        (check "a window keeps what fell inside it: the first day's produce and count, the second day's count and produce"
               (and (= 2 (length day1)) (= 2 (length day2))
                    (equal? (map (lambda (r) (list-ref (car r) 2)) day1) '(produce raise))
                    (equal? (map (lambda (r) (list-ref (car r) 2)) day2) '(lower produce))))
        (check "a technique narrows it: the scale's two counts, signed" (equal? (map (lambda (r) (list-ref (cdr r) 1)) weigh) '(2.0 -1.0)))
        (check "the rows are keyed as the fold's cells are, so folding them gives the fold's own bread cells"
               (lset= equal? (window-fold all) (filter (lambda (c) (and (equal? "bread" (car (car c))) (not (list-ref (car c) 4)))) own)))
        (check "…and a window's fold is what the fold would say from that window alone: day one's bread weighs 40 kg made, +2 counted"
               (let ((f (window-fold day1)))
                 (and (= 2 (length f))
                      (= 40.0 (list-ref (cdr (assoc '("bread" "bake" produce "kg" #f "bakery") f)) 1))
                      (= 2.0 (list-ref (cdr (assoc '("bread" "weigh" raise "kg" #f "bakery") f)) 1)))))
        (check "the wire's shape is the fold's row, one reading each" (every (lambda (r) (= 1 (assq-ref (cell->alist r) 'n))) all))
        ;; the rail's standing contrary observations are rows of the history too, through
        ;; the one reader the fold takes them by: keyed by the nominal, valued cautiously
        (let* ((with (readings-between events "bread" #:scope-id "bakery" #:contrary (observed "bakery")))
               (contrary (filter (lambda (r) (list-ref (car r) 4)) with)))
          (check "the rail's contrary observations are rows of the history, keyed by the nominal they contradict"
                 (and (= 2 (length contrary)) (every (lambda (r) (= 12.0 (list-ref (car r) 4))) contrary)))
          (check "…valued as the solve takes them: a produce read at most the nominal" (equal? (map (lambda (r) (list-ref (cdr r) 1)) contrary) '(6.0 12.0)))
          (check "…and folding the whole history gives the fold's own bread cells, contrary ones included"
                 (lset= equal? (window-fold with) (filter (lambda (c) (equal? "bread" (car (car c)))) own)))
          (check "a window before the rail's readings leaves them out"
                 (null? (filter (lambda (r) (list-ref (car r) 4))
                                (readings-between events "bread" #:until "2026-03-03T00:00:00Z" #:scope-id "bakery" #:contrary (observed "bakery")))))))
      (check-pred "…each row naming spec, source, count and freshest reading"
                  (every (lambda (r) (and (assq 'spec r) (assq 'source r) (assq 'n r) (assq 'latest r))) ($ node 'rows "bread")))
      (check "contrary agrees" (equal? ($ node 'contrary) (contrary-of own)))

      (display "\n── every source apart ──\n")
      (let ((raise (assoc '("bread" "weigh" raise "kg" #f "bakery") own))
            (lower (assoc '("bread" "weigh" lower "kg" #f "bakery") own))
            (bake  (assoc '("bread" "bake" produce "each" #f "bakery") own))
            (log   (assoc '("flour" #f consume "kg" #f "bakery") own)))
        (check "a raise folds as +2, a lower as −1: the ledger's drift, signed"
               (and raise lower (= (cadr (cdr raise)) 2.0) (= (cadr (cdr lower)) -1.0)))
        (check "drift of bread: two counts, mean |q| 1.5, net +1"
               (equal? (drift-of own "bread") '(2 1.5 1.0)))
        (check "the baker's count in loaves is its own cell (a second technique = a second instance)"
               (and bake (= (car (cdr bake)) 1)))
        (check "a log entry with no process keys on #f" (and log #t))
        (check "latest of bread reads flows alone: the 12 loaves on the 2nd, never an adjustment"
               (equal? (latest-of own "bread") '(12.0 "2026-03-02T09:00:00Z" "each" "bakery")))
        (check "no drift on a spec with no adjustments" (equal? (drift-of own "flour") '(0 0.0 0.0)))
        (check "five cells of bread in this scope: two flows, two adjustments, the contrary cell"
               (= (length (readings-of own "bread")) 5))
        (check "one scope has read bread" (= (sources-of own "bread") 1)))

      (display "\n── anonymity ──\n")
      (check "no key names a person, every key ends in the scope"
             (every (lambda (c) (and (equal? (last (car c)) "bakery")
                                     (not (any (lambda (x) (member x '("ada" "bob" "cy"))) (car c)))))
                    own))

      (display "\n── the contrary observation, at its cautious reading ──\n")
      (let ((c (assoc '("bread" "bake" produce "" 12.0 "bakery") own)))
        (check "the two witnesses are one cell: 6 stands, 20 folds as the nominal 12"
               (and c (equal? (list-head (cdr c) 4) '(2 18.0 6.0 12.0)))))
      (check "the node's rows give observed-shocks the same shocks as the reader's rows"
             (equal? (observed-shocks (contrary-of own))
                     (observed-shocks (map (lambda (r) (list (cadr r) (caddr r) (cadddr r) (list-ref r 4)))
                                           (observed "bakery")))))
      (check "a flattering reading alone leaves the map where it stands"
             (let ((own1 (scope-own-readings root "bakery"
                                             (lambda (sid) '(("bread" "bake" produce 12.0 20.0 "2026-03-03T09:00:00Z" "s"))))))
               (equal? (contrary-of own1) '(("bake" produce 12.0 12.0))))))

    (display "\n── two scopes under the UC ──\n")
    (let* ((farm (spawn-scope-root "farm"))
           (uc (spawn ^reading-pool '() '() "uc"))
           (bn (spawn ^reading-pool '() '() "bakery"))
           (fn (spawn ^reading-pool '() '() "farm")))
      (reading! ($ farm 'observer) "f1" 'produce "flour" 100 "kg" #:process "mill" #:agent "dee" #:scope "farm"
                #:at "2026-03-04T08:00:00Z")
      (wire-reading-node! root bn #:parent uc #:scope-id "bakery")
      (wire-reading-node! farm fn #:parent uc #:scope-id "farm")
      (check "the UC keeps the two scopes' flour apart (two sources)"
             (= (sources-of ($ uc 'cells) "flour") 2))
      (check "the UC's latest flour is the farm's milling"
             (equal? (latest-of ($ uc 'cells) "flour") '(100.0 "2026-03-04T08:00:00Z" "kg" "farm")))
      (reading! ($ farm 'observer) "f2" 'produce "flour" 90 "kg" #:process "mill" #:agent "dee"
                #:at "2026-03-05T08:00:00Z" #:scope "farm")
      (set! %later (list uc bn)))))

;; the refold is an eventual send: it lands in the turn after the event
(with-vat vat
  (let ((uc (car %later)) (bn (cadr %later)))
    (check "an event recorded later refolds up to the UC (next turn)"
           (equal? (latest-of ($ uc 'cells) "flour") '(90.0 "2026-03-05T08:00:00Z" "kg" "farm")))
    (check "a departing scope's readings leave exactly"
           (begin ($ uc 'drop-child "farm")
                  (and (= (sources-of ($ uc 'cells) "flour") 1)
                       (equal? ($ uc 'cells) ($ bn 'cells)))))))

(test-summary!)
