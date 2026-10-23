;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; log-observe.scm — an observation a person makes of their own doing.
;;;
;;; "I worked two hours on the pump", "I picked twelve kilos of apples": a
;;; captain's-log entry lands as a self-scoped EconomicEvent on the scope's
;;; observer. This is the door's whole body over a scope root, so the planner
;;; service on a gateway and a scope held in a page (page-scope.scm) record an
;;; observation alike.

(define-module (playnet observation log-observe)
  #:use-module ((playnet utils units) #:select (%count-unit %effort-unit))
  #:use-module (goblins)
  #:use-module (playnet vf schemas)
  #:use-module ((playnet utils envelope) #:select (success failure catch-as-failure))
  #:use-module ((playnet utils store-utils) #:select (generate-id))
  #:use-module ((playnet utils clock) #:select (iso-now))
  #:use-module ((playnet vf formulas flows) #:select (make-work-event))
  #:use-module ((playnet observation landing) #:select (land-once))
  #:export (%log-actions do-log-observe))

(define %log-actions
  '(("work" . work) ("produce" . produce) ("consume" . consume)
    ("use" . use) ("raise" . raise) ("lower" . lower)))

(define* (do-log-observe root scope-id agent action-name spec qty unit
                         #:key (note #f) (when-iso #f))
  "Record a self-scoped ACTION-NAME of QTY UNIT of SPEC by AGENT, narrated
   by a captain's-log entry. Returns the event id (and the resource id when
   the action minted one)."
  (let ((action (assoc-ref %log-actions action-name)))
    (cond
     ((not action) (failure "not an observable action"))
     ((not (and (number? qty) (> qty 0))) (failure "quantity must be positive"))
     ((not (and (string? spec) (not (string-null? spec)))) (failure "no resource named"))
     (else
      (catch-as-failure
       (lambda ()
         (let* ((obs ($ root 'observer))
                ;; an observation is of its instant: stated at one, it is named by
                ;; who observed, what, when and how much, so it is the same event
                ;; however often it lands (the observer's log is a set keyed by id)
                (eid (if (and (string? when-iso) (not (string-null? when-iso)))
                         (string-append "evt-log-" agent "-" action-name "-" spec "-" when-iso
                                        "-" (number->string (exact->inexact qty)))
                         (generate-id "evt-log-")))
                (m   (make-measure (exact->inexact qty)
                                   (if (and (string? unit) (not (string-null? unit)))
                                       unit
                                       (if (eq? action 'work) %effort-unit %count-unit))))
                ;; only the creating actions mint a resource: the observer
                ;; auto-creates it as the RECEIVER's — the speaker's own
                (rid (and (memq action '(produce raise))   ; verb-meant: the two acts a spoken log makes a resource by
                          (string-append "log/" eid))))
           ;; stated at an instant, the entry is named by what it says, and the books answer
           ;; a repeat (a device flushing its queue) with the entry that stands, whatever
           ;; note or clock the repeat carried; unstated, it has no name to repeat under
           (land-once obs (and (string? when-iso) (not (string-null? when-iso)) eid)
             (lambda (_) (success `((event . ,eid) (resource . ,(or rid "")) (again . #t))))
             (lambda ()
           ($ obs 'record-event
              (if (eq? action 'work)
                  ;; labour has its one constructor (vf/formulas/flows)
                  (make-work-event
                   #:id eid #:resource-spec spec #:provider agent #:receiver agent
                   #:effort-qty (measure-has-numerical-value m) #:effort-unit (measure-has-unit m)
                   #:timestamp (or when-iso (iso-now)) #:created (iso-now)
                   #:note (or note "captain's log") #:in-scope-of (list scope-id))
              (make-economic-event
               #:id eid #:action action
               #:resource-inventoried-as rid                              ; 5-6 the thing, when minted
               #:resource-conforms-to spec                             ; 7-8 conforms-to, classified-as
               #:provider agent #:receiver agent                         ; 9-10 self-scoped
               #:resource-quantity m                                   ; 11 resource-quantity
                               ; 12-14 effort-quantity, has-beginning, has-end
               #:has-point-in-time (or when-iso (iso-now)) #:created (iso-now)   ; 15-16 point-in-time, created
             ; 17-24
               #:note (or note "captain's log") #:in-scope-of (list scope-id)  ; 25-26 note, in-scope-of
)))                          ; 27-29
           (success `((event . ,eid) (resource . ,(or rid "")))))))))))))
