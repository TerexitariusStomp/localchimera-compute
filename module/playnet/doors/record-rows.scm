;;; doors/record-rows.scm — a ValueFlows record as the page's row.
;;;
;;; The snapshot's record arms — commitments, intents, proposals, events — are
;;; lists of records; each leaves the planner written by the table here over its
;;; record type (wire/rows.scm). A field the page reads under its own name is a
;;; field symbol, checked against the record as the table is made; what the row
;;; joins — a specification's name, a process's name, who holds a skill, the
;;; plan's pull on a shift, how much of a commitment is recorded — is a computed
;;; entry reading the reply's context, the scope's stores looked up once
;;; (`record-context`, carried with the reply by `with-context`).
;;;
;;; The grid clock: a record sits on the dial's day grid by its date and, only
;;; where it STATED a beginning, by its hours; an absent clock stays absent and
;;; the dial renders the row undated-in-its-day, never at a fabricated hour.

(define-module (playnet doors record-rows)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf formulas flows)
  #:use-module ((playnet doors slots) #:select (window->arcs))
  #:use-module ((playnet doors counts) #:select (count-process-name))
  #:use-module ((playnet observation states) #:select (fulfillment-state-total-fulfilled))
  #:use-module ((playnet utils clock) #:select (instant->civil instant->unix window-close-epoch (now . clock-now)))
  #:use-module (playnet vf beyond schedules)
  #:use-module ((playnet vf facts availability) #:select (dated-week? dated-week-week dated-week-dated))
  #:use-module ((playnet knowledge recipes store) #:select (recipe-deliverable))
  #:use-module ((playnet knowledge catalogues substances) #:select (conservation-reading boundary-process? balance-flows))
  #:use-module ((playnet solve recipe-response) #:select (response-margin curve-reach capture-at standing-position))
  #:use-module ((playnet vf formulas shocks) #:select (%stress-band))
  #:use-module (playnet wire rows)
  #:export (payout->alist record-context agent-skills
            planner-time->date-string planner-time->hour-min numeric-string? iso-date-from-epoch
            lookup-spec-name lookup-process-name intent-cell
            %commitment-wire %intent-wire %event-wire %proposal-wire
            %member-wire %plan-ref-wire %payout-wire %recipe-wire %recipe-response-wire))

;;; ── the planner's times, read for the grid ──────────────────────────────

(define (iso-date-from-epoch secs)
  "Render an instant as a YYYY-MM-DD civil UTC string."
  (and secs (instant->civil secs "%Y-%m-%d")))

(define (numeric-string? s)
  "True if S is a string of digits (optionally with a leading minus)."
  (and (string? s)
       (> (string-length s) 0)
       (let loop ((i (if (char=? (string-ref s 0) #\-) 1 0)))
         (cond
           ((>= i (string-length s)) #t)
           ((not (char-numeric? (string-ref s i))) #f)
           (else (loop (+ i 1)))))))

(define (planner-time->date-string s)
  "The planner stores has-beginning/has-end/due as either ISO datetime
   strings or as (number->string epoch-secs). Detect and convert to
   YYYY-MM-DD; return #f on failure."
  (cond
    ((not (string? s)) #f)
    ((numeric-string? s)
     (let ((n (string->number s)))
       (and n (iso-date-from-epoch n))))
    ((>= (string-length s) 10) (substring s 0 10))
    (else #f)))

(define (planner-time->hour-min s default-hour)
  "Pull (hour . minute) out of a planner time string. Handles both
   epoch-string and ISO formats. Falls back to (DEFAULT-HOUR . 0)."
  (cond
    ((not (string? s)) (cons default-hour 0))
    ((numeric-string? s)
     (let ((n (string->number s)))
       (if n
           (let ((day (modulo (instant->unix n) 86400)))   ; UTC, by arithmetic: a page has no gmtime
             (cons (quotient day 3600) (quotient (modulo day 3600) 60)))
           (cons default-hour 0))))
    ((>= (string-length s) 16)
     (let ((h (string->number (substring s 11 13)))
           (m (string->number (substring s 14 16))))
       (cons (or h default-hour) (or m 0))))
    (else (cons default-hour 0))))

(define* (grid-clock begin end #:key (or-date #f) (default-hour 9) (span 1))
  "Where a record sits on the day grid. Its DATE is its beginning's day, else
   OR-DATE's, else today; it is CLOCKED only where it stated a beginning, at
   that hour (DEFAULT-HOUR where the beginning names a day alone); a stated
   END closes it, else SPAN hours on. The end's own day rides as END-DATE."
  (let* ((date (or (planner-time->date-string begin)
                   (planner-time->date-string or-date)
                   (iso-date-from-epoch (clock-now))))
         (clocked? (and (planner-time->date-string begin) #t))
         (start (planner-time->hour-min begin default-hour))
         (sh (car start)) (sm (cdr start))
         (end-date (planner-time->date-string end))
         (close (and end-date (planner-time->hour-min end sh))))
    `((date . ,date) (clocked . ,clocked?) (end-date . ,end-date)
      (sh . ,sh) (sm . ,sm)
      (eh . ,(if close (car close) (min 23 (+ sh span))))
      (em . ,(if close (cdr close) sm)))))

;; the four clock entries of a table, reading its CLOCK-OF (rec ctx) → grid
;; clock; a key the clock leaves unclocked is left out of the row
(define (clock-entries clock-of)
  (map (lambda (key)
         (list (symbol->string key)
               (lambda (rec ctx) (let ((c (clock-of rec ctx))) (and (alist-ref c 'clocked) (alist-ref c key))))
               '(omit-false int)))
       '(sh sm eh em)))
(define (clock-field clock-of key) (lambda (rec ctx) (alist-ref (clock-of rec ctx) key)))

;;; ── the reply's context: the scope's stores, looked up once ─────────────

(define* (record-context scope-id rs as obs ps preg
                         #:key (holders (make-hash-table)) (willing (make-hash-table)) (pulls '())
                               (member-ids '()) (responses '()) (material '()) (places #f))
  "What the record rows join through: the scope and its stores, the skill
   holders (spec → agent ids), the willing race ((spec . cell) → ((aid . status) …)),
   the standing solve's labour pulls ((skill@place@period . λ) …), the scope's
   member ids in their order (a member's colour is its place in it), the
   recipes' standing (scope-standing's records, one per recipe) and the scope's
   places (its spatial-thing-store, a place's name). A context carries what it
   has: a row reads a name through a store it names, and "" through one it lacks."
  `((scope-id . ,scope-id) (rs . ,rs) (as . ,as) (obs . ,obs) (ps . ,ps) (preg . ,preg)
    (holders . ,holders) (willing . ,willing) (pulls . ,pulls)
    (member-ids . ,member-ids) (responses . ,responses) (now . ,(instant->unix (clock-now)))
    ;; the standing plan's material rows: a pickup's destination is its dropoff's place
    (material . ,material)
    (places . ,places)))

(define (ctx-ref ctx key) (alist-ref ctx key))
(define (of key) (lambda (rec ctx) (ctx-ref ctx key)))

(define (lookup-process-name preg rs process-id)
  "PROCESS-ID may be a recipe-process id (e.g. 'rp-meeting') OR a
   dynamically-generated process id from dependent-demand (e.g. 'dd-…').
   Try the process registry first (where dependent-demand registers its
   created processes), then fall back to the recipe-store, then the id."
  (and process-id
       (let ((p (and preg ($ preg 'get process-id))))
         (cond
           (p (or (process-name p) process-id))
           (else
            (let ((rp (and rs ($ rs 'get-recipe-process process-id))))
              (if rp (or (recipe-process-name rp) process-id) process-id)))))))

(define (lookup-spec-name rs spec-id)
  (and spec-id
       (let ((s (and rs ($ rs 'get-resource-spec spec-id))))
         (if s (or (resource-specification-name s) spec-id) spec-id))))

(define (agent-name-of ctx aid)
  (let* ((as (ctx-ref ctx 'as))
         (a (and aid as ($ as 'get-agent aid))))
    (and a (agent-name a))))
;; a place's name, through the scope's places; the id where the context has none
(define (place-name-of ctx id)
  (let* ((sts (and id (ctx-ref ctx 'places)))
         (s (and sts ($ sts 'get-location id))))
    (or (and s (spatial-thing-name s)) id "")))

(define (intent-cell loc) (string-append (or loc "") "@0"))

;;; ── a commitment, an intent ─────────────────────────────────────────────

;; the record's clock: its beginning, its end, its due day where it names no
;; beginning; its effort spans it where it states no end
(define (record-clock rec ctx)
  (grid-clock (row-when rec) (row-until rec)
              #:or-date (cond ((intent? rec) (intent-due rec)) ((commitment? rec) (commitment-due rec)) (else #f))
              #:default-hour 10
              #:span (max 1 (inexact->exact (ceiling (or (row-effort rec) 1))))))

;; a spec's classifications — the join onto the dial's taxonomy: the dial
;; scopes a work intent to the leaf being viewed
(define (categories rec ctx)
  (let* ((rs (ctx-ref ctx 'rs))
         (s (and rs (row-spec rec) ($ rs 'get-resource-spec (row-spec rec)))))
    (if s (or (resource-specification-resource-classified-as s) '()) '())))

;; the willingness overlay (the offer side: who could help, who has signalled):
;; each work intent carries the candidate set (scope members holding the skill)
;; and the willing race, by the cell location@0 the convex gate reads too
(define (candidates rec ctx)
  (let ((spec (row-spec rec)))
    (if spec (delete-duplicates (hash-ref (ctx-ref ctx 'holders) spec '())) '())))
(define (willing-race rec ctx)
  (let ((spec (row-spec rec)))
    (if spec (hash-ref (ctx-ref ctx 'willing) (cons spec (intent-cell (row-place rec))) '()) '())))
;; a hand lowered again, `declined`, is no hand
(define (hands-up rec ctx)
  (filter-map (lambda (ws) (and (not (eq? (cdr ws) 'declined)) (car ws))) (willing-race rec ctx)))

;; the plan's PULL on an open shift: λ(skill, place@period), the dual of the
;; located labour balance the shift was minted from. The shift's id carries
;; that very cell ("ni|proc|skill|place@period", persist-open-shifts!), so the
;; join is on the solve's own key: the dial orders one person's choices among
;; a shift's locations by what the plan GAINS from them there
(define (shift-pull rec ctx)
  (let ((parts (string-split (or (row-id rec) "") #\|)) (pulls (ctx-ref ctx 'pulls)))
    (and (pair? pulls) (= (length parts) 4) (string=? (car parts) "ni")
         (let ((lam (assoc-ref pulls (string-append (caddr parts) "@" (cadddr parts)))))
           (and (number? lam) lam)))))

;; an intent's suggested provider rides its plan-store meta
(define (suggested-provider rec ctx)
  (let ((ps (ctx-ref ctx 'ps)))
    (alist-ref (or (and ps ($ ps 'get-meta (row-id rec))) '()) 'suggested-provider)))

;; how much of a commitment the books already record
(define (fulfilled rec ctx)
  (let* ((obs (ctx-ref ctx 'obs))
         (fs (and obs ($ obs 'get-fulfillment (row-id rec)))))
    (if fs (or (measure->qty (fulfillment-state-total-fulfilled fs)) 0) 0)))

;; the row SAYS what it is, from its OWN terms — an intent awaits a yes; a
;; commitment is committed while its window is open, done once finished,
;; expired when the window wholly passed unworked — so no reader has to infer
;; standing from which list it rode, and last month's accepts stop painting as live
(define (commitment-status rec ctx)
  (cond ((row-finished rec) "done")
        ((let ((u (window-close-epoch (row-until rec))))
           (and u (> (ctx-ref ctx 'now) u))) "expired")
        (else "committed")))

(define (none rec ctx) #f)
(define (process-name-of rec ctx)
  (let ((obs (ctx-ref ctx 'obs)) (run (row-run rec)))
    (or (and obs run (count-process-name obs run))
        (and run (lookup-process-name (ctx-ref ctx 'preg) (ctx-ref ctx 'rs) run)) "")))
;; THE LABEL, composed once: a work row reads "process: skill" where both are
;; named, else whichever stands, else its spec id; a material row reads
;; "action spec" (a pickup of flour: "pickup Flour")
(define (row-label rec ctx)
  (let ((pn (process-name-of rec ctx)) (sn (spec-label rec ctx)) (a (row-action rec)))
    (if (eq? a 'work)
        (cond ((and (not (string-null? pn)) (not (string-null? sn))) (string-append pn ": " sn))
              ((not (string-null? pn)) pn)
              ((not (string-null? sn)) sn)
              (else (or (row-spec rec) "work")))
        (let ((what (if (string-null? sn) (or (row-spec rec) "") sn)))
          (cond ((string-null? what) (if a (symbol->string a) "event"))
                (a (string-append (symbol->string a) " " what))
                (else what))))))

;; THE VOCABULARY, stated once: the keys the dial's DayEvent reads, the suites
;; speak, and the page's types are generated from. A row says which arm of the
;; snapshot it rides, its source.
(define (record-entries intent-table?)
  `(("id" ,(lambda (rec ctx) (row-id rec)) str)
    ("label" ,row-label str)
    ,@(clock-entries record-clock)
    ;; the record's own instants, verbatim: the schedule's cell (a confirmation
    ;; names a row by its id, the coordinates serve a caller without one), and
    ;; the join onto what the act needs (act-requires: proc, place, when)
    ("when" ,(lambda (rec ctx) (row-when rec)) str)
    ("until" ,(lambda (rec ctx) (row-until rec)) str)
    ("scope" ,(of 'scope-id) str)
    ;; willingness keying: express-willingness binds (worker skill cell)
    ("spec" ,(lambda (rec ctx) (row-spec rec)) str)
    ("specName" ,spec-label str)
    ;; the process the row is a flow of: the one it is the output of, else an input of
    ("proc" ,(lambda (rec ctx) (or (row-run rec) "")) str) ("procName" ,process-name-of str)
    ("cell" ,(if intent-table? (lambda (rec ctx) (intent-cell (row-place rec))) none) str)
    ;; the candidate field (skill holders = eligible) and the willing race: the
    ;; dial reads `candidates` to find work it is ELIGIBLE for, and `willing`
    ;; for its own willing-state straight from the planner
    ("candidates" ,(if intent-table? candidates none) strs)
    ("willing" ,(if intent-table? hands-up none) strs)
    ;; the plan's word on the suggestion: matched | unmatched; a commitment is accepted
    ("suggested" ,(if intent-table? suggested-provider none) str)
    ("suggestedName" ,(if intent-table? (lambda (rec ctx) (agent-name-of ctx (suggested-provider rec ctx))) none) str)
    ("match" ,(if intent-table?
                  (lambda (rec ctx) (if (suggested-provider rec ctx) "matched" "unmatched"))
                  (lambda (rec ctx) "accepted"))
     str)
    ("provider" ,(if intent-table? none (lambda (rec ctx) (row-provider rec))) str)
    ("providerName" ,(if intent-table? none (lambda (rec ctx) (agent-name-of ctx (row-provider rec)))) str)
    ("status" ,(if intent-table? (lambda (rec ctx) "proposed") commitment-status) str)
    ;; the VF action and the receiver, verbatim — what lets a reader tell a WORK
    ;; intent (a door someone can take) from the scope's standing DEMAND (a
    ;; consume/use addressed to a receiver)
    ("action" ,(lambda (rec ctx) (row-action rec)) str) ("receiver" ,(lambda (rec ctx) (row-receiver rec)) str)
    ;; how much the record asks, and how much is already recorded — the record
    ;; verb defaults to the REMAINDER
    ("effort" ,(lambda (rec ctx) (or (row-effort rec) 1)) num)
    ("done" ,(if intent-table? (lambda (rec ctx) 0) fulfilled) num)
    ;; a material row's one number — its quantity, or a means occupied its hours — and its unit
    ("qty" ,(lambda (rec ctx) (or (row-figure rec) 0)) num)
    ("unit" ,(lambda (rec ctx) (row-unit rec)) opt-str)
    ("note" ,(lambda (rec ctx) (row-note rec)) str)
    ;; the plan's pull on an open shift; "" where no solve holds one
    ("pull" ,(if intent-table? shift-pull none) num)
    ;; where + what it serves: the at-location id (a map pin via the snapshot's
    ;; `locations`) and the spec's first classification (the leaf the dial scopes to)
    ("at" ,(lambda (rec ctx) (row-place rec)) str)
    ("placeName" ,(lambda (rec ctx) (place-name-of ctx (row-place rec))) str)
    ;; a pickup's destination: the place its dropoff lands it, and that place's name
    ("to" ,dropoff-place-of opt-str)
    ("toName" ,(lambda (rec ctx) (let ((p (dropoff-place-of rec ctx))) (if p (place-name-of ctx p) ""))) str)
    ("serves" ,(lambda (rec ctx) (let ((cs (categories rec ctx))) (and (pair? cs) (string? (car cs)) (car cs)))) str)
    ;; the full classifiedAs list — the dial derives its spine from these
    ("categories" ,categories strs)
    ;; the record's own calendar day (and its end's, when it crosses midnight)
    ("date" ,(clock-field record-clock 'date) str) ("endDate" ,(clock-field record-clock 'end-date) str)
    ;; the record's recurrence, in the same arcs wire the slots speak
    ("arcs" ,(lambda (rec ctx) (window->arcs (cond ((intent? rec) (intent-availability-window rec))
                                                   ((commitment? rec) (commitment-availability-window rec))
                                                   (else #f))))
     (rows arc))
    ("source" ,(lambda (rec ctx) (if intent-table? "intent" "commitment")) str)))

;; ── the schedule: the plan's own commitments at their space-time coordinates ──
;; The plan's schedule rides as the commitment-record rows themselves (the plan
;; table, wire/snapshot.scm): one vocabulary for a commitment wherever it is
;; read, the day's list and the schedule board alike. The readers below are the
;; record entries' joins.
(define (spec-label rec ctx)
  (let ((sp (row-spec rec)) (rs (ctx-ref ctx 'rs))) (or (and sp rs (lookup-spec-name rs sp)) sp "")))
(define (dropoff-place-of rec ctx)
  "Where a pickup's cargo lands: the dropoff of the same run and spec among the plan's
   material rows (the pair shares one run, a Process of its own)."
  (and (eq? (row-action rec) 'pickup)
       (let ((run (row-run rec)) (spec (row-spec rec)))
         (and=> (find (lambda (m) (and (eq? (row-action m) 'dropoff)
                                       (equal? (row-run m) run) (equal? (row-spec m) spec)))
                      (ctx-ref ctx 'material))
                row-place))))
;; ── what an act needs HERE: the engine's requirement rows as they are ──
;; keyed by the same (proc, place, when) its schedule rows carry: the engine's
;; `process` and `begin` are read under the names the schedule uses, so the join
;; a reader writes is equality on identically-named fields
(define %act-need-wire
  (wire-table 'act-need #f
    `(("kind" kind str) ("name" name str)
      ("label" ,(lambda (n ctx) (let ((nm (alist-ref n 'name)) (rs (ctx-ref ctx 'rs))) (or (and nm rs (lookup-spec-name rs nm)) nm ""))) str)
      ("qty" qty num) ("unit" unit opt-str)
      ;; held, missing, or the word the solve left (unknown: nobody checked)
      ("met" ,(lambda (x ctx) (let ((m (alist-ref x 'met))) (cond ((symbol? m) m) (m 'held) (else 'missing)))) str))))
(define %act-why-wire
  (wire-table 'act-why #f
    `(("reason" reason str)
      ("detail" detail (list str)))))
(define %act-requires-wire
  (wire-table 'act-requires #f
    `(("proc" process str) ("place" place str) ("when" begin str) ("until" until str)
      ("why" why (omit-false (row act-why)))
      ("needs" needs (rows act-need)))))

(define %commitment-wire (wire-table 'commitment-record <commitment> (record-entries #f)))
(define %intent-wire (wire-table 'intent-record <intent> (record-entries #t)))

;;; ── a lived event ───────────────────────────────────────────────────────
;; what happened, when, where — and where it went (`to`), so the map can draw
;; the journey between the ends. The name parts ride verbatim and the dial
;; composes the label: a work event reads by its skill, a material one by its
;; action and spec. The instant ladder is beginning ∥ point-in-time ∥ created,
;; the same preference event->custody-step reads by; an event is always clocked.

(define (event-clock e ctx)
  (grid-clock (or (economic-event-has-beginning e) (economic-event-has-point-in-time e) (economic-event-created e))
              (economic-event-has-end e)))
(define %event-wire
  (wire-table 'event <economic-event>
    `(("id" id str)
      ;; THE LABEL, composed once: what happened to what — a work event reads
      ;; by its skill, a material one by its action and spec ("harvest Garden greens")
      ("label" ,(lambda (e ctx)
                  (let ((what (or (lookup-spec-name (ctx-ref ctx 'rs) (economic-event-resource-conforms-to e))
                                  (economic-event-resource-conforms-to e) ""))
                        (a (economic-event-action e)))
                    (cond ((string-null? what) (if a (symbol->string a) "event"))
                          ((eq? a 'work) what)
                          (a (string-append (symbol->string a) " " what))
                          (else what))))
       str)
      ("specName" ,(lambda (e ctx) (or (lookup-spec-name (ctx-ref ctx 'rs) (economic-event-resource-conforms-to e)) "")) str)
      ("action" action str) ("spec" resource-conforms-to str)
      ("from" ,(lambda (e ctx) (let ((p (economic-event-provider e))) (or (agent-name-of ctx p) p ""))) str)
      ("scope" ,(of 'scope-id) str) ("at" at-location str) ("to" to-location str)
      ("date" ,(clock-field event-clock 'date) str) ("endDate" ,(clock-field event-clock 'end-date) str)
      ,@(map (lambda (key) (list (symbol->string key) (clock-field event-clock key) 'int)) '(sh sm eh em)))))

;;; ── a directed proposal ─────────────────────────────────────────────────
;; Two kinds ride this record: a SOCIAL INVITE (a person proposed an event to
;; you), routed to acceptInvite, and a DIRECTED WORK OFFER (offers.scm
;; offer-work turned a solve suggestion into an offer), routed to
;; acceptWorkOffer, which carries its work terms (spec, proc) so the dial's
;; offer card has a planner key and same-time offers group into one picker. VF
;; purpose 'offer covers both; the discriminator is offer-work's own id grammar:
;; the bounded rung publishes its intent as offer:<agent>:<proc>@<when>.

(define (published-intent p ctx)
  (let ((pubs (or (proposal-publishes p) '())))
    (and (pair? pubs) ($ (ctx-ref ctx 'ps) 'get-intent (car pubs)))))
(define (offer? p ctx)
  (let ((pubs (or (proposal-publishes p) '())))
    (and (pair? pubs) (string? (car pubs)) (string-prefix? "offer:" (car pubs)) (published-intent p ctx) #t)))
(define (proposal-clock p ctx)
  (let ((it (published-intent p ctx)))
    (grid-clock (and it (intent-has-beginning it)) (and it (intent-has-end it)))))
(define (offered read)
  (lambda (p ctx) (and (offer? p ctx) (let ((v (read (published-intent p ctx)))) (and (string? v) (not (string=? v "")) v)))))
(define %proposal-wire
  (wire-table 'proposal <proposal>
    `(("label" ,(lambda (p ctx) (or (proposal-name p) (let ((it (published-intent p ctx))) (and it (intent-name it))) "event")) str)
      ("id" id str) ("vfId" id str)
      ("from" ,(lambda (p ctx)
                 (let* ((it (published-intent p ctx)) (prov (and it (intent-provider it))))
                   (or (agent-name-of ctx prov) prov (if (offer? p ctx) "the plan" "someone"))))
       str)
      ("kind" ,(lambda (p ctx) (if (offer? p ctx) "work" "free")) str)
      ("status" ,(lambda (p ctx) "proposed") str)
      ("social" ,(lambda (p ctx) (not (offer? p ctx))) bool)
      ("offer" ,offer? (omit-false bool))
      ("spec" ,(offered (lambda (it) (or (intent-resource-conforms-to it) (intent-input-of it)))) (omit-false str))
      ("proc" ,(offered intent-input-of) (omit-false str))
      ("scope" ,(of 'scope-id) str)
      ,@(clock-entries proposal-clock)
      ("date" ,(clock-field proposal-clock 'date) str)
      ;; the published intent's venue — an invite pins like any other event
      ("at" ,(lambda (p ctx) (let ((it (published-intent p ctx))) (and it (intent-at-location it)))) str))))

;;; ── the scope itself: a member, a plan, a payout ────────────────────────

;; an availability window as the page's rows: a dated week is its week's day
;; schedules and then one row per exception (a withdrawn day: dates with no ranges)
(define (availability-rows aw)
  (cond ((not aw) '())
        ((dated-week? aw) (append (availability-rows (dated-week-week aw)) (or (dated-week-dated aw) '())))
        (else (or (availability-window-day-schedules aw) '()))))

(define %time-range-wire
  (wire-table 'time-range <time-range> '(("start" start-time str) ("end" end-time str))))
;; a row is a day schedule (its days) or an exception (its dates), and the ranges it offers
(define %availability-day-wire
  (wire-table 'availability-day #f
    `(("days" ,(lambda (r ctx) (and (day-schedule? r) (or (day-schedule-days r) '()))) (omit-false (list str)))
      ("dates" ,(lambda (r ctx) (and (specific-date-window? r) (or (specific-date-window-specific-dates r) '())))
       (omit-false (list str)))
      ("timeRanges" ,(lambda (r ctx) (or (if (day-schedule? r) (day-schedule-time-ranges r) (specific-date-window-time-ranges r)) '()))
       (rows time-range)))))

(define (agent-skills obs agent-id)
  "Skill spec-ids held by AGENT-ID (resources where accountable=agent)."
  (if (not obs) '()
      (filter-map
       (lambda (r)
         (and (equal? (economic-resource-primary-accountable r) agent-id)
              (> (measure-has-numerical-value (economic-resource-onhand-quantity r)) 0)
              (economic-resource-conforms-to r)))
       ($ obs 'all-resources))))

(define %member-palette
  (vector "#63b3ed" "#f6ad55" "#b794f4" "#4fd1c5" "#f687b3"
          "#7ee8a2" "#fc8181" "#d6bcfa" "#90cdf4" "#fbd38d"))
(define (member-color a ctx)
  (let ((at (list-index (lambda (id) (equal? id (agent-id a))) (ctx-ref ctx 'member-ids))))
    (vector-ref %member-palette (modulo (or at 0) (vector-length %member-palette)))))

(define %member-wire
  (wire-table 'member <agent>
    `(("id" id str)
      ("name" ,(lambda (a ctx) (or (agent-name a) (agent-id a))) str)
      ("color" ,member-color str)
      ("visible" ,(lambda (a ctx) #t) bool)
      ("availability" ,(lambda (a ctx) (availability-rows (agent-availability-window a))) (some-rows availability-day))
      ("skills" ,(lambda (a ctx) (agent-skills (ctx-ref ctx 'obs) (agent-id a))) (list str)))))

(define %plan-ref-wire
  (wire-table 'plan-ref <plan>
    `(("id" id str) ("name" ,(lambda (p ctx) (or (plan-name p) (plan-id p))) str))))

;; a payout is an intent: the member's ask to be paid in XMR, its address on the
;; at-location (as "xmr:ADDRESS"), its state read off the records — the ctx
;; carries `payout-of`, (intent) → the row's word and began
;; (economy/payouts.scm payout-row-context, handed in by the door so this
;; table, which the page's scope bundle carries, imports no payout law)
(define (payout-context i ctx)
  (let ((f (and ctx (ctx-ref ctx 'payout-of)))) (if f (f i) '())))
(define %payout-wire
  (wire-table 'payout <intent>
    `(("id" id str) ("aid" provider str)
      ("address" ,(lambda (i ctx) (let ((r (intent-at-location i)))
                                    (if (and (string? r) (string-prefix? "xmr:" r)) (substring r 4) r)))
       str)
      ("xmr" ,(lambda (i ctx) (measure-has-numerical-value (intent-resource-quantity i))) num)
      ("due" due str) ("note" note str)
      ;; where it stands, and when the coins started moving
      ("began" ,(lambda (i ctx) (or (assq-ref (payout-context i ctx) 'began) (intent-has-beginning i))) str)
      ("state" ,(lambda (i ctx) (or (assq-ref (payout-context i ctx) 'word) "pending")) str))))
;; one open debt the commons carries to a member (economy/debts.scm debt->alist):
;; what it owes back for a purchase fronted, once accepted; the face amount never
;; changes, `remaining` is what is still open after part-payments
(define %debt-wire
  (wire-table 'debt #f
    '(("id" id str) ("aid" aid str) ("spec" spec str) ("amount" amount num) ("unit" unit str)
      ("remaining" remaining num) ("due" due str) ("since" since str))))
;; what my-payouts answers: the hours available to draw, every standing payout,
;; and every open debt
(reply-table 'my-payouts
  '(("available" available num) ("payouts" payouts (rows payout)) ("owed" owed (rows debt))))

;;; ── a recipe ────────────────────────────────────────────────────────────
;; What a recipe is (the recipe-store's) and how it has stood (the scope's
;; standing as its solve takes it, economy/recipe-standing.scm scope-standing:
;; one record per recipe, the ctx's `responses`). The face and the solve read the
;; one record:
;;   standing  "experimental" while every run was calm, "observed" once some
;;             flow has a run under stress, "" for a recipe never run here
;;   profile   one entry per channel
;;   yield     what it delivers of what the weather live now allows, in
;;             [0, 1]; 1 where it has no record
;;   margin    where it stands among the recipes for its output, by reach
;;             (solve/recipe-response.scm response-margin): "bounded" where another
;;             has met heavier stress, "bare" where none has been pressed,
;;             "" for the furthest-reaching and where no standing was read

(define (flows-of rp ctx) ($ (ctx-ref ctx 'rs) 'flows-for-process (recipe-process-id rp)))

(define %recipe-flow-wire
  (wire-table 'recipe-flow <recipe-flow>
    `(("spec" ,(lambda (f ctx) (recipe-flow-resource-conforms-to f)) str)
      ("name" ,(lambda (f ctx) (let ((spec (recipe-flow-resource-conforms-to f)))
                                 (or (and spec (lookup-spec-name (ctx-ref ctx 'rs) spec)) spec "")))
       str)
      ("q" ,(lambda (f ctx) (or (measure->qty (flow-measure f)) 1)) num)
      ("u" ,(lambda (f ctx) (or (measure->unit (flow-measure f)) "")) str)
      ("action" action str)
      ("primary" is-primary bool))))
(define (flow-measure f) (or (recipe-flow-resource-quantity f) (recipe-flow-effort-quantity f)))

(define %recipe-step-wire
  (wire-table 'recipe-step <recipe-process>
    `(("id" id str)
      ("name" ,(lambda (rp ctx) (or (recipe-process-name rp) (recipe-process-id rp))) str)
      ("hours" ,(lambda (rp ctx) (let ((dur (recipe-process-has-duration rp)))
                                   (if dur (or (duration-has-numerical-value dur) 0) 0)))
       num)
      ;; its classification (VF processClassifiedAs): the folksonomy terms the face
      ;; cuts by, and "hole" on a process known by its boundary alone
      ("tags" process-classified-as strs)
      ;; its balance over the tracked elements: closed, open (the rift at this
      ;; step), or "" untracked
      ("balance" ,(lambda (rp ctx)
                    (let* ((flows (flows-of rp ctx))
                           (fs (balance-flows (append (car flows) (cdr flows)) #:basis? #f)))
                      (conservation-reading fs #:boundary? (boundary-process? fs))))
       str)
      ("in" ,(lambda (rp ctx) (car (flows-of rp ctx))) (rows recipe-flow))
      ("out" ,(lambda (rp ctx) (cdr (flows-of rp ctx))) (rows recipe-flow)))))

;; one reading of a curve: (stress . capture); a claim an event fulfilled:
;; (action spec intended realized); a run behind a curve: (when stress capture claims)
(define %curve-point-wire
  (wire-table 'curve-point #f `(("s" ,(lambda (p ctx) (car p)) num) ("c" ,(lambda (p ctx) (cdr p)) num))))
(define %claim-wire
  (wire-table 'claim #f
    `(("action" ,(lambda (t ctx) (car t)) str) ("spec" ,(lambda (t ctx) (cadr t)) str)
      ("intended" ,(lambda (t ctx) (caddr t)) num) ("realized" ,(lambda (t ctx) (cadddr t)) num))))
(define %channel-point-wire
  (wire-table 'channel-point #f
    `(("when" ,(lambda (r ctx) (car r)) str) ("s" ,(lambda (r ctx) (cadr r)) num)
      ("c" ,(lambda (r ctx) (caddr r)) num)
      ("claims" ,(lambda (r ctx) (cadddr r)) (rows claim)))))     ; the observer log this point's capture came from
;; the three stress levels the word was read off; 0 where a level is absent
(define (level key) (lambda (b ctx) (or (alist-ref b key) 0)))
(define %bend-wire
  (wire-table 'bend #f
    `(("kind" kind str) ("gap" ,(level 'gap) num) ("from" ,(level 'from) num)
      ("at" ,(level 'at) num) ("to" ,(level 'to) num))))

(define (channel-runs runs channel)
  "RUNS' rows for one CHANNEL — the observer log a reader traces the curve back
   to: every (day capture stresses tuples) row filed under it, as (day stress
   capture tuples)."
  (filter-map (lambda (run)
                (let ((s (assoc-ref (caddr run) channel)))
                  (and s (list (car run) s (cadr run) (cadddr run)))))
              runs))
(define (curve-of row) (or (alist-ref row 'curve) '()))
(define (licensed-of row) (or (alist-ref row 'licensed) '()))
(define (licensed-level key) (lambda (row ctx) (or (alist-ref (licensed-of row) key) 0)))

;; ONE channel of a recipe's response (solve/recipe-response.scm's row, with the
;; recipe's `recipe-runs` beside it), read off the scope's own production runs,
;; never declared. A channel is one of the recipe's own flows, wired "action · spec".
;; CURVE is what the plan reads: one reading per stress level observed. REACH is
;; the heaviest stress the curve has a run under: what the record is proven to.
;; BEYOND is what the curve reads at the end of the stress band. WORD describes the
;; curve's bend and BEND names the three stress levels it was read off (kind "" where
;; none bend); the solve reads neither. CONFIDENT says whether a witnessed regime
;; claim licenses the fitted ACCEL ± SE; the numbers are 0 where it does not.
;; POINTS come from the recipe's runs, each carrying WHEN it happened and the raw
;; CLAIMS behind its capture.
(define %recipe-channel-wire
  (wire-table 'recipe-channel #f
    `(("channel" ,(lambda (row ctx)
                    (let ((c (alist-ref row 'channel)))
                      (if (pair? c) (format #f "~a · ~a" (car c) (cdr c)) (format #f "~a" c))))
       str)
      ("word" word str) ("n" n num)
      ("curve" ,(lambda (row ctx) (curve-of row)) (rows curve-point))   ; one reading per stress level observed
      ("reach" ,(lambda (row ctx) (curve-reach (alist-ref row 'curve))) num)
      ("beyond" ,(lambda (row ctx) (or (capture-at (curve-of row) %stress-band) 0)) num)
      ("bend" ,(lambda (row ctx) (or (alist-ref row 'bend) '())) (row bend))
      ("confident" ,(lambda (row ctx) (pair? (licensed-of row))) bool)
      ("accel" ,(licensed-level 'accel) num) ("se" ,(licensed-level 'se) num)
      ("points" ,(lambda (row ctx) (channel-runs (alist-ref row 'recipe-runs) (alist-ref row 'channel)))
       (rows channel-point)))))

;; a recipe's standing, read off its record OWN: the entries both the recipe's row
;; and the standalone response row (a fixture is written by the very reading the
;; wire takes, tools/emit/recipe-demo-emit.scm) state
(define (response-entries own-of)
  (let ((runs (lambda (own) (or (and own (alist-ref own 'runs)) '())))
        (rows (lambda (own) (or (and own (alist-ref own 'rows)) '()))))
    `(("standing" ,(lambda (r ctx) (let ((own (own-of r ctx)))
                                     (if (pair? (runs own)) (symbol->string (standing-position (rows own))) "")))
       str)
      ("profile" ,(lambda (r ctx) (let ((own (own-of r ctx)))
                                    (map (lambda (row) (acons 'recipe-runs (runs own) row)) (rows own))))
       (rows recipe-channel))
      ("yield" ,(lambda (r ctx) (or (let ((own (own-of r ctx))) (and own (alist-ref own 'yield))) 1)) num)
      ("margin" ,(lambda (r ctx) (let* ((own (own-of r ctx))
                                        (m (and own (response-margin own (ctx-ref ctx 'responses)))))
                                   (if m (symbol->string m) "")))
       str))))

(define (own-response r ctx)
  (find (lambda (o) (equal? (recipe-id r) (alist-ref o 'id))) (ctx-ref ctx 'responses)))

(define %recipe-response-wire
  (wire-table 'recipe-response #f (response-entries (lambda (own ctx) own))))

(define %recipe-wire
  (wire-table 'recipe <recipe>
    `(("id" id str)
      ("name" ,(lambda (r ctx) (or (recipe-name r) (recipe-id r))) str)
      ("produces" ,(lambda (r ctx) (or (recipe-deliverable (ctx-ref ctx 'rs) r) "")) str)
      ("steps" ,(lambda (r ctx)
                  (sort ($ (ctx-ref ctx 'rs) 'processes-for-recipe (recipe-id r))
                        (lambda (a b) (< (or (recipe-process-sequence-group a) 0)
                                         (or (recipe-process-sequence-group b) 0)))))
       (rows recipe-step))
      ,@(response-entries own-response))))

(define* (payout->alist i #:optional (context #f))
  "A payout intent as the plain alist its readers (the runner, the member's list) hold:
   the payout table's row, read back; CONTEXT carries `payout-of`, the reader of
   its word and its began (economy/payouts.scm payout-row-context)."
  (wire->plain (wire-row* %payout-wire i context)))
