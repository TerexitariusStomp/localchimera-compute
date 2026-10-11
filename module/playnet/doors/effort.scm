;;; module/playnet/doors/effort.scm — effort recorded against a commitment, and a container dropped: the two events a worker lands.
;;;
;;; A library the planner service's doors call (docs/planning/codebase-layout.md §12): a
;;; verb takes the scope root and the arguments; the door is the gate and one call.

(define-module (playnet doors effort)
  #:use-module ((goblins) #:select ($))
  #:use-module ((playnet doors counts) #:select (fresh-label))
  #:use-module ((playnet observation account) #:select (fulfillment-remaining))
  #:use-module ((playnet observation observer) #:select (target-passed?))
  #:use-module ((playnet observation states) #:select (fulfillment-state-finished))
  #:use-module ((playnet scope live) #:select (end-fulfilled!))
  #:use-module ((playnet utils clock) #:select (iso-now))
  #:use-module ((playnet utils envelope) #:select (catch-as-failure failure success))
  #:use-module ((playnet utils store-utils) #:select (generate-id))
  #:use-module ((playnet utils units) #:select (%count-unit %effort-unit hours-in time-unit?))
  #:use-module ((playnet vf formulas actions) #:select (relocating-action?))
  #:use-module ((playnet vf formulas flows) #:select (make-work-event))
  #:use-module ((playnet vf schemas) #:select (commitment-at-location commitment-effort-quantity commitment-finished commitment-has-beginning commitment-has-end commitment-id commitment-in-scope-of commitment-input-of commitment-provider commitment-resource-conforms-to economic-resource-conforms-to economic-resource-current-location economic-resource-onhand-quantity make-economic-event make-economic-resource make-measure measure-has-numerical-value measure-qty resource-spec-keep-in-place?))
  #:export (finite-positive? effort-remaining do-record-effort %container-resource? do-drop-event))

;; The hours a member records are the ledger's "number up": a finite positive
;; quantity of time (counted in hours), stated by the commitment's own provider, for no more
;; than the commitment still holds. The door states these because it is where
;; the member's word becomes a work event.
(define (finite-positive? x) (and (real? x) (finite? x) (> x 0)))
(define (effort-remaining obs cmt)
  "Hours CMT still holds: its committed effort less what the observer has
   counted as fulfilling it; +inf.0 when the commitment states no effort."
  (let ((fs  ($ obs 'get-fulfillment (commitment-id cmt)))
        (eff (commitment-effort-quantity cmt)))
    (cond (fs  (max 0 (fulfillment-remaining fs)))
          (eff (measure-has-numerical-value eff))
          (else +inf.0))))
(define (do-record-effort scope-root cid provider qty unit)
  "Build a 'work <economic-event> and feed it to the observer.
   The commitment named in 'fulfills' reads this event as fulfilment."
  (let* ((ps  ($ scope-root 'plan-store))
         (obs ($ scope-root 'observer))
         (cmt ($ ps 'get-commitment cid))
         ;; what the member states, counted in hours
         (hours (and (finite-positive? qty) (time-unit? unit) (hours-in qty unit))))
    (cond
      ((not cmt) (failure "commitment not found"))
      ((not (finite-positive? qty)) (failure "hours are a finite positive number"))
      ((not (time-unit? unit)) (failure "effort is recorded in a unit of time"))
      ((and (commitment-provider cmt) (not (equal? (commitment-provider cmt) provider)))
       (failure "hours are recorded by the commitment's own provider"))
      ((commitment-finished cmt) (failure "the commitment is finished"))
      ((target-passed? hours (effort-remaining obs cmt))
       (failure (format #f "the commitment holds ~a hours; ~a recorded"
                        (effort-remaining obs cmt) hours)))
      (else
       (catch-as-failure
         (lambda ()
           (let* ((eid (generate-id "evt-"))
                  (evt (make-work-event
                         #:id eid
                         #:provider provider
                         #:effort-qty hours
                         #:effort-unit %effort-unit
                         #:fulfills cid
                         #:input-of (commitment-input-of cmt)
                         #:resource-spec (commitment-resource-conforms-to cmt)
                         ;; the commitment's own terms ride on the event: the fold
                         ;; of hours by part reads events alone (live.scm make-work-event)
                         #:at-location (commitment-at-location cmt)
                         #:has-beginning (commitment-has-beginning cmt)
                         #:has-end (commitment-has-end cmt)
                         #:in-scope-of (commitment-in-scope-of cmt))))
             ($ obs 'record-event evt)
             ;; the commitment ends fulfilled when its hours are all in, so a
             ;; finished block neither takes more hours nor reads as expired
             (let ((fs ($ obs 'get-fulfillment cid)))
               (when (and fs (fulfillment-state-finished fs))
                 (end-fulfilled! scope-root cid)))
             (success eid))))))))

;;; ── The captain's log observes (write path) ──────────────────────────
;;;
;;; A spoken log entry names things that HAPPENED — hours worked, a meal
;;; cooked, stock found or lost — and this turns one such narration into an
;;; EconomicEvent on the scope's observer. The door is deliberately narrow:
;;; the event is SELF-scoped (provider = receiver = the speaker), so nothing
;;; recorded here moves rights or custody between agents, and the action set
;;; is the observational half of the VF table. Only produce/raise mint a
;;; resource (auto-created as the speaker's own, in the event's unit); a
;;; consume/use/lower with no resource named records the fact alone — the
;;; ledger keeps the observation, indexed by agent/action/spec, and stock
;;; reconciliation stays with the paths that know which stock (drop-event,
;;; claim, record-effort).


;;; ── Leaving a thing somewhere, and taking it away (write path) ───────
;;;
;;; The two acts a shared container affords, and they are the VF pair the
;;; ActionDefinition table already names — so this records an EconomicEvent and
;;; lets the observer do the rest. `dropoff` increments what is on hand at the
;;; container's place and hands custody to the container; `pickup` decrements it
;;; and hands custody back to the taker. Both leave `primary-accountable`
;;; untouched, which is the whole difference between leaving a thing somewhere
;;; and giving it away: the person who left it still owns it and may come back.
;;;
;;; No new state, and no policy: the swap etiquette a shared box lives by ("leave
;;; one to take one") is the map face's, not the ledger's. What is enforced here
;;; is only what the ledger can know — you cannot take what is not there, and you
;;; cannot leave a thing in something that is not a container.

(define (%container-resource? root r)
  "True iff R's spec keeps what is in it in place — the flag that makes a
   container a container (and makes `recipe-hold` tile through time)."
  (let* ((spec-id (and r (economic-resource-conforms-to r)))
         (s (and spec-id ($ ($ root 'recipe-store) 'get-resource-spec spec-id))))
    (and s (resource-spec-keep-in-place? s) #t)))

(define* (do-drop-event root action container-id agent spec qty
                        #:key (unit %count-unit) (resource-id #f) (note #f)
                              (name #f) (accountable #f) (scope #f))
  "Record ACTION ('dropoff | 'pickup) of QTY of SPEC at CONTAINER-ID by AGENT.
   RESOURCE-ID names the thing moved. On a pickup it must already exist; on a
   dropoff, naming something the scope already holds MOVES that thing — its
   rights, its rail, its history all untouched — and naming nothing introduces
   one.

   ACCOUNTABLE is who holds the rights to a thing being INTRODUCED, and it is a
   declaration. Left out, the thing enters the books as the COMMONS' — the scope
   whose container it is — on the communal rail.

   That default is a position, not a technicality. A public drop point is a
   common thing; what somebody puts in it, claiming nothing, joins the commons
   rather than becoming the property of whoever last touched it. The alternative
   defaults are both worse: owned by the leaver mints private property out of
   the act of putting something down, and owned by nobody leaves a thing in the
   books that no rule can speak about. The claim is always available — say who
   holds the rights and they hold them — so this takes nothing that was not
   given.

   Returns the resource id touched."
  (let* ((obs   ($ root 'observer))
         (cont  ($ obs 'get-resource container-id))
         (place (and cont (economic-resource-current-location cont))))
    (cond
     ((not cont) (failure "no such container"))
     ((not (%container-resource? root cont)) (failure "not a container"))
     ((not (relocating-action? action)) (failure "not a leave or a take"))
     ((not (and (number? qty) (> qty 0))) (failure "quantity must be positive"))
     (else
      (catch-as-failure
       (lambda ()
         (let* ((eid (generate-id "evt-"))
                (rid (or resource-id (string-append container-id "/" eid)))
                (have (let ((r ($ obs 'get-resource rid)))
                        (and r (measure-qty (economic-resource-onhand-quantity r)))))
                (taking? (eq? action 'pickup)))
           (cond
            ((and taking? (not have)) (failure "nothing of that here"))
            ((and taking? (< have qty)) (failure "not that much here"))
            (else
             ;; Leaving something the books have never seen introduces it: an
             ;; empty identity — a name, a kind, a place — and the rights over
             ;; it, DECLARED or common by default. The event below is what puts
             ;; the quantity in it and hands the box custody. (The observer would
             ;; auto-create it too, but as the RECEIVER's — and the receiver of a
             ;; dropoff is the box, which would make every box the owner of
             ;; everything left in it.)
             (unless have
               ($ obs 'record-resource
                  (make-economic-resource
                   #:id rid #:name (or name note spec) #:tracking-identifier (fresh-label obs) #:conforms-to spec #:classified-as '()
                   #:accounting-quantity (make-measure 0.0 unit) #:onhand-quantity (make-measure 0.0 unit)
                   #:current-location place
                   #:primary-accountable (or accountable scope)             ; claimed, else the commons'
                   ;; unclaimed ⇒ it is on the commons rail, which is what being
                   ;; the commons' property means for everything downstream
                   #:distribution-mode (and (not accountable) 'communal))))
             ;; the CUSTODY act: quantity in or out, and who holds it after.
             ;;
             ;; Custody passes to the SCOPE, not to the box. `custodian-scope`
             ;; is a Scope id (schemas.scm) and a box is an EconomicResource;
             ;; putting the box there would say a thing is held by a thing, and
             ;; would make a commune's own loaf in a commune's own box read as
             ;; held under somebody else's rights (`resource-rented?`) — the
             ;; federation counting a shelf as a dependency. Which BOX it is in
             ;; is the containment event below, which is what `contained-in` is
             ;; for. So: the commons holds what is in its boxes, and taking
             ;; something out is what moves custody to you.
             ($ obs 'record-event
                (make-economic-event
                 #:id eid #:action action
                 #:resource-inventoried-as rid                              ; 5-6 the thing moved
                 #:resource-conforms-to spec                             ; 7-8 conforms-to, classified-as
                 #:provider (if taking? scope agent)            ; 9  provider
                 #:receiver (if taking? agent scope)            ; 10 receiver
                 #:resource-quantity (make-measure (exact->inexact qty) unit) #:has-point-in-time (iso-now) #:created (iso-now)           ; 13-16
                 #:at-location place #:to-location (and (not taking?) place)     ; 17-18 at-location, to-location
                   ; 19-24
                 #:note (or note "") #:in-scope-of (list scope)           ; 25-26 note, in-scope-of (a list, as VF has it)
))                          ; 27-29
             ;; …and the CONTAINMENT act: it is now inside the box, or out of it.
             ;; A take that leaves some behind does NOT empty the box — what is
             ;; left is still in there — so the separate waits for the last of it.
             ;;
             ;; Two events because they are two facts, and they come apart: a
             ;; socialized stash has the commune's custody while it sits in the
             ;; same box under the same bridge. Custody says who may hold it;
             ;; `contained-in` says what it is physically inside. `combine` and
             ;; `separate` are the schema's own pair for the second — the same
             ;; pair transport.scm uses to put a rider inside a car for the trip.
             ;;
             ;; Their quantity is ZERO on purpose: combining normally consumes an
             ;; input into a composite (onhand decrement) and separating yields
             ;; one back. Nothing is consumed or yielded by putting a loaf in a
             ;; box, so the only effect asked for here is the containment one.
             (when (or (not taking?) (<= (- have qty) 0))
              ($ obs 'record-event
                (make-economic-event
                 #:id (string-append eid (if taking? "-out" "-in"))
                 #:action (if taking? 'separate 'combine)
                 #:resource-inventoried-as rid #:to-resource-inventoried-as (and (not taking?) container-id)  ; 5-6 the thing, the box
                 #:resource-conforms-to spec
                 #:provider (if taking? scope agent)
                 #:receiver (if taking? agent scope)
                 #:resource-quantity (make-measure 0.0 unit)            ; 11-12 containment only
 #:has-point-in-time (iso-now) #:created (iso-now)
                 #:at-location place #:to-location place
                 #:note "" #:in-scope-of scope)))
             (success rid))))))))))