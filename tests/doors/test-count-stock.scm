;;; test-count-stock.scm — a count of a stock, over the real ^planner-service.
;;;
;;; A person looks at a stock the books hold and says how much is there
;;; (docs/observation/capture.md §3). What this pins is the door's rule and
;;; its width:
;;;
;;;   • a count that finds the ledger off lands a `raise` or `lower` of the
;;;     DIFFERENCE on that same stock, and the stock then reads the count;
;;;   • a count that agrees lands no adjustment;
;;;   • the adjustment carries the technique as its process, the place, the
;;;     narrated instant and the evidence hash;
;;;   • a count is in the stock's own unit, of zero or more, by a known
;;;     technique, of a stock that exists;
;;;   • unasked, a person counts their own and the scope's stock; another
;;;     person's stock is counted on a commitment;
;;;   • a planned count lands the run's record as a `produce` that fulfils
;;;     the record's commitment, whether or not the count found anything;
;;;   • the reading fold's drift reads the adjustments.
;;;
;;; Run from project root:
;;;   tools/test/own-ccache.sh guile --no-auto-compile -q -L module tests/doors/test-count-stock.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)

(add-to-load-path "module")
(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness))
(use-modules ((playnet wire rows) #:select (plain-reply)))   ; a door's rows, read back as alists
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (playnet scope root) (playnet vf schemas) (playnet observation states) (srfi srfi-1)
             (playnet doors service)
             ((playnet observation observer) #:select (void-event))
             ((playnet vf formulas counting) #:select (count-figure))
             (srfi srfi-1))

(display "\n── Setup: a scope, its service, three stocks ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env
                        (lambda () (spawn-scope-root "Commune"))
                        store))

(define svc
  (with-vat vat (spawn ^planner-service (hashmap-set (hashmap) "org:commune" scope))))

(define (call method . args) (plain-reply (with-vat vat (apply $ svc method args))))
(define (obs method . args)
  (with-vat vat (apply $ ($ scope 'observer) method args)))
(define (ps method . args)
  (with-vat vat (apply $ ($ scope 'plan-store) method args)))
(define (ok? r)  (and (pair? r) (eq? (car r) 'ok)))
(define (err r)  (and (pair? r) (eq? (car r) 'error) (cdr r)))
(define (field r k) (and (ok? r) (assq-ref (cdr r) k)))
(define (onhand rid)
  (measure-qty (economic-resource-onhand-quantity (obs 'get-resource rid))))
(define (near? a b) (< (abs (- a b)) 1e-9))

(define (seed! rid spec qty unit owner place)
  (obs 'seed-resource
       (make-economic-resource #:id rid #:name spec #:conforms-to spec #:classified-as '()
                               #:accounting-quantity (make-measure qty unit) #:onhand-quantity (make-measure qty unit)
                               #:current-location place #:primary-accountable owner)))

(seed! "ada/flour"   "flour" 10.0 "kg" "ada"         "place:pantry")
(seed! "bob/drill"   "drill" 1.0  %count-unit "bob"       "place:shed")
(seed! "pantry/rice" "rice"  40.0 "kg" "org:commune" "place:pantry")

(check-pred "setup: service spawned" svc)
(check "setup: the flour is on the books" (onhand "ada/flour") 10.0)

;;; ── 1. a count that finds less ──────────────────────────────────────────

(display "\n── 1. a count finds the ledger high ──\n")

(define %pic (string-append "sha256:" (make-string 64 #\a)))
(define less (call 'count-stock "org:commune" "ada" "ada/flour" 8.5 "kg"
                   "stated" "place:kitchen" "2026-09-28T09:00:00Z"
                   "" %pic "second shelf"))
(check-pred "the count is accepted" (ok? less))
(check-pred "the difference landed is the count minus the ledger"
            (near? (field less 'delta) -1.5))
(check-pred "the stock now reads the count" (near? (onhand "ada/flour") 8.5))

(define l-ev (obs 'get-event (field less 'event)))
(check-pred "the adjustment is on the ledger" l-ev)
(check "it is a lower" (economic-event-action l-ev) 'lower)
(check-pred "of the difference, in the stock's unit"
            (and (near? (measure-qty (economic-event-resource-quantity l-ev)) 1.5)
                 (equal? "kg" (measure-has-unit (economic-event-resource-quantity l-ev)))))
(check "on the stock that was counted"
       (economic-event-resource-inventoried-as l-ev) "ada/flour")
(check "the technique is the event's process"
       (economic-event-output-of l-ev) "count:stated")
(check "the place it was counted at is on the event"
       (economic-event-at-location l-ev) "place:kitchen")
(check "the narrated instant is on the event"
       (economic-event-has-point-in-time l-ev) "2026-09-28T09:00:00Z")
(check "the counter is the provider" (economic-event-provider l-ev) "ada")
(check-pred "the evidence hash rides the event as a tag"
            (member (string-append "evidence:" %pic) (economic-event-resource-classified-as l-ev)))
(check-pred "…and the note says only what was seen"
            (not (string-contains (economic-event-note l-ev) "sha256")))
(check-pred "a hash that is no sha256 is refused"
            (err (call 'count-stock "org:commune" "ada" "ada/flour" 8.0 "kg"
                       "stated" "" "" "" "sha256:abc123" "")))
(check-pred "…and so is a picture named by a path"
            (err (call 'count-stock "org:commune" "ada" "ada/flour" 8.0 "kg"
                       "stated" "" "" "" "/home/ada/flour.jpg" "")))
(check "an unplanned count names no commitment"
       (economic-event-fulfills l-ev) #f)
(define l-rec (obs 'get-event (field less 'record)))
(check-pred "…and lands its record all the same" l-rec)
(check "the record states the figure that was found"
       (count-figure (economic-event-resource-classified-as l-rec)) '(8.5 . "kg"))
(check "…and so does the adjustment"
       (count-figure (economic-event-resource-classified-as l-ev)) '(8.5 . "kg"))
(check "the record fulfils nothing" (economic-event-fulfills l-rec) #f)

;;; ── 2. a count that agrees ──────────────────────────────────────────────

(display "\n── 2. a count agrees with the ledger ──\n")

(define events-before (length (obs 'all-events)))
(define same (call 'count-stock "org:commune" "ada" "ada/flour" 8.5 "kg"))
(check-pred "the count is accepted" (ok? same))
(check "no adjustment lands" (field same 'event) "")
(check-pred "the difference is nothing" (near? (field same 'delta) 0.0))
(check "the ledger gains the count's record alone"
       (length (obs 'all-events)) (+ 1 events-before))
(check "a count that agrees is still a count that ran: its record states the figure"
       (count-figure (economic-event-resource-classified-as (obs 'get-event (field same 'record))))
       '(8.5 . "kg"))

;;; ── 2b. a count is of its instant ───────────────────────────────────────

(display "\n── 2b. a count read later is laid under what happened since ──\n")

;; twenty jars on the books; a picture taken at noon shows twenty; four are
;; drawn in the afternoon; the picture is read in the evening
(seed! "pantry/jars" "jar" 20.0 %count-unit "org:commune" "place:pantry")
(obs 'record-event
     (make-economic-event
      #:id "evt-jars-drawn" #:action 'consume #:input-of "proc-supper" #:resource-inventoried-as "pantry/jars" #:resource-conforms-to "jar"
      #:provider "ada" #:receiver "ada" #:resource-quantity (make-measure 4.0 %count-unit) #:has-point-in-time "2026-09-20T15:00:00Z"))
(define noon (call 'count-stock "org:commune" "ada" "pantry/jars" 20.0 %count-unit
                   "photo" "" "2026-09-20T12:00:00Z"))
(check-pred "the count is accepted" (ok? noon))
(check "it agrees with the ledger of its instant: no adjustment" (field noon 'event) "")
(check-pred "what was drawn since stays drawn" (near? (onhand "pantry/jars") 16.0))
(check-pred "the door answers what is on hand now" (near? (field noon 'onhand) 16.0))

;; the same picture showing eighteen: two were missing at noon, and are now
(define short (call 'count-stock "org:commune" "ada" "pantry/jars" 18.0 %count-unit
                    "photo" "" "2026-09-20T12:00:00Z"))
(check-pred "a count short at its instant lands that shortfall" (near? (field short 'delta) -2.0))
(check-pred "on the ledger as it stands" (near? (onhand "pantry/jars") 14.0))
(check "the adjustment carries the picture's instant"
       (economic-event-has-point-in-time (obs 'get-event (field short 'event)))
       "2026-09-20T12:00:00Z")

;; a later count stands: an older picture is an earlier sighting
(define older (call 'count-stock "org:commune" "ada" "pantry/jars" 20.0 %count-unit
                    "photo" "" "2026-09-20T09:00:00Z"))
(check-pred "a count older than the stock's latest count lands" (ok? older))
(check "…as an earlier sighting" (field older 'sighting) "earlier")
(check-pred "…and moves nothing" (near? (onhand "pantry/jars") 14.0))
(check "…and lands no adjustment" (field older 'event) "")
(check-pred "…but keeps what it saw"
            (let ((rec (obs 'get-event (field older 'record))))
              (equal? '(20.0 . "each") (count-figure (economic-event-resource-classified-as rec)))))

;; a lower takes at most what is there
(seed! "pantry/eggs" "egg" 12.0 %count-unit "org:commune" "place:pantry")
(obs 'record-event
     (make-economic-event
      #:id "evt-eggs-drawn" #:action 'consume #:input-of "proc-supper" #:resource-inventoried-as "pantry/eggs" #:resource-conforms-to "egg"
      #:provider "ada" #:receiver "ada" #:resource-quantity (make-measure 10.0 %count-unit) #:has-point-in-time "2026-09-20T15:00:00Z"))
(define eggs (call 'count-stock "org:commune" "ada" "pantry/eggs" 6.0 %count-unit
                   "photo" "" "2026-09-20T12:00:00Z"))
(check-pred "six short at noon, two on the books now: the lower takes the two"
            (and (near? (field eggs 'delta) -2.0) (near? (onhand "pantry/eggs") 0.0)))

;; an instant in the future is now
(define ahead (call 'count-stock "org:commune" "ada" "pantry/eggs" 3.0 %count-unit
                    "stated" "" "2999-01-01T00:00:00Z"))
(check-pred "a count dated ahead lands as of now"
            (and (near? (onhand "pantry/eggs") 3.0)
                 (string<? (economic-event-has-point-in-time (obs 'get-event (field ahead 'event)))
                           "2999")))

;;; ── 3. a count that finds more ──────────────────────────────────────────

(display "\n── 3. a count finds the ledger low ──\n")

(define more (call 'count-stock "org:commune" "ada" "pantry/rice" 42.0 ""
                   "label"))
(check-pred "the scope's stock is counted unasked" (ok? more))
(check "it is a raise"
       (economic-event-action (obs 'get-event (field more 'event))) 'raise)
(check-pred "the stock now reads the count" (near? (onhand "pantry/rice") 42.0))
(check "an unstated place is the stock's own"
       (economic-event-at-location (obs 'get-event (field more 'event)))
       "place:pantry")
(check "the technique named is the process"
       (economic-event-output-of (obs 'get-event (field more 'event)))
       "count:label")

;;; ── 4. the door's width ─────────────────────────────────────────────────

(display "\n── 4. what does not fit through ──\n")

(check-pred "a count is in the stock's unit"
            (err (call 'count-stock "org:commune" "ada" "ada/flour" 8.0 "l")))
(check-pred "a count is zero or more"
            (err (call 'count-stock "org:commune" "ada" "ada/flour" -1.0 "kg")))
(check-pred "a technique is one the door knows"
            (err (call 'count-stock "org:commune" "ada" "ada/flour" 8.0 "kg" "guess")))
(check-pred "a count names a stock that exists"
            (err (call 'count-stock "org:commune" "ada" "no/such" 1.0 %count-unit)))
(check-pred "another person's stock is counted on a commitment"
            (err (call 'count-stock "org:commune" "ada" "bob/drill" 0.0 %count-unit)))
(check-pred "…and stands untouched" (near? (onhand "bob/drill") 1.0))
(check-pred "a count of nothing left is a count"
            (ok? (call 'count-stock "org:commune" "ada" "ada/flour" 0.0 "kg")))
(check-pred "…and the stock reads zero" (near? (onhand "ada/flour") 0.0))

;;; ── 5. a planned count ──────────────────────────────────────────────────

(display "\n── 5. a count the plan asked for ──\n")

;; the counter's hours, and the record the run produces
(ps 'add-commitment
    (make-commitment #:id "cmt-count-work" #:action 'work #:input-of "count-shed" #:resource-conforms-to "skill-count"
                     #:effort-quantity (make-measure 0.25 %effort-unit) #:provider "ada" #:receiver "org:commune" #:at-location "place:shed" #:in-scope-of '("org:commune")))
(ps 'add-commitment
    (make-commitment #:id "cmt-count-record" #:action 'produce #:output-of "count-shed" #:resource-conforms-to "count-record"
                     #:resource-quantity (make-measure 1.0 %count-unit) #:provider "ada" #:receiver "org:commune" #:at-location "place:shed" #:in-scope-of '("org:commune")))

(check-pred "a commitment is its counter's alone"
            (err (call 'count-stock "org:commune" "carol" "bob/drill" 1.0 %count-unit
                       "stated" "" "" "cmt-count-work")))
(check-pred "a count names a commitment the plan holds"
            (err (call 'count-stock "org:commune" "ada" "bob/drill" 1.0 %count-unit
                       "stated" "" "" "cmt-none")))

(define planned (call 'count-stock "org:commune" "ada" "bob/drill" 1.0 %count-unit
                      "stated" "" "" "cmt-count-work"))
(check-pred "on a commitment, another's stock is counted" (ok? planned))
(check "the count agrees, so no adjustment lands" (field planned 'event) "")
(check-pred "…and the run's record lands all the same"
            (not (string-null? (field planned 'record))))

(define rec (obs 'get-event (field planned 'record)))
(check-pred "the record is on the ledger" rec)
(check "it is a produce" (economic-event-action rec) 'produce)
(check "of the record the plan committed"
       (economic-event-resource-conforms-to rec) "count-record")
(check "it fulfils the record's commitment"
       (economic-event-fulfills rec) "cmt-count-record")
(check "its process is the planned run's"
       (economic-event-output-of rec) "count-shed")
(check "its place is the stock's"
       (economic-event-at-location rec) "place:shed")
(check-pred "the record's commitment is fulfilled"
            (fulfillment-state-finished (obs 'get-fulfillment "cmt-count-record")))

;;; ── 6. the fold reads the adjustments ───────────────────────────────────

(display "\n── 6. the reading fold's drift ──\n")

(define flour (call 'scope-readings "org:commune" "flour"))
(check-pred "the fold answers for the spec" (ok? flour))
(check-pred "its drift counts the counts that found the ledger off"
            (>= (assq-ref (field flour 'drift) 'n) 2))
(check-pred "…and nets them in the direction they ran"
            (< (assq-ref (field flour 'drift) 'net) 0))
(check-pred "a row is kept per technique"
            (any (lambda (row) (equal? "count:stated" (assq-ref row 'technique)))
                 (field flour 'rows)))

;;; ── 7. a count that was contested and voided leaves the readings ────────

(display "\n── 7. a voided count is no reading and no last count ──\n")

(define drift-n (lambda () (assq-ref (field (call 'scope-readings "org:commune" "flour") 'drift) 'n)))
(define readings-n (lambda () (length (field (call 'readings-between "org:commune" "flour" "" "") 'rows))))
(define n-before (drift-n))
(define flour-before (onhand "ada/flour"))
(define rows-before (readings-n))
(define late (call 'count-stock "org:commune" "ada" "ada/flour" 1.0 "kg" "stated" "place:pantry"
                   "2030-01-01T00:00:00Z" "" "" "a count made much later"))
(check-pred "a later count is accepted" (ok? late))
(check "…and a reading in the fold" (drift-n) (+ n-before 1))

;; what a member reads to contest a count
(define (history who) (field (call 'count-history "org:commune" who "ada/flour" 3) 'rows))
(check "the newest count heads the history" (assq-ref (car (history "bob")) 'id) (field late 'event))
(check-pred "…as the adjustment landed, signed" (near? (assq-ref (car (history "bob")) 'delta) (- 1.0 flour-before)))
(check "…with the technique and the counter" 
       (list (assq-ref (car (history "bob")) 'technique) (assq-ref (car (history "bob")) 'counter))
       '("count:stated" "ada"))
(check "…and whether the reader counted it" 
       (list (assq-ref (car (history "bob")) 'mine) (assq-ref (car (history "ada")) 'mine)) '(#f #t))
(check "the history is bounded" (length (history "bob")) 3)
(check "a count that named a picture says which"
       (assq-ref (find (lambda (r) (not (string-null? (assq-ref r 'evidence))))
                       (field (call 'count-history "org:commune" "bob" "ada/flour" 20) 'rows))
                 'evidence)
       %pic)
(for-each (lambda (id suffix)
            (obs 'apply-correction
                 (void-event (obs 'get-event id) (string-append "contest:late:void" suffix)
                             "contested, and found not done" "org:commune" "2030-01-02T00:00:00Z")))
          (list (field late 'event) (field late 'record)) '("" "-record"))
(check "voided, the stock reads what it read before"
       (onhand "ada/flour") flour-before)
(check "…nor a reading in the fold" (drift-n) n-before)
(check "…nor a row of the history" (readings-n) rows-before)
(check "…nor a count a member may contest" 
       (any (lambda (r) (equal? (field late 'event) (assq-ref r 'id))) (history "bob")) #f)

;;; ── 7. every count is in the drift and in the history ───────────────────

(display "\n── 7. a count that agrees weighs in ──\n")

(define (drift-of-spec spec) (field (call 'scope-readings "org:commune" spec) 'drift))
(seed! "pantry/salt" "salt" 5.0 "kg" "org:commune" "place:pantry")
(define salt-off (call 'count-stock "org:commune" "ada" "pantry/salt" 4.0 "kg"))
(check "one count that found the ledger off: the drift is that difference"
       (list (assq-ref (drift-of-spec "salt") 'n) (assq-ref (drift-of-spec "salt") 'mean-abs)) '(1 1.0))
(define salt-ok (call 'count-stock "org:commune" "ada" "pantry/salt" 4.0 "kg"))
(check "a count that agrees is a count: the mean halves"
       (list (assq-ref (drift-of-spec "salt") 'n) (assq-ref (drift-of-spec "salt") 'mean-abs)) '(2 0.5))
(check-pred "…and moves the net nowhere" (near? (assq-ref (drift-of-spec "salt") 'net) -1.0))

(define salt-rows (field (call 'count-history "org:commune" "bob" "pantry/salt" 10) 'rows))
(check "the history holds a row a count" (length salt-rows) 2)
(check "the agreeing count heads it, named by its record, a difference of nothing"
       (list (assq-ref (car salt-rows) 'id) (assq-ref (car salt-rows) 'delta))
       (list (field salt-ok 'record) 0.0))
(check "each row states the figure found and its unit"
       (map (lambda (r) (list (assq-ref r 'counted) (assq-ref r 'unit))) salt-rows)
       '((4.0 "kg") (4.0 "kg")))
(check "the count that found the ledger off is named by its adjustment"
       (assq-ref (cadr salt-rows) 'id) (field salt-off 'event))

;; a container's count scales what is in it; that is no reading of the contents
(seed! "pantry/box" "box" 10.0 %count-unit "org:commune" "place:pantry")
(obs 'seed-resource
     (make-economic-resource #:id "pantry/box/tea" #:name "tea" #:conforms-to "tea" #:classified-as '()
                             #:accounting-quantity (make-measure 30.0 "kg") #:onhand-quantity (make-measure 30.0 "kg")
                             #:current-location "place:pantry" #:primary-accountable "org:commune" #:contained-in "pantry/box"))
(call 'count-stock "org:commune" "ada" "pantry/box" 5.0 %count-unit)
(check-pred "the contents follow their container" (near? (onhand "pantry/box/tea") 15.0))
(check "…and the fold holds no reading of them"
       (length (field (call 'readings-between "org:commune" "tea" "" "") 'rows)) 0)
(check "…nor any drift" (assq-ref (drift-of-spec "tea") 'n) 0)

;;; ── 8. the door's two pure halves: whether a count lands, and what it lands ──

(display "\n── 8. count-refusal and count-plan, read directly ──\n")

(use-modules ((playnet doors count-door) #:select (count-refusal count-plan count-run))
             ((playnet vf formulas counting) #:select (count-expected count-agreed?))
             ((playnet utils clock) #:select (civil->instant)))

(define (stock rid qty unit)
  (make-economic-resource #:id rid #:name "oats" #:conforms-to "oats" #:classified-as '()
                          #:accounting-quantity (make-measure qty unit) #:onhand-quantity (make-measure qty unit)
                          #:current-location "place:pantry" #:primary-accountable "ada"))
(define oats (stock "ada/oats" 10.0 "kg"))
(define (refusal . kw) (apply count-refusal oats 8.0 "kg" "stated" #f #:agent "ada" #:standing? #t kw))

(check "a count that may land is refused nothing" (refusal) #f)
(check "no stock" (count-refusal #f 8.0 "kg" "stated" #f #:agent "ada") "no such stock")
(check "a figure below nothing" (count-refusal oats -1 "kg" "stated" #f #:agent "ada" #:standing? #t) "a count is zero or more")
(check "a commitment the plan does not hold" (refusal #:fulfills "cmt-x" #:cmt #f) "commitment not found")
(check "a technique nobody carries" (count-refusal oats 8.0 "kg" "guess" #f #:agent "ada" #:standing? #t) "not a counting technique")
(check-pred "evidence that is no hash" (string? (count-refusal oats 8.0 "kg" "photo" "nope" #:agent "ada" #:standing? #t)))
(check "a stock that is not the counter's to count" (count-refusal oats 8.0 "kg" "stated" #f #:agent "bob") "not yours to count")
(check "a count whose commitment has ended" (refusal #:finished? #t) "that count has ended")
(check "an instant before the books held the stock" (refusal #:predates? #t) "the books did not hold this stock yet")
(check "another unit than the stock's" (count-refusal oats 8.0 %count-unit "stated" #f #:agent "ada" #:standing? #t) "count in the stock's unit: kg")
(check "the technique alone is the process of a count no plan asked for" (count-run #f "photo") '(#f . "count:photo"))

(define now (civil->instant "2026-09-28T12:00:00Z"))
(define (plan counted . kw)
  (apply count-plan "evt-x" oats counted "kg" #:agent "ada" #:scope-id "org:commune" #:tech "stated"
         #:now now #:then #f #:held 10.0 #:have 10.0 #:latest? #t #:flows '() kw))
(define (actions p) (map economic-event-action (assq-ref p 'events)))
(define (reply p k) (assq-ref (assq-ref p 'reply) k))

(let ((p (plan 8.0)))
  (check "a count that finds the ledger off lands its adjustment, then its record" (actions p) '(lower produce))
  (check "…and answers the difference and what is on hand after" (list (reply p 'delta) (reply p 'onhand) (reply p 'event)) '(-2.0 8.0 "evt-x")))
(let ((p (plan 10.0)))
  (check "a count that agrees lands its record alone" (actions p) '(produce))
  (check-pred "…marked as agreeing" (count-agreed? (economic-event-resource-classified-as (car (assq-ref p 'events)))))
  (check "…and names no adjustment" (reply p 'event) ""))
(let ((p (plan 8.0 #:latest? #f)))
  (check "an earlier sighting lands its record alone and moves nothing" (list (actions p) (reply p 'delta) (reply p 'sighting)) '((produce) 0.0 "earlier"))
  (check "…and does not say it agreed" (count-agreed? (economic-event-resource-classified-as (car (assq-ref p 'events)))) #f))
(let ((p (plan 0.0 #:held 12.0 #:have 10.0)))
  (check "a lower takes at most what the ledger holds now" (reply p 'delta) -10.0))
(let* ((flows '(((id . "bake") (action . "consume") (quantity . -3.0) (when . "") (proc . "bake"))))
       (p (plan 8.0 #:flows flows))
       (tags (economic-event-resource-classified-as (car (assq-ref p 'events)))))
  (check "the plan's range rides the count's events" (count-expected tags) '(7.0 10.0 . "kg"))
  (check "…and the answer" (assq-ref (reply p 'expected) 'low) 7.0))
(let ((p (plan 8.0 #:then (civil->instant "2026-09-28T09:00:00Z") #:when-iso "2026-09-28T09:00:00Z")))
  (check "a count of an earlier instant is dated as the counter stated it"
         (economic-event-has-point-in-time (car (assq-ref p 'events))) "2026-09-28T09:00:00Z"))

;;; ── a count stated at an instant is one count, however often it lands ──

(display "\n── a count of an instant lands once ──\n")

(seed! "pantry/oats" "oats" 30.0 "kg" "org:commune" "place:pantry")
(define (count-oats) (call 'count-stock "org:commune" "ada" "pantry/oats" 27.0 "kg"
                           "stated" "place:pantry" "2026-09-20T08:00:00Z" "" "" ""))
(define first-landing (count-oats))
(define events-after-one (length (obs 'all-events)))
(define second-landing (count-oats))
(check "the first landing moves the ledger" (list (field first-landing 'delta) (onhand "pantry/oats")) '(-3.0 27.0))
(check "the second names the same count" (field second-landing 'record) (field first-landing 'record))
(check "…and the same adjustment and difference"
       (list (field second-landing 'event) (field second-landing 'delta))
       (list (field first-landing 'event) (field first-landing 'delta)))
(check "…and lands nothing more" (length (obs 'all-events)) events-after-one)
(check "the ledger stands where the one count left it" (onhand "pantry/oats") 27.0)
(check-pred "the door says it had it" (field second-landing 'again))
(check "another person's count of that stock at that instant is their own count"
       (equal? (field (call 'count-stock "org:commune" "bob" "pantry/oats" 27.0 "kg"
                            "stated" "place:pantry" "2026-09-20T08:00:00Z" "" "" "")
                      'record)
               (field first-landing 'record))
       #f)

(test-summary!)
