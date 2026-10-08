;;; dev-ledger.scm — the development scope's books: what was taken, what was done.
;;;
;;; The scope is a real commune — `server/gateway.scm` registers
;;; "E_commune_devwork" under `earth` at boot, the same durable,
;;; one-persistence-graph path Berlin and the Bay Area communes take — so a
;;; booked hour is a REAL VF event, read by the SAME account.scm/skill-
;;; law.scm every other commune's work already reaches: `credit-balance`
;;; rises, `skill-hours-of`/`competence-fold` fold it in, `claim` and
;;; `request-payout` (already live) turn it into spendable money. Nothing
;;; here mints credit itself — landing the event through
;;; `(playnet planner scope live)`'s ordinary doors (`record-work-done`,
;;; `record-flow-done` — the same ones any commune's calendar and shop
;;; confirm work through) is the whole of it. `open-dev-ledger` remains a
;;; standalone scope-in-its-own-store, for a test or a private instance —
;;; the live tools reach the real commune instead, over the gateway's own
;;; REPL socket (`module/playnet/utils/repl-client.scm`).
;;;
;;;   commit-row!        a plan row taken: one work commitment per share of
;;;                      the row, on the scope's plan-store and registered
;;;                      with its observer. The plan's word, made a
;;;                      commitment by whoever takes the work — a HUMAN's:
;;;                      dispatching a coding session is not itself a
;;;                      committable act (see book-issue-done!'s own note).
;;;   book-issue-done!   an issue solved: each commitment standing for its act
;;;                      is fulfilled by a work event (record-work-done), and
;;;                      the deliverable is produced (record-flow-done).
;;;                      Where no commitment stands, the work event names who
;;;                      did it and the hours the issue states.
;;;
;;; Every id derives from the issue's, so a fact booked again is the fact
;;; already booked: the tools that call these run on a timer and keep no
;;; memory of their own.
;;;
;;; The hours booked are the hours the issue states: its `spent:` label where
;;; one stands, else its estimate, else its kind's. A commitment's share of
;;; the act is its share of those hours.
;;;
;;; VALIDATION: a commitment made first (commit-row!, itself sourced from
;;; the week's plan-matched intent) carries a real trust chain when later
;;; booked. Work reported after the fact with no prior commitment — a
;;; self-reported `spent:` claim — carries none, and lands through the SAME
;;; door every other self-reported work event in this codebase already
;;; falls through: the observer's own 7-day silence/contest rail
;;; (observer.scm %validation-window, governance/service.scm contest-work)
;;; — no new machinery. Radicle's own merge signature was investigated and
;;; is not this door: every merge is fast-forwarded and signed by ONE fixed
;;; delegate (deploy/scripts/promote.sh), never attributed to whoever
;;; actually did the work.
;;;
;;; box NEVER holds a commitment or a work event of its own (mimir.md's own
;;; precedent: an AI co-facilitator is a consumed resource, never labour).
;;; tools/dev-signal-cycle.scm never calls commit-row! for it — dispatching
;;; a coding session is not a committable, creditable act; a human's own
;;; merge is. book-issue-done! keeps one defensive check for the same
;;; invariant, on BOTH its paths — a commitment for an `(kind . agent)`
;;; person (a human running commit-row! by hand against the wrong id), and
;;; a `#:by` naming one (an assignee resolution that somehow answered
;;; "box") — either mints no event at all, rather than silently crediting
;;; a machine.

(define-module (playnet planner dev ledger)
  #:use-module (playnet planner scope root)
  #:use-module (playnet planner vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner vf schemas)
  #:use-module ((playnet planner scope live) #:select (make-work-event record-work-done record-flow-done))
  #:use-module (playnet planner dev recipes)
  #:use-module (playnet planner dev priorities)
  #:use-module ((playnet planner dev plan) #:select (row-ref))
  #:use-module (goblins)
  #:use-module (goblins persistence-store syrup)
  #:use-module (srfi srfi-1)
  #:export (open-dev-ledger
            commitment-id-for commit-row! issue-commitments
            done-event-id work-event-id commitment-event-id booked? book-issue-done!
            ledger-hours issue-done-hours))

(define %scope-name "playnet development")

(define (open-dev-ledger path)
  "The development scope, held in the store at PATH: restored where the
   store holds it, spawned where it does not. Returns (values vat scope)."
  (call-with-values
      (lambda ()
        (spawn-persistent-vat scope-root-env
                              (lambda () (spawn-scope-root %scope-name))
                              (make-syrup-store path)
                              #:name "dev-ledger"))
    (lambda (vat scope)
      ;; a restored scope's plan→observer callbacks are wired again on opening
      (with-vat vat (false-if-exception ($ scope 'rewire-callbacks)))
      (values vat scope))))

;; ── taking a row ─────────────────────────────────────────────────────────

(define (commitment-id-for oid agent)
  (string-append "commit|" (issue-spec-id oid) "|" agent))

(define* (commit-row! scope row #:key span (only #f))
  "ROW of the week's plan (dev-plan read-dev-plan), taken: a work commitment
   for each of its shares, or for ONLY's share alone when an agent is named.
   SPAN is the week (first-day . last-day). Returns the commitment ids; a
   share already committed keeps the commitment it has."
  (let ((ps  ($ scope 'plan-store))
        (oid (row-ref row 'oid)))
    (filter-map
     (lambda (share)
       (let* ((agent (car share))
              (cid   (commitment-id-for oid agent)))
         (and (or (not only) (equal? only agent))
              (begin
                (unless ($ ps 'get-commitment cid)
                  (let ((c (make-commitment
                            #:id cid #:action 'work #:note (row-ref row 'title)
                            #:input-of (dev-process-id oid)                 ; input-of, output-of
 #:resource-conforms-to (row-ref row 'skill)              ; inventoried-as, conforms-to, classified-as
 #:effort-quantity (make-measure (cdr share) "hours")   ; resource-quantity, effort-quantity
                            #:provider agent                                ; provider, receiver
                            #:has-beginning (and span (car span)) #:has-end (and span (cdr span))   ; has-beginning, has-end, point-in-time
                            #:due (and span (cdr span))                ; due, created
                            #:at-location %dev-place #:in-scope-of (list %scope-name)           ; at-location, in-scope-of
)))
                    ;; on the plan-store, where the scope keeps what it decided,
                    ;; and with the observer, which tracks its fulfilment
                    ($ ps 'add-commitment c)
                    ($ ($ scope 'observer) 'register-commitment c)))
                cid))))
     (row-ref row 'shares))))

(define (issue-commitments scope oid)
  "The commitments standing for issue OID's act, finished or open."
  ($ ($ scope 'plan-store) 'commitments-for-process (dev-process-id oid)))

;; ── booking an issue done ────────────────────────────────────────────────

(define (done-event-id oid) (string-append "ev-done|" (issue-spec-id oid)))
(define (work-event-id oid agent) (string-append "ev-work|" (issue-spec-id oid) "|" agent))
;; the id record-work-done itself derives from a commitment (its "ev-" + id) —
;; named here too, so book-issue-done! can guard each write before making it,
;; the same way it guards the deliverable
(define (commitment-event-id c) (string-append "ev-" (commitment-id c)))

(define (booked? scope oid)
  "Does the scope's observer hold issue OID's deliverable as produced?"
  (and ($ ($ scope 'observer) 'get-event (done-event-id oid)) #t))

(define (issue-done-hours facts)
  "The hours issue FACTS took: what it states as spent, else what it asks."
  (or (fact-ref facts 'spent) (issue-hours facts)))

(define (provider-aid people scope-local-id)
  "SCOPE-LOCAL-ID's real AID, per PEOPLE (docs/dev-scope.sexp's own
   shape) — SCOPE-LOCAL-ID itself when PEOPLE states none, or none
   matches, or the match states no `aid` yet: a person with no minted
   identity on record still books, under their scope-local name, rather
   than being refused or silently dropped. What `credit-balance`/
   `skill-hours-of` key on (account.scm) is whatever lands here — a real
   AID once one is known, the scope-local name until then."
  (or (person-lookup people 'id scope-local-id 'aid)
      scope-local-id))

(define* (book-issue-done! scope facts #:key (by #f) (when-iso #f) (people '()))
  "Issue FACTS is solved. Books, once:
     · a work event per commitment standing for its act (record-work-done),
       by the commitment's provider (resolved to their real AID through
       PEOPLE where one is stated — provider-aid), for that commitment's
       share of the hours the issue took — each fulfilling its
       commitment, which ends fulfilled;
     · where no commitment stands and BY names who did it, one work event
       by BY's own AID (same resolution) for the hours the issue took;
     · the produce event of the deliverable (record-flow-done).
   An `(kind . agent)` provider or BY — box — mints no work event on
   either path; the deliverable still lands. Returns the ids of the
   events this call recorded; '() when the issue was booked before."
  (let* ((oid   (fact-ref facts 'oid))
         (obs   ($ scope 'observer))
         (as    ($ scope 'agent-store))
         (pid   (dev-process-id oid))
         (spec  (issue-spec-id oid))
         (skill (issue-skill facts))
         (hours (issue-done-hours facts))
         (cs    (filter (lambda (c) (eq? 'work (commitment-action c)))
                        (issue-commitments scope oid)))
         (asked (fold (lambda (c a)
                        (+ a (measure-has-numerical-value (commitment-effort-quantity c))))
                      0.0 cs))
         (new   '()))
    (if (booked? scope oid)
        '()
        (begin
          (for-each
           (lambda (c)
             ;; the defensive check the header names: an (kind . agent)
             ;; provider (dev-people->world's own org* marker reads back as
             ;; agent-type 'organization) mints no event of its own — the
             ;; primary fix is upstream, box never holds this commitment at
             ;; all, so an id the agent-store does not know at all (unseeded,
             ;; or a real person) is read as a human, not silently dropped
             (let* ((who   ($ as 'get-agent (commitment-provider c)))
                    (agent? (and who (eq? 'organization (agent-type who)))))
               (unless (or agent? ($ obs 'get-event (commitment-event-id c)))
                 (let* ((part (measure-has-numerical-value (commitment-effort-quantity c)))
                        (h    (if (> asked 0.0) (* hours (/ part asked)) part)))
                   (record-work-done scope
                     `((id          . ,(commitment-id c))
                       (provider    . ,(provider-aid people (commitment-provider c)))
                       (effort      . ,h)
                       (input-of    . ,(commitment-input-of c))
                       (conforms-to . ,(commitment-resource-conforms-to c))
                       (at-location . ,(commitment-at-location c))
                       (when        . ,(commitment-has-beginning c))
                       (until       . ,(commitment-has-end c))
                       (in-scope-of . ,(commitment-in-scope-of c)))
                     #:when-iso when-iso))
                 (set! new (cons (commitment-event-id c) new)))))
           cs)
          (when (and (null? cs) by
                     (not (let ((who ($ as 'get-agent by))) (and who (eq? 'organization (agent-type who)))))
                     (not ($ obs 'get-event (work-event-id oid by))))
            ($ obs 'record-event
               (make-work-event
                ;; the id stays keyed by BY's stable scope-local name —
                ;; provider-aid's OWN answer can change the moment a real
                ;; AID becomes known, and an id that moved with it would
                ;; break the idempotence get-event above depends on
                #:id (work-event-id oid by) #:provider (provider-aid people by) #:receiver #f
                #:effort-qty hours #:fulfills #f
                #:input-of pid #:resource-spec skill
                #:at-location %dev-place
                #:in-scope-of (list %scope-name)
                #:timestamp when-iso #:created #f
                #:note "Issue solved"))
            (set! new (cons (work-event-id oid by) new)))
          ;; the deliverable: one unit of the issue's spec, made by its act.
          ;; MC names no real commitment — record-flow-done's own end-commitment
          ;; attempt fails closed on an unknown id and is swallowed there, the
          ;; same way it is for any produce event that fulfils nothing.
          (unless ($ obs 'get-event (done-event-id oid))
            (record-flow-done scope
              `((id          . ,(done-event-id oid))
                (action      . produce)
                (conforms-to . ,spec)
                (quantity    . 1)
                (at-location . ,%dev-place)
                (output-of   . ,pid)
                (note        . ,(fact-ref facts 'title)))
              #:event-id (done-event-id oid) #:when-iso when-iso)
            (set! new (cons (done-event-id oid) new)))
          (reverse new)))))

;; ── reading the books ────────────────────────────────────────────────────

(define (ledger-hours scope)
  "The work the scope's books hold, as ((agent skill hours) …): every work
   event's hours, summed by who worked and at what skill."
  (let ((acc (fold (lambda (e acc)
                      (if (eq? 'work (economic-event-action e))
                          (let* ((key (cons (economic-event-provider e)
                                            (economic-event-resource-conforms-to e)))
                                 (h   (let ((m (economic-event-effort-quantity e)))
                                        (if m (measure-has-numerical-value m) 0.0))))
                            (alist-cons key (+ h (or (assoc-ref acc key) 0.0))
                                        (alist-delete key acc)))
                          acc))
                    '() ($ ($ scope 'observer) 'all-events))))
    (map (lambda (p) (list (caar p) (cdar p) (cdr p)))
         (sort acc (lambda (a b) (string<? (format #f "~a~a" (caar a) (cdar a))
                                           (format #f "~a~a" (caar b) (cdar b))))))))
