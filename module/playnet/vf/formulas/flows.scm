;;; vf/formulas/flows.scm — a planned flow, read.
;;;
;;; What a plan lays down is ValueFlows: an Intent (an open need or an offer) or a
;;; Commitment (a flow somebody is held to). The two carry the same properties of a
;;; flow (its action, its specification, its quantity or effort, the process it
;;; stands on a side of, its place, when it begins), so everything that reads a
;;; plan's rows asks through the readers here and need not know which of the two it
;;; holds: `(row-action r)`, `(row-quantity r)`, `(row-place r)`.
;;;
;;; A quantity and an effort are read as their number, with `row-unit` for the unit
;;; the quantity is counted in, since the solve and the doors' tallies work in
;;; numbers of the specification's unit.
;;;
;;; A row is also read off the alist a plan held before its rows were records (a
;;; plan stored by an earlier build, docs/planning/codebase-organization.md §7): the
;;; same readers take it, so a stored plan reads as it did.

(define-module (playnet vf formulas flows)
  #:use-module ((playnet utils units) #:select (%effort-unit))
  #:use-module (playnet vf schemas)
  #:use-module ((playnet utils keyed-id) #:select (keyed-id))
  #:use-module ((playnet utils records) #:select (vf-record-accessor))
  #:use-module ((playnet vf formulas actions) #:select (input-action? output-action? occupying-actions))
  #:use-module ((playnet utils clock) #:select (now instant->civil))
  #:export (row-id row-action row-spec row-quantity row-unit row-effort
            row-provider row-input-of row-output-of row-run row-place
            row-when row-until row-note row-tags row-scope row-satisfies
            row-finished row-ambient? carried-lot-id %ambient-tag
            row-scopes row-satisfies? scopes-of row-figure
            committed-by-spec committed-quantity
            make-work-intent make-work-commitment make-work-event make-flow-commitment))

(define %ambient-tag "ambient")   ; resourceClassifiedAs of a flow with no stock behind it: the world's own, a means in use

(define (number-of m) (and m (measure-has-numerical-value m)))

;; one reader per property: of a Commitment, of an Intent, of a stored alist row.
;; A reader names the FIELD once; the commitment and intent accessors are read
;; off the two types, so a field the schema renames fails here at load.
(define-syntax-rule (define-row-reader name field key)
  (define name
    (let ((of-commitment (vf-record-accessor <commitment> 'field))
          (of-intent     (vf-record-accessor <intent> 'field)))
      (lambda (r)
        (cond ((commitment? r) (of-commitment r))
              ((intent? r) (of-intent r))
              (else (let ((p (and (pair? r) (assq 'key r)))) (and p (cdr p)))))))))

(define-row-reader row-id        id                     id)
(define-row-reader row-spec      resource-conforms-to   conforms-to)
(define-row-reader row-provider  provider               provider)
(define-row-reader row-input-of  input-of               input-of)
(define-row-reader row-output-of output-of              output-of)
(define-row-reader row-place     at-location            at-location)
(define-row-reader row-when      has-beginning          when)
(define-row-reader row-until     has-end                until)
(define-row-reader row-note      note                   note)
(define-row-reader row-tags      resource-classified-as classified-as)
(define-row-reader row-scope     in-scope-of            in-scope-of)
(define-row-reader row-satisfies satisfies              satisfies)
(define-row-reader row-finished  finished               finished)
(define-row-reader %action       action                 action)
(define-row-reader %quantity     resource-quantity      quantity)
(define-row-reader %effort       effort-quantity        effort)
(define-row-reader %unit         resource-quantity      unit)

(define (row-action r)
  "R's action, a symbol."
  (let ((a (%action r))) (if (string? a) (string->symbol a) a)))
(define (row-quantity r)
  "How much of its specification R moves, as a number; #f where it states none."
  (let ((q (%quantity r))) (if (measure? q) (number-of q) q)))
(define (row-unit r)
  "The unit R's quantity is counted in."
  (let ((u (%unit r))) (if (measure? u) (measure-has-unit u) u)))
(define (row-effort r)
  "The hours of effort R takes, as a number; #f where it states none."
  (let ((e (%effort r))) (if (measure? e) (number-of e) e)))

(define (row-figure r)
  "The one number R states: its quantity of its spec, or, for a means occupied, its hours."
  (or (row-quantity r) (row-effort r)))

(define (row-run r)
  "The process R is a flow of: the one it is the output of, else the one it is an input of."
  (or (row-output-of r) (row-input-of r)))
(define (row-ambient? r)
  "No stock stands behind R: the world's own, or a means in use."
  (and (member %ambient-tag (or (row-tags r) '())) #t))
(define (carried-lot-id r)
  "The lot of its own a run's cargo is on the way: one per run and spec, the same for
   the pickup that fills it and the dropoff that empties it."
  (keyed-id "carry" (row-run r) (row-spec r)))

;; ── the list-valued fields, read as lists whatever a row wrote ──────────────
;; VF's inScopeOf and satisfies are lists. Rows written before 2026-10-09 may
;; carry one id bare; every reader takes either through these two.
(define (scopes-of x)
  "X as the list inScopeOf is: a list as it stands, one id as a list of one, nothing as none."
  (cond ((not x) '()) ((pair? x) x) ((null? x) '()) (else (list x))))
(define (row-scopes r)
  "The scopes R stands in, as a list."
  (scopes-of (row-scope r)))
(define (row-satisfies? r id)
  "Does R satisfy ID: among what it satisfies (a list), or the one id an earlier row wrote."
  (let ((s (row-satisfies r)))
    (and id (cond ((pair? s) (and (member id s) #t))
                  (else (equal? s id))))))

;; ── the ONE constructor of a work Intent ────────────────────────────────────
;; A need for hours (a process's side: INPUT-OF the process, no provider) or an
;; offer of them (PROVIDER's, OFFERED? putting the same hours in availableQuantity):
;; `work`, the skill as resourceConformsTo, the hours as effortQuantity.
(define* (make-work-intent #:key id name provider skill hours (unit %effort-unit) input-of
                                 (offered? #f) at-location has-beginning has-end
                                 (has-point-in-time has-beginning) planned-within)
  (make-intent #:id id #:action 'work #:name name #:input-of input-of #:resource-conforms-to skill
               #:effort-quantity (make-measure hours unit)
               #:available-quantity (and offered? (make-measure hours unit))
               #:provider provider
               #:has-beginning has-beginning #:has-end has-end #:has-point-in-time has-point-in-time
               #:at-location at-location #:planned-within planned-within))

;; ── the ONE constructor of a work Commitment ────────────────────────────────
;; Every solve and door that commits hours builds the row here: `work`, the skill
;; as resourceConformsTo, the hours as effortQuantity, the scope as a list.
(define* (make-work-commitment #:key id provider skill hours (unit %effort-unit) input-of
                                     at-location has-beginning has-end
                                     (has-point-in-time has-beginning) due
                                     in-scope-of satisfies planned-within independent-demand-of
                                     availability-window note)
  (make-commitment #:id id #:action 'work #:input-of input-of #:resource-conforms-to skill
                   #:effort-quantity (make-measure hours unit) #:provider provider
                   #:has-beginning has-beginning #:has-end has-end #:has-point-in-time has-point-in-time #:due due
                   #:at-location at-location #:in-scope-of (let ((l (scopes-of in-scope-of))) (and (pair? l) l))
                   #:satisfies satisfies #:planned-within planned-within #:independent-demand-of independent-demand-of
                   #:availability-window availability-window #:note note))

;; ── the ONE constructor of a 'work event ─────────────────────────────────────
;; Every door that records effort against a commitment builds its event here,
;; and the event carries the commitment's own TERMS — the place, the window it
;; was placed in, the scope of the solve that placed it — so that the fold of
;; hours by part (observer `hours-by`, keyed by `event-terms`) reads events
;; alone, the terms survive any later change to the plan-store, and an hour
;; logged late is dated by the window it was worked in, which a windowed part
;; ("nights") needs (docs/planning/voice/voice-follows-work.md, step 0).
;; FULFILLS links the event to its commitment and nothing else: the observer
;; enforces fulfills ⊕ satisfies, the intent's satisfaction is the commitment's
;; edge, and an event claiming both would count the same quantity twice — a
;; caller states one or the other.
(define* (make-work-event #:key id provider effort-qty (effort-unit %effort-unit)
                                fulfills satisfies input-of resource-spec
                                at-location has-beginning has-end in-scope-of
                                (receiver provider)
                                (note "Effort recorded from calendar")
                                (timestamp (instant->civil (now)))
                                (created timestamp))
  (make-economic-event
    #:id id                                 ; 1 id (auto-generated if #f)
    #:action 'work                              ; 2 action
    #:input-of input-of                        ; 3-4 input-of, output-of
                              ; 5-6 (to-)resource-inventoried-as
    #:resource-conforms-to resource-spec                   ; 7-8 resource-conforms-to, classified-as
    #:provider provider #:receiver receiver                  ; 9-10 provider, receiver
                                 ; 11 resource-quantity
    #:effort-quantity (make-measure effort-qty effort-unit) ; 12 effort-quantity
    #:has-beginning has-beginning #:has-end has-end #:has-point-in-time timestamp #:created created ; 13-16 has-beginning, -end, -point-in-time, created
    #:at-location at-location                  ; 17-19 at-location, to-location, state
    #:fulfills fulfills #:satisfies satisfies   ; 20-21 fulfills, satisfies
                        ; 22-24 corrects, realization-of, settles
    #:note note                               ; 25 note
    #:in-scope-of (let ((l (scopes-of in-scope-of))) (and (pair? l) l))))   ; 26-27 in-scope-of, prev-event

;; ── the ONE constructor of a material Commitment ────────────────────────────
;; The solve's rows (engine plan->material), a row the scope holds back
;; (scope/live held-commitment) and the test books' rows are all built here:
;; the action's side gives input-of / output-of (the table's io column), the
;; figure rides as resource-quantity in UNIT — or, for a means OCCUPIED (a `use`),
;; as HOURS in effort-quantity, the field VF gives a use's duration — and a row
;; with no stock behind it (an ambient draw, a means occupied) carries the ambient tag.
(define* (make-flow-commitment #:key id action spec qty unit hours process place
                                     has-beginning has-end (has-point-in-time has-beginning)
                                     (ambient? #f) tags note in-scope-of)
  (make-commitment #:id id #:action action
                   #:input-of (and (input-action? action) process)
                   #:output-of (and (output-action? action) process)
                   #:resource-conforms-to spec
                   #:resource-classified-as (or tags (and (or ambient? (memq action occupying-actions)) (list %ambient-tag)))
                   #:resource-quantity (and qty (make-measure qty unit))
                   #:effort-quantity (and hours (make-measure hours %effort-unit))
                   #:has-beginning has-beginning #:has-end has-end #:has-point-in-time has-point-in-time
                   #:at-location place #:note note
                   #:in-scope-of (let ((l (scopes-of in-scope-of))) (and (pair? l) l))))

;; ── the one tally of what rows commit per specification ─────────────────────
(define (committed-by-spec commitments actions)
  "What the COMMITMENTS whose action is in ACTIONS commit of each specification,
   ((spec . quantity) …) in the order the specifications are first met: with
   `creating-actions` what a plan newly makes, with `using-up-actions` what it
   uses up. A row is a commitment, an intent or a stored plan row, read by the
   flow readers. The one tally every reading of a plan's material is written with."
  (let ((sum (make-hash-table)) (order '()))
    (for-each (lambda (c)
                (let ((spec (row-spec c)) (q (row-quantity c)))
                  (when (and spec q (memq (row-action c) actions))
                    (unless (hash-ref sum spec) (set! order (cons spec order)))
                    (hash-set! sum spec (+ q (hash-ref sum spec 0.0))))))
              commitments)
    (map (lambda (spec) (cons spec (hash-ref sum spec))) (reverse order))))
(define (committed-quantity commitments spec actions)
  "How much of SPEC the COMMITMENTS whose action is in ACTIONS commit, as a number;
   0.0 where they commit none of it."
  (or (assoc-ref (committed-by-spec commitments actions) spec) 0.0))
