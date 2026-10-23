;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; adjustment.scm — a count lands the difference
;;;
;;; ValueFlows' rule for a count (docs/observation/readings-are-counts.md §1.1):
;;; a figure that agrees with the ledger leaves no adjustment, and one that
;;; disagrees lands a `raise` or a `lower` of the difference on that same stock.
;;; An adjustment states the figure that was counted (counting.scm
;;; count-figure-tag), so the observation outlives the difference. Every
;;; place that counts a stock states the rule through this module, so the
;;; tolerance that says "agrees" and the shape of the event that says
;;; "disagrees" each have one statement:
;;;
;;;   a host's probe        observation/host-facts.scm   count-host-stock!
;;;   a person's count      doors/count-door.scm       do-count-stock
;;;                         (its record: count-record-event; what an event of
;;;                         a count is: count-event?, count-event-of)
;;;   a re-declared means   doors/service.scm          declare-means
;;;   a skill held or not   doors/service.scm          declare-skill, revoke-skill
;;;
;;; Pure over numbers and strings, importing the records alone, so the probe
;;; (which the service imports) and the service can both import it.

(define-module (playnet observation adjustment)
  #:use-module ((playnet utils units) #:select (%count-unit))
  #:use-module (playnet vf schemas)
  #:use-module ((playnet vf formulas counting)
                #:select (count-contestable? count-target count-of-tag count-record-id
                          count-figure-tag count-spec-tag %count-agreed-tag %count-tolerance))
  #:re-export (%count-tolerance)
  #:export (count-difference adjustment-event
            count-event? count-event-of count-record-event))

(define (count-difference onhand counted)
  "COUNTED less ONHAND (a stock never seen holds nothing), or nothing when they
   agree within the tolerance. The arithmetic is the caller's own: exact
   figures give an exact difference, so a stock counted in whole units stays in
   whole units."
  (let ((d (- counted (or onhand 0))))
    (if (< (abs d) %count-tolerance) (if (exact? d) 0 0.0) d)))

(define (figure-tags counted unit tags)
  "TAGS with the figure COUNTED UNIT stated first, or TAGS alone (#f when
   there are none) for a count that states no figure."
  (let ((tags (if counted (cons (count-figure-tag counted unit) (or tags '())) (or tags '()))))
    (and (pair? tags) tags)))

(define* (adjustment-event id resource-id spec delta unit
                           #:key provider receiver process at to when created
                                 note in-scope-of (classified-as '()) counted
                                 fulfills satisfies)
  "The `raise` (DELTA above nothing) or `lower` (below) of |DELTA| UNIT on
   RESOURCE-ID, or #f when DELTA is nothing: an agreeing count lands no
   adjustment. COUNTED is the figure the count found, stated on the event.
   PROCESS is the technique that produced the count (the event's output-of);
   WHEN is the instant it was counted and CREATED the instant it was written."
  (and (number? delta)
       (>= (abs delta) %count-tolerance)
       (make-economic-event
        #:id id #:action (if (> delta 0) 'raise 'lower) #:output-of process                                 ; 3-4 input-of, output-of
        #:resource-inventoried-as resource-id                             ; 5-6 the stock counted
        #:resource-conforms-to spec #:resource-classified-as (figure-tags counted unit classified-as) ; 7-8 conforms-to, classified-as
        #:provider provider #:receiver receiver                          ; 9-10
        #:resource-quantity (make-measure (abs delta) unit)         ; 11-12 resource-quantity, effort
 #:has-point-in-time when #:created created                         ; 13-16 beginning, end, point, created
        #:at-location at #:to-location to                  ; 17-19 at-location, to-location, state
        #:fulfills fulfills #:satisfies satisfies          ; 20-21 the planned purchase, the need it answers
                                   ; 22-24 corrects, realization-of, settles
        #:note note #:in-scope-of in-scope-of                           ; 25-26
)))                                ; 27 previous-event

(define (count-event? e)
  "E is a part of a count: its adjustment, its record or its hours. One rule
   with the contest's (counting.scm count-contestable?), so a count and a
   contest of it cannot disagree about what a count is."
  (count-contestable? (economic-event-action e) (economic-event-output-of e)
                      (economic-event-input-of e)))

(define (count-event-of e)
  "The resource id count event E is a count of, or #f."
  (and (count-event? e)
       (count-target (economic-event-resource-inventoried-as e)
                     (economic-event-resource-classified-as e))))

(define* (count-record-event base-id resource-id spec
                             #:key provider process at when created fulfills
                                   note in-scope-of (classified-as '())
                                   counted unit stock-spec agreed?)
  "The `produce` a count lands whether or not it found the ledger off, so a
   count that agrees is still a count that ran: one record of the run's
   product, held nowhere, the counter's own act. BASE-ID is the count's
   adjustment id (the record's id is derived from it); RESOURCE-ID is the
   stock counted and STOCK-SPEC its spec, each named by a tag; COUNTED UNIT is
   the figure found and AGREED? whether the ledger read the same; FULFILLS the
   record commitment the plan laid, where it laid one."
  (make-economic-event
   #:id (count-record-id base-id) #:action 'produce #:output-of process                                 ; 3-4 input-of, output-of
                                      ; 5-6 a record, held nowhere
   #:resource-conforms-to spec #:resource-classified-as (append (list (count-of-tag resource-id))
                (if stock-spec (list (count-spec-tag stock-spec)) '())
                (if agreed? (list %count-agreed-tag) '())
                (or (figure-tags counted unit classified-as) '())) ; 7-8 conforms-to, classified-as
   #:provider provider #:receiver provider                          ; 9-10 the counter's own act
   #:resource-quantity (make-measure 1.0 %count-unit)               ; 11-12 resource-quantity, effort
 #:has-point-in-time when #:created created                         ; 13-16 beginning, end, point, created
   #:at-location at                                   ; 17-19 at-location, to-location, state
   #:fulfills fulfills                                ; 20-21 fulfills, satisfies
                                   ; 22-24 corrects, realization-of, settles
   #:note note #:in-scope-of in-scope-of                           ; 25-26
))                                 ; 27 previous-event
