;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; pools/reading-fold.scm — ^reading-pool: the scope fold of readings.
;;;
;;; docs/observation/observe-wiring.md §4: several sources observe one target
;;; and their readings stand side by side, keyed by who read and how, combined
;;; only when read. This is `^fold-node` (vf/aggregation/fold-node.scm) with a
;;; reading's three pieces, the sibling of credit-fold.scm and voice-fold.scm:
;;;
;;;   monoid   keyed merge, one cell per (spec process action unit nominal scope):
;;;              what was read, by which technique (the process is the
;;;              technique, observe.md), which act, in what unit, against
;;;              which mapped figure (#f for a plain reading), by which SCOPE
;;;              — the scope is the source, so NO PERSON IS VISIBLE ABOVE THEIR
;;;              OWN SCOPE, as voice's rule has it. A produce, consume or use
;;;              cell holds FLOW quantities, what the technique saw move. A
;;;              raise or lower cell holds ADJUSTMENTS, signed: ValueFlows'
;;;              raise and lower are the difference a count found between the
;;;              world and the ledger (docs/valueflows/concepts/actions.md),
;;;              +q for raise, −q for lower, so the cell's mean |q| is the
;;;              count's drift from the record (measure.md §1, MAE) and its
;;;              sum the net adjustment. The count itself is the ledger's
;;;              on-hand after the adjustment (the observer's resource).
;;;            cell = (n sum min max at latest): how many readings, their sum
;;;              and extrema, and the freshest with its instant. Combine adds
;;;              n and sum, takes the extrema, keeps the later `at`: associative
;;;              and commutative, so the tree folds in any order (the suite
;;;              pins it on random cells), and one cell per key per scope keeps
;;;              the total bounded — the history is the event log's
;;;   writes   reading-changed: re-derive this scope's own cells from its
;;;            observer (`fold-by` over the quantity-bearing events) and the
;;;            standing contrary observations its rail holds (OBSERVED-OF,
;;;            injected: the planner imports no governance)
;;;   reads    readings — spec → its cells, every technique and scope apart:
;;;              the multi-instance view (NGSI-LD's datasetId, ngsi-ld.md)
;;;            latest — spec → the freshest FLOW reading over every source
;;;            drift — spec → (n mean-abs net) over the adjustment cells: how
;;;              far counts have found the ledger off, and which way
;;;            contrary — ((process action nominal reading) …), what the solve
;;;              takes (solve/robust.scm observed-shocks), one row per cell at its
;;;              mean: the fold's cautious readings averaged
;;;            sources — spec → how many scopes have read it
;;;   history  readings-between: what every source reported of a spec between two
;;;            instants, one row per reading, keyed exactly as the fold's cells
;;;            are (spec technique action unit nominal scope) and in time order:
;;;            the fold's rows BEFORE folding. The fold is this history's
;;;            reduction, so `window-fold` over a window's rows is what the fold
;;;            would have said from those readings alone (ngsi-ld.md: the
;;;            temporal query, built from the event log the fold already reads);
;;;            the rail's standing contrary observations are rows of it too,
;;;            through the one reader the fold takes them by (`contrary-rows`)
;;;
;;; A contrary observation is a reading whose key carries the nominal it
;;; contradicts, and the value folded is the CAUTIOUS reading (a produce read
;;; at most the nominal, a draw or hours at least it — shocks.scm
;;; cautious-reading, the one the solve's own observed-shocks takes); so the
;;; cell's mean is observed-shocks' mean exactly,
;;; and a flattering reading folds as the nominal and moves nothing.

(define-module (playnet pools reading-fold)
  #:use-module ((playnet utils units) #:select (%count-unit))
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (playnet vf aggregation fold-node)
  #:use-module ((playnet vf formulas shocks) #:select (cautious-reading))
  #:re-export (cautious-reading)
  #:use-module ((playnet vf schemas) #:select (economic-event-id economic-event-action economic-event-input-of economic-event-output-of economic-event-resource-conforms-to economic-event-resource-quantity economic-event-has-beginning economic-event-has-point-in-time economic-event-resource-classified-as measure-has-numerical-value measure-has-unit))
  #:use-module ((playnet vf formulas actions) #:select (*stock-moving-actions* *adjustment-actions* *flow-actions*))
  #:use-module ((playnet vf formulas counting) #:select (count-agreed? count-spec count-figure count-expected))
  #:use-module ((playnet observation observer) #:select (cascade-parent-id event-stamps))
  #:export (%reading-actions reading-combine reading-monoid
            reading-key reading-cell contrary-rows readings-between window-fold
            scope-own-readings ^reading-pool
            reading-reads reading-writes wire-reading-node!
            readings-of latest-of drift-of contrary-of sources-of scope-subtree-readings cell->alist
            node-readings-reply readings-between-reply))

;; the events that MOVE a stock of a spec — what a technique's `produce` lands as,
;; what a person's log entry lands as (service.scm do-log-observe), what a count
;; that found the ledger off lands as — read off the ValueFlows action table
;; (schemas.scm *stock-moving-actions*), so a new action is a reading by construction
(define %reading-actions *stock-moving-actions*)
(define (flow-cell? c) (and (not (list-ref (car c) 4)) (memq (list-ref (car c) 2) *flow-actions*)))   ; a plain flow: no nominal
(define (adjustment-cell? c) (memq (list-ref (car c) 2) *adjustment-actions*))

;; ── the cell, and its combine ───────────────────────────────────────────────
(define (reading-cell q at)
  "One reading Q at instant AT as a cell: (n sum min max at latest)."
  (list 1 q q q at q))

(define (reading-combine a b)
  "Two cells of one key as one: counts and sums add, the extrema widen, the
   later instant's reading is the freshest (ties go to the larger reading, so
   the combine is commutative)."
  (let ((a-at (list-ref a 4)) (b-at (list-ref b 4)))
    (list (+ (car a) (car b))
          (+ (cadr a) (cadr b))
          (min (caddr a) (caddr b))
          (max (cadddr a) (cadddr b))
          (if (string<? a-at b-at) b-at a-at)
          (cond ((string<? a-at b-at) (list-ref b 5))
                ((string<? b-at a-at) (list-ref a 5))
                (else (max (list-ref a 5) (list-ref b 5)))))))

(define reading-monoid (keyed-monoid reading-combine))

;; ── this scope's OWN cells ──────────────────────────────────────────────────
(define (agreed-count ev)
  "For the record of a count that agreed with the ledger: (spec . unit), the
   counted stock's spec and the unit of the figure found. #f for any other
   event."
  (let ((tags (economic-event-resource-classified-as ev)))
    (and (count-agreed? tags)
         (let ((spec (count-spec tags)) (fig (count-figure tags)))
           (and spec (cons spec (if fig (cdr fig) %count-unit)))))))

(define (reading-key ev)
  "(spec process action unit #f) for an event with a quantity of a spec; #f
   for one with neither. The process is the technique that produced the
   reading; an event with none is a bare statement (the log door). Two kinds
   of event are placed by what they are: a count that agreed with the ledger
   reads as an adjustment of nothing on the stock's spec, so the drift counts
   every count; and an event of a containment cascade is the consequence of
   the event it hangs from and is no reading of its own."
  (let ((q (economic-event-resource-quantity ev))
        (spec (economic-event-resource-conforms-to ev))
        (agreed (agreed-count ev)))
    (cond
     ((cascade-parent-id (economic-event-id ev)) #f)
     (agreed (list (car agreed) (economic-event-output-of ev) 'raise (cdr agreed) #f))
     (else
      (and q spec
           (list spec
                 (or (economic-event-input-of ev) (economic-event-output-of ev))
                 (economic-event-action ev)
                 (or (measure-has-unit q) %count-unit)
                 #f))))))

(define (unexplained ev)
  "For the adjustment of a count made against the plan's expectation: the part
   of its difference the plan does not account for, signed as the adjustment is.
   The figure the count found inside the range the plan expected is a ledger
   that lagged its unlogged flows, and nothing is off; short of the range or past
   it, the shortfall or excess is. #f for any other event."
  (let ((tags (economic-event-resource-classified-as ev)))
    (and (memq (economic-event-action ev) *adjustment-actions*)
         (let ((fig (count-figure tags)) (range (count-expected tags)))
           (and fig range
                (let ((counted (car fig)) (low (car range)) (high (cadr range)))
                  (cond ((< counted low) (- counted low))
                        ((> counted high) (- counted high))
                        (else 0.0))))))))

(define (event-reading-cell ev)
  "The event's quantity as a cell: a flow as it stands, an adjustment signed
   (a lower is a negative difference), an agreeing count a difference of
   nothing, and a count made against the plan's expectation the part of its
   difference the plan does not account for."
  (let ((q (exact->inexact (measure-has-numerical-value (economic-event-resource-quantity ev)))))
    (reading-cell (cond ((agreed-count ev) 0.0)
                        ((unexplained ev))
                        ((eq? (economic-event-action ev) 'lower) (- q))
                        (else q))
                  (or (and=> (event-stamps ev) car) ""))))

(define (contrary-rows observed scope-id)
  "The rail's standing contrary observations OBSERVED, ((spec process action
   nominal reading at said) …), as rows (key . cell): each keyed by the nominal
   it contradicts, the value the CAUTIOUS reading (what the solve takes), one
   reading each. The one reader of a contrary observation's shape, for the fold
   and the history alike."
  (filter-map
   (lambda (r)
     (let ((spec (list-ref r 0)) (process (list-ref r 1)) (action (list-ref r 2))
           (nominal (list-ref r 3)) (reading (list-ref r 4)) (at (list-ref r 5)))
       (and (string? process) (symbol? action) (real? nominal) (real? reading) (> nominal 0.0)
            (cons (list spec process action "" (exact->inexact nominal) scope-id)
                  (reading-cell (exact->inexact (cautious-reading action nominal reading))
                                (if (string? at) at ""))))))
   (or observed '())))

(define (scope-own-readings scope-root scope-id observed-of)
  "This scope's cells: its observer's quantity-bearing events folded by
   `fold-by` under `reading-key`, and the standing contrary observations
   OBSERVED-OF : scope-id → ((spec process action nominal reading at said) …)
   hands back, each keyed by the nominal it contradicts. Every key ends in
   SCOPE-ID; no cell names a person."
  (let* ((obs ($ scope-root 'observer))
         (own (map (lambda (kv) (cons (append (car kv) (list scope-id)) (cdr kv)))
                   ($ obs 'fold-by %reading-actions reading-key event-reading-cell reading-combine))))
    (merge-by-key reading-combine '() (append own (contrary-rows (and observed-of (observed-of scope-id)) scope-id)))))

;; ── the history: the same rows, before they fold ────────────────────────────
(define* (readings-between events spec #:key (since #f) (until #f) (scope-id "") (technique #f) (contrary #f))
  "What every source reported of SPEC among EVENTS (the observer's, chronological)
   and among CONTRARY, the rail's standing contrary observations in the shape
   `contrary-rows` reads, from SINCE up to and excluding UNTIL, ISO-8601
   instants (#f leaves an end open; a reading with no instant falls inside
   only an open window): one row per reading, (key . cell) keyed as the fold's
   cells are with SCOPE-ID as the source and n = 1, in time order. TECHNIQUE
   narrows to one process."
  (define (inside? at)
    (if (string-null? at)
        (and (not since) (not until))
        (and (or (not since) (string<=? since at)) (or (not until) (string<? at until)))))
  (define (wanted? row)                 ; SPEC's, this TECHNIQUE's, inside the window
    (and (equal? spec (car (car row)))
         (or (not technique) (equal? technique (cadr (car row))))
         (inside? (list-ref (cdr row) 4))))
  (let ((rows (filter wanted?
                      (append (filter-map (lambda (ev)
                                            (let ((k (reading-key ev)))
                                              (and k (memq (economic-event-action ev) %reading-actions)
                                                   (cons (append k (list scope-id)) (event-reading-cell ev)))))
                                          events)
                              (contrary-rows contrary scope-id)))))
    (sort rows (lambda (a b) (string<? (list-ref (cdr a) 4) (list-ref (cdr b) 4))))))

(define (window-fold rows)
  "ROWS of `readings-between` folded: what the fold says from these readings alone."
  (merge-by-key reading-combine '() rows))

;; ── the reads, over the total ───────────────────────────────────────────────
(define (readings-of cells spec)
  "SPEC's cells, every technique, act, nominal and scope apart."
  (filter (lambda (c) (equal? (caar c) spec)) cells))

(define (latest-of cells spec)
  "The freshest FLOW reading of SPEC over every source: (reading at unit scope),
   or #f. An adjustment is a difference, never a reading of the spec."
  (let ((rs (filter flow-cell? (readings-of cells spec))))
    (and (pair? rs)
         (let ((c (fold (lambda (c best)
                          (if (or (not best) (string<? (list-ref (cdr best) 4) (list-ref (cdr c) 4))) c best))
                        #f rs)))
           (list (list-ref (cdr c) 5) (list-ref (cdr c) 4) (list-ref (car c) 3) (list-ref (car c) 5))))))

(define (drift-of cells spec)
  "(n mean-abs net) over SPEC's adjustment cells: how many counts there were
   (one that agreed is an adjustment of nothing), how far they found the
   ledger off on average, and the net direction. (0 0.0 0.0) with no count. A cell is one action, so its readings share a
   sign and Σ|cell sum| / n is the mean of |q| exactly."
  (let* ((as (filter adjustment-cell? (readings-of cells spec)))
         (n (apply + (map (lambda (c) (car (cdr c))) as)))
         (net (apply + (map (lambda (c) (cadr (cdr c))) as)))
         (abs-sum (apply + (map (lambda (c) (abs (cadr (cdr c)))) as))))
    (list n (if (zero? n) 0.0 (/ abs-sum n)) (exact->inexact net))))

(define (contrary-of cells)
  "((process action nominal reading) …): every cell read against a nominal,
   at its mean cautious reading — the rows solve/robust.scm observed-shocks takes."
  (filter-map (lambda (c)
                (let ((k (car c)) (v (cdr c)))
                  (and (list-ref k 4)
                       (list (list-ref k 1) (list-ref k 2) (list-ref k 4) (/ (cadr v) (car v))))))
              cells))

(define (cell->alist c)
  "One cell as an alist: the key's fields and the value's, named — the one place
   the cell's layout is read out for a wire."
  (let ((k (car c)) (v (cdr c)))
    `((spec . ,(list-ref k 0)) (technique . ,(or (list-ref k 1) "")) (action . ,(symbol->string (list-ref k 2)))
      (unit . ,(list-ref k 3)) (nominal . ,(list-ref k 4)) (source . ,(list-ref k 5))
      (n . ,(list-ref v 0)) (sum . ,(list-ref v 1)) (min . ,(list-ref v 2)) (max . ,(list-ref v 3))
      (at . ,(list-ref v 4)) (latest . ,(list-ref v 5)))))

(define (sources-of cells spec)
  "How many scopes hold a reading of SPEC."
  (length (delete-duplicates (map (lambda (c) (list-ref (car c) 5)) (readings-of cells spec)))))

(define reading-reads
  `((cells    . ,(lambda (t) t))
    (readings . ,(lambda (t spec) (readings-of t spec)))
    (latest   . ,(lambda (t spec) (latest-of t spec)))
    (drift    . ,(lambda (t spec) (drift-of t spec)))
    (contrary . ,(lambda (t) (contrary-of t)))
    (sources  . ,(lambda (t spec) (sources-of t spec)))
    (rows     . ,(lambda (t spec) (map cell->alist (readings-of t spec))))))   ; the wire's reading

(define reading-writes
  `((reading-changed . ,(lambda (own scope-root scope-id observed-of)
                          (scope-own-readings scope-root scope-id observed-of)))))

(define ^reading-pool
  (fold-aggregate reading-monoid reading-reads reading-writes #:prefix "reading"))

;; ── the pull: the same fold, as its definition ──────────────────────────────
(define (scope-subtree-readings scope scope-id-of observed-of)
  (fold-tree-total reading-monoid scope
                   (lambda (root) (scope-own-readings root (scope-id-of root) observed-of))))

;; ── wiring ──────────────────────────────────────────────────────────────────
(define* (wire-reading-node! scope-root node #:key (parent #f) (scope-id #f) (observed-of #f))
  "Seed OWN from the scope's observer and rail, refold on every event the
   observer records (a contrary cast calls `reading-changed` itself, as a
   stance cast calls voice's), hand the TOTAL to PARENT keyed by SCOPE-ID."
  (let ((refold (lambda args (<-np node 'reading-changed scope-root scope-id observed-of))))
    ($ ($ scope-root 'observer) 'add-event-listener refold))
  ($ node 'reading-changed scope-root scope-id observed-of)
  (wire-fold-parent! node parent scope-id))

;;; ── What the readings doors answer ────────────────────────────────────
;;; The door's whole answer, as plain alists: the planner service and a scope held
;;; in a page both answer with these.

(define (node-readings-reply node spec)
  "What every source says of SPEC on the reading NODE: the fold's rows, the drift
   between counts and the ledger, and the latest reading or #f."
  (let ((drift ($ node 'drift spec)) (latest ($ node 'latest spec)))
    `((rows . ,($ node 'rows spec))                          ; the fold names its own cell (cell->alist)
      (drift . ((n . ,(car drift)) (mean-abs . ,(cadr drift)) (net . ,(caddr drift))))
      (latest . ,(and latest `((reading . ,(car latest)) (at . ,(cadr latest))
                               (unit . ,(caddr latest)) (source . ,(cadddr latest))))))))

(define* (readings-between-reply standing-log scope-id spec from until #:key (contrary #f))
  "Every reading of SPEC between FROM and UNTIL (instants as text, or #f for an
   open end) in the STANDING-LOG, with the rail's CONTRARY observations, and what
   the fold says from those readings alone."
  (let ((rows (readings-between standing-log spec #:since from #:until until
                                #:scope-id scope-id #:contrary contrary)))
    `((rows . ,(map cell->alist rows))
      (fold . ,(map cell->alist (window-fold rows))))))
