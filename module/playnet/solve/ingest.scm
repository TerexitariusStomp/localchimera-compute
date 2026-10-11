;;; module/playnet/solve/ingest.scm — the observer ingest: records become the world's tables.
;;;
;;; The engine (solve/engine) builds a program from the world (solve/world);
;;; this module fills the world from a scope's records. `ingest-located!`
;;; derives the partition the records tile (the clock, the spans, the
;;; stretches a wall-clock key covers), declares the world through the
;;; engine's one door, `declare-world!`, and lays onto it what the records
;;; say: each holding as a stock at its place (`ingest-stock!`, the stock key
;;; naming which lot of the plan it is), the means that move
;;; (`means->movers!`), the arc table (`ingest-travel-times!`), each person's
;;; hours from their availability window. The reproduction bands enter here
;;; too (`apply-repro-bands!`, the one pour), and a fragility routes to the
;;; table whose collector reads its scale (`route-fragility!`, the grid as one
;;; dispatch). What is written onto a standing world afterwards goes through a
;;; named layering door, and tests/solve/test-world-door.scm reads this file
;;; beside the engine to hold that.

(define-module (playnet solve ingest)
  #:use-module (playnet solve world)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module ((playnet utils units) #:select (convert-unit/strict unit-known? unit->substance convert-unit unit-rate? unit-rate-parts unit-factor %placeholder-unit %count-unit %effort-unit))
  #:use-module ((playnet utils clock) #:select (hhmm->minutes minutes->hhmm clock-length-minutes clock-overlap-minutes clock-ranges-minutes civil->instant instant->civil instant->weekday now timescale instant->unix unix->instant iso->epoch))
  #:use-module ((playnet vf facts availability) #:select (dated-week? dated-week-week dated-week-overrides))
  #:use-module ((playnet vf facts agent-time) #:select (agent-schedulable-window agent-disposable-hours agent-away-dates away-count))
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf beyond schedules)
  #:use-module (playnet vf facts located)
  #:use-module (playnet vf formulas periods)   ; what a period is in wall-clock time
  #:use-module (playnet vf facts boundary)   ; the flows nothing makes
  #:use-module (playnet vf formulas fragility)   ; a limit as a record: one form for every scale
  #:use-module (playnet solve compile)
  #:use-module (playnet vf formulas capacity)
  #:use-module (playnet knowledge worlds bioregions)
  #:use-module (playnet solve engine)
  #:export (*default-agent-hours* nepair? window->day-schedules ranges-minutes window-ranges-on window-hours
            agent-window-hours period-time-range temporal-clock-boundaries declared-clock-boundaries stamp-time refine-span
            owned-spec unowned-demand resolve-date-keys refine-spans declared-partition coarse->fine
            dates-through specific-window-hours-within offer-expression? temporal-hours-within dated-week-hours-within window-hours-within
            resource-window-hours %containment-max-depth resource-place resource-resolver used-spec-set *refused-stock*
            refused-stock refuse-stock! named-good-set person-set stock-vocabulary make-stock-key
            ingest-stock! means->movers! adopt-container-pools! ingest-located! ingest-travel-times! period-disposable-hours
            apply-repro-bands! repro-bands route-fragility!))

;; ════════════════════════════════════════════════════════════════════════════
;; §6b — OBSERVER INGEST: real EconomicResource / Agent / SpatialThing → the model
;; ════════════════════════════════════════════════════════════════════════════
;; The seam from observation/observer.scm (the live event-sourced stockbook) into
;; the located program above. The observer holds STATE (what *is* — stock drawn
;; down by consume/produce/move events); the planner is POLICY (what *should* be).
;; This wires the first into the second so the engine plans over the REAL stock
;; instead of the demo setup-* tables. It is the inverse of the demos: there a
;; human declares *init*/*A*/*latlon*; here they are READ OFF the records.
;;
;;   located stock  ← EconomicResource.onhand-quantity @ (contained-in | current-location)
;;   labour / cell  ← Agent.primary-location  (aggregate hours; EMP refines who-works-which)
;;   coordinates    ← SpatialThing.lat / .long
;;
;; Quantity choice (VF resources.md): a resource carries TWO current quantities —
;; *accounting* (rights/ownership, irrespective of custody) and *onhand* (custody/
;; physical possession, irrespective of rights). The plan allocates PHYSICAL
;; production, so feasibility runs on ONHAND — what can actually be consumed here
;; now. (accounting is the ledger of who owns it; reservable infrastructure passes
;; live-resource's `available` instead — reservation-aware free capacity.)
;; Records in, globals populated. The caller bridges the Goblins actor, e.g.
;;   (ingest-located! ($ observer 'all-resources) agents spatial-things …)
(define *default-agent-hours* 8.0)

;; ── availabilityWindow → hours per period (input conformance) ────────────────
;; VF (actions.md:20): an agent's schedule "kept on a calendar" says WHEN they are
;; available to work. The lattice period is abstract, so a period→days map
;; (*period-days*, default the whole week) ties it to the schedule; the hours an
;; agent offers in a period = the schedule's time-range minutes on those days.
;; Reimplemented compactly here rather than importing matching/availability (which
;; is module-scoped while the planner is primitive-load — same reason the spatial
;; math is local); it's the same window-flatten (month>week>day>ranges priority).
;; ── period ↔ wall-clock ───────────────────────────────────────────────────────
;; What a period is on the clock (its span, its weekdays, its stated length, the
;; horizons that lay it) is periods.scm; reset! below clears its two tables.
(define (nepair? x) (and (pair? x)))

(define (window->day-schedules w)           ; flatten <availability-window> to day-schedules (VF priority)
  (cond ((dated-week? w) (window->day-schedules (dated-week-week w)))   ; every recurring reader sees the week; the exceptions are read only where a date is met
        ((not (availability-window? w)) '())
        ((nepair? (availability-window-month-schedules w))
         (append-map (lambda (ms)
           (cond ((nepair? (month-schedule-week-schedules ms)) (append-map week-schedule-day-schedules (month-schedule-week-schedules ms)))
                 ((nepair? (month-schedule-day-schedules ms)) (month-schedule-day-schedules ms))
                 ((nepair? (month-schedule-time-ranges ms)) (list (make-day-schedule *all-days* (month-schedule-time-ranges ms))))
                 (else '())))
           (availability-window-month-schedules w)))
        ((nepair? (availability-window-week-schedules w)) (append-map week-schedule-day-schedules (availability-window-week-schedules w)))
        ((nepair? (availability-window-day-schedules w)) (availability-window-day-schedules w))
        ((nepair? (availability-window-time-ranges w)) (list (make-day-schedule *all-days* (availability-window-time-ranges w))))
        (else '())))

;; Ranges that overlap are one stretch of the day: a person who states 09-13 and
;; 11-15 offers 09-15, however many schedules name it. The solve and the roster
;; (matching/availability.scm) take the union through the same clock reading.
(define (ranges-minutes trs ptr)           ; the minutes <time-range>s TRS cover together, inside period extent PTR when given
  (clock-ranges-minutes (map (lambda (tr) (cons (time-range-start-time tr) (time-range-end-time tr))) trs)
                        (and ptr (cons (time-range-start-time ptr) (time-range-end-time ptr)))))

(define (window-ranges-on w days)          ; the ranges of every schedule of W that names one of DAYS
  (append-map day-schedule-time-ranges
              (filter (lambda (ds) (any (lambda (d) (memq d days)) (day-schedule-days ds)))
                      (window->day-schedules w))))

(define (window-hours w days)               ; hours the window offers on a day-set: each day's stated ranges, once
  (/ (fold (lambda (d acc) (+ acc (ranges-minutes (window-ranges-on w (list d)) #f)))
           0 (delete-duplicates days))
     60.0))

(define (agent-window-hours a t)            ; conformant agent-hours: read the agent's availabilityWindow
  "Hours agent A offers in period T. The TWIN of `resource-window-hours`, and it
   has to be: a worker's availability and a machine's are ONE declaration
   (playnet.typ §Worker, soil, and tool: one field), so they are read the same way
   or a plan matches hours that never meet.

   A period carrying clock boundaries is INTERSECTED with the window, exactly as a
   means' is. Summing the window's minutes over the period's weekdays instead
   counts a shift in every period of the day it touches — measured: a declared
   06:00–10:00 came back as four hours in each of five refined periods, twenty-four
   in total, from a four-hour shift. That inflation grows with the partition, which
   is the wrong direction for the whole point of refining it: a declared boundary
   is supposed to put those hours in the period that holds them and none in its
   neighbours (docs/planning/solve/intra-period-time.md).

   A period spanning whole dates is unchanged — `window-hours-within` falls back to
   the weekday sum there, which was already exact.

   Every period has a span: declare-world! lays the standing partition for a
   world that declares none. A window met by a period with no place on the
   clock is refused rather than guessed — the weekday sum there was a week's
   worth in a one-day period (09:00–10:30 every day read as 10.5 h)."
  ;; no declaration: a working day, per day of the period — *default-agent-hours*
  ;; is a day's, so a week-long period holds seven of them and an eight-hour
  ;; band a third of one; the roster's default (labour-fold) is the same week.
  ;; A person with no stated window still declares away days (§2c): there is
  ;; no window to withdraw them from (agent-schedulable-window stays #f, its
  ;; own offer untouched), so they are read here, directly off the period's
  ;; own dates, and the flat rate is prorated by how many of them are away.
  (define (working-days)
    (let* ((dates (period-dates t)) (n (length dates)))
      (if (zero? n)
          (* *default-agent-hours* (/ (period-hours t) 24.0))
          (* *default-agent-hours* (/ (period-hours t) 24.0)
             (/ (- n (away-count (agent-away-dates a) dates)) n)))))
  (let ((w (agent-schedulable-window a)))            ; the offer less the person's sleep span
    (cond
     ((not (offer-expression? w)) (working-days))
     ;; a span means the overlap can be taken exactly — no approximation left
     ((car (period-span t)) (or (temporal-hours-within w t) (working-days)))
     (else (error "a window has nothing to meet: period has no place on the clock" t)))))

(define (period-time-range t)               ; a timed period's clock extent, else #f
  (and (span-timed? t)
       (let* ((sp (period-span t))
              (s  (or (iso-time-of (car sp)) 0))
              (e  (or (iso-time-of (cdr sp)) 0))
              ;; an end on a LATER date with no time means midnight, i.e. 24:00
              (e* (if (and (= e 0) (> (iso->epoch (cdr sp)) (iso->epoch (car sp)))) 1440 e)))
         (make-time-range (minutes->hhmm s) (minutes->hhmm e*)))))

;; ── THE PARTITION IS DERIVED, NOT ASKED FOR ──────────────────────────────────
;; A boundary somebody declared IS a period boundary. That is the whole claim,
;; and until the derivation existed it was only half true: the solve honoured a
;; boundary once a caller stated the matching span by hand, and a scope that
;; simply said "the baker works 09:00–17:00" fell back to reading that window as
;; a SHARE of a coarse day — the approximation this whole thread was about.
;;
;; So the boundaries are the horizon's own, plus every declared clock boundary
;; falling strictly inside one of them. Sort, dedupe, emit. Mornings become a
;; period because somebody works mornings, and a scope that declares nothing
;; keeps exactly the partition it had.
(define (temporal-clock-boundaries w)
  "The clock moments a temporal expression names, recurring or one-off."
  (let ((ends (lambda (trs) (append-map (lambda (tr)
                                          (list (time-range-start-time tr)
                                                (time-range-end-time tr)))
                                        (or trs '())))))
    (cond ((availability-window? w)
           (append-map (lambda (ds) (ends (day-schedule-time-ranges ds)))
                       (window->day-schedules w)))
          ((specific-date-window? w) (ends (specific-date-window-time-ranges w)))
          (else '()))))

(define (declared-clock-boundaries resources agents)
  "Every clock boundary anybody declared, as minutes past midnight.

   Midnight is dropped: it is a DATE boundary already, and re-cutting there
   would split a day into a day and nothing."
  (sort (delete-duplicates
         (filter (lambda (m) (and m (> m 0) (< m 1440)))
                 (map hhmm->minutes
                      (append
                       (append-map (lambda (r) (temporal-clock-boundaries
                                                (economic-resource-availability-window r)))
                                   resources)
                       (append-map (lambda (a) (temporal-clock-boundaries
                                                (agent-schedulable-window a)))
                                   agents)))))
        <))

(define (stamp-time date m)                  ; date + minutes → ISO, midnight closing the day
  (if (>= m 1440)
      (string-append (epoch->iso (+ (iso->epoch date) 86400)) "T00:00")
      (string-append date "T" (minutes->hhmm m))))

(define (refine-span sp cuts)
  "The pieces ONE span becomes: its own boundaries, plus every declared one
   falling strictly inside it."
  (let* ((dates (span-dates (car sp) (cdr sp)))
         (n     (length dates)))
    (if (null? dates)
        (list sp)
        (append-map
         (lambda (d i)
           (let* ((lo (if (= i 0) (or (iso-time-of (car sp)) 0) 0))
                  (hi (if (= i (- n 1))
                          (let ((e (iso-time-of (cdr sp)))) (if (and e (> e 0)) e 1440))
                          1440))
                  (ms (sort (delete-duplicates
                             (append (list lo hi)
                                     (filter (lambda (m) (and (> m lo) (< m hi))) cuts)))
                            <)))
             (map (lambda (a b) (cons (stamp-time d a) (stamp-time d b)))
                  (drop-right ms 1) (cdr ms))))
         dates (iota n)))))

(define (owned-spec spec aid) (string-append spec (string %owner-sep) aid))

(define (unowned-demand demand)
  "DEMAND ((\"spec~aid#place@t\" . q) …) with every owned good folded back onto
   the scope's good at the same cell — the aggregate a reserve or a reader
   per spec wants."
  (let ((acc '()))
    (for-each (lambda (d)
                (let* ((g (car d)) (o (spec-owner (key-spec g)))
                       (k (if o (string-append (car o) (substring g (string-length (key-spec g)))) g))
                       (row (assoc k acc)))
                  (if row (set-cdr! row (+ (cdr row) (cdr d))) (set! acc (cons (cons k (cdr d)) acc)))))
              demand)
    (reverse acc)))

(define (resolve-date-keys alist spans)
  "Let a caller say WHEN by wall clock: `bread#town@2026-06-03`.

   An integer names a PERIOD; a date names the STRETCH of periods covering that
   day, read off SPANS ((start . end) …, period t = position t). The two can no
   longer be mistaken for one another, and a date cannot go stale under
   refinement — refining changes which periods a day is made of, and never
   changes which day was meant.

   PURE: returns (values alist* regs), the alist with each date key moved to
   its stretch's first period and ((key . (t …)) …), the stretch each moved key
   stands for — the caller declares those through the door (#:stretches). The
   key moves and the stretch is declared TOGETHER, or the key names one thing
   while the form covers another."
  (let ((dates (map (lambda (sp) (if (car sp) (span-dates (car sp) (cdr sp)) '())) spans)))
    (let loop ((in alist) (out '()) (regs '()))
      (if (null? in) (values (reverse out) regs)
          (let* ((kv (car in)) (k (car kv)) (d (key-date k)))
            (if (or (not d) (key-period k))
                (loop (cdr in) (cons kv out) regs)     ; already a position
                (let* (
                       (ts (filter (lambda (t) (member d (list-ref dates t))) (iota (length spans)))))
                  (when (null? ts)
                    (error "located input names a date outside the horizon" k))
                  (let ((k* (key-retime k (car ts))))
                    (loop (cdr in) (cons (cons k* (cdr kv)) out)
                          (cons (cons k* ts) regs))))))))))

(define (refine-spans spans cuts)
  "Split each span at every declared boundary falling strictly inside it.

   Refining is IDEMPOTENT: a span already cut at 09:00 has no boundary strictly
   inside to cut at, so deriving twice is deriving once."
  (if (null? cuts) spans (append-map (lambda (sp) (refine-span sp cuts)) spans)))

(define* (declared-partition resources agents period-spans horizon #:optional (n 1))
  "The partition plan-from-records will actually tile for these records —
   the declared spans (or a horizon's daily expansion, or N periods of the
   standing partition when neither is declared), refined by the
   clock boundaries the resources and agents themselves declare. The ONE
   derivation, so a pre-solve compile (standing accepts → #:pins,
   held offers → #:holds) lays these spans and lands its terms on the
   very periods the solve's columns live at; a compile on the COARSE
   partition mis-addresses every sub-day band. plan-from-records'
   own spans*/refinement below derives the same answer interleaved with
   its key-retime bookkeeping."
  (let* ((spans (cond (period-spans period-spans)
                      (horizon (let ((s (iso->epoch (car horizon))))
                                 (map (lambda (i)
                                        (let ((d (epoch->iso (+ s (* i 86400)))))
                                          (cons d d)))
                                      (iota (cdr horizon)))))
                      (else (standing-partition n))))
         (cuts (declared-clock-boundaries resources agents))
         (coarse (filter car spans)))
    ;; refined only where the partition was declared — the standing partition
    ;; stays whole, as plan-from-records keeps it (ingest-located!)
    (if (or (null? cuts) (null? coarse) (not (or period-spans horizon))) spans
        (refine-spans coarse cuts))))

(define (coarse->fine spans cuts)
  "Which refined periods each declared one became: ((coarse . (fine …)) …)."
  (let loop ((sps spans) (i 0) (j 0) (acc '()))
    (if (null? sps) (reverse acc)
        (let ((n (length (refine-span (car sps) cuts))))
          (loop (cdr sps) (+ i 1) (+ j n) (cons (cons i (iota n j)) acc))))))

(define (dates-through from to)
  "Every \"YYYY-MM-DD\" from FROM to TO inclusive.

   A one-off window names its dates outright, which says \"the 14th and the
   21st\" plainly and says \"from the 14th onward\" only tediously. This writes
   the run out, so arrival stays the same record: the dates from the 14th to the
   end of the horizon ARE \"we get it on the 14th, and keep it\"."
  (let ((s (iso->epoch from)) (e (iso->epoch to)))
    (let loop ((d s) (acc '()))
      (if (> d e) (reverse acc) (loop (+ d 86400) (cons (epoch->iso d) acc))))))

(define (specific-window-hours-within w t)
  "Hours a ONE-OFF window offers inside period T.

   `<specific-date-window>` names calendar dates — \"we have the hall on the 14th
   and the 21st\" — optionally with clock ranges. So the reading is the same
   intersection as everywhere else, taken on the other axis: the dates it names
   meet the dates the period covers, and within a hit date its ranges meet the
   period's own clock extent.

   Naming no ranges means the whole of each hit date, which is `period-hours`
   divided over the dates the period spans."
  (let* ((named (or (specific-date-window-specific-dates w) '()))
         (cover (period-dates t))
         (hits  (length (filter (lambda (d) (member d named)) cover)))
         (trs   (specific-date-window-time-ranges w))
         (ptr   (period-time-range t)))
    (cond
     ((or (null? cover) (= 0 hits)) 0.0)      ; names no date this period holds
     ((not (pair? trs))                        ; a whole date, however long that is here
      (* (/ (exact->inexact hits) (length cover)) (period-hours t)))
     (ptr                                      ; the period carries clock boundaries
      (* hits (/ (ranges-minutes trs ptr) 60.0)))
     (else                                     ; whole dates: the ranges stand as stated
      (* hits (/ (ranges-minutes trs #f) 60.0))))))

(define (offer-expression? w)
  "A temporal expression, or a dated week — the offer a citizen makes: a
   recurring week with the dates a one-time commitment falls stated outright."
  (or (temporal-expression? w) (dated-week? w)))

(define (temporal-hours-within w t)
  "Hours ANY temporal expression offers inside period T, or #f if W is not one.

   A recurring window and a one-off are two notations for one thing — a set of
   moments — so they answer the same question and the callers below do not branch.
   A dated week is both at once: its week, with each date its exceptions name
   answered by their ranges instead — a stated day beats the week."
  (cond ((availability-window? w)    (window-hours-within w t))
        ((specific-date-window? w)   (specific-window-hours-within w t))
        ((dated-week? w)             (dated-week-hours-within w t))
        (else #f)))

(define (dated-week-hours-within w t)
  "The week's hours inside period T, less the week's hours on the dates the
   exceptions name, plus what the exceptions offer on them inside T."
  (let* ((week  (dated-week-week w))
         (over  (dated-week-overrides w))
         (named (filter (lambda (d) (assoc d over)) (period-dates t))))
    (if (null? named)
        (window-hours-within week t)
        (let* ((ptr   (period-time-range t))
               (mins  (lambda (trs) (ranges-minutes trs ptr)))
               (wday  (lambda (d) (vector-ref *weekday-syms* (instant->weekday (civil->instant d)))))
               ;; the week's own hours on one named date, inside T
               (week-on (lambda (d) (/ (mins (window-ranges-on week (list (wday d)))) 60.0))))
          (+ (- (window-hours-within week t) (fold + 0.0 (map week-on named)))
             (fold + 0.0 (map (lambda (d) (/ (mins (cdr (assoc d over))) 60.0)) named)))))))

(define (window-hours-within w t)
  "Hours window W offers inside period T — the EXACT overlap, not a share.

   For a period spanning whole dates this is `window-hours` over the weekdays it
   covers, which was already exact. For a period carrying clock boundaries it is
   the intersection of the window's ranges with the period's own extent, which is
   what makes a declared boundary mean anything: staffing 09:00-17:00 puts every
   one of those hours in the period that holds them and none in its neighbours.

   The intersection is `intersect-time-ranges` from the matching layer — the same
   code `matching/feasibility.scm` uses to decide whether two people can meet.
   There is one notion of overlap in the system, and this is it."
  (let ((ptr (period-time-range t))
        (days (period-days t)))
    (if (not ptr)
        (window-hours w days)
        (/ (ranges-minutes (window-ranges-on w days) ptr) 60.0))))

(define (resource-window-hours r t)         ; the TWIN of agent-window-hours, for a means
  "Hours resource R stands available in period T — its own availabilityWindow when
   it declares one, else the whole period.

   A worker's availability and a machine's are one declaration, not two
   (playnet.typ §Worker, soil, and tool: one field): a window over a period
   yields hours, and hours over a stock yield capacity. This is what lets a means
   be down for maintenance, staffed only part of the day, or seasonal — said the
   same way a person says it, and read by the same `window-hours`."
  (let ((w (economic-resource-availability-window r)))
    (cond
     ((not (offer-expression? w)) (period-hours t))
     ;; A period with a SPAN can be intersected exactly — no approximation left.
     ((car (period-span t)) (temporal-hours-within w t))
     ;; every period has a span (declare-world! lays the standing partition);
     ;; a window met by a period with no place on the clock is refused, as
     ;; the agent twin refuses it, rather than read as a share of a week
     (else (error "a window has nothing to meet: period has no place on the clock" t)))))

;; ── WHERE A CONTAINED THING IS: the container's place, not its name ──────────
;; A resource inside another is somewhere: seats are in a train, the train is at a
;; station, so the seats are at that station. `contained-in` names the container
;; and the container names where it is, which makes the place a WALK up the
;; containment chain to the first ancestor that states a location.
;;
;; Reading the container's ID as the place instead puts the seats in a cell called
;; "train" — a cell no arc reaches and no other holding shares, so a capacity held
;; that way is spatially disconnected from the plan that needs it. The walk is what
;; makes containment mean location rather than merely mean parentage.
;;
;; `vf/aggregation/containment.scm` states the same walk as `containment-first`, and
;; governance already reads a socialized resource's place through it
;; (`%socialization-place-of`). This is the compact twin, here for the reason the
;; availability window is: that module is module-scoped while the engine is
;; primitive-load. There is no arithmetic to drift — a loop and a seen-set — and
;; both stop for the same three reasons: a cycle, an unresolvable parent (a
;; container held elsewhere), or the depth cap.
(define %containment-max-depth 32)

(define (resource-place r . resolve)        ; the cell's place: where the chain finally says it is
  "Where R sits: its own `current-location`, else the location of the nearest
   container above it. RESOLVE (optional) turns a container id into its record; with
   none, an unresolvable parent leaves the container's own id as the place, which is
   what a solve given no resource list can honestly say."
  (let ((resolve (if (pair? resolve) (car resolve) (lambda (id) #f))))
    (let loop ((cur r) (seen '()) (d 0))
      (or (economic-resource-current-location cur)
          (let ((parent-id (economic-resource-contained-in cur)))
            (cond
             ((not parent-id) #f)
             ;; a cycle, or deeper than any real nesting: stop where we are
             ((or (member parent-id seen) (>= d %containment-max-depth)) parent-id)
             (else
              (let ((parent (resolve parent-id)))
                ;; an unresolvable container still LOCATES its contents relative to
                ;; itself, so its id remains the place — the pre-containment reading,
                ;; kept for the solves that pass no resource list
                (if parent
                    (loop parent (cons parent-id seen) (+ d 1))
                    parent-id)))))))))

(define (resource-resolver resources)
  "id → record over RESOURCES, for the containment walk. Built once per ingest: the
   walk is per holding and a linear scan per step would make it quadratic."
  (let ((by-id (make-hash-table)))
    (for-each (lambda (r) (let ((id (economic-resource-id r)))
                            (when id (hash-set! by-id id r))))
              resources)
    (lambda (id) (and id (hash-ref by-id id #f)))))

;; The twin of produced-spec-set, read off the other end of a template: specs some
;; recipe `use`s. A `use` compiles to a consume of the per-period service good
;; Svc|spec (compile-process), so what a stocked durable bounds is that SERVICE,
;; not a consumable quantity of itself — three ovens are three oven-periods each
;; period, and stay three ovens.
(define (used-spec-set)
  (let ((s (make-hash-table)))
    (for-each (lambda (tpl)
                (for-each (lambda (iq)
                            (when (svc-good? (car iq))
                              (hash-set! s (bar-spec (car iq)) #t)))
                          (proc-inputs tpl)))
              *templates*)
    ;; a travel mode rides what it `use`s (a vehicle, a network, a pass); the mode
    ;; recipes are parted from the plain templates, so they are read here too
    (for-each (lambda (m)
                (for-each (lambda (f)
                            (let ((sp (and (eq? 'use (recipe-flow-action f)) (recipe-flow-resource-conforms-to f))))
                              (when sp (hash-set! s sp #t))))
                          (mrec-flows m)))
              *mode-recipes*)
    s))

;; ── THE STOCK KEY: which lot of the plan a holding is ────────────────────────
;; A holding is a lot of a specification, in a stage and a state, held by one
;; accountable agent, somewhere. The plan's stock row for it is that lot's good at
;; that place, and this is the ONE function that says which. A stage or a state
;; qualifies the spec where some template flow names the qualified good (the
;; recipe's own vocabulary: an output at a stage and an input requiring it are one
;; good); any other stage a holding carries is a record of how it came to be,
;; and the holding stays the bare spec's.
(define *refused-stock* '())              ; ((resource-id . reason) …): holdings the last ingest could not count or place

(define (refused-stock) (reverse *refused-stock*))

(define (refuse-stock! r why)
  (set! *refused-stock* (cons (cons (economic-resource-id r) why) *refused-stock*)))

(define (named-good-set)                  ; every good some template flow names, qualified or not
  (let ((s (produced-spec-set)))
    (for-each (lambda (tpl) (for-each (lambda (iq) (hash-set! s (car iq) #t)) (proc-inputs tpl)))
              *templates*)
    s))

(define (person-set agents)
  "(aid → #t) over the person agents among AGENTS: who a stock key may call an owner."
  (let ((h (make-hash-table)))
    (for-each (lambda (a) (when (eq? (agent-type a) 'person) (hash-set! h (agent-id a) #t))) agents)
    h))

(define (stock-vocabulary)
  "The goods the standing recipes speak of, as (produced used named) spec sets: what a
   stock key reads a holding against. A confirmation reads the vocabulary the plan it
   confirms was solved with, and a solve states its own."
  (list (produced-spec-set) (used-spec-set) (named-good-set)))

(define* (make-stock-key resources #:optional (persons #f) #:key (vocabulary (stock-vocabulary)))
  "(resource → (good . place)) over RESOURCES: the lot R is of, and where it sits.
   PERSONS (aid → #t): a PRODUCED good one of them holds — a loaf a citizen
   claimed — is that citizen's own, \"spec~aid\" (owned-spec), so the next plan
   eats from it and claims no second copy; a means a person holds stays the
   scope's capacity through custody (what a process uses, no person claims), and
   so does a good they lent to the scope's box (custodian-scope set). VOCABULARY
   is `stock-vocabulary`: (produced used named)."
  (let ((produced (car vocabulary)) (used (cadr vocabulary)) (named (caddr vocabulary))
        (resolve (resource-resolver resources)))
    (lambda (r)
      (let* ((conforms (economic-resource-conforms-to r))
             (stage (economic-resource-stage r)) (state (economic-resource-state r))
             (spec0 (and conforms
                         (or (find (lambda (g) (hash-ref named g #f))
                                   (good-names conforms stage state))
                             conforms)))
             (holder (economic-resource-primary-accountable r)))
        (cons (if (and spec0 persons holder (hash-ref persons holder #f)
                       (not (economic-resource-custodian-scope r))
                       (hash-ref produced spec0 #f) (not (hash-ref used spec0 #f)))
                  (owned-spec spec0 holder)
                  spec0)
              (resource-place r resolve))))))

(define* (ingest-stock! resources #:key (period 0) (live-avail #f) (accounting? #f) (persons #f) (spec-units '()))
  "Sum located stock per (spec @ place@period) over the records, routed by role:
   a PRODUCED spec's stock is starting inventory → *init* (added to delivered); a
   RAW spec's stock is its available draw this period → *cap* (the draw bound).
   quantity = live `available` if registered live, else onhand (default; the
   custody/physical quantity — what can actually be consumed) or accounting.
   A holding adds its SIGNED quantity in the unit its specification counts in
   (SPEC-UNITS: ((spec . unit) …); `unit-factor`), and a lot's sum is floored at
   zero. A holding in a unit that does not convert, or with no place, is left
   out and named (`refused-stock`). Which lot a holding is: `make-stock-key`."
  (let* ((vocabulary (stock-vocabulary))
         (produced (car vocabulary)) (used (cadr vocabulary))
         (key (make-stock-key resources persons #:vocabulary vocabulary))
         (counted (make-hash-table))         ; (table . good) → signed sum of the count lots
         (containers (make-hash-table)))     ; the ids something stands in
    (set! *refused-stock* '())
    (for-each (lambda (r)
                (let ((c (economic-resource-contained-in r)))
                  (when c
                    (hash-set! containers c #t)
                    (hash-set! *stands-in* (economic-resource-id r) c))))
              resources)
    (for-each
     (lambda (r)
       (let* ((k (key r)) (spec (car k)) (place (cdr k))
              (live (and live-avail (live-avail (economic-resource-id r))))
              ;; the holding ITSELF, kept beside its number: `mqty` is about to
              ;; drop the unit, and the unit is what says whether this is a count
              ;; to be converted or a capacity already stated (holding-capacity).
              ;; A live availability reading is a level, not a declared stock, so
              ;; it is a count like any other.
              (m (and (not live)
                      (if accounting?
                          (economic-resource-accounting-quantity r)
                          (economic-resource-onhand-quantity r))))
              (q (cond (live live)
                       (accounting? (mqty (economic-resource-accounting-quantity r)))
                       (else (mqty (economic-resource-onhand-quantity r))))))
         (when (and spec (not place) (> q 0.0)) (refuse-stock! r 'no-place))
         (when (and spec place)
           (let* ((g (lg spec (cell place period)))
                  ;; what the holding is FOR: the prior of a fragility agent, the
                  ;; service of a used durable, or (the rest) a count of the good
                  (role (cond ((or (hash-ref *frag-budget* spec #f) (hash-ref *frag-container* spec #f)) 'prior-by-spec)
                              ((or (hash-ref *frag-cap* g #f) (hash-ref *frag-spec* spec #f)) 'prior-by-good)
                              ((hash-ref used spec #f) 'service)
                              (else 'count))))
             (cond ((and (not (eq? role 'count)) (<= q 0.0)) #f)                   ; only a count can be a debt
                   ((eq? role 'prior-by-spec) (hash-add! *frag-prior* spec q))   ; a FRAGILITY agent (budget | container): observed quantity is the draw-to-date PRIOR, by spec
                   ((eq? role 'prior-by-good) (hash-add! *frag-prior* g q))   ; per-period (located-good | per-spec rate): prior by located-good
                   ;; a PRODUCED (or never-raw) spec's stock is starting inventory →
                   ;; *init*; an UNPRODUCED spec's stock is its raw draw bound → *cap*.
                   ;; A stocked unproduced good is thus a bounded raw exactly as before
                   ;; (fail-closed touches only UNstocked unproduced goods, in good-index).
                   ;; a USED durable's stock is neither inventory nor a raw draw:
                   ;; it is the per-period SERVICE that much of it can render, so
                   ;; it bounds Svc|spec rather than the bare spec. This is the
                   ;; rule the supplier path already applies to a substitutable
                   ;; means (`durable? ⇒ Svc|`), stated once here for an ordinary
                   ;; stocked resource too — until now an uncapped Svc| was a
                   ;; structural pool, so a `use`d durable rendered UNBOUNDED
                   ;; service and every scope had to remember to cap it by hand.
                   ;; Accumulating is right: two ovens are two oven-periods, and a
                   ;; caller that sets its own cap afterwards still overrides.
                   ;;
                   ;; And it is capped in EVERY period, not only the one stock is
                   ;; read at. That is the difference between a stock and a
                   ;; standing capacity: inventory is a quantity that arrives once
                   ;; and is spent, while a durable renders its service again each
                   ;; period and is still there afterwards. Capping only the first
                   ;; period would let a mill run unbounded from the second one on
                   ;; — the service good is a structural pool, so an absent cap is
                   ;; not a small cap but no limit at all.
                   ((eq? role 'service)
                    ;; …times the hours it stands available. Capacity is a FLOW:
                    ;; three ovens over a day are seventy-two oven-hours, and over
                    ;; a season vastly more, though the count never moves. Without
                    ;; the hours the cap is a headcount and the plan rations the
                    ;; means' substance rather than its time (playnet.typ §Means
                    ;; of production). A holding already stated as a rate carries
                    ;; its own denominator, and `holding-capacity` reads it off
                    ;; the unit, so both readings are the one multiplication.
                    ;; WHERE it serves. A means at an ordinary place serves that
                    ;; place. One held at a place that CONTAINS others serves all of
                    ;; them — a line's seats are boardable at any of its stations —
                    ;; and out of one pool, because the seats spent at Alexanderplatz
                    ;; are not also available at Kottbusser Tor. That is a bar over a
                    ;; set of cells, which a per-cell cap cannot express: repeating
                    ;; the number at each place is that much capacity again, and
                    ;; capping only the container leaves every other cell unbounded
                    ;; (the trade-off `svc-held?` documents, now unnecessary).
                    ;; …and the pool's SPAN: the declared span when governance
                    ;; states one (*span-of*), else the holding place — location
                    ;; is fact, span is decision (§2.3 of the patchwork doc).
                    (let* ((span  (or (hash-ref *span-of* (economic-resource-id r) #f) place))
                           (under (places-within span *spatial-things* *places*)))
                      (cond
                       ;; A BUDGET — `200 hours`, a total that regenerates nowhere —
                       ;; is one bar over its whole window: spendable in any period it
                       ;; is available, at any place it reaches, and gone once spent.
                       ;; A ceiling at each cell would grant it afresh at every one.
                       ((holding-budget? m)
                        (let ((cells (append-map
                                      (lambda (t)
                                        (if (> (resource-window-hours r t) 0.0)
                                            (map (lambda (p) (cell p t)) under)
                                            '()))
                                      *periods*)))
                          (when (pair? cells)
                            (set! *container-pools*
                                  (cons (list (string-append "bg|" (economic-resource-id r))
                                              (list spec) cells q #t)
                                        *container-pools*)))))
                       ((> (length under) 1)
                          ;; one pool PER PERIOD: the service regenerates each period,
                          ;; so it is fungible across space and not across time
                          (for-each
                           (lambda (t)
                             (let ((cap (holding-capacity q m r (resource-window-hours r t))))
                               (when (> cap 0.0)
                                 (set! *container-pools*
                                       (cons (list (string-append "cp|" (economic-resource-id r)
                                                                  "|" (number->string t))
                                                   (list spec)
                                                   (map (lambda (p) (cell p t)) under)
                                                   cap #t)
                                             *container-pools*)))))
                           *periods*))
                       (else
                        ;; a single-place span caps at the SPAN'S place — with no
                        ;; declaration that is the holding place, as it always was.
                        (let ((at (if (pair? under) (car under) span)))
                          (for-each (lambda (t)
                                      (hash-add! *cap* (lg (svc-good spec) (cell at t))
                                                 (holding-capacity q m r (resource-window-hours r t))))
                                    *periods*)
                          ;; a means that TRAVELS (classified "mobile"): remembered here,
                          ;; where its capacity and place are known, and turned into a
                          ;; mover once the shed's modes are — means->movers!, which takes
                          ;; this same capacity back off the cell and hands it to presence
                          ;; …and so is a means some mode of the scope CARRIES
                          ;; (means-carried?): what is carried is the thing itself
                          ;; What stands IN something, stating no place of its own, is
                          ;; where its container is: remembered too, for the container
                          ;; that turns out to travel (means->movers!).
                          (cond ((or (member "mobile" (or (economic-resource-classified-as r) '()))
                                     (means-carried? spec))
                                 (set! *mobile-means* (cons (list r spec at q m #t) *mobile-means*)))
                                ((and (economic-resource-contained-in r) (not (economic-resource-current-location r)))
                                 (set! *contents* (cons (list r spec at q m) *contents*)))))))))
                   (else
                    ;; a lot's number is the signed sum of its holdings, each in the
                    ;; unit its spec counts in, floored once at the end; a consumable
                    ;; exists only in a period its window offers hours
                    (let ((f (unit-factor (and m (measure-has-unit m))
                                          (assoc-ref spec-units (economic-resource-conforms-to r)))))
                      ;; a CONTAINER a mode carries (a toolbox, a lockbox) travels as
                      ;; the thing it is, whatever it renders itself: a mover that
                      ;; bears what stands in it
                      (when (and (means-carried? spec) (hash-ref containers (economic-resource-id r) #f))
                        (set! *mobile-means* (cons (list r spec place q m #f) *mobile-means*)))
                      (cond ((not f) (refuse-stock! r 'unit))
                            ((and (economic-resource-availability-window r) (<= (resource-window-hours r period) 0.0)) #f)
                            (else (hash-add! counted (cons (if (hash-ref produced spec #f) 'init 'cap) g) (* f q)))))))))))
     resources)
    ;; a lot that nets to nothing states nothing: no entry, so an absent row stays absent
    (hash-for-each (lambda (k v) (when (> v 0.0) (hash-add! (if (eq? (car k) 'init) *init* *cap*) (cdr k) v)))
                   counted)))

;; ── the mobile means, remembered by ingest-stock! for means->movers! ──────────
(define (means->movers!)
  "Turn every durable that TRAVELS into a MOVER: one classified \"mobile\", or one
   a mode of the scope names as its mover (means-carried?). Its per-period
   service leaves the cell it is held at and follows its presence instead. Its
   hours are the service each period of it renders (holding-capacity through
   its availability window, period by period — rider-hours); its travel skills
   are its own classifiedAs tags, narrowed by mobility-skills exactly as a
   person rider's are, and folded into the same skills list a means otherwise
   uses only to name the service it carries.

   A MOVER BEARS WHAT STANDS IN IT. A means standing in a mover — the saw in a
   carried toolbox, at any depth — stating no place of its own, renders its
   capacity where that mover stands: its service joins the mover's skills, out
   of its own hours (*borne-hours*), and leaves its cell. What stands in a
   container nobody carries stays where it is. The books say the same of a
   container that moved (observer relocate-contents).

   A no-op without modes: with nowhere to ride, a mobile means serves where it
   stands."
  (when (and (pair? *mode-recipes*) (pair? *mobile-means*))
    (let ((capacity (lambda (r q m) (map (lambda (t) (cons t (holding-capacity q m r (resource-window-hours r t)))) *periods*)))
          (leave-cell! (lambda (svc at hours)                     ; the capacity leaves the cell…
                         (for-each (lambda (th) (hash-add! *cap* (lg svc (cell at (car th))) (- (cdr th)))) hours))))
      (for-each
       (lambda (mm)
         (let* ((r (car mm)) (spec (cadr mm)) (at (caddr mm)) (q (cadddr mm)) (m (list-ref mm 4))
                (serves? (list-ref mm 5))                           ; it renders a service of its own (a `use`d means)
                (id (economic-resource-id r)) (svc (svc-good spec))
                (hours (if serves? (capacity r q m) '())))
           (hash-set! *means-lot* id (cons spec q))             ; the thing a ride of it carries
           (when serves? (leave-cell! svc at hours))
           (set! *riders*                                       ; …and follows the means
                 (cons (list id at (append (if serves? (list svc) '())
                                           (mobility-skills (economic-resource-classified-as r)))
                             hours 'means)
                       *riders*))))
       *mobile-means*)
      (for-each
       (lambda (ct)
         (let* ((r (car ct)) (spec (cadr ct)) (at (caddr ct)) (q (cadddr ct)) (m (list-ref ct 4))
                (svc (svc-good spec))
                (bearer (let climb ((id (economic-resource-contained-in r)) (n 0))   ; the nearest mover it stands in
                          (cond ((or (not id) (> n %containment-max-depth)) #f)
                                ((hash-ref *means-lot* id #f) id)
                                (else (climb (hash-ref *stands-in* id #f) (+ n 1)))))))
           (when bearer
             (let* ((hours (capacity r q m))
                    (k (cons bearer svc))
                    (had (hash-ref *borne-hours* k #f)))
               (leave-cell! svc at hours)
               (hash-set! *borne-hours* k
                          (if had (map (lambda (th) (cons (car th) (+ (cdr th) (or (assv-ref had (car th)) 0.0)))) hours) hours))
               (set! *riders*
                     (map (lambda (rd)
                            (if (and (equal? (car rd) bearer) (not (member svc (caddr rd))))
                                (cons* (car rd) (cadr rd) (append (caddr rd) (list svc)) (cdddr rd))
                                rd))
                          *riders*))))))
       *contents*))))

;; populate the whole located model from real records. templates/demand/eco-caps
;; are POLICY (recipes from the recipe store, desires from Intents, caps from
;; ecological limits) — passed in, not read from stock. Stock/labour/coordinates
;; are read from the records. Leaves *templates* untouched (set via compile-recipe).
(define* (adopt-container-pools! #:optional (own *resource-suppliers*))
  "The pools ingest-stock! derived from containment become suppliers, after the
   caller's OWN (the order build-columns reads them in). ingest-located! does
   this as one of its steps; a caller who ingested stock by hand does it here."
  (set! *resource-suppliers* (append own *container-pools*)))

(define* (ingest-located! resources agents spatial-things
                          #:key (periods '(0)) (whole '()) (proc-frag '()) (live-avail #f)
                                (mode-recipes '())   ; the scope's travel modes, parted from its recipes: what a stock ingest reads as used
                                (agent-hours agent-window-hours)   ; reads the Agent's availabilityWindow (VF schedule)
                                (accounting? #f)
                                ;; ONE knob, ONE default. plan-from-records and
                                ;; ingest-records! both default this #t and both
                                ;; forward it here, so a low-level #f meant the
                                ;; same call meant different things depending on
                                ;; which door a caller entered — and the quiet
                                ;; answer (labour pours into the aggregate *A*
                                ;; cap, no worker columns, no work commitments)
                                ;; is the one that looks like a working plan.
                                ;; Every direct caller passes '() agents, so
                                ;; this changes no behaviour today; it removes
                                ;; the trap for the first one that does not.
                                (per-agent? #t) (stock-frag '())
                                (span-of '())   ; ((resource-id . place) …): governed pool spans (*span-of*)
                                (agent-skills (lambda (a) '("general")))  ; the agent's skill ERs (observer 'skills-of)
                                ;; live/expected POSITION override: (agent-id period) → place | #f.
                                ;; When it returns a place, that's where the agent IS this period
                                ;; (the commute ORIGIN), overriding the static primary-location.
                                (agent-position (lambda (id t) #f))
                                ;; a DECLARED partition: ((start . end) …), periods of
                                ;; any length, boundaries carrying an optional THH:MM
                                (period-spans #f)
                                ;; Derive the partition from what people declared:
                                ;; a stated clock boundary becomes a period boundary.
                                ;;
                                ;; On by default: a located input keyed @2 still means
                                ;; day 2 afterwards, because what was said about a
                                ;; stretch stays ONE form over that stretch (*stretch*).
                                ;; Nothing is split and no piece is chosen.
                                (refine-periods? #t)
                                ;; planning HORIZON: (start-iso . n-days) ⇒ n daily periods
                                ;; with spans set (availability lands on the right days,
                                ;; commitments carry real hasBeginning). #f ⇒ single period.
                                (horizon #f)
                                (movable '()) (storable '()) (tau 0.0) (hold 0.0)
                                (eco-caps '()) (eco-frag '()) (eco-spec-frag #f) (eco-budget '()) (eco-container '()) (eco-couple '()) (couplings '()) (eco-prior '()) (demand '()) (reserve '()) (desire-weights '()) (certificates '()) (never-raw '()) (raws '())
                                ;; substitutable MEANS as suppliers: (id closure-specs cell cap durable?).
                                ;; The instrument twin of per-agent? labour — a means offers its spec's
                                ;; conformance closure on one shared budget (build-columns). Split out
                                ;; live-side so the caller keeps passing plain eco-caps; the singleton
                                ;; (non-substitutable) case never routes here, staying a plain eco-cap.
                                (resource-suppliers '())
                                ;; ((spec (element . mass-fraction) …) …) — the chemistry,
                                ;; passed in as policy. Given, every template gains its
                                ;; element rows (close-elements!) and conservation becomes
                                ;; a constraint. Absent, the solve is byte-identical.
                                (composition '())
                                (spec-units '()))      ; ((spec . unit) …): the unit each spec counts stock in
  ;; ── the partition, derived purely ─────────────────────────────────────────
  ;; Everything up to the declaration is LIST MATH over the records and the
  ;; keyword arguments — no global is read or written, which is what lets the
  ;; one declare-world! below reset the world itself. A horizon (start . n) is
  ;; n daily spans; #:period-spans is the declared partition for a scope whose
  ;; periods are not uniform days (playnet.typ: a period is a length of time,
  ;; and how long is a governed choice); declared neither, the caller's
  ;; #:periods lie from today at the stated length (standing-partition), so
  ;; every period has a place on the clock and every window something to meet.
  (define spans*
    (cond (period-spans period-spans)
          (horizon (let ((s (iso->epoch (car horizon))))
                     (map (lambda (i) (let ((d (epoch->iso (+ s (* i 86400))))) (cons d d)))
                          (iota (cdr horizon)))))
          ;; declared nothing: the caller's periods, laid from today at the
          ;; stated length — every period has a place on the clock
          (else (standing-partition (length periods)))))
  (when (pair? spans*) (set! periods (iota (length spans*))))
  ;; the partition AS DECLARED and the coarse→fine map, kept for *locate-key*
  ;; (the reproduction bands pour after ingest and take the same two passes)
  (define coarse-spans spans*)
  (define fine-map #f)
  ;; Wall-clock addressing, resolved against the partition AS DECLARED — before
  ;; any refinement, so a date names the day the caller meant either way. The
  ;; stretch registrations collect here and are DECLARED with the world below —
  ;; a hash keyed by the located key, with insertion order kept beside it: the
  ;; retime pass below reads and replaces one registration per retimed row,
  ;; and the rows run O(crowd × wants), so an alist probed with `assoc` and
  ;; rewritten with `alist-delete` per row read the table once per row.
  (define regs (make-hash-table))
  (define reg-order '())
  (define (reg-set! k ts)
    (unless (hash-ref regs k #f) (set! reg-order (cons k reg-order)))
    (hash-set! regs k ts))
  (define (reg-list)                      ; the registrations, insertion-ordered
    (filter-map (lambda (k) (let ((ts (hash-ref regs k #f))) (and ts (cons k ts))))
                (reverse reg-order)))
  (define (resolve! alist)
    (call-with-values (lambda () (resolve-date-keys alist spans*))
      (lambda (alist* rs) (for-each (lambda (r) (reg-set! (car r) (cdr r))) rs) alist*)))
  (set! demand   (resolve! demand))
  (set! reserve  (resolve! reserve))
  (set! eco-caps (resolve! eco-caps))
  (set! eco-frag (resolve! eco-frag))
  (set! desire-weights (resolve! desire-weights))
  ;; …and now the boundaries nobody had to state twice. Someone saying "I work
  ;; 09:00–17:00" HAS declared a boundary at 09:00; deriving it is what makes the
  ;; window land in the period that holds it instead of being spread as a share
  ;; over a coarse day. A scope that declares no clock keeps its partition
  ;; exactly, which is the degenerate case and must stay free. Every located
  ;; input carries across: its key moves to the stretch's FIRST piece — one
  ;; representative, so the form is emitted once — and its registration now
  ;; spans ALL the fine pieces of ALL its coarse periods. Nothing is split and
  ;; nothing is chosen: what was said about day 2 is still said about day 2.
  ;; The partition refined is a DECLARED one — spans or a horizon the caller
  ;; laid. The standing partition is the clock's own, laid because a period
  ;; has to lie somewhere, and a scope that declared no clock keeps it whole:
  ;; its windows meet the whole day exactly, and what its reports address by
  ;; period is the period it asked for.
  (when (and refine-periods? (or period-spans horizon))
    (let ((cuts (declared-clock-boundaries resources agents))
          (coarse (filter car spans*)))
      (unless (or (null? cuts) (null? coarse))
        (let* ((m   (coarse->fine coarse cuts))
               (mts (lambda (ts) (append-map (lambda (t) (or (assv-ref m t) '())) ts)))
               (retime
                (lambda (kv)
                  (let* ((k (car kv)) (t (key-period k)))
                    (if (not t) kv
                        (let ((ts (mts (or (hash-ref regs k #f) (list t)))))
                          (if (null? ts) kv
                              (let ((k* (key-retime k (car ts))))
                                (hash-remove! regs k)
                                (reg-set! k* ts)
                                (cons k* (cdr kv))))))))))
          (set! spans* (refine-spans coarse cuts))
          (set! periods (iota (length spans*)))
          (set! demand    (map retime demand))
          (set! reserve   (map retime reserve))
          (set! eco-caps  (map retime eco-caps))
          (set! eco-frag  (map retime eco-frag))
          (set! desire-weights (map retime desire-weights))
          (set! fine-map m)))))
  ;; ── the declaration ───────────────────────────────────────────────────────
  ;; The world's identity — its places, from the union of everything the
  ;; records and located inputs touch — handed with the partition and the
  ;; caller's movable/storable/tau/hold to declare-world!: the ONE door, which
  ;; RESETS (a declaration is a fresh world), so this records world and a
  ;; fixture's world are the same world by construction.
  (let ((places (make-hash-table)))          ; places = union over resources + agents + resource-suppliers (+ position overrides)
    (let ((resolve (resource-resolver resources)))   ; one place rule: the same walk ingest-stock! reads
      (for-each (lambda (r) (let ((p (resource-place r resolve))) (when p (hash-set! places p #t)))) resources))
    (for-each (lambda (a) (let ((p (agent-primary-location a))) (when p (hash-set! places p #t)))) agents)
    (for-each (lambda (s)                     ; a substitutable means/stock is a located source; its place must exist even when
      (hash-set! places (place-of (caddr s)) #t))  ; the record itself left the resource list (a stock joined the bundles). cell = place@period
      resource-suppliers)
    (for-each (lambda (a)                     ; any place the agent is positioned at, this/any period
      (for-each (lambda (t) (let ((p (agent-position (agent-id a) t))) (when p (hash-set! places p #t)))) periods))
      agents)
    ;; …and any place a LOCATED INPUT names. `good#place@t` keys — demand, caps,
    ;; per-good fragilities, the reserve tranche — each say that something is
    ;; wanted or bounded THERE, which is a statement that the place is part of
    ;; this plan. Deriving places from stock alone made that silent: a scope
    ;; could declare a plot, place it in its shed, inherit the shed's scenarios
    ;; and limits, ask for food at it — and get no cell, no columns, and a plan
    ;; reading zero with no error anywhere. The mirror of the planner's own
    ;; fail-closed rule: a draw it has not accounted for dies loudly rather than
    ;; conjuring itself, so a demand at a place it does not have should bring the
    ;; place into being rather than be quietly unmeetable.
    (for-each (lambda (kv)
                (let ((p (false-if-exception (place-of (located-cell (car kv))))))
                  (when (and (string? p) (not (string-null? p))) (hash-set! places p #t))))
              (append demand eco-caps eco-frag reserve))
    (declare-world! #:places (sort (hash-map->list (lambda (k v) k) places) string<?)
                    #:periods periods
                    #:spans (filter-map (lambda (sp t) (and (car sp) (list t (car sp) (cdr sp))))
                                        spans* (iota (length spans*)))
                    #:stretches (map (lambda (r)
                                       (cons (car r) (map (lambda (t) (key-retime (car r) t)) (cdr r))))
                                     (reg-list))
                    #:movable movable #:storable storable
                    #:tau tau #:hold hold
                    #:mode-recipes mode-recipes
                    #:spatial-things spatial-things)
    ;; the world's own key addressing for statements poured AFTER ingest — the
    ;; reproduction bands: a date key resolves against the declared partition
    ;; and a coarse period retimes to its stretch's first piece, registering
    ;; the stretch in *stretch* — exactly the two passes every located input
    ;; took above. Identity in a span-less or unrefined world. A date RANGE
    ;; on a band is not spread (a band names a day); its first day stands.
    (set! *locate-key*
      (lambda (k)
        (let* ((k1 (call-with-values
                       (lambda () (resolve-date-keys (list (cons k #t)) coarse-spans))
                     (lambda (a* rs) (if (pair? a*) (car (car a*)) k))))
               (t  (key-period k1))
               (ts (and fine-map t (assv-ref fine-map t))))
          (if (and ts (pair? ts))
              (let ((k* (key-retime k1 (car ts))))
                (hash-set! *stretch* k* (map (lambda (p) (key-retime k1 p)) ts))
                k*)
              k1))))
    ;; HONESTY REPORT (the RAW-LINT precedent): a declared place that never
    ;; became a cell. A CONTAINER legitimately never is one — the biosphere and
    ;; the shed hold things, nothing is produced at them — so only LEAVES are
    ;; reported: a place with nothing inside it and nothing on it is a place the
    ;; plan cannot use, and saying so beats reading zero and wondering.
    (let* ((contained (map spatial-thing-contained-in spatial-things))
           (orphans (filter (lambda (st)
                              (let ((id (spatial-thing-id st)))
                                (and id (not (hash-ref places id #f))
                                     (not (member id contained)))))   ; a leaf, not a container
                            spatial-things)))
      (when (pair? orphans)
        (format (current-error-port)
                "[PLACE-LINT] ~a declared place(s) hold nothing and are not containers, so they are not cells: ~s~%"
                (length orphans) (map spatial-thing-id orphans)))))
  ;; never-raw specs (money, credit) are GOODS, set BEFORE ingest-stock! so their
  ;; stock routes to *init* (a starting balance) not *cap* — no free raw draw.
  (for-each (lambda (s) (hash-set! *never-raw* s #t)) never-raw)
  ;; (spec . w) — a limit carried as a LEVEL rather than a wall, felt at the optimum:
  ;; its ≥0 balance is emitted as `frag` at the profile's governance weight instead of
  ;; the swept `bar` every other good carries (build-located). Declaring the weight also
  ;; declares the spec NEVER-RAW, because a level IS an accounted good — and, like every
  ;; never-raw above, it must be set BEFORE ingest-stock! so the level routes to *init*
  ;; (a starting balance) rather than *cap* (an available draw). Registered after it, the
  ;; balance would read a const of 0 and admit no draw at all.
  (for-each (lambda (p)
              (hash-set! *stock-frag-w* (car p) (cdr p))
              (hash-set! *never-raw* (car p) #t))
            stock-frag)
  ;; span declarations ((resource-id . place) …) — governed pool extents, set
  ;; BEFORE ingest-stock! because that is where the pools are constituted.
  ;; Location stays the record's own; only the pool's span follows the declaration.
  (for-each (lambda (p) (hash-set! *span-of* (car p) (cdr p))) span-of)
  ;; the free-raw allow-list (fail-closed default): only these specs — plus the
  ;; structural Lab|/Svc| pools — may be drawn free when unproduced.
  (for-each (lambda (s) (hash-set! *raws* s #t)) (append *ambient-flows* raws))
  ;; fragility caps set BEFORE ingest-stock! so a frag-capped agent's observed quantity
  ;; routes to *frag-prior* (its draw-to-date), not to *cap* as an available-draw bound.
  (for-each (lambda (fc) (hash-set! *frag-cap* (car fc) (cdr fc))) eco-frag)        ; (located-good . (lo hi alpha w)) — a per-period fragility barrier
  ;; INHERITED LIMITS: a scope placed contained-in a bioregion carries that
  ;; region's fragilities, exactly as it already inherits the region's scenarios
  ;; (see the `scen` climb in navdanya-farm.scm). The shed declares its own
  ;; envelopes once — Doon's `groundwater` and `topsoil`, with real WRI Aqueduct
  ;; and SoilGrids state behind them (knowledge/doon-shed.scm) — and every plot
  ;; inside it is held to them without restating anything. Placement is the
  ;; wiring; that is the whole point of the containment tree.
  ;;
  ;; NOT SUPPLIED (#f) means inherit; an explicit list OVERRIDES, and an
  ;; explicit '() means NO limits. The three have to stay distinguishable: a
  ;; study that isolates one fragility, or removes them to show what runs
  ;; without any, has to be able to say so — if empty meant inherit there would
  ;; be no way to express an unconstrained run at all.
  ;; The inherited list may hold either shape: bare `(spec . profile)` pairs,
  ;; which have always meant a per-period rate, or <fragility> records that name
  ;; their own extent and window. `as-fragilities` lifts the first into the
  ;; second, so ONE list carries a shed's recharge envelope (a rate) and its
  ;; tipping point (a horizon total) together — which the old single-shape list
  ;; could not say, and which is why nothing declared a tipping point.
  (for-each route-fragility!
            (as-fragilities (or eco-spec-frag (scope-bioregion-fragilities spatial-things))))
  (for-each (lambda (bg) (hash-set! *frag-budget* (car bg) (cdr bg))) eco-budget)   ; (spec . (lo hi alpha w)) — a CUMULATIVE horizon budget
  (for-each (lambda (cf) (hash-set! *frag-container* (car cf) (cdr cf))) eco-container)   ; (container . (lo hi alpha w)) — a fragility on an ecological container
  ;; CONTAINMENT map from the records: each resource's spec is contained-in its parent (contained-in is also its PLACE, via resource-place).
  (for-each (lambda (r) (let ((c (economic-resource-contained-in r)) (spec (economic-resource-conforms-to r)))
                          (when (and c spec) (let ((cur (hash-ref *contained* c '())))
                                               (unless (member spec cur) (hash-set! *contained* c (cons spec cur)))))))
            resources)
  ;; Discreteness arrives the SAME way storability does — as data. Two doors, one
  ;; table each: the RECIPE states it (a minimumBatchQuantity, a "whole-count"
  ;; classification — compile-recipe carries both in the template, which is what
  ;; outlives the reset! above), and the SCOPE may add to it through the keyword.
  ;; The knowledge layer cannot call `declare-whole!`: that lives in the engine,
  ;; which is primitive-loaded, while a recipe reaches the planner as a MODULE.
  ;; So a scope states what is true of its acts and the solve reads it, which is
  ;; what every other declaration here already does. §7 reads only these tables.
  (for-each (lambda (tpl)
              (let ((b (proc-batch tpl)))
                (when (and (real? b) (> b 0.0)) (hash-set! *mbq-procs* (proc-id tpl) b)))
              (when (proc-whole? tpl) (hash-set! *whole-procs* (proc-id tpl) #t))
              (when (pair? (proc-tags tpl)) (hash-set! *proc-tags* (proc-id tpl) (proc-tags tpl))))
            *templates*)
  (for-each (lambda (p) (hash-set! *whole-procs* p #t)) whole)
  (declare-proc-frag! proc-frag)   ; the acts whose LEVEL is a fragility — the scope's declaration, like `whole`
  ;; the chemistry, then the rows it implies — before any column is built
  (for-each (lambda (c) (hash-set! *composition* (car c) (cdr c))) composition)
  (close-elements!)
  (ingest-stock! resources #:period (car periods) #:live-avail live-avail #:accounting? accounting? #:spec-units spec-units
                 #:persons (person-set agents))                   ; a produced good a citizen holds is their own
  ;; labour from Agent.primary-location, per period: where the agent IS (a
  ;; live/expected override if given, else their static home — the commute
  ;; ORIGIN for the cell) and the hours they offer there. Computed HERE, after
  ;; the declaration, because the default agent-hours (agent-window-hours)
  ;; intersects the agent's availability window with the period spans the door
  ;; just laid. per-agent? ⇒ each entry is a WORKER, a located-dated supplier
  ;; (skill-resolved, EMP in the solve, who-works-which falls out), layered on
  ;; through declare-workers!; else the hours pour into the aggregate per-cell
  ;; cap *A*. agent-skills resolves the agent's skills — must match the
  ;; *proc-skill* the caller tags templates with.
  (let* ((rows (append-map (lambda (a)              ; (agent period disposable-hours-or-#f), every person × every period
                             (map (lambda (t) (list a t (period-disposable-hours a t))) periods))
                           agents))
         (labour (filter-map (lambda (row)
                               (let* ((a (car row)) (t (cadr row)) (d (caddr row))
                                      (p (or (agent-position (agent-id a) t) (agent-primary-location a)))
                                      (offer (agent-hours a t))
                                      (h (if d (min offer d) offer)))   ; the offer kept inside what the body leaves
                                 (and p (> h 0.0) (list a (cell p t) h))))
                             rows)))
    (set! *disposable-total* (fold + 0.0 (filter-map caddr rows)))
    (if per-agent?
        (declare-workers! (map (lambda (e) (list (agent-id (car e)) (agent-skills (car e)) (cadr e) (caddr e)))
                               (reverse labour))    ; the order the old cons loop left them in
                          ;; PEOPLED: somebody stands somewhere in this world, so its labour is
                          ;; theirs — whether or not any of them has an hour (*roster-labour?*).
                          ;; A world with no located person states nothing about labour.
                          #:peopled? (or (eq? per-agent? 'roster)      ; the caller says so (a live scope)
                                         (any (lambda (a) (or (agent-primary-location a)
                                                          (any (lambda (t) (agent-position (agent-id a) t)) periods)))
                                              agents)))
        (for-each (lambda (e) (hash-add! *A* (cadr e) (caddr e))) labour)))
  ;; A PERIOD NOBODY IS AVAILABLE IN HAS ZERO LABOUR, NOT UNLIMITED LABOUR —
  ;; but only where labour comes from LOCATED AGENTS in the first place.
  ;;
  ;; The loop above records an hours entry only where an agent actually has hours,
  ;; and build-columns emits the aggregate labour bar only for cells that HAVE an
  ;; entry. A cell with no entry therefore carried no bar at all — it was
  ;; UNCAPPED, not empty. That left every multi-period aggregate solve
  ;; under-constrained: the plan could conjure labour in a period nobody had
  ;; declared, which is why a good never HAD to cross time and storage columns
  ;; looked inert. (test-store-recipe.scm names it in its own header.)
  ;;
  ;; The zero-fill is scoped to PEOPLED PLACES: a place where some agent stands in
  ;; some period is a place whose labour is the roster's, so a period they are all
  ;; absent in has none. A place with no agent at any period is left alone — its
  ;; labour, if any, arrives by another channel entirely (a supplier bundle, the
  ;; skilled per-worker path), and zeroing it there would be a claim this function
  ;; is not entitled to make.
  (unless per-agent?
    (let ((peopled (make-hash-table)))
      (for-each (lambda (a)
                  (let ((home (agent-primary-location a)))
                    (when home (hash-set! peopled home #t))
                    (for-each (lambda (t)
                                (let ((p (agent-position (agent-id a) t)))
                                  (when p (hash-set! peopled p #t))))
                              periods)))
                agents)
      (for-each (lambda (c)
                  (when (and (hash-ref peopled (place-of c) #f)
                             (not (hash-ref *A* c #f)))
                    (hash-set! *A* c 0.0)))
                *cells*)))
  ;; the caller's substitutable means, plus the pools ingest derived from containment
  ;; above (a means held at a container place). Both are shared-budget supply bundles
  ;; in build-columns; a non-substitutable means at an ordinary place stays a plain
  ;; eco-cap below.
  (adopt-container-pools! resource-suppliers)
  ;; (located-good . cap). The FIRST policy cap on a located good overrides a
  ;; stock-derived one; a SECOND policy cap on the same located good is another
  ;; POOL — a UC allocation and a member's lent lathe at one place — and pools
  ;; ADD (the means fold's own monoid), never overwrite. A caller wanting a
  ;; what-if to REPLACE a standing cap filters the standing one out first
  ;; (service.scm plan-fn); ingest itself states only the lawful combine.
  ;; A cap keyed on a located good WITHOUT a period (`Svc|spec#place`) names
  ;; that pool at every period of this solve: the UC allocation lands once
  ;; (service.scm means-plan) and bounds every period a later solve lays.
  (let ((seen (make-hash-table))
        (eco-caps (append-map (lambda (ec)
                                (let ((k (car ec)))
                                  (if (and (string? k) (string-index k #\#) (not (key-period k)))
                                      (map (lambda (t) (cons (string-append k "@" (number->string t)) (cdr ec))) *periods*)
                                      (list ec))))
                              eco-caps)))
    (for-each (lambda (ec)
                (let* ((k (car ec)) (v (cdr ec)) (prior (hash-ref *cap* k #f)))
                  (hash-set! *cap* k
                             (if (and (hash-ref seen k #f) (number? v) (number? prior))
                                 (+ prior v)
                                 v))
                  (hash-set! seen k #t)))
              eco-caps)
    ;; A LIMIT THAT NAMES NOTHING LIMITS NOTHING, and says so. A reproduction band
    ;; on a good no column touches is refused (it could never be held); a cap on
    ;; one is merely inert — but a ban spelt `soyl` is a ban nobody is under, and
    ;; the plan runs in full without a word. Read against the RECIPES, never the
    ;; pruned columns: a working ban prunes its own consumers, and that is the
    ;; cap doing its job. Structural pools (Lab|…) are the roster's to name.
    (let ((named (make-hash-table)))
      (for-each (lambda (tpl)
                  (for-each (lambda (io) (hash-set! named (car io) #t))
                            (append (proc-outputs tpl) (proc-inputs tpl))))
                *templates*)
      (let ((inert (filter (lambda (k) (let ((g (good-spec k)))
                                         (not (or (hash-ref named g #f) (lab-good? g)))))
                           (hash-map->list (lambda (k _) k) seen))))
        (set! *inert-caps* (sort inert string<?))      ; the finding as DATA, for a caller or a suite to read
        (when (pair? inert)
          (format (current-error-port) "  [cap] ~a cap(s) name a good no recipe touches — they limit nothing: ~s~%"
                  (length inert) (sort inert string<?))))))
  ;; A declared LEVEL must have routed to *init* (a starting balance). Every other
  ;; destination leaves its balance at const 0 — a well-formed barrier that forbids
  ;; all activity, and reads downstream exactly like a plan that chose not to draw.
  ;; `ingest-stock!`'s cond has three ways to divert it, and all three are silent:
  ;;   *cap*        the spec was also declared an eco-cap, or its never-raw flag was
  ;;                registered after ingest-stock! (see the note where stock-frag is
  ;;                set) — either way the level was read as an available draw bound;
  ;;   *frag-cap* / *frag-spec*
  ;;                the spec was ALSO given a fragility profile, so its quantity
  ;;                routed to *frag-prior*. Worse than double-counting: never-raw
  ;;                then sends the good to the `goods` branch, which the fragility
  ;;                emission never reaches, so the profile is dropped as well.
  ;; A limit is carried ONE way. Say which.
  (let ((diverted
         (lambda (spec)
           (cond ((hash-fold (lambda (g v a) (or a (and (number? v) (> v 0.0)
                                                        (equal? spec (good-spec g)) (cons '*cap* v))))
                             #f *cap*))
                 ((hash-fold (lambda (g v a) (or a (and (equal? spec (good-spec g)) (cons '*frag-cap* v))))
                             #f *frag-cap*))
                 ((hash-ref *frag-spec* spec #f) => (lambda (v) (cons '*frag-spec* v)))
                 (else #f)))))
    (hash-for-each
     (lambda (spec w)
       (let ((d (diverted spec)))
         (when d
           (error (format #f "stock-frag: ~s is declared a LEVEL (w=~a) and ALSO appears in ~a — its quantity routes away from the starting balance, leaving the barrier at 0 and forbidding every draw. Carry the limit one way: a level, or a wall."
                          spec w (car d))))))
     *stock-frag-w*))
  (for-each (lambda (e) (hash-set! *eco-couple* (car e)                            ; (k-spec j-spec c) — drawing j stresses agent k by c (the cascade matrix C)
                          (cons (cons (cadr e) (caddr e)) (hash-ref *eco-couple* (car e) '())))) eco-couple)
  ;; COUPLINGS: ((name . triples) …) — any number of registered couplings in
  ;; one keyword, register-coupling! the one door each goes through.
  (for-each (lambda (nc) (register-coupling! (car nc) (cdr nc))) couplings)
  (for-each (lambda (p) (hash-set! *frag-prior* (car p) (cdr p))) eco-prior)       ; (located-good|spec . prior) — an explicit MANUAL override, after the observed prior from ingest-stock!
  ;; No no-phantom-raw 0-cap sweep: a raw absent from a cell is unavailable there
  ;; UNLESS its stock / eco-cap can REACH it along storage / transport arcs.
  ;; build-columns derives this from the arc graph (raw-reach-set), so a stocked
  ;; storable raw feeds production at the cells it carries to, and a raw with no
  ;; reachable source drops the column with no explicit 0-cap. The eco-caps set
  ;; above (and ingested stock) are the only caps; everything else is reachability.
  (for-each (lambda (d) (hash-set! *demand* (car d) (cdr d))) demand)        ; (located-good . target)
  (for-each (lambda (dw) (hash-set! *desire-weight* (car dw) (cdr dw))) desire-weights)  ; (located-good . w_d) — priority, uniform when unset
  (set! *certificates* (filter (lambda (c) (and (pair? c) (string? (car c)) (number? (cdr c)))) certificates))   ; ((aid . hours) …) — build-columns lays the bars
  (when (and (getenv "PLANNER_PD_DEBUG") (pair? *certificates*)) (format (current-error-port) "  [cert] stated ~s~%" *certificates*))
  (for-each (lambda (rv) (hash-set! *reserve* (car rv) (cdr rv))) reserve))  ; (located-good . (extra . w))

;; Pour a merged arc-time table into *arc-hours*. TABLE is the alist solve/routing.scm
;; produces — ("from|to|manner" . hours | (hours . net-km)) — Valhalla matrix
;; priors (pairs) ⊕ observed EWMA (bare hours). Must run AFTER ingest-located!
;; (which reset!s, clearing *arc-hours* — same ordering contract as *willing?*).
;; Empty/absent table ⇒ the hash stays empty ⇒ every arc call falls back to
;; rate×haversine: strict parity.
;;
;; Matrix-sourced entries make the table a first-class source of two more
;; facts, both derived here:
;;   PACE — each manner's nominal hours/km = the MEDIAN over its (hours . km)
;;     entries: the network's own typical pace, which arc-scale-time normalises
;;     congestion against for generic recipes. A ride mode's own pace always
;;     wins; bare-hours entries carry no distance and contribute nothing, so
;;     tables without matrix data leave pace — and parity — alone.
;;   TOPOLOGY (opt-in, derive-topology?) — when NO transport network is
;;     declared, the matrix's finite arcs become the *neighbours* edges: the
;;     legacy "connected to all" default sharpened to "connected as the
;;     network says" (islands drop out). Declared edges always win: which
;;     places are coupled is partly a governance choice, so the matrix only
;;     ever fills silence.
(define* (ingest-travel-times! table #:key (derive-topology? #f))
  (when (pair? table)
    (for-each (lambda (kv) (hash-set! *arc-hours* (car kv) (cdr kv))) table)
    (let ((paces (make-hash-table)))                       ; manner → (hours/km …)
      (for-each (lambda (kv)
                  (let ((v (cdr kv)))
                    (when (and (pair? v) (> (cdr v) 0.0))
                      (let ((manner (caddr (string-split (car kv) #\|))))
                        (hash-set! paces manner
                                   (cons (/ (car v) (cdr v))
                                         (hash-ref paces manner '())))))))
                table)
      (hash-for-each
       (lambda (manner ps)
         (let ((s (sort ps <)))
           (set! *manner-pace*
                 (cons (cons manner (list-ref s (quotient (length s) 2)))
                       *manner-pace*))))
       paces))
    (when (and derive-topology?
               (zero? (hash-count (const #t) *neighbours*)))
      (for-each (lambda (kv)
                  (let* ((p (string-split (car kv) #\|))
                         (a (car p)) (b (cadr p))
                         (cur (hash-ref *neighbours* a '())))
                    (unless (member b cur)
                      (hash-set! *neighbours* a (cons b cur)))))
                table))))

;; THE RESERVATION OF REST (docs/planning/food/reproduction-of-labour-power.md §2b). What a
;; person's body leaves of a period is read through availability.scm's one door
;; (agent-disposable-hours): the hours of the period after their own reproduction time
;; (SNIRT), or #f where nothing is reserved. The hours a person OFFERS sit inside it, and
;; the free-time fraction reads over every person's disposable time — the spec's
;; f = 1 − L/Σ D_p. With nothing registered every offer stands and N·T is the Σ of the
;; offers. A period under a day places its hours through the person's availability
;; window and reserves nothing.
(define (period-disposable-hours a t)
  (let ((days (/ (period-hours t) 24.0)))
    (and (>= days 1.0) (agent-disposable-hours a days))))

;; The band pour — the ONE place a reproduction band enters a solve, called by
;; every path (plan-from-records, solve/robust.scm's per-scenario block, federation-
;; solve's commune record) AFTER ingest (which reset!s) and BEFORE build-located.
;; A bare floor becomes a deficit on the good's on-hand here (its ≥0 balance is
;; the barrier); a margin floor and a ceiling are stored for build-located to
;; emit. `repro-bands` folds the four spellings into one list of
;; (located-good floor ceiling w) so no caller assembles a band by hand.
(define (apply-repro-bands! bands)
  (when (tier-shape 'floor)
   (for-each
   (lambda (b)
     (let* ((g (*locate-key* (car b)))    ; the world's own addressing: date → period, coarse → its stretch
            (fl (cadr b)) (hi (caddr b)) (w (cadddr b))
            (prev (hash-ref *band* g (make-band)))
            (lo (cond ((number? fl) fl) ((pair? fl) (car fl)) (else #f))))
       ;; EVERY floor is a need before any want: its level comes off the good's
       ;; on-hand, so the ≥0 balance holds it and a #:demand on the same good
       ;; counts ABOVE it — the reserve under the want, "the credit pool draws on
       ;; q* alone, the target net of the held-back reserve" (playnet.typ). A
       ;; bare floor is done there. A margin floor keeps its margin as `held`
       ;; on what remains: wall at 0 of the remainder (= lo of the level),
       ;; at ease at quantile_alpha of the margin above it.
       ;; a wall at zero (a held need's insurance band) asks nothing of the
       ;; balance — registering it as a stretch floor would only trip the
       ;; fail-closed guard on a good nobody makes yet
       (when (and lo (> lo 0.0))
         (if (pair? (cdr (stretch-of g)))
             ;; a floor over a refined day: the DAY must hold it (the stretch
             ;; wall build-located emits), each band keeps its own conservation
             (hash-set! *stretch-floor* g (+ (hash-ref *stretch-floor* g 0.0) lo))
             (hash-set! *init* g (- (hash-ref *init* g 0.0) lo))))
       (hash-set! *band* g
                  (make-band #:floor   (if (pair? fl) (list 0.0 (- (cadr fl) lo) (caddr fl)) (band-floor prev))
                             #:ceiling (or hi (band-ceiling prev))
                             #:w       (if (or (pair? fl) hi) w (band-w prev))))))
   bands)))

(define* (repro-bands #:key (floors '()) (caps '()) (insurance '()) (bands '()))
  "One list of (located-good floor ceiling w) from the four spellings:
     floors    ((g . lo) …)                — the deficiency edge, a hard floor
     caps      ((g . hi) | (g . (hi . w)) …) — the toxicity edge (w defaults to 1);
                                              hi may be a range (lo hi alpha)
     insurance ((g lo hi alpha w) …)        — a floor with a margin, `held`
     bands     ((g lo hi w) …)              — a whole band, lo/hi may be #f
                                              (the catalogue's own row)"
  (append (map (lambda (f) (list (car f) (cdr f) #f 1.0)) floors)
          (map (lambda (c) (if (pair? (cdr c))
                               (list (car c) #f (cadr c) (cddr c))
                               (list (car c) #f (cdr c) 1.0)))
               caps)
          (map (lambda (i) (list (car i) (list (cadr i) (caddr i) (cadddr i)) #f (list-ref i 4))) insurance)
          bands))

;; Bioregion = ecological agent = SpatialThing container (playnet.typ §bioregion):
;; a scope inherits its shed's climate scenarios up the contained-in tree, the same
;; containment relation *frag-container* uses for the shed's regenerative envelope.
;; Generic mechanism (a registry + the upward walk), no data — knowledge files seed
;; real sheds. Loaded here so plan-scope can resolve scenarios from placement alone.
;; the containment registry + the upward walk — a module. module-use! imports the interface without
;; switching current-module, and unconditionally: an import is all-or-nothing,
;; so a (defined? 'scope-bioregion-scenarios) probe would skip the rest of the interface
;; on the strength of that one name being visible.

;; ── the grid, as the one dispatch ───────────────────────────────────────────
;; Every cell of (extent × window) routes to the table whose collector already
;; reads that scale. This procedure IS the grid: adding a scale means adding a
;; line here, not a table elsewhere, and a combination nobody had spelled before
;; (a container's per-period yield; a commons' lifetime total) is reachable
;; without new machinery. The tables stay as they were, so every existing call
;; site and every existing test reads exactly what it did.
(define (route-fragility! f)
  (let ((p (fragility-profile f))
        (k (fragility-key f))
        (w (fragility-window f)))
    ;; SIDE is honoured, never guessed: a floor is a LEVEL to hold, and only a
    ;; located good has a level. A floor-sided spec / container / commons would
    ;; be a band tiled per cell (the way *frag-spec* tiles a ceiling) — until
    ;; that is built it is an error here, not a ceiling by accident.
    (when (and (eq? (fragility-side f) 'floor) (not (eq? (fragility-kind f) 'good)))
      (error "a floor-sided fragility holds a LEVEL, and only a located good has one — extent:"
             (fragility-extent f)))
    (case (fragility-kind f)
      ((good)      (if (eq? (fragility-side f) 'floor)
                       (apply-repro-bands!                ; a level to HOLD: the good's band, floor with margin
                        (list (list k (list (car p) (cadr p) (caddr p)) #f (cadddr p))))
                       (hash-set! *frag-cap* k p)))      ; a limit on a DRAW: one cell, per period
      ((spec)      (if (eq? w 'horizon)
                       (hash-set! *frag-budget* k p)    ; that spec, summed over time
                       (hash-set! *frag-spec* k p)))    ; that spec, each period
      ((contained) (hash-set! *frag-container* k p))    ; its contents, at its own cell
      ((within)    (hash-set! *frag-within* k (list p (fragility-specs f) w
                                                    (fragility-level f))))
      (else (error "unknown fragility extent" (fragility-extent f))))))

;; Regenerating stocks (docs/planning + social-means.typ): a resource whose
;; CONDITION is a carried level — soil fertility, tool wear, an aquifer — drawn by
;; production, restored by regeneration, threaded period→period as a *storable*
;; good. The soil-condition recurrence generalised; a stock you may mine or tend.
;; Generic MECHANISM (a record + registry + flow-builders), no data.
;; the regenerating-stock record + registry + flow-builders — a module. module-use! imports the interface without
;; switching current-module, and unconditionally: an import is all-or-nothing,
;; so a (defined? 'register-regenerating-stock!) probe would skip the rest of the interface
;; on the strength of that one name being visible.

;; The comparator (docs/planning/solve/recipe-metabolism-barbell.md): a recipe's
;; response — per flow of its own, the curve of what its runs captured at each
;; stress delivered — read from its runs, never stored. Pure; the observer
;; adapter that assembles the runs lives governance-side (recipe-standing.scm).
;; A module, imported the way capacity.scm is: module-use! brings the interface
;; in WITHOUT switching current-module, so the rest of this engine still defines
;; into whichever module primitive-load'ed it. Unconditional — an import is
;; all-or-nothing, and a guard on one name being visible would skip the rest
;; on the strength of that one.
