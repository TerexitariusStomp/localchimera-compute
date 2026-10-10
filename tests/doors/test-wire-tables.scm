;;; test-wire-tables.scm — a row of the wire is a table over the record it reads.
;;;
;;; (playnet wire rows) states what the page reads of a thing as a table: a wire key,
;;; where its value comes from (a field of the record, or a computed entry) and the
;;; kind it is written as. This holds the mechanism:
;;;
;;;   FIELDS    a table over a record reads its fields by the record's accessors, and
;;;             a table naming a field the record lacks is refused as it is made;
;;;   KINDS     each kind writes what it says, absent values included;
;;;   NESTING   a row holds child rows and one nested row by their own tables, and a
;;;             table may nest rows of its own kind by name;
;;;   COMPUTED  a computed entry reads the row and what the reply looked up once;
;;;   REGISTRY  every table is found by its name, with the record type it reads;
;;;   ALISTS    a row with no record behind it is read off an alist by the same table.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/doors/test-wire-tables.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness)
             (playnet wire rows)
             (playnet wire snapshot) (playnet wire replies)
             (playnet doors family wire)
             (playnet doors record-rows)
             ((playnet utils records) #:select (vf-record-type-name))
             (playnet vf schemas)
             ((playnet knowledge dsl shorthand) #:select (flow*))
             (srfi srfi-1))

(define measure-row
  (wire-table 'test-measure <measure>
    '(("q" has-numerical-value num) ("u" has-unit str))))
(define flow-row
  (wire-table 'test-flow <recipe-flow>
    `(("id" id str)
      ("action" action str)
      ("spec" resource-conforms-to str)
      ("name" ,(lambda (f names) (or (assoc-ref names (recipe-flow-resource-conforms-to f)) "")) str)
      ("amount" resource-quantity (row test-measure))
      ("effort" effort-quantity (omit-false (row test-measure)))
      ("primary" is-primary bool)
      ("note" note opt-str))))

(define f (flow* "f1" 'produce "bread" 4 "bake" %count-unit #:primary #t))
(define names '(("bread" . "Bread")))

(display "\n── FIELDS ──\n")
(check "a record's row reads its fields, in the table's order"
       (wire-row* flow-row f names)
       '(("id" . "f1") ("action" . "produce") ("spec" . "bread") ("name" . "Bread")
         ("amount" . (("q" . 4) ("u" . "each"))) ("primary" . #t) ("note" . null)))
(check "a table naming a field the record lacks is refused as it is made"
       (catch #t (lambda () (wire-table 'test-bad <recipe-flow> '(("x" no-such-field str))) 'made)
         (lambda (k . a) 'refused))
       'refused)

(display "\n── KINDS ──\n")
(define (as kind v) (wire-value kind v #f))
(check "str: a string, a symbol's name, \"\" where absent" (map (lambda (v) (as 'str v)) '("a" b #f)) '("a" "b" ""))
(check "opt-str: null where absent" (list (as 'opt-str "a") (as 'opt-str #f)) '("a" null))
(check "int: rounded, 0 where absent" (list (as 'int 2.6) (as 'int #f)) '(3 0))
(check "num: a finite number, null where absent or not finite"
       (list (as 'num 1/2) (as 'num #f) (as 'num (/ 0. 0.))) '(0.5 null null))
(check "bool: whether it is set" (list (as 'bool "x") (as 'bool #f)) '(#t #f))
(check "strs: the strings among the elements" (as 'strs '("a" 1 "b")) #("a" "b"))
(check "list: each element written as its kind" (as '(list num) '(1 2.5 #f)) #(1 2.5 null))
(check "map: an object under the keys' names, each value written as its kind"
       (as '(map str) '((n . "one") ("two" . two))) '(("n" . "one") ("two" . "two")))
(check "an unknown kind is an error"
       (catch #t (lambda () (as 'no-such-kind 1)) (lambda (k . a) 'refused)) 'refused)

(display "\n── NESTING ──\n")
(define process-row
  (wire-table 'test-process #f
    '(("id" id str) ("flows" flows (rows test-flow)) ("steps" steps (rows test-process)))))
(let ((r (wire-row* process-row `((id . "bake") (flows . ,(list f)) (steps . (((id . "knead") (flows . ()) (steps . ()))))) names)))
  (check "child rows are written by their own table"
         (assoc-ref (vector-ref (assoc-ref r "flows") 0) "name") "Bread")
  (check "a table nests rows of its own kind, by name"
         (assoc-ref (vector-ref (assoc-ref r "steps") 0) "id") "knead")
  (check "no child rows is an empty array" (assoc-ref (vector-ref (assoc-ref r "steps") 0) "flows") #()))
(check "an absent nested row is left out where the entry says so"
       (assoc "effort" (wire-row* flow-row f names)) #f)

(display "\n── REGISTRY ──\n")
(check "a table is found by its name" (eq? (wire-table-ref 'test-flow) flow-row) #t)
(check "…with the record type it reads" (eq? (wire-table-record-type flow-row) <recipe-flow>) #t)
(check "the tables the wire modules state are registered"
       (lset-difference eq? '(credit inventory-spec inventory-resource expected-flow
                              count-row count-history contest claim-row reading-row counted)
                        (map wire-table-name (wire-tables)))
       '())

(display "\n── ALISTS ──\n")
(check "a row with no record behind it is read off an alist by its table"
       (credit->wire '((gross . 12.5) (claimed . 2) (free-time . 40)))
       '(("gross" . 12.5) ("claimed" . 2) ("drawable" . null) ("capacity" . null) ("pool" . null)
         ("voice" . null) ("freeTime" . 40)))

(display "\n── THE PLAN: a row of rows, with what is absent said as the page reads it ──\n")
(define a-plan
  `((scope . "s") (coverage . 0.75) (feasible . yes) (stale . #t) (labourH . 12.5)
    (produced . (((spec . "bread") (q . 3.0))))
    (needs . (((id . "n") (label . "Bread") (met . 0.5) (want . 10) (recipeId . "r") (runs . 2) (labourH . 1.25))))
    (flow . (((id . "p") (spec . "Bread") (specId . "bread") (name . "Bake") (q . 2.0) (u . "kg") (period . "0")
              (in . (((spec . "flour") (id . "f") (q . 1.5) (action . consume)))))))
    (requires . (((proc . "p") (place . "A") (when . "t0") (until . "t1") (why . ((reason . no-worker) (detail . (baking))))
                  (needs . (((kind . labour) (name . "baking") (label . "Baking") (qty . 2) (unit . "h") (met . #f)))))
                 ((proc . "q") (place . "A") (when . "t0") (until . "t1") (why . #f) (needs . ()))))
    (schedule . ((work . (((who . "ana") (skill . baking) (effort . 2.5) (place . "A") (when . "t0") (proc . "p"))))
                 (material . (((action . produce) (id . "mc|1") (spec-id . "bread") (spec . "Bread") (qty . 3)
                               (place . "A") (when . "t0") (proc . "p"))))))))
(check "a plan is written whole by its table"
       (plan->wire a-plan)
       `(("scope" . "s") ("coverage" . 0.75) ("feasible" . "yes") ("stale" . "yes") ("labourH" . 12.5)
         ("produced" . #((("spec" . "bread") ("q" . 3.0))))
         ("needs" . #((("id" . "n") ("label" . "Bread") ("met" . 0.5) ("want" . 10) ("recipeId" . "r")
                       ("runs" . 2) ("labourH" . 1.25))))
         ("flow" . #((("id" . "p") ("spec" . "Bread") ("specId" . "bread") ("name" . "Bake") ("q" . 2.0)
                      ("u" . "kg") ("period" . "0")
                      ("in" . #((("spec" . "flour") ("id" . "f") ("q" . 1.5) ("action" . "consume")))))))
         ("requires" . #((("proc" . "p") ("place" . "A") ("when" . "t0") ("until" . "t1")
                          ("why" . (("reason" . "no-worker") ("detail" . #("baking"))))
                          ("needs" . #((("kind" . "labour") ("name" . "baking") ("label" . "Baking")
                                        ("qty" . 2) ("unit" . "h") ("met" . "missing")))))
                         (("proc" . "q") ("place" . "A") ("when" . "t0") ("until" . "t1") ("needs" . #()))))
         ("schedule" . (("work" . #((("who" . "ana") ("skill" . "baking") ("effort" . 2.5) ("place" . "A")
                                     ("when" . "t0") ("until" . "") ("proc" . "p"))))
                        ("material" . #((("action" . "produce") ("id" . "mc|1") ("specId" . "bread")
                                         ("spec" . "Bread") ("qty" . 3) ("place" . "A") ("when" . "t0")
                                         ("proc" . "p") ("note" . ""))))))))
(let ((bare (plan->wire '((scope . "s")))))
  (check "a plan no solve has filled: no flow and no schedule are false, the verdict unknown, the lists empty"
         (map (lambda (k) (assoc-ref bare k)) '("flow" "schedule" "feasible" "stale" "needs"))
         (list #f #f "unknown" "no" (vector))))
(check "every row the plan nests is a named table"
       (map (lambda (n) (wire-table? (wire-table-ref n)))
            '(plan plan-need plan-yield flow-prod flow-in schedule sched-work sched-mat))
       (make-list 8 #t))

(display "\n── THE SNAPSHOT: every row the page reads of it is a named table ──\n")
(check "the snapshot and the rows it nests are registered"
       (map (lambda (n) (wire-table? (wire-table-ref n)))
            '(scope-snapshot-reply commitment-record intent-record clock arc proposal event location
              recipe recipe-step recipe-flow recipe-channel curve-point channel-point claim bend
              inventory inventory-spec inventory-stock expected expected-flow credit
              matter matter-node matter-link))
       (make-list 25 #t))
;; the record rows read their records: the tables say which (record-rows.scm)
(check "a record row's table reads its record"
       (map (lambda (n) (vf-record-type-name (wire-table-record-type (wire-table-ref n))))
            '(commitment-record intent-record event proposal))
       '(Commitment Intent EconomicEvent Proposal))
(let ((snap (reply->wire 'scope-snapshot `((plan . ,a-plan) (credit . ((gross . 3)))
                                           (locations . (((id . "l1") (name . "Mill"))))))))
  (check "the snapshot states its arms in the page's order"
         (map car snap)
         '("commitments" "intents" "proposals" "recipes" "plan" "matter" "inventory" "credit" "fragility" "locations" "events"
           "scopeId" "scopeName" "members" "plans" "alerts" "floors"))
  (check "an arm's rows are written by their table"
         (let ((l (vector-ref (assoc-ref snap "locations") 0)))
           (list (assoc-ref l "id") (assoc-ref l "name")))
         '("l1" "Mill"))
  (check "what the scope does not have is false"
         (map (lambda (k) (assoc-ref snap k)) '("matter" "inventory" "fragility")) '(#f #f #f))
  ;; the spine's fold is read off the same table: a gathered arm appends the
  ;; memberships behind the dialed scope, an own arm is the dialed scope's
  (let ((folded (fold-snapshots snap (list (reply->wire 'scope-snapshot '((locations . (((id . "l2"))))
                                                                           (credit . ((gross . 9)))))))))
    (check "a gathered arm appends the memberships, the dialed scope first"
           (map (lambda (l) (assoc-ref l "id")) (vector->list (assoc-ref folded "locations"))) '("l1" "l2"))
    (check "an own arm is the dialed scope's" (assoc-ref (assoc-ref folded "credit") "gross") 3)
    (check "the fold keeps the table's order" (map car folded) (map car snap)))
  (check "while the dialed scope's snapshot is in flight its own arms are absent, as the kind's empty"
         (let ((f (fold-snapshots '() (list snap))))
           (list (assoc-ref f "plan") (assoc-ref f "recipes") (assoc-ref f "scopeId")
                 (vector-length (assoc-ref f "locations"))))
         '(#f #() "" 1)))

(display "\n── A DOOR'S REPLY: a table found by the door's name ──\n")
(check "each read door's reply is a registered table"
       (map (lambda (d) (wire-table? (wire-table-ref d)))
            '(count-schedule-reply count-history-reply contests-reply my-claims-reply my-slots-reply
              our-slots-reply slots-at-reply match-slots-reply scope-readings-reply
              readings-between-reply count-stock-reply allotment-reply label-stock-reply read-label-reply))
       (make-list 14 #t))
(check "a means of the pool carries its owner, and how drawn it is where the solve says"
       (let ((m (vector-ref (assoc-ref (reply->wire 'slots-at '((means . (((id . "s") (owner . "bo") (drawn . 0.25))))))
                                       "means") 0)))
         (list (car (car m)) (assoc-ref m "drawn") (assoc-ref m "owner") (assoc-ref m "id")))
       '("drawn" 0.25 "bo" "s"))
(check "a door with no table is refused by name"
       (catch #t (lambda () (reply->wire 'no-such-door '()) #f) (lambda _ #t)) #t)
(check "the household's reply nests its best effort as the same table"
       (let ((r (family-split->json-alist '((feasible? . #f) (best-effort . ((feasible? . #t) (spent . 4)))))))
         (list (assoc-ref r "feasible") (assoc-ref (assoc-ref r "bestEffort") "spent")))
       '("no" 4))

(test-summary!)
