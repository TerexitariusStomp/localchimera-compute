;;; counting.scm — the planned count: which stocks are counted, how often, and
;;; under which regime (docs/observation/capture.md §4).
;;;
;;; A count is inspection pointed at a quantity. solve/inspection.scm keeps a claim
;;; about a skill or a means fresh; this keeps a ledger figure true. The
;;; cadence is the lumpy-inspection interval formulas/cadence.scm already
;;; computes, T* = sqrt(2K / (D·κ)), read for a stock:
;;;
;;;   D  what the plan stakes on the figure: the good's crystallized labour,
;;;      hours per unit, times the quantity the figure answers for
;;;   κ  how fast the figure drifts: what counts have found the ledger off by,
;;;      as a share of what it holds, and a prior where nothing has been counted
;;;   K  what one count costs: the counter's hours
;;;
;;; ABC classification falls out as a consequence: a stock the plan leans on
;;; harder is counted more often, and a ledger that counts keep confirming is
;;; counted less. The class a row reports is a reading of its interval against
;;; the frequencies docs/observation/measure.md gives, four, two and one a year.
;;;
;;; The regime is a property of the run (docs/observation/observe-wiring.md §3):
;;;
;;;   announced    the custodian reads the commitment from the moment it is laid
;;;   undisclosed  the counter alone reads it until its window opens
;;;   random       undisclosed, its window drawn from a distribution everybody
;;;                knows by a draw anybody can reproduce afterwards
;;;
;;; A planned count's process names its regime and its target,
;;; count~<regime>~<resource-id>, so the terms ride every wire a process rides.
;;; The event a count lands names the technique alone, count~<regime>, and the
;;; reading fold keeps one cell per technique.
;;;
;;; Pure over numbers, strings and alists; the service assembles the rows.

(define-module (playnet planner formulas counting)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet planner formulas cadence) #:select (recert-interval-discrete))
  #:use-module ((playnet planner facts audit) #:select (audit-draw))
  #:use-module ((playnet planner facts agent-tags) #:select (tag-value))
  #:export (%count-prefix %count-regimes count-regime %count-blind-regimes %count-techniques %count-technique-prefix %count-skill %count-record-spec count-window-close
            count-run-process? count-contestable? count-base-id count-family-id?
            count-figure-tag count-figure count-spec-tag count-spec
            count-expected-tag count-expected
            %count-agreed-tag count-agreed? %count-tolerance
            count-record-id count-hours-id %contest-prefix contest-ballot-id
            count-of-tag count-target
            count-process count-process? count-process-regime count-process-target
            count-technique count-blind?
            stock-reliance drift-rate count-interval count-class
            count-row count-schedule count-window
            %count-hours-per-line %count-hours-per-visit count-hours))

;; A difference smaller than this is the ledger agreeing: the one tolerance of a
;; count, for the door, the adjustment and the observer's anchor.
;; ui/app/count-catalogue.ts carries the same number, generated from here.
(define %count-tolerance 1e-9)

(define %count-prefix "count~")
(define %count-regimes '("announced" "undisclosed" "random"))
;; the regimes whose counter states a figure before seeing the ledger's
(define %count-blind-regimes (delete "announced" %count-regimes))
;; how a person came by a count: an unplanned count's event names the technique
;; alone, count:<technique>
(define %count-techniques '("stated" "label" "photo"))
(define %count-technique-prefix "count:")
;; the skill a count's hours are worked under, and the record a run produces
(define %count-skill "skill-counting")
(define %count-record-spec "count-record")

;; ── the process grammar ──────────────────────────────────────────────────────

(define (count-regime x)
  "X when it names a regime, else the default, announced: the one reading of a
   door's optional regime."
  (if (and (string? x) (member x %count-regimes)) x "announced"))

(define (count-process regime rid)
  "The process of a planned count of RID under REGIME."
  (string-append %count-prefix (count-regime regime) "~" rid))

(define (count-process? proc)
  (and (string? proc) (string-prefix? %count-prefix proc)))

(define (%after-prefix proc)
  (and (count-process? proc) (substring proc (string-length %count-prefix))))

(define (count-process-regime proc)
  "The regime PROC names, or #f when PROC is no planned count. A count whose
   technique is its own name (count:stated) names no regime."
  (let* ((rest (%after-prefix proc))
         (cut  (and rest (string-index rest #\~)))
         (head (if cut (substring rest 0 cut) rest)))
    (and head (member head %count-regimes) head)))

(define (count-process-target proc)
  "The resource id PROC is a count of, or #f."
  (let* ((rest (%after-prefix proc))
         (cut  (and rest (string-index rest #\~))))
    (and cut (< (+ cut 1) (string-length rest))
         (member (substring rest 0 cut) %count-regimes)
         (substring rest (+ cut 1)))))

;; ── what a count leaves on the ledger, as one family ─────────────────────────
;; A count lands an adjustment (when it found a difference), a record and the
;; counter's hours (when a plan asked for it), and the containment cascade of
;; the adjustment when what was counted holds other things. The three are
;; named from the adjustment's id, so a contest of any one of them is a contest
;; of the count and settles all of them.

(define (count-run-process? proc)
  "PROC is the process a count's event carries: a technique's own name
   (count:stated) or a planned run's (count~regime[~target])."
  (and (string? proc)
       (or (string-prefix? %count-technique-prefix proc) (count-process? proc))))

(define (count-contestable? action output-of input-of)
  "An event of ACTION whose output-of is OUTPUT-OF and input-of INPUT-OF is a
   part of a count: its adjustment (raise or lower), its record (a produce) or
   the counter's hours (a work on the planned run)."
  (case action
    ((raise lower produce) (count-run-process? output-of))
    ((work)                (count-process? input-of))
    (else                  #f)))

;; the ballot a contest of an event opens: contest:<event id>, and for a count
;; the id of its adjustment whichever of its parts is named
(define %contest-prefix "contest:")

(define (contest-ballot-id event-id count?)
  "The ballot of the contest of EVENT-ID: for a count (COUNT? true) named from
   its adjustment, whichever of its parts EVENT-ID is."
  (string-append %contest-prefix (if count? (count-base-id event-id) event-id)))

;; a count's record names what it counts by a tag, count-of:<resource id>
(define (count-of-tag resource-id)
  "The classification tag that names the stock a count record counts."
  (tagged "count-of" resource-id))

(define (count-target inventoried-as tags)
  "The resource id a count event is of: the stock it lands on, else the one its
   count-of tag names; #f when neither."
  (or inventoried-as (stated tags "count-of")))

;; What a count's events state rides their classification as "key:value" tags,
;; read by the one reader of such tags (agent-tags.scm tag-value): the figure it
;; found, the range the plan expected, the spec of the stock it counted.
(define (stated tags key) (tag-value (or tags '()) key))
(define (tagged key value) (string-append key ":" value))

;; counted:<figure> <unit>. The adjustment's quantity is a difference from the
;; ledger of its day; the figure is what was seen, and it stands whatever the
;; ledger later says of that day.
(define (count-figure-tag counted unit)
  "The classification tag that states the figure a count found."
  (tagged "counted" (string-append (number->string (exact->inexact counted)) " " unit)))

(define (count-figure tags)
  "The figure a count event's TAGS state, as (quantity . unit), or #f."
  (let* ((body (stated tags "counted"))
         (i    (and body (string-index body #\space)))
         (q    (and body (string->number (if i (substring body 0 i) body)))))
    (and q (cons q (if i (substring body (+ i 1)) "")))))

;; expected:<low> <high> <unit>: the range the plan expected of the stock when it
;; was counted, a fact about the plan's state that day, stated beside the figure
;; so both stay readable whatever is later voided around them
(define (count-expected-tag low high unit)
  "The classification tag that states the range the plan expected of a stock."
  (tagged "expected" (string-append (number->string (exact->inexact low)) " "
                                    (number->string (exact->inexact high)) " " unit)))

(define (count-expected tags)
  "The range a count event's TAGS state the plan expected, as (low high . unit),
   or #f."
  (let* ((parts (string-split (or (stated tags "expected") "") #\space))
         (low   (string->number (car parts)))
         (high  (and low (pair? (cdr parts)) (string->number (cadr parts)))))
    (and low high (cons* low high (string-join (cddr parts) " ")))))

;; count-spec:<spec> names the spec of the stock a count's record counted, and
;; count-agreed says the figure agreed with the ledger, so a reader of readings
;; places the count under the stock's spec from the record alone
(define %count-agreed-tag "count-agreed")

(define (count-spec-tag spec)
  "The classification tag that names the spec of the stock a count counted."
  (tagged "count-spec" spec))

(define (count-spec tags)
  "The stock's spec a count record's TAGS name, or #f."
  (stated tags "count-spec"))

(define (count-agreed? tags)
  "TAGS are those of the record of a count that agreed with the ledger."
  (and (member %count-agreed-tag (or tags '())) #t))

(define %count-record-suffix "-record")
(define %count-hours-suffix "-hours")
(define %count-family-suffixes (list %count-record-suffix %count-hours-suffix))

(define (count-record-id base)
  "The id of the record a count lands, named from the adjustment's id BASE."
  (string-append base %count-record-suffix))

(define (count-hours-id base)
  "The id of the counter's hours a count lands, named from BASE."
  (string-append base %count-hours-suffix))

(define (count-base-id id)
  "The adjustment's id a count event's id is named from: the id itself, or the
   id with the record's or the hours' suffix taken off."
  (or (any (lambda (sfx)
             (and (string-suffix? sfx id)
                  (> (string-length id) (string-length sfx))
                  (substring id 0 (- (string-length id) (string-length sfx)))))
           %count-family-suffixes)
      id))

(define (count-family-id? base id)
  "ID is BASE, its record or its hours. The containment cascade under the
   adjustment is the observer's: it goes back with the adjustment
   (observation/observer.scm standing-of)."
  (or (equal? id base)
      (any (lambda (sfx) (equal? id (string-append base sfx))) %count-family-suffixes)))

(define (count-technique proc)
  "The technique a planned count's event names: the process with its target
   left off, so every count under one regime folds into one cell."
  (let ((regime (count-process-regime proc)))
    (and regime (string-append %count-prefix regime))))

(define (count-blind? proc)
  "A count the custodian does not read ahead is counted blind: the counter
   states a figure before seeing the ledger's."
  (let ((regime (count-process-regime proc)))
    (and regime (member regime %count-blind-regimes) #t)))

;; ── what one count costs ─────────────────────────────────────────────────────
;; A visit to the place, and a line for each thing counted there. Minutes a
;; line is the manual technique's own pace; the visit is the walk and the door.

(define %count-hours-per-visit 0.1)
(define %count-hours-per-line 0.05)

(define (count-hours lines)
  "The counter's hours for one visit counting LINES lines."
  (+ %count-hours-per-visit (* %count-hours-per-line (max 1 lines))))

;; ── the cadence ──────────────────────────────────────────────────────────────

(define* (stock-reliance price onhand #:key (draw 0.0) (default-price 1.0))
  "D: the hours the plan stakes on the figure. PRICE is the good's crystallized
   labour in hours per unit (#f or infinite where no recipe prices it: weighed
   at DEFAULT-PRICE), over the larger of what the plan draws a period and what
   the ledger says is there."
  (let ((p (if (and (number? price) (finite? price) (> price 0.0)) price default-price))
        (q (max (if (number? draw) draw 0.0) (if (number? onhand) onhand 0.0) 0.0)))
    (* p q)))

(define* (drift-rate n mean-abs onhand #:key (prior 0.05))
  "κ: the share of the figure a period's drift moves. With N counts having
   found the ledger off by MEAN-ABS on average, the share is that over what the
   ledger holds, bounded by one; with none, the PRIOR: a ledger nobody has
   counted is taken to drift a twentieth a period."
  (if (and (number? n) (> n 0) (number? mean-abs) (> mean-abs 0.0))
      (let ((base (max (if (number? onhand) onhand 0.0) mean-abs)))
        (max prior (min 1.0 (/ mean-abs base))))
      prior))

(define* (count-interval reliance kappa hours
                         #:key (period-span 604800.0) (shortest 86400.0)
                               (longest (* 52 604800.0)))
  "The seconds between counts: T* periods of PERIOD-SPAN, held between a day
   and a year. A stock the plan stakes nothing on is counted at the longest
   interval, so every figure on the books is looked at within the year."
  (let ((t (recert-interval-discrete reliance kappa hours)))
    (if (not t) longest
        (max shortest (min longest (* t period-span))))))

(define (count-class interval)
  "The interval read against the frequencies of ABC cycle counting: A counted
   four times a year or more, B twice, C once."
  (let ((quarter (* 13 604800.0)) (half (* 26 604800.0)))
    (cond ((<= interval quarter) 'A)
          ((<= interval half) 'B)
          (else 'C))))

;; ── the window of one run ────────────────────────────────────────────────────

(define* (count-window-close opens interval #:key (shortest 86400.0))
  "When an offered count's window closes: a quarter of the interval after it
   OPENS, a day at the least, so a count asked of someone stays theirs to take
   for as long as the next one is far off."
  (+ opens (max shortest (/ interval 4.0))))

(define* (count-window last interval regime rid #:key (now 0) (cycle #f))
  "When the next count of RID is due, in epoch seconds. LAST is when it was
   last counted (#f: never, so it is due NOW). Announced and undisclosed runs
   fall one interval after the last. A random run falls between half an
   interval and one and a half after, by audit-draw over the target and the
   cycle: the mean is the interval, the distribution is public, and the draw
   is reproduced by anyone who asks afterwards."
  (cond
   ((not last) now)
   ((equal? regime "random")
    (let* ((c (or cycle (inexact->exact (floor (/ last (max 1.0 interval))))))
           (u (audit-draw "count" rid c)))
      (+ last (* interval (+ 0.5 u)))))
   (else (+ last interval))))

;; ── the schedule ─────────────────────────────────────────────────────────────

(define* (count-row stock #:key (now 0) (period-span 604800.0) (regime "announced")
                    (prior 0.05))
  "One stock's place in the schedule. STOCK is an alist: id, name, spec,
   onhand, unit, place, and where known price (hours per unit), draw (units a
   period), drift-n and drift-mean (the reading fold's drift), last-count
   (epoch seconds), lines (things counted on the visit). Returns the stock's
   own fields with reliance, kappa, hours, interval, class, due-at and
   overdue? beside them."
  (let* ((ref (lambda (k) (assq-ref stock k)))
         (onhand (or (ref 'onhand) 0.0))
         (lines  (or (ref 'lines) 1))
         (hours  (count-hours lines))
         (d      (stock-reliance (ref 'price) onhand #:draw (or (ref 'draw) 0.0)))
         (k      (drift-rate (ref 'drift-n) (ref 'drift-mean) onhand #:prior prior))
         (iv     (count-interval d k hours #:period-span period-span))
         (due    (count-window (ref 'last-count) iv regime (or (ref 'id) "") #:now now)))
    (append stock
            `((reliance . ,d) (kappa . ,k) (hours . ,hours)
              (interval . ,iv) (class . ,(count-class iv))
              (regime . ,regime)
              (due-at . ,due) (overdue? . ,(<= due now))))))

(define* (count-schedule stocks #:key (now 0) (period-span 604800.0)
                         (regime "announced") (prior 0.05))
  "Every stock's row, soonest due first; among stocks due together, the one
   the plan stakes most on."
  (sort (map (lambda (s) (count-row s #:now now #:period-span period-span
                                    #:regime regime #:prior prior))
             stocks)
        (lambda (a b)
          (let ((da (assq-ref a 'due-at)) (db (assq-ref b 'due-at)))
            (if (= da db)
                (> (assq-ref a 'reliance) (assq-ref b 'reliance))
                (< da db))))))
