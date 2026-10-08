;;; federation.scm
;;;
;;; ^calendar-view — capability-based shim for cross-org calendar sharing.
;;;
;;; The capability-based alternative to CalDAV for playnet ↔ playnet:
;;; Org A spawns this actor with a reference to its planner-service +
;;; the scope-id to expose. Org A's binding table publishes the actor
;;; ref at "public:calendar". Org B, holding the scope ref, calls
;;; ($ org-a-calendar 'events-in-range from-date to-date) and gets a
;;; list of event alists rendered with Org A's events on Org B's grid.
;;;
;;; No URLs, no shared secrets, no polling — the capability reference
;;; IS the subscription; revocation is just dropping the ref.
;;;
;;; Read-only by design. Mutations on remote scope go through the full
;;; ^planner-service path (with its scope-membership checks).
;;;
;;; TODO before this is ever actually published at "public:calendar":
;;; facet-wrap it to exactly info/events-in-range/events-as-vcalendar.
;;; Registering the raw ^calendar-view ref would hand any sturdyref
;;; holder every method ever added to this actor later, not just the
;;; three read-only ones documented today.
;;;
;;; Stateless: holds only the planner-service ref and display name
;;; passed at spawn time — no portrait needed.
;;;
;;; Spawn:
;;;   (define ^view-ref
;;;     (spawn ^calendar-view planner-service "org:meeting" "Meeting Commune"))

(define-module (playnet calendar federation)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet wire rows) #:select (wire->plain))
  #:use-module ((playnet calendar ical) #:select (events->vcalendar))
  #:export (^calendar-view))

(define (^calendar-view bcom planner-service scope-id display-name)

  (define (snapshot-events)
    "Pull events from planner-service via its public method.
Returns a list of event alists; filters out dateless intents."
    ;; $, not <-: planner-service is near (Org A's own vat, per this
    ;; module's docstring — Org B's calls land on ^calendar-view itself,
    ;; never on planner-service directly). <- always returns a promise
    ;; for both near and remote targets; treating it as an immediate
    ;; value here (as this did before) made (pair? snap) permanently #f
    ;; and every query silently empty, with no error — confirmed by
    ;; tracing syscaller-<-/syscaller-$ in goblins/core.scm.
    ;; plan-id = #f is deliberate, not a placeholder: build-snapshot
    ;; (doors/service.scm:1831) treats it as "no plan filter" — the
    ;; scope's whole intent/commitment set, which is what a cross-org
    ;; feed wants.
    (let* ((snap ($ planner-service 'scope-snapshot scope-id #f))
           ;; the snapshot's arms are the page's rows: vectors of string-keyed records
           ;; the snapshot's arms are the page's rows; the feed reads each record as
           ;; the alist event->ical takes
           (arm (lambda (k) (wire->plain (or (and (pair? snap) (assoc-ref snap k)) '()))))
           (intents     (arm "intents"))
           (commitments (arm "commitments"))
           (datable? (lambda (e)
                       (let ((d (assoc-ref e 'date)))
                         (and d (string? d) (>= (string-length d) 10))))))
      (filter datable? (append commitments intents))))

  (define (date-in-range? evt from to)
    (let ((d (assoc-ref evt 'date)))
      (and d
           (or (not from) (string>=? d from))
           (or (not to)   (string<=? d to)))))

  (methods
   ;; Display metadata. Useful so the calling org can name the feed.
   [(info)
    `((kind        . calendar-view)
      (scope-id    . ,scope-id)
      (name        . ,display-name)
      (read-only   . #t))]

   ;; All events in [FROM, TO] inclusive (YYYY-MM-DD; both can be #f).
   ;; Returns a list of event alists in the standard browser-projection
   ;; shape — same data the local UI consumes, so cross-org views
   ;; render with zero special-casing.
   [(events-in-range from to)
    (filter (lambda (e) (date-in-range? e from to))
            (snapshot-events))]

   ;; VCALENDAR body for [FROM, TO], same shape used by Layer 2 webcal.
   ;; Useful when a remote org wants to publish the federated feed as
   ;; its own /cal/<remote>.ics — saves a translation step.
   [(events-as-vcalendar from to)
    (events->vcalendar
     (filter (lambda (e) (date-in-range? e from to))
             (snapshot-events))
     #:name display-name)]))
