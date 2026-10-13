;;; counts.scm — what the ledger says of counts, read off the observer
;;;
;;; The observer-side half of the count door (docs/observation/capture.md §4, §6):
;;; which events are counts that stand, when a stock was last counted, who may
;;; count it, whose turn a planned count is, whether one is already asked, the
;;; rows a contest reads, and the code a stock is known by. The door that lands
;;; a count, the schedule's rows and the offers stay in doors/service.scm,
;;; which owns the error envelope and the inventory snapshot; the shape of a
;;; count's events is observation/adjustment.scm's, the grammar of its process
;;; counting.scm's.

(define-module (playnet doors counts)
  #:use-module (playnet vf formulas actions)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (playnet vf schemas)
  #:use-module ((playnet vf aggregation containment) #:select (containment-first))
  #:use-module ((playnet vf formulas counting)
                #:select (count-process count-process-target %count-regimes count-blind? count-figure count-base-id
                          contest-ballot-id))
  #:use-module ((playnet observation adjustment)
                #:select (count-event? count-event-of))
  #:use-module ((playnet observation observer)
                #:select (measure-qty event-instant event-stamps latest-anchor
                          economic-resource-set-tracking-identifier))
  #:use-module ((playnet observation evidence) #:select (tags-evidence))
  #:use-module ((playnet vf facts labels) #:select (label-normal draw-label))
  #:use-module ((playnet utils common) #:select (take-up-to))
  #:use-module ((playnet utils clock) #:select (civil->epoch epoch->civil instant->unix))
  #:export (count-process-name count-standing? count-outside-target? count-readable?
            count-latest? count-predates-stock? count-overlaps standing-count-events last-counted count-lines count-history-rows
            count-row->wire count-standing-for? count-counter limit-or
            resource-by-label fresh-label ensure-label!))

;;; ── who may count, and what a count is of ────────────────────────────

(define (count-standing? r scope-id agent)
  "AGENT may count R unasked: R is AGENT's own, the scope's own, or in the
   scope's custody. A planned count stands on its commitment instead."
  (let ((pa (economic-resource-primary-accountable r))
        (cs (economic-resource-custodian-scope r)))
    (or (equal? pa agent) (equal? pa scope-id) (equal? cs scope-id)
        (eq? 'communal (economic-resource-distribution-mode r)))))

(define (count-outside-target? obs cmt resource-id)
  "CMT is a planned count of a target, and RESOURCE-ID is neither the target
   nor anything inside it."
  (let ((target (count-process-target (or (commitment-input-of cmt)
                                          (commitment-output-of cmt)))))
    (and target
         (not (or (equal? resource-id target)
                  (let ((r ($ obs 'get-resource resource-id)))
                    (and r (containment-first
                            r (lambda (x) (equal? (economic-resource-id x) target))
                            #:parent-of economic-resource-contained-in
                            #:resolve (lambda (id) ($ obs 'get-resource id))))))))))

(define (count-overlaps obs resource-id)
  "RESOURCE-ID and what contains it, as resource ids: the stocks whose counts
   speak for RESOURCE-ID (the observer's containers-of, nearest first)."
  (cons resource-id ($ obs 'containers-of resource-id)))

(define (count-latest? obs resource-id instant)
  "No count of a stock that speaks for RESOURCE-ID (count-overlaps) is of a later
   instant than INSTANT: a count of INSTANT is the latest word on the stock,
   and the ledger follows it. Two counts of one instant are in the order they
   landed."
  (not (any (lambda (rid)
              (any (lambda (e) (> (event-instant e) instant))
                   (or ($ obs 'standing-anchors rid) '())))
            (count-overlaps obs resource-id))))

(define (count-predates-stock? obs resource-id instant)
  "The `produce` that brought RESOURCE-ID onto the books came after INSTANT:
   the books did not hold the stock yet, and a count of that day has no ledger
   to follow."
  (let* ((evs   (filter event-instant
                        (or ($ obs 'active-events-for-resource resource-id) '())))
         (first (and (pair? evs)
                     (fold (lambda (e best)
                             (if (< (event-instant e) (event-instant best)) e best))
                           (car evs) (cdr evs)))))
    (and first
         (> (event-instant first) instant)
         (eq? 'produce (economic-event-action first)))))   ; verb-meant: a count's record is a produce

(define (count-readable? c viewer nowu)
  "Commitment C may be read by VIEWER at NOWU. Every commitment is, but a
   count whose regime keeps it from the custodian: that one is read by its
   counter alone until its window has opened."
  (let ((proc (commitment-input-of c)))
    (or (not (count-blind? proc))
        (equal? viewer (commitment-provider c))
        (let ((opens (civil->epoch (commitment-has-beginning c))))
          (or (not (number? opens)) (<= opens nowu))))))

;;; ── the counts that stand ────────────────────────────────────────────

(define (limit-or n default)
  "N as a whole number above zero, else DEFAULT: a door's optional bound."
  (if (and (number? n) (> n 0)) (inexact->exact (floor n)) default))

(define (standing-count-events obs)
  "The parts of counts that stand on OBS's ledger: what no later correction has
   replaced, voids dropped."
  (filter count-event? (or ($ obs 'standing-log) '())))

(define (last-counted obs rid)
  "The epoch second RID was last counted, or #f: the instant of its latest
   standing count (observer.scm latest-anchor), the one notion of \"counted\"
   the ledger and the schedule share."
  (let ((a (latest-anchor (or ($ obs 'standing-anchors rid) '()))))
    (and a (instant->unix (event-instant a)))))

(define (count-lines obs rid)
  "RID and everything inside it, as resource ids: the lines of one visit."
  (let walk ((id rid) (seen '()))
    (if (member id seen) '()
        (cons id
              (append-map (lambda (k) (walk (economic-resource-id k) (cons id seen)))
                          (or ($ obs 'resources-contained-in id) '()))))))

(define (count-history-rows obs agent-id resource-id n)
  "The counts of RESOURCE-ID as wire rows, newest first, at most N, one row a
   count: the figure it found, the difference it landed (nothing when it
   agreed), who counted, by what technique, and the picture it names. A row is
   named by the count's adjustment where it landed one, else by its record. A
   contested and voided count is gone, since the rows read the standing
   events."
  (define (adjustment? e) (and (memq (economic-event-action e) *adjustment-actions*) #t))
  (define (row e)
    (let* ((q    (and (adjustment? e) (economic-event-resource-quantity e)))
           (tags (economic-event-resource-classified-as e))
           (fig  (count-figure tags)))
      `((id . ,(economic-event-id e))
        ;; the ballot a contest of this count is, whichever part names it
        (ballot . ,(contest-ballot-id (economic-event-id e) #t))
        (at . ,(or (and=> (event-stamps e) cdr) ""))   ; the observer's one reading of when
        (delta . ,(if q
                      (* (or (onhand-sign (economic-event-action e)) 0)
                         (exact->inexact (measure-qty q)))
                      0.0))
        (unit . ,(cond (q (measure-has-unit q)) (fig (cdr fig)) (else "")))
        ;; the figure the count found, where its tags state one
        (counted . ,(and fig (car fig)))
        (counter . ,(or (economic-event-provider e) ""))
        (technique . ,(or (economic-event-output-of e) ""))
        (evidence . ,(or (tags-evidence tags) ""))
        (mine . ,(equal? agent-id (economic-event-provider e))))))
  (let* ((parts (filter (lambda (e)
                          (and (equal? resource-id (count-event-of e))
                               (or (adjustment? e) (eq? 'produce (economic-event-action e)))))   ; verb-meant: a count's record is a produce
                        (standing-count-events obs)))
         (bases (map (lambda (e) (count-base-id (economic-event-id e)))
                     (filter adjustment? parts)))
         ;; one event a count: its adjustment, else its record
         (counts (filter (lambda (e)
                           (or (adjustment? e)
                               (not (member (count-base-id (economic-event-id e)) bases))))
                         parts)))
    (map row (take-up-to (reverse counts) n))))

;;; ── the planned count: the rows, who counts, what is asked ───────────

(define (count-process-name obs process-id)
  "\"count <the thing's name>\" for a planned count's process, else #f."
  (let ((rid (count-process-target process-id)))
    (and rid
         (let ((r ($ obs 'get-resource rid)))
           (string-append "count "
                          (or (and r (economic-resource-name r)) rid))))))

(define (count-row->wire row)
  "A schedule row for a wire: plain values, the class as a string."
  `((id . ,(assq-ref row 'id)) (name . ,(assq-ref row 'name))
    (spec . ,(assq-ref row 'spec)) (place . ,(assq-ref row 'place))
    (onhand . ,(assq-ref row 'onhand)) (unit . ,(assq-ref row 'unit))
    (lines . ,(assq-ref row 'lines)) (hours . ,(assq-ref row 'hours))
    (interval . ,(assq-ref row 'interval))
    (class . ,(symbol->string (assq-ref row 'class)))
    (regime . ,(assq-ref row 'regime))
    (last-count . ,(and=> (assq-ref row 'last-count) epoch->civil))
    (due . ,(epoch->civil (assq-ref row 'due-at)))
    (overdue? . ,(assq-ref row 'overdue?))))

(define (count-standing-for? ps rid)
  "A count of RID is already asked or accepted: an open offer's intent or an
   unfinished commitment names it, under any regime."
  (let ((names? (lambda (proc) (equal? rid (count-process-target proc)))))
    (or (any (lambda (i) (and (not (intent-finished i)) (names? (intent-input-of i))))
             (or ($ ps 'all-intents) '()))
        ;; a count's process is named by its regime and the stock, so the store's
        ;; index by process answers for each regime
        (any (lambda (regime)
               (any (lambda (c) (not (commitment-finished c)))
                    (or ($ ps 'commitments-for-process (count-process regime rid)) '())))
             %count-regimes))))

(define (count-counter member-ids owner cycle)
  "Who counts: the members take turns, CYCLE picking whose it is, and the
   owner of a stock is passed over while anyone else can count it, so a figure
   others rely on is counted by someone who does not hold the stock."
  (let* ((ids (sort (filter string? member-ids) string<?))
         (others (filter (lambda (id) (not (equal? id owner))) ids))
         (pool (if (pair? others) others ids)))
    (and (pair? pool)
         (list-ref pool (modulo cycle (length pool))))))

;;; ── a label: the code a thing is known by ────────────────────────────
;;;
;;; A resource's tracking identifier is a short code, unique in its scope, that
;;; says nothing of the owner or the contents (docs/observation/capture.md §6).
;;; The label on a bin is that code printed; a scan or a typed code finds the
;;; thing. The alphabet, the length and the reading of a typed code live in
;;; (playnet vf facts labels).

(define (resource-by-label obs code)
  "The resource in OBS known by CODE, or #f."
  (let ((c (label-normal code)))
    (and c (find (lambda (r) (equal? c (economic-resource-tracking-identifier r)))
                 (or ($ obs 'all-resources) '())))))

(define (fresh-label obs)
  "A code no resource in OBS is known by."
  (let loop ()
    (let ((c (draw-label)))
      (if (resource-by-label obs c) (loop) c))))

(define (ensure-label! obs rid)
  "The code resource RID is known by, giving it one when it has none.
   #f when there is no such resource."
  (let ((r ($ obs 'get-resource rid)))
    (and r
         (or (economic-resource-tracking-identifier r)
             (let ((c (fresh-label obs)))
               ($ obs 'record-resource (economic-resource-set-tracking-identifier r c))
               c)))))
