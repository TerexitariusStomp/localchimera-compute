;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; capacity.scm — a holding, read as the capacity it renders.
;;;
;;; ── FOUR THINGS, ONE WORD ────────────────────────────────────────────────────
;;; "Capacity" names four distinct quantities in economic planning, and the shape of
;;; a solve depends on telling them apart. The vocabulary this codebase holds to:
;;;
;;;   a STOCK      what exists.  `3 each` of oven, `1 each` of Lastenrad.
;;;                Dimension: things.  Lives on a holding's measure.
;;;
;;;   a RATE       a stock, stated as how much it renders per unit time.
;;;                `200 seat-hours/day`.  Dimension: things again — seat-hours per
;;;                hour IS a number of seats — which is exactly why one conversion
;;;                covers both, with the denominator as the only difference. A rate
;;;                is a stock that says its own averaging window; the codebase reads
;;;                one from a quotient unit (`unit-rate?`, utils/units.scm).
;;;
;;;   a CAPACITY   a FLOW: what a stock renders over a span. `72 oven-hours`.
;;;                Dimension: thing·hours.  This is what `Svc|spec` is denominated
;;;                in, what a `use` flow draws, and what a `*cap*` entry holds. It is
;;;                the ONLY sense in which this file says "capacity".
;;;
;;;   a BUDGET     a capacity that is FUNGIBLE across a set of cells: `200 hours,
;;;                spendable any time this month`. Same dimension as a capacity,
;;;                constrained differently — one Σ bar over many cells rather than a
;;;                ceiling at each. Carried by a supplier bundle's shared bar
;;;                (planner.scm `*supplier-bundles*`), not by `*cap*`.
;;;
;;; The rule: a sentence that says "capacity" without a span in it means a stock or a
;;; rate, and should say so. A HOLDING is a stock, a rate, or a budget; a LIMIT is a
;;; ceiling or a bar; a CAPACITY is what a holding renders over a span, at a cell.
;;;
;;; A holding's UNIT says which of the three it is, and nothing else has to:
;;;
;;;   `3 each`          a stock  — renders itself for every hour it is there
;;;   `200 hours/day`   a rate   — renders its own share of the hours on offer
;;;   `200 hours`       a budget — a total, spendable anywhere in its window
;;;
;;; The first two become a per-cell capacity (`holding-capacity`); the third is one Σ
;;; bar over its window (`holding-budget?`), because a total that regenerates nowhere
;;; cannot be a ceiling at each cell without being granted afresh at every one.
;;;
;;; Worth naming because the slippage is not idle. A stock read as a capacity rations
;;; a means' substance instead of its time (a headcount where the solve wants
;;; oven-hours). A rate read as a capacity applies the span twice, or not at all. And
;;; "uncapped" is a fifth thing again — the ABSENCE of a bound, which for a
;;; structural `Svc|` pool means unbounded rather than zero (`spec-skips-balance?`).
;;;
;;; ── WHY IT LIVES HERE ────────────────────────────────────────────────────────
;;; THE stock/rate→capacity conversion, and the only one. Three places need the same
;;; answer, and a second derivation drifts from the first by a factor of the period,
;;; silently:
;;;
;;;   the SOLVE            — ingest-stock! bounds `Svc|spec` off every holding
;;;   a scope's CAPS TABLE — held-svc-caps (below)
;;;   GOVERNANCE           — a socialization grant's ceiling (socialization.scm)
;;;
;;; Needs only `<measure>` and the unit algebra, so it loads beside the schemas and
;;; is reachable from the umbrella module and from the primitive-load engine alike.
;;;
;;; A module, imported beside schemas.scm: it is the one reading either side loads, so
;;; whichever side loads first defines it once.

(define-module (localchimera vf formulas capacity)
  #:use-module ((localchimera vf facts located) #:select (svc-good lg cell))
  #:use-module (localchimera utils units)
  #:use-module (localchimera vf schemas)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:export (holding-budget? holding-capacity svc-cap-key svc-eco-caps held-svc-caps))

(define (holding-budget? m)
  "Is this holding a BUDGET — a total, fungible over its window, rather than a rate?

   A bare quantity of TIME says it: `200 hours` of service is two hundred hours,
   full stop. It names no denominator because it HAS none — nothing regenerates,
   and spending it in one afternoon or across a month is the same two hundred
   hours. That is a budget, and the only honest reading of the shape.

   `200 hours/day` is the other thing: a rate, a flow limit, two hundred hours in
   EVERY day and yesterday's unspent hours gone. The presence of a denominator is
   the whole of the difference, so the two are told apart by the unit and nothing
   else has to be declared.

   The two are bounded differently — a rate is a ceiling at each cell, a budget one
   Σ bar across them (planner.scm `*container-pools*`) — which is why the question
   is asked here rather than folded into `holding-capacity`: a budget has no per-cell
   capacity to compute."
  (let ((u (and m (measure-has-unit m))))
    (and u (not (unit-rate? u)) (eq? 'time (unit->substance u)))))

(define (holding-capacity q m r hours)
  "The CAPACITY a holding of Q renders over the HOURS it stands available — a flow,
   in unit·hours. The whole of the stock/rate→capacity conversion, in the one form
   both readings of a holding share.

     a STOCK — `3 each` — renders itself for every hour it is there, so three ovens
     over eight available hours are twenty-four oven-hours.

     a RATE — `200 seat-hours/week` — states its own denominator, so it renders that
     share of the hours on offer: 200·(8/168) over those same eight.

   Both are `q · hours / D`, with D = 1 for a stock and the rate's own denominator
   otherwise, which is why the conversion has one form and no branch. The two agree
   at the dimension: seat-hours per hour is a number of seats, so a rate is a stock
   that carries its own averaging window, and D is the whole of the difference.

   Written as one ratio rather than a per-hour rate multiplied back up, so a window
   covering a whole denominator cancels EXACTLY — a full day of `200 hours/day` is
   200, not 199.99999999999997, and a quantity nobody rounded is one an assertion
   can state.

   Both readings sum the same over any partition of a span, because the hours a
   window offers are additive over a partition while D belongs to the holding. That
   is what makes a capacity a fact about the means instead of a fact about how finely
   the scope chose to slice its periods — the length of a period is a governed choice
   (see `*period-length*`), so a number that moves with it is not a quantity of
   anything.

   A bare quantity of TIME — `200 hours`, no denominator — is neither: it is a
   BUDGET, one total over its window, and has no per-cell capacity to return. Ask
   `holding-budget?` first and bound it with a single bar. Reading the solve's own
   period as its denominator instead is exactly what would make such a holding's
   total depend on the granularity."
  (let ((u (and m (measure-has-unit m))))
    (cond
     ;; no measure at all — a LIVE availability reading is a level, not a declared
     ;; holding, so it reads as a stock like any other
     ((not u) (* q hours))
     ((unit-rate? u)
      (let* ((parts (unit-rate-parts u))
             (num   (convert-unit q (car parts)))            ; the numerator in ITS base
             (d     (convert-unit 1.0 (cdr parts))))         ; the denominator, in hours
        (if (> d 0.0) (* num (/ hours d)) 0.0)))
     ;; a BUDGET has no per-cell capacity — it is one total over its whole window —
     ;; so asking for one is a caller that skipped `holding-budget?`
     ((eq? 'time (unit->substance u))
      (error (string-append
              "a budget has no per-period capacity: resource "
              (or (economic-resource-id r) "?")
              " holds " (number->string q) " " u
              ", a total rather than a rate. Bound it with one bar over its window"
              " (holding-budget?), or state a rate — " u "/day, " u "/week — if it"
              " regenerates each period.")))
     (else (* q hours)))))

;;; ── a means' service as located eco-caps ────────────────────────────────────

;; SERVICE-CAPACITY facts → located eco-caps.  A durable `use`d in a process draws
;; its per-period SERVICE good `Svc|spec`; that service is capped through the sole
;; capacity channel — an eco-cap on `Svc|spec` (ingest-located: "eco-caps and
;; ingested stock are the only caps").  This turns per-period service-capacity
;; FACTS = ((spec place per-period-capacity) …) into the `Svc|spec#place@t`
;; eco-caps the solve consumes, one per period.  It owns the located-good FORMAT
;; (so no caller re-encodes `Svc|…#…@…`) while knowing nothing about *why* a
;; durable has capacity — a commune-owned means and a temporarily-socialized
;; private one both flow through here; the socialization semantics (which grants
;; are live, whose custody) live entirely on the governance side, one dependency
;; layer up.  Pure and record-free (built from strings), so it serves both the
;; convex core and that governance caller.  Sits beside `custody-cred-live?`
;; because the two compose: that predicate GATES which service facts are live, this
;; MAPS them to caps — the instrument twin of the skill→labour path.
(define (svc-cap-key spec place t)
  "The located key of a spec's SERVICE at PLACE in period T. The one encoding of
   `Svc|spec#place@t`, so a caller that computes a capacity per period — one whose
   availability window opens for part of the horizon — still spells the key here."
  (lg (svc-good spec) (cell place t)))

(define (svc-eco-caps facts periods)
  (append-map
   (lambda (f)
     (let ((spec (car f)) (place (cadr f)) (cap (caddr f)))
       (map (lambda (t)
              ;; a capacity may be one number for the horizon or a reading PER
              ;; PERIOD: an availability window makes a means present for eight
              ;; hours of one period and none of the next, and a flat number
              ;; cannot say that. A procedure is asked for each period.
              (cons (svc-cap-key spec place t) (if (procedure? cap) (cap t) cap)))
            periods)))
   facts))

;; HELD DURABLES → the same located eco-caps, without stating the number twice.
;;
;; A durable's own stock caps the BARE good; the per-period SERVICE good a `use`
;; draws is capped only through the channel above. So a fleet, a pass or a
;; network seeded as a resource and then left out of #:eco-caps is a means whose
;; service is FREE: the pool is a structural one, drawn without bound. Declaring
;; the number a second time in a caps table is how that gets papered over, and
;; two declarations of one physical fact drift.
;;
;; This reads the fact off the holding itself: what a commune HAS is what its
;; service pool is worth. A count is worth itself for every hour it stands there —
;; one Lastenrad is twenty-four bike-hours across a day — and a rate states its own
;; denominator (`200 hours/day` of a network). Both readings are `holding-capacity`,
;; the same conversion the solve applies to the same holding, so a caps table and an
;; ingested stock cannot disagree about what a thing can do.
(define* (held-svc-caps resources periods #:key (specs '()) (place-of-resource #f)
                                                (hours-of #f))
  "Located `Svc|spec` caps derived from what is HELD: ((spec place onhand) …) fed
   through svc-eco-caps. SPECS restricts it to those specs (default: every held
   spec — a spec no recipe `use`s simply never draws its pool). Resources with no
   place, or none on hand, cap nothing.

   A pool is what a place holds ALTOGETHER, so holdings of one spec at one place
   are summed. They have to be: eco-caps reach the engine as a hash, so two bikes
   sent as two facts of 1.0 arrive as a cap of 1.0 — a second Lastenrad that
   silently carries nothing.

   HOURS-OF `(resource period → hours)` says how long a holding stands available,
   and is REQUIRED, because a capacity is what a stock renders over time: without
   it the number here would be a headcount where the solve's own is oven-HOURS, and
   the two differ by a factor of the period — the caller passes the engine's
   `resource-window-hours` (exported from `(localchimera scope live)`) so both read the
   one answer. The conversion itself is `holding-capacity` (utils/capacity.scm),
   shared with the solve rather than restated here."
  (unless hours-of
    (error (string-append
            "held-svc-caps needs #:hours-of: a capacity is what a holding renders"
            " over the hours it stands available, so pass the engine's"
            " resource-window-hours — (localchimera scope live) exports it — rather"
            " than let a headcount pass for a capacity.")))
  (svc-eco-caps
   (fold-right
    (lambda (r acc)
      (let* ((spec (economic-resource-conforms-to r))
             (place (if place-of-resource
                        (place-of-resource r)
                        (economic-resource-current-location r)))
             (m (economic-resource-onhand-quantity r))
             (q (and m (measure-has-numerical-value m)))
             ;; per PERIOD: the window may open for part of the horizon, so the
             ;; capacity is a reading rather than a number (svc-eco-caps asks it)
             (cap-at (and q (lambda (t) (holding-capacity q m r (hours-of r t))))))
        (if (and spec place q (> q 0.0)
                 (or (null? specs) (member spec specs)))
            (let ((pool (find (lambda (f) (and (equal? spec (car f)) (equal? place (cadr f))))
                              acc)))
              (if pool
                  ;; two holdings of one spec at one place are one pool, summed
                  ;; period by period — their windows need not agree
                  (let ((prev (caddr pool)))
                    (set-car! (cddr pool) (lambda (t) (+ (prev t) (cap-at t))))
                    acc)
                  (cons (list spec place cap-at) acc)))
            acc)))
    '() resources)
   periods))
