;;; test-planned-counts.scm — the planned count, over the real ^planner-service
;;; (docs/observation/capture.md §4): the schedule the inventory's stocks fall
;;; into, the offers the due counts are laid as, the accept that makes one a
;;; commitment, and the count that fulfils it.
;;;
;;; What this pins:
;;;
;;;   • every thing the inventory shows that sits in no other is one target,
;;;     with a line for itself and one for each thing in it;
;;;   • a stock never counted is due, and one just counted is due an interval
;;;     on;
;;;   • due counts are laid as directed work offers, by turn, the owner of a
;;;     stock passed over while another member can count it, a bounded number
;;;     a call, and a target already asked is left as it stands;
;;;   • an accepted count is the counter's commitment, and the solve after the
;;;     accept stands;
;;;   • counting on it lands the hours, the record and the adjustment, under
;;;     the regime's technique, and refuses a stock outside the target;
;;;   • an undisclosed count is read by its counter alone until its window
;;;     opens.
;;;
;;; Run from project root:
;;;   tools/own-ccache.sh guile --no-auto-compile -q -L module tests/playnet/test-planned-counts.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)

(add-to-load-path "module")
(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules ((playnet wire rows) #:select (plain-reply))   ; a door's rows, read back as alists
             (playnet test harness))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (playnet planner scope root) (playnet planner vf schemas) (playnet planner observation states) (srfi srfi-1)
             (playnet planner doors service)
             (playnet planner formulas counting)
             (playnet planner doors offers)
             ((playnet planner observation observer) #:select (void-event))
             (playnet utils clock)
             (srfi srfi-1))

(display "\n── Setup: a commune of three, a bin of jam, a sack of rice ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env
                        (lambda () (spawn-scope-root "Commune"))
                        store))

(define svc
  (with-vat vat
    (let ((as ($ scope 'agent-store)))
      ($ as 'add-role
         (make-agent-relationship-role #:id "role-member" #:label "member"
                                       #:inverse-label "has member"))
      (for-each (lambda (who)
                  ($ as 'add-agent (make-agent #:id who #:type 'person #:name who
                                               #:classified-as '()))
                  ($ as 'add-relationship
                     (make-agent-relationship #:id (string-append "rel-" who) #:subject who #:object "org:commune"
                                              #:relationship "role-member" #:in-scope-of "org:commune")))
                '("ada" "bob" "cyd")))
    ($ ($ scope 'recipe-store) 'add-resource-spec
       (make-resource-specification #:id "spec-bin" #:name "Storage bin"
                                    #:resource-classified-as '("container") #:default-unit-of-resource %count-unit #:default-unit-of-effort %effort-unit
                                    #:keep-in-place #t))
    ;; the inventory shows what conforms to a spec the recipes know
    (for-each (lambda (spec)
                ($ ($ scope 'recipe-store) 'add-resource-spec
                   (make-resource-specification #:id (car spec) #:name (car spec) #:resource-classified-as '()
                                                #:default-unit-of-resource (cdr spec))))
              '(("rice" . "kg") ("jam" . "each") ("lid" . "each") ("tools" . "each") ("grain" . "kg")))
    (spawn ^planner-service (hashmap-set (hashmap) "org:commune" scope))))

;; a read door answers the page's rows; the test reads them back as alists
(define (call method . args)
  (let ((r (with-vat vat (apply $ svc method args))))
    (plain-reply r)))
(define (obs method . args) (with-vat vat (apply $ ($ scope 'observer) method args)))
(define (ps method . args) (with-vat vat (apply $ ($ scope 'plan-store) method args)))
(define (ok? r)  (and (pair? r) (eq? (car r) 'ok)))
(define (err r)  (and (pair? r) (eq? (car r) 'error) (cdr r)))
(define (field r k) (and (ok? r) (assq-ref (cdr r) k)))
(define (near? a b) (< (abs (- a b)) 1e-6))

(define (seed! rid name spec qty unit owner place in)
  (obs 'seed-resource
       (make-economic-resource #:id rid #:name name #:conforms-to spec #:classified-as '()
                               #:accounting-quantity (make-measure qty unit) #:onhand-quantity (make-measure qty unit)
                               #:current-location place #:primary-accountable owner #:custodian-scope "org:commune" #:contained-in in)))

(seed! "bin/1"      "the jar bin" "spec-bin" 1.0  %count-unit "org:commune" "place:shelf" #f)
(seed! "bin/1/jam"  "plum jam"    "jam"      12.0 %count-unit "org:commune" "place:shelf" "bin/1")
(seed! "bin/1/lids" "lids"        "lid"      30.0 %count-unit "org:commune" "place:shelf" "bin/1")
(seed! "rice"       "rice"        "rice"     40.0 "kg"   "ada"         "place:pantry" #f)

(check-pred "setup: service spawned" svc)

;;; ── 1. the schedule ─────────────────────────────────────────────────────

(display "\n── 1. the schedule ──\n")

(define sched (call 'count-schedule "org:commune"))
(check-pred "the schedule answers" (ok? sched))
(define rows (field sched 'rows))
(define (row id) (find (lambda (r) (equal? id (assq-ref r 'id))) rows))

(check-pred "the bin is a target" (row "bin/1"))
(check-pred "the rice is a target" (row "rice"))
(check "what is in the bin is a line of its visit, not a target of its own"
       (row "bin/1/jam") #f)
(check "the bin's visit counts the bin and the two things in it"
       (assq-ref (row "bin/1") 'lines) 3)
(check "the rice's visit counts one line" (assq-ref (row "rice") 'lines) 1)
(check-pred "a visit with more lines takes more hours"
            (> (assq-ref (row "bin/1") 'hours) (assq-ref (row "rice") 'hours)))
(check-pred "a stock never counted is due" (assq-ref (row "rice") 'overdue))
(check "…and names no last count" (assq-ref (row "rice") 'last-count) "")
(check-pred "every row names its class"
            (every (lambda (r) (member (assq-ref r 'class) '("A" "B" "C"))) rows))
(check-pred "every interval lies between a day and a year"
            (every (lambda (r) (let ((i (assq-ref r 'interval)))
                                 (and (>= i 86400.0) (<= i (* 52 604800.0)))))
                   rows))

;;; ── 2. the offers ───────────────────────────────────────────────────────

(display "\n── 2. due counts are laid as offers ──\n")

(define laid (call 'plan-counts "org:commune" "ada" "announced" "" 1))
(check-pred "the door answers" (ok? laid))
(check "one call lays as many as it was bounded to" (length (field laid 'laid)) 1)
(check "…and says how many were due" (field laid 'due) 2)

(define more (call 'plan-counts "org:commune" "ada" "announced" "" 5))
(check "a second call lays the target the first left"
       (length (field more 'laid)) 1)
(check-pred "…which is the other target"
            (not (equal? (assq-ref (car (field laid 'laid)) 'target)
                         (assq-ref (car (field more 'laid)) 'target))))
(define none (call 'plan-counts "org:commune" "ada" "announced" "" 5))
(check "a target already asked is left as it stands" (field none 'laid) '())

(define offers (append (field laid 'laid) (field more 'laid)))
(define (offer-of target) (find (lambda (o) (equal? target (assq-ref o 'target))) offers))
(check-pred "every offer names a member as counter"
            (every (lambda (o) (member (assq-ref o 'counter) '("ada" "bob" "cyd"))) offers))
(check-pred "the rice is ada's, and its count goes to another"
            (not (equal? "ada" (assq-ref (offer-of "rice") 'counter))))

(define rice-offer (offer-of "rice"))
(define rice-counter (assq-ref rice-offer 'counter))
(define snap (call 'scope-snapshot "org:commune" #f rice-counter))
(check-pred "the counter finds the offer among their proposals"
            (any (lambda (p) (equal? (assq-ref rice-offer 'proposal) (assq-ref p 'id)))
                 (or (assq-ref snap 'proposals) '())))
(check-pred "…as offered work that names what it counts"
            (let ((p (find (lambda (p) (equal? (assq-ref rice-offer 'proposal) (assq-ref p 'id)))
                           (assq-ref snap 'proposals))))
              (and (assq-ref p 'offer)
                   (equal? "count rice" (assq-ref p 'label))
                   (equal? "rice" (count-process-target (assq-ref p 'proc))))))
(check "another member's proposals hold no such offer"
       (filter (lambda (p) (equal? (assq-ref rice-offer 'proposal) (assq-ref p 'id)))
               (or (assq-ref (call 'scope-snapshot "org:commune" #f "ada") 'proposals) '()))
       '())

(define named (call 'plan-counts "org:commune" "ada" "announced" "cyd" 5))
(check "a counter may be named, and with nothing due nothing is laid"
       (field named 'laid) '())

;;; ── 3. the accept ───────────────────────────────────────────────────────

(display "\n── 3. an accepted count ──\n")

(define accepted (call 'accept-work-offer "org:commune" rice-counter
                       (assq-ref rice-offer 'proposal)))
(check-pred "the counter accepts, and the solve after the accept stands" (ok? accepted))

(define cmt (find (lambda (c) (equal? "rice" (count-process-target (commitment-input-of c))))
                  (ps 'all-commitments)))
(check-pred "the count is a commitment" cmt)
(check "…its counter's" (commitment-provider cmt) rice-counter)
(check "…of work" (commitment-action cmt) 'work)
(check "…at the stock's place" (commitment-at-location cmt) "place:pantry")
(check-pred "…for the hours a visit of one line takes"
            (near? (measure-qty (commitment-effort-quantity cmt)) (count-hours 1)))

(define snap2 (call 'scope-snapshot "org:commune" #f rice-counter))
(define on-wire (find (lambda (c) (equal? (commitment-id cmt) (assq-ref c 'id)))
                      (assq-ref snap2 'commitments)))
(check-pred "the commitment rides the calendar's wire" on-wire)
(check "…named for what it counts" (assq-ref on-wire 'proc-name) "count rice")

;;; ── 4. the count ────────────────────────────────────────────────────────

(display "\n── 4. counting on the commitment ──\n")

(check-pred "a stock outside the target is another count"
            (err (call 'count-stock "org:commune" rice-counter "bin/1/jam" 12.0 %count-unit
                       "stated" "" "" (commitment-id cmt))))
(check-pred "a commitment is its counter's alone"
            (err (call 'count-stock "org:commune" "ada" "rice" 40.0 "kg"
                       "stated" "" "" (commitment-id cmt))))

(define counted (call 'count-stock "org:commune" rice-counter "rice" 37.5 "kg"
                      "stated" "" "" (commitment-id cmt)))
(check-pred "the counter counts" (ok? counted))
(check-pred "the difference lands" (near? (field counted 'delta) -2.5))
(check-pred "the hours land, the visit and its line"
            (near? (field counted 'hours) (count-hours 1)))

(define adj (obs 'get-event (field counted 'event)))
(define rec (obs 'get-event (field counted 'record)))
(check "the adjustment's technique is the regime's, its target left off"
       (economic-event-output-of adj) "count~announced")
(check "the record lands under the same technique"
       (economic-event-output-of rec) "count~announced")
(check-pred "the record names what was counted"
            (member "count-of:rice" (economic-event-resource-classified-as rec)))
(define hours-ev
  (find (lambda (e) (and (eq? 'work (economic-event-action e))
                         (equal? (commitment-id cmt) (economic-event-fulfills e))))
        (obs 'all-events)))
(check-pred "the hours are a work event fulfilling the commitment" hours-ev)
(check "…the counter's" (economic-event-provider hours-ev) rice-counter)
(check-pred "the commitment is fulfilled"
            (fulfillment-state-finished (obs 'get-fulfillment (commitment-id cmt))))
(check-pred "the stock reads the count"
            (near? (measure-qty (economic-resource-onhand-quantity (obs 'get-resource "rice"))) 37.5))

(define after (field (call 'count-schedule "org:commune") 'rows))
(define rice-after (find (lambda (r) (equal? "rice" (assq-ref r 'id))) after))
(check-pred "the schedule names when the rice was last counted"
            (string? (assq-ref rice-after 'last-count)))
(check-pred "…and it is due an interval on" (not (assq-ref rice-after 'overdue)))

;;; ── 5. a container, line by line ────────────────────────────────────────

(display "\n── 5. a container counted line by line ──\n")

(define bin-offer (offer-of "bin/1"))
(define bin-counter (assq-ref bin-offer 'counter))
(call 'accept-work-offer "org:commune" bin-counter (assq-ref bin-offer 'proposal))
(define bin-cmt (find (lambda (c) (equal? "bin/1" (count-process-target (commitment-input-of c))))
                      (ps 'all-commitments)))
(check-pred "the bin's count is a commitment" bin-cmt)

(define c1 (call 'count-stock "org:commune" bin-counter "bin/1" 1.0 %count-unit
                 "label" "" "" (commitment-id bin-cmt)))
(define c2 (call 'count-stock "org:commune" bin-counter "bin/1/jam" 11.0 %count-unit
                 "label" "" "" (commitment-id bin-cmt)))
(define c3 (call 'count-stock "org:commune" bin-counter "bin/1/lids" 30.0 %count-unit
                 "label" "" "" (commitment-id bin-cmt)))
(check-pred "the bin and each thing in it is counted on the one commitment"
            (and (ok? c1) (ok? c2) (ok? c3)))
(check-pred "the visit rides the bin's own line"
            (near? (field c1 'hours) (count-hours 1)))
(check-pred "every other line is a line"
            (and (near? (field c2 'hours) %count-hours-per-line)
                 (near? (field c3 'hours) %count-hours-per-line)))
(check-pred "the lines' hours sum to the visit's"
            (near? (+ (field c1 'hours) (field c2 'hours) (field c3 'hours)) (count-hours 3)))
(check "a line that agreed lands no adjustment" (field c3 'event) "")
(check-pred "…and lands its record all the same" (not (string-null? (field c3 'record))))
(check-pred "the commitment is fulfilled by the three lines"
            (fulfillment-state-finished (obs 'get-fulfillment (commitment-id bin-cmt))))

;;; ── 6. a count the custodian does not read ahead ────────────────────────

(display "\n── 6. an undisclosed count ──\n")

(seed! "tools" "the tool chest" "tools" 1.0 %count-unit "org:commune" "place:shed" #f)
(define hid (call 'plan-counts "org:commune" "ada" "undisclosed" "bob" 5))
(check "the undisclosed count is laid, to the counter named"
       (map (lambda (o) (assq-ref o 'counter)) (field hid 'laid)) '("bob"))
(define hid-offer (car (field hid 'laid)))
(check "…under its regime" (assq-ref hid-offer 'regime) "undisclosed")
(call 'accept-work-offer "org:commune" "bob" (assq-ref hid-offer 'proposal))
(define hid-cmt (find (lambda (c) (equal? "tools" (count-process-target (commitment-input-of c))))
                      (ps 'all-commitments)))
(check-pred "it is counted blind" (count-blind? (commitment-input-of hid-cmt)))

;; the window is open from the moment an overdue count is laid, so the
;; commitment is set a day ahead to read it from both sides of its opening
(define ahead
  (copy-commitment hid-cmt
                   #:id "cmt-hidden-ahead"
                   #:has-beginning "2999-01-01T00:00:00Z" #:has-end "2999-01-02T00:00:00Z"))
(ps 'add-commitment ahead)
(define (reads? who id)
  (any (lambda (c) (equal? id (assq-ref c 'id)))
       (or (assq-ref (call 'scope-snapshot "org:commune" #f who) 'commitments) '())))
(check-pred "its counter reads it ahead of its window" (reads? "bob" "cmt-hidden-ahead"))
(check-pred "another member does not" (not (reads? "ada" "cmt-hidden-ahead")))
(check-pred "a reader who names nobody does not" (not (reads? #f "cmt-hidden-ahead")))
(check-pred "once its window has opened, every member reads it"
            (reads? "ada" (commitment-id hid-cmt)))
(check-pred "an announced count is read by every member from the start"
            (reads? "ada" (commitment-id bin-cmt)))

;; a window is read at its own time of day: a commitment beginning this afternoon
;; is hidden from the others this morning, and read once its hour has come
(define nowu* (instant->unix (now)))
(define (epoch->civil* u) (instant->civil (unix->instant (inexact->exact (floor u)))))
(define (ahead-at id secs)
  (ps 'add-commitment
      (copy-commitment hid-cmt #:id id
                       #:has-beginning (instant->civil (unix->instant (inexact->exact (floor (+ nowu* secs)))))
                       #:has-end (instant->civil (unix->instant (inexact->exact (floor (+ nowu* secs 7200))))))))
(with-vat vat (ahead-at "cmt-hidden-later" 3600))
(with-vat vat (ahead-at "cmt-hidden-earlier" -3600))
(check-pred "a blind count beginning in an hour is hidden from the others" (not (reads? "ada" "cmt-hidden-later")))
(check-pred "…and read by them once its hour has passed" (reads? "ada" "cmt-hidden-earlier"))

;;; ── 7. the offer loop's own bound ───────────────────────────────────────

(display "\n── 7. counts are held to the bound on open offers ──\n")

(define just-counted (find (lambda (r) (equal? "rice" (assq-ref r 'id)))
                           (field (call 'count-schedule "org:commune") 'rows)))
(check-pred "the last count stands at the moment it was made, not at its midnight"
            (let ((at (instant->unix (civil->instant (assq-ref just-counted 'last-count)))))
              (< (abs (- at nowu*)) 600)))
(check "a stock counted a moment ago is not laid again"
       (field (call 'plan-counts "org:commune" "ada" "announced" "" 5) 'laid) '())

(seed! "grain" "grain sack" "grain" 5.0 "kg" "org:commune" "place:shed" #f)
(for-each (lambda (i)
            (with-vat vat (offer-work scope `((input-of . ,(string-append "filler-" (number->string i)))
                                              (effort . 0.5))
                                      "bob")))
          (iota 12))
(define bounded (call 'plan-counts "org:commune" "ada" "announced" "" 5))
(check-pred "the door answers" (ok? bounded))
(check "with the offer loop full, no count is laid" (field bounded 'laid) '())
(check "…and the walk names why it stopped" (field bounded 'refused) "max-open")

;;; ── 8. a count that was contested and voided is no last count ───────────

(display "\n── 8. a voided count is not the last ──\n")

(define (rice-row) (find (lambda (r) (equal? "rice" (assq-ref r 'id)))
                         (field (call 'count-schedule "org:commune") 'rows)))
(check-pred "the rice has a last count" (string? (assq-ref (rice-row) 'last-count)))
(check-pred "…and is not due" (not (assq-ref (rice-row) 'overdue)))
;; a contest settles the whole count: the adjustment and its record
(for-each (lambda (eid)
            (obs 'apply-correction
                 (void-event (obs 'get-event eid) (string-append "contest:rice:void~" eid)
                             "contested, and found not done" "org:commune" (epoch->civil* nowu*))))
          (list (field counted 'event) (field counted 'record)))
(check "voided, the rice has no last count" (assq-ref (rice-row) 'last-count) "")
(check-pred "…and is due again" (assq-ref (rice-row) 'overdue))

(test-summary!)
