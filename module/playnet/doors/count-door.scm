;;; count-door.scm — a count lands, and the planned count is scheduled and offered
;;;
;;; The write path of docs/observation/capture.md §1–§4 over a scope root: a
;;; person's count of a stock (do-count-stock), the scope's count rows
;;; (count-stocks, scheduled-counts), and the offers a schedule lays
;;; (offer-count, lay-counts). What the ledger says of counts, read off the
;;; observer, is counts.scm; the shape of a count's events is
;;; observation/adjustment.scm; the grammar and the cadence are counting.scm.
;;; doors/service.scm wraps these as doors: it owns the scope lookup and the
;;; personhood gate.

(define-module (playnet doors count-door)
  #:use-module (playnet solve ingest)
  #:use-module ((playnet utils units) #:select (%count-unit %intensive-units))
  #:use-module ((playnet knowledge catalogues substances) #:select (thermal-base thermal-form-id %ambient-kelvin))
  #:use-module ((playnet vf formulas actions) #:select (onhand-sign))
  #:use-module (playnet vf formulas flows)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (playnet vf schemas)
  #:use-module (playnet utils envelope)
  #:use-module ((playnet doors inventory) #:select (build-inventory-snapshot resource->inv-alist))
  #:use-module (playnet doors counts)
  #:use-module (playnet vf formulas counting)
  #:use-module ((playnet observation adjustment)
                #:select (count-difference adjustment-event count-record-event))
  #:use-module ((playnet observation evidence) #:select (evidence-hash? evidence-tag))
  #:use-module ((playnet observation observer) #:select (measure-qty))
  #:use-module ((playnet scope live)
                #:select (make-work-event lot-of? scope-persons met-quantity
                          resource-place resource-resolver))
  #:use-module ((playnet vf aggregation containment) #:select (containment-first))
  #:use-module ((playnet algorithms rollup) #:select (crystallized-snlt-for-spec))
  #:use-module ((playnet utils store-utils) #:select (generate-id))
  #:use-module ((playnet doors offers) #:select (offer-work))
  #:use-module ((playnet utils clock)
                #:select (epoch->civil civil->instant instant->civil instant->unix (now . clock-now)))
  #:use-module ((playnet utils common) #:select (string-or-false))
  #:export (do-count-stock do-read-condition count-refusal count-plan count-run count-stocks scheduled-counts offer-count lay-counts
            plan-reader expected-range with-expected
            count-schedule-reply count-history-reply label-stock-reply read-label-reply)
  #:use-module ((playnet utils catch) #:select (catch* throw* with-throw-handler*)))

;;; ── What the plan expects of a stock ─────────────────────────────────
;;;
;;; The plan's last solve holds every produce, consume, pickup and dropoff it expects, as
;;; material rows (live.scm material->alist). A row bears on a stock when it is
;;; the stock's good at the stock's place (live.scm lot-of? and resource-place,
;;; the reading record-flow-done makes of a row), and it has not happened while
;;; the observer's fulfilment of the row's commitment is short of its quantity.
;;; A flow the plan scheduled to begin by the count's instant and that nobody
;;; has recorded may have happened or not, so the stock stands between the
;;; ledger with none of them and the ledger with all: a range, and a point (the
;;; ledger's) where no plan touches the stock.

(define (plan-reader root rows)
  "A reader of what the plan ROWS (its material rows) expect of a stock: a
   procedure (stock instant) → the flows on STOCK that began by INSTANT and are
   not met yet, as alists (id action quantity when proc), the quantity signed by
   what the flow does to the stock: a produce or a dropoff adds, a consume or a
   pickup takes. The books are read once, so one reader serves every stock of a
   listing."
  (let* ((obs     ($ root 'observer))
         (persons (scope-persons root))
         (resolve (resource-resolver (or ($ obs 'all-resources) '())))
         (rows    (filter (lambda (m) (not (row-ambient? m)))
                          rows))
         ;; the rows that touch a place: the ones that happen there
         (at      (let ((h (make-hash-table)))
                    (for-each (lambda (m)
                                (let ((place (row-place m)))
                                  (when (string? place)
                                    (hash-set! h place (cons m (hash-ref h place '()))))))
                              rows)
                    h)))
    (lambda (r instant)
      (let ((here (resource-place r resolve)))
        (filter-map
         (lambda (m)
           (let* ((act   (row-action m))
                  (id    (row-id m))
                  (good  (row-spec m))
                  (q     (row-quantity m))
                  (iso   (row-when m))
                  (place (row-place m))
                  (sign  (and (equal? place here) (onhand-sign act))))   ; +1 a produce or a dropoff, -1 a consume or a pickup
             (and sign (string? good) (number? q) (> q 0)
                  (lot-of? r good persons)
                  (or (not (string? iso)) (<= (civil->instant iso) instant))
                  (let ((left (- q (met-quantity obs id))))
                    (and (> left %count-tolerance)
                         `((id . ,id) (action . ,(symbol->string act))
                           (quantity . ,(exact->inexact (* sign left)))
                           (when . ,(if (string? iso) iso ""))
                           (proc . ,(or (row-run m) ""))))))))
         (if (string? here) (hash-ref at here '()) '()))))))

(define (expected-range held flows)
  "The range a stock that HELD stands in once any of FLOWS (plan-reader) has
   happened: ((low . n) (high . n) (flows . FLOWS)). Each flow may or may not
   have, so the low end takes every draw and the high end every addition."
  (let ((draw (apply + (map (lambda (f) (min 0 (row-figure f))) flows)))
        (add  (apply + (map (lambda (f) (max 0 (row-figure f))) flows))))
    `((low . ,(max 0.0 (exact->inexact (+ held draw))))
      (high . ,(exact->inexact (+ held add)))
      (flows . ,flows))))

(define (with-expected root rows snapshot instant)
  "SNAPSHOT (inventory.scm build-inventory-snapshot) with, on each stock the
   plan ROWS bear on at INSTANT, the range they leave it in (expected). A stock
   no row bears on carries nothing, and a scope with no plan is read as it is."
  (if (null? rows)
      snapshot
      (let ((read (plan-reader root rows))
            (obs  ($ root 'observer)))
        (map (lambda (field)
               (if (eq? (car field) 'resources)
                   (cons 'resources
                         (map (lambda (res)
                                (let* ((r     ($ obs 'get-resource (assq-ref res 'id)))
                                       (flows (if r (read r instant) '())))
                                  (if (null? flows)
                                      res
                                      (append res
                                              `((expected . ,(expected-range
                                                              (let ((q (assq-ref res 'onhand))) (if (number? q) q 0))
                                                              flows)))))))
                              (cdr field)))
                   field))
             snapshot))))

;;; ── A count of a stock (write path) ──────────────────────────────────
;;;
;;; A person looks at a stock the books already hold and says how much is
;;; there. ValueFlows' rule for a count applies, the one count-host-stock!
;;; (observation/host-facts.scm) applies to a host's capacity: a count that
;;; agrees with the ledger leaves no adjustment, and one that disagrees lands
;;; a `raise` or `lower` of the difference on that same resource.
;;;
;;; The adjustment carries what a reader of counts needs (docs/observation/
;;; capture.md §1): the technique as its process, so the reading fold keeps a
;;; stated count apart from a photo read; the place it was counted at; the
;;; instant; the hash of the picture it was read from.
;;;
;;; Every count lands its record, and what else it lands follows from what it
;;; found and whether a plan asked for it (docs/observation/observe-wiring.md
;;; §3):
;;;
;;;   the record    a `produce` of the run's own product, landed whether or not
;;;                 the count found the ledger off, so a count that agrees is
;;;                 still a count that ran. It states the figure found
;;;                 (counting.scm count-figure-tag), and it fulfils the record's
;;;                 commitment where a plan laid one
;;;   the adjustment  when the count finds the ledger off
;;;   the hours     of a PLANNED count, which names the counter's commitment: a
;;;                 `work` event fulfilling it, the visit and a line for the
;;;                 target, a line for each thing in it
;;;
;;; A count is of an instant. One read from a picture is of the instant the
;;; picture was taken, so its difference is from the ledger as it stood then
;;; (observer.scm onhand-as-of): what was drawn from the shelf between the
;;; picture and its reading is on the books already and stays out of the
;;; difference. The ledger follows the latest count of a stock (observer.scm
;;; anchored-onhand), so a count of an earlier instant than a count of the stock
;;; or of what holds it lands as an earlier sighting: its record and its figure,
;;; no adjustment (counts.scm count-latest?). A count of an instant before the
;;; books held the stock is refused (counts.scm count-predates-stock?). A lower
;;; takes at most what the ledger holds now.
;;;
;;; The plan's rows state what it expects of the stock by that instant (plan-reader
;;; above): the door answers the range and the record tags it, so the plan's word
;;; on the figure and the drift beyond the range read from the count alone.
;;;
;;; The technique is the commitment's process with its target left off
;;; (counting.scm count-technique), so every count under one regime folds into
;;; one cell. The adjustment's quantity is a difference in the stock's unit and
;;; stays off the fulfilment of commitments measured in hours and in records.
;;; A commitment that names a target counts that target and what is in it.
;;;
;;; An adjustment on a container scales what is in it, a lower down and a raise
;;; back up (observer.scm phase-containment-cascade), so a count names ONE
;;; line: the bin, or a jar in the bin.


(define (count-run cmt tech)
  "(RUN . PROC) of a count: RUN is the planned run's own process, target and
   all (#f for a count no plan asked for); PROC is the technique the count's
   events carry as their process, the run's with its target left off, else the
   technique's name."
  (let ((run (and cmt (or (commitment-input-of cmt) (commitment-output-of cmt)))))
    (cons run
          (or (and run (or (count-technique run) run))
              (string-append %count-technique-prefix tech)))))

(define* (count-refusal r counted unit tech evidence
                        #:key agent fulfills cmt standing? outside? predates?)
  "Why the door refuses this count, in its own words, or #f when it lands. R is
   the stock (#f when the books hold none); CMT the commitment FULFILLS names
   (#f when the plan holds none); STANDING? says the counter may count the
   stock unasked, OUTSIDE? that CMT is a count of another stock, PREDATES? that
   the count is of an instant before the books held the stock."
  (let* ((m0 (and r (economic-resource-onhand-quantity r)))
         (u0 (and m0 (measure-has-unit m0))))
    (cond
     ((not r) "no such stock")
     ((not (and (number? counted) (>= counted 0))) "a count is zero or more")
     ((and fulfills (not cmt)) "commitment not found")
     ((and cmt (commitment-provider cmt) (not (equal? (commitment-provider cmt) agent)))
      "that count is another's")
     ((not (member tech %count-techniques)) "not a counting technique")
     ((and evidence (not (evidence-hash? evidence)))
      "evidence is a sha256 hash, sha256: and sixty-four hex digits")
     ((not (or cmt standing?)) "not yours to count")
     ((and cmt outside?) "that count is of another stock")
     (predates? "the books did not hold this stock yet")
     ((and u0 unit (not (equal? unit u0))) (string-append "count in the stock's unit: " u0))
     (else #f))))

(define* (count-plan eid r counted u
                     #:key agent scope-id tech note evidence fulfills cmt rec-c
                           now then when-iso held have latest? flows place)
  "What a count lands and what the door answers, as ((events EVENT …) (reply .
   ALIST)): the counter's hours where a plan asked for the count, the adjustment
   where the count finds the ledger off, and the record, in the order they land.
   Pure over its arguments. R is the stock and U the unit; NOW is the clock's
   instant, THEN the count's own (#f for now) and WHEN-ISO its civil label as the
   counter stated it; HELD is what the ledger held
   at the count's instant and HAVE what it holds now; LATEST? says no later
   count of the stock stands; FLOWS are the plan's unmet flows on the stock
   (plan-reader); REC-C is the record's commitment where the plan laid one."
  (let* ((resource-id (economic-resource-id r))
         (spec  (economic-resource-conforms-to r))
         (at    (or place (economic-resource-current-location r)))
         (now*  (instant->civil now))
         (past? (and then (< then now)))
         (when* (if past? when-iso now*))
         ;; a lower takes at most what is there now; an earlier sighting moves nothing
         (delta (if latest?
                    (let ((d (count-difference held counted)))
                      (if (< d (- have)) (- have) d))
                    0.0))
         (off?  (not (zero? delta)))
         ;; what the plan expected of the stock by then, and the picture a photo
         ;; read was made from: each named on the count's events
         (range (expected-range held flows))
         (tags  (append (if evidence (list (evidence-tag evidence)) '())
                        (if (pair? flows)
                            (list (count-expected-tag (assq-ref range 'low) (assq-ref range 'high) u))
                            '())))
         (run+proc (count-run cmt tech))
         (run   (car run+proc))
         (proc  (cdr run+proc))
         ;; the counter's hours for this line: the visit rides the target's own
         ;; line, every other line is a line
         (hours (and cmt (eq? 'work (commitment-action cmt))
                     (if (equal? resource-id (or (count-process-target run) resource-id))
                         (count-hours 1)
                         %count-hours-per-line)))
         (line  (string-append "count " tech ": "
                               (number->string (exact->inexact counted)) " " u
                               " of " resource-id
                               (if note (string-append " · " note) ""))))
    `((events
       ,@(if hours
             (list (make-work-event
                    #:id (count-hours-id eid)
                    #:provider agent
                    #:effort-qty hours
                    #:fulfills fulfills
                    #:input-of proc
                    #:resource-spec (commitment-resource-conforms-to cmt)
                    #:at-location at
                    #:has-beginning (commitment-has-beginning cmt)
                    #:has-end (commitment-has-end cmt)
                    #:in-scope-of (list scope-id)
                    #:note line
                    #:timestamp when*))
             '())
       ,@(if off?
             (list (adjustment-event eid resource-id spec delta u
                                     #:provider agent #:receiver agent #:process proc
                                     #:at at #:when when* #:created now*
                                     #:note line #:in-scope-of (list scope-id)
                                     #:classified-as tags #:counted counted))
             '())
       ,(count-record-event eid resource-id
                            (if rec-c (commitment-resource-conforms-to rec-c) %count-record-spec)
                            #:provider agent #:process proc #:at at
                            #:when when* #:created now*
                            #:fulfills (and rec-c (commitment-id rec-c))
                            #:note line #:in-scope-of (list scope-id)
                            #:classified-as tags
                            #:counted counted #:unit u
                            #:stock-spec spec #:agreed? (and latest? (not off?))))
      (reply . ((event . ,(if off? eid ""))
                (record . ,(count-record-id eid))
                (hours . ,(or hours 0.0))
                (delta . ,delta)
                (sighting . ,(if latest? "" "earlier"))
                (expected . ,range)
                (onhand . ,(+ have delta)))))))

;; ── A count named by its instant ───────────────────────────────────────
(define (count-id-at agent resource-id when-iso counted)
  "The id of AGENT's count of RESOURCE-ID, found COUNTED, stated at the instant
   WHEN-ISO. Two figures stated of one instant are two counts, and the later to
   land is the latest word (observer.scm, the anchor's tie)."
  (string-append "evt-count-" agent "-" resource-id "-" when-iso "-" (number->string counted)))

(define (count-landed-reply obs eid r flows then)
  "What the door answers of a count the books already hold under EID: its
   adjustment where it landed one, its record, the difference it landed, what
   the stock holds now, and the range the plan's FLOWS leave it in at the
   count's instant THEN."
  (let* ((adj (obs-event obs eid))
         (q   (and adj (economic-event-resource-quantity adj)))
         (m0  (economic-resource-onhand-quantity r))
         (have (if m0 (exact->inexact (measure-qty m0)) 0.0))
         (held (exact->inexact (or ($ obs 'onhand-as-of (economic-resource-id r) then) have))))
    `((event . ,(if adj eid ""))
      (record . ,(string-append eid "-record"))
      (hours . 0.0)
      (delta . ,(if q
                    (* (or (onhand-sign (economic-event-action adj)) 0) (exact->inexact (measure-qty q)))
                    0.0))
      (sighting . "")
      (again . #t)
      (expected . ,(expected-range held flows))
      (onhand . ,have))))
(define (obs-event obs id) ($ obs 'get-event id))

(define* (do-count-stock root scope-id agent resource-id counted unit
                         #:key (technique #f) (place #f) (when-iso #f)
                               (fulfills #f) (evidence #f) (note #f) (rows '()))
  "Record AGENT's count of RESOURCE-ID as COUNTED UNIT at WHEN-ISO (now when
   #f, and never later than now). A count stated at an instant that the books
   already hold is answered as it stands and lands nothing more. ROWS are the plan's material rows, which
   state the range the plan expected of the stock at that instant. Returns the
   adjustment's event id (\"\" when the count agrees), the count record's event
   id, the difference landed, what is on hand after and the range expected.
   The door reads the books and the plan, asks count-refusal whether the count
   lands and count-plan what it lands, and records that."
  (let* ((obs  ($ root 'observer))
         (ps   ($ root 'plan-store))
         (r    ($ obs 'get-resource resource-id))
         (cmt  (and fulfills ($ ps 'get-commitment fulfills)))
         (tech (or technique "stated"))
         (now  (clock-now))                     ; one reading of the clock
         (then (let ((t (and when-iso (civil->instant when-iso)))) (and t (< t now) t)))
         ;; a count is of its instant: one stated at an instant is named by who
         ;; counted, what, when and the figure found, so it is the same count
         ;; wherever and however often it lands; a count of now is named afresh
         (eid  (if then (count-id-at agent resource-id when-iso counted) (generate-id "evt-count-")))
         (no   (count-refusal r counted unit tech evidence
                              #:agent agent #:fulfills fulfills #:cmt cmt
                              #:standing? (and r (count-standing? r scope-id agent))
                              #:outside? (and r cmt (count-outside-target? obs cmt resource-id))
                              #:predates? (and r when-iso
                                               (count-predates-stock? obs resource-id (civil->instant when-iso))))))
    (cond
     (no (failure no))
     ;; the same count, landing again (a device flushing what it queued): the
     ;; books already hold it, and the door answers what stands
     ((and then ($ obs 'get-event (string-append eid "-record")))
      (success (count-landed-reply obs eid r ((plan-reader root rows) r then) then)))
     (else
        (catch-as-failure
         (lambda ()
           (let* ((m0    (economic-resource-onhand-quantity r))
                  (have  (if m0 (exact->inexact (measure-qty m0)) 0.0))
                  (u     (or unit (and m0 (measure-has-unit m0)) %count-unit))
                  ;; what the ledger held at the count's instant
                  (held  (if then
                             (exact->inexact (or ($ obs 'onhand-as-of resource-id then) have))
                             have))
                  (proc  (cdr (count-run cmt tech)))
                  (run   (car (count-run cmt tech)))
                  ;; the record this run produces, where the plan laid one
                  (rec-c (and cmt
                              (find (lambda (k)
                                      (and (not (commitment-finished k))
                                           (eq? 'produce (commitment-action k))   ; verb-meant: a count's record is a produce
                                           (member (commitment-output-of k) (list run proc))))
                                    ($ ps 'all-commitments))))
                  (plan  (count-plan eid r counted u
                                     #:agent agent #:scope-id scope-id #:tech tech #:note note
                                     #:evidence evidence #:fulfills fulfills #:cmt cmt #:rec-c rec-c
                                     #:now now #:then then #:when-iso when-iso #:held held #:have have
                                     ;; the latest word on the stock, or an earlier sighting of it
                                     #:latest? (or (not then) (count-latest? obs resource-id then))
                                     #:flows ((plan-reader root rows) r (or then now))
                                     #:place place)))
             ;; a commitment the events fulfil is registered before they land
             (for-each (lambda (c)
                         (when (and c (not ($ obs 'get-fulfillment (commitment-id c))))
                           ($ obs 'register-commitment c)))
                       (list (and (eq? 'work (commitment-action* cmt)) cmt) rec-c))
             (for-each (lambda (ev) ($ obs 'record-event ev)) (assq-ref plan 'events))
             (success (assq-ref plan 'reply)))))))))

(define (commitment-action* c) (and c (commitment-action c)))

;;; ── A condition read names the form the stock is in ──────────────────
;;;
;;; A thermometer's degrees or a probe's percent is no count of the stock: an
;;; intensive number never enters the reading fold (docs/observation/readings-
;;; are-counts.md §1.1). A state is a form (§2.3): dough at +6 K over the room is
;;; the spec `dough+6K`, its heat a row of its composition. So a reading says
;;; which form the stock is in, and lands as the counts that say so: the stock
;;; of the form the books held is found to be nothing, and the whole of it is
;;; found in the form the reading names. Mass and specific heat are not asked:
;;; the form's row already carries them. A form the scope has not declared is
;;; refused, since a scope tracks the states it has named (thermal-form!).

(define %condition-tolerance 0.5)   ; K: a reading within this of a declared form is that form

(define (form-delta spec-id)
  "The excess a thermal form's id states, in K, or #f for a base."
  (let ((base (thermal-base spec-id)))
    (and base (string->number (substring spec-id (string-length base) (- (string-length spec-id) 1))))))

(define* (do-read-condition root scope-id agent resource-id reading unit
                            #:key (when-iso #f) (ambient #f) (note #f))
  "AGENT reads RESOURCE-ID's condition as READING UNIT, an intensive unit, against
   AMBIENT (°C; the catalogue's when #f). The reading names the form the stock
   is in among the forms its base has declared on the recipe store, within
   %condition-tolerance; the stock the books held under another form is
   counted as nothing and the same quantity is raised on the stock of the
   form named, created if the scope holds none. Replies the form, what moved
   and the two events; a stock already in the form named moves nothing."
  (let* ((row  (assoc-ref %intensive-units unit))
         (obs  ($ root 'observer))
         (rs   ($ root 'recipe-store))
         (r    ($ obs 'get-resource resource-id))
         (v    (if (string? reading) (string->number reading) reading)))
    (cond
     ((not row) (failure "that is a count, not a condition: count-stock takes it"))
     ((not (eq? (caddr row) 'temperature))
      (failure (format #f "no form of a thing is keyed by ~a yet: declare one first" unit)))
     ((not r) (failure "no such stock"))
     ((not (real? v)) (failure "a reading is a number"))
     (else
      (let* ((spec    (economic-resource-conforms-to r))
             (base    (or (thermal-base spec) spec))
             (amb     (or ambient (- %ambient-kelvin 273.15)))
             (delta   (- v amb))
             (near?   (lambda (d) (< (abs (- delta d)) %condition-tolerance)))
             (forms   (filter (lambda (s) (equal? base (thermal-base (resource-specification-id s))))
                              ($ rs 'all-resource-specs)))
             (target  (cond ((near? 0) base)
                            ((find (lambda (s) (near? (form-delta (resource-specification-id s)))) forms)
                             => resource-specification-id)
                            (else #f))))
        (cond
         ((not target)
          (failure (format #f "no declared form of ~a at ~a K over ambient: declare it first" base
                           (/ (round (* 10 delta)) 10.0))))
         ((equal? target spec)
          (success `((form . ,spec) (reading . ,v) (ambient . ,amb) (moved . 0)
                     (word . "the stock is in the form the books hold"))))
         (else
          (catch-as-failure
           (lambda ()
             (let* ((m0    (economic-resource-onhand-quantity r))
                    (q     (if m0 (exact->inexact (measure-qty m0)) 0.0))
                    (u     (or (and m0 (measure-has-unit m0)) %count-unit))
                    (brid  (or (thermal-base resource-id) resource-id))
                    (trid  (if (equal? target base) brid (thermal-form-id brid (form-delta target))))
                    (said  (or note (format #f "read ~a ~a against ~a: ~a is ~a" v unit amb base target)))
                    (gone  (do-count-stock root scope-id agent resource-id 0 u
                                           #:technique "stated" #:when-iso when-iso #:note said))
                    (now   (clock-now))
                    (then  (let ((t (and when-iso (civil->instant when-iso)))) (and t (< t now) t)))
                    (eid   (if then
                               (count-id-at agent trid when-iso q)
                               (generate-id "evt-count-"))))
               (if (not (eq? (car gone) 'ok))
                   gone
                   (begin
                     ($ obs 'record-event
                        (make-economic-event
                         #:id eid #:action 'raise #:output-of "count:reading"
                         #:resource-inventoried-as trid #:resource-conforms-to target
                         #:resource-quantity (make-measure q u)
                         #:has-point-in-time (instant->civil (or then now))
                         #:provider agent #:receiver agent
                         #:note said #:in-scope-of (list scope-id)))
                     (success `((form . ,target) (was . ,spec) (reading . ,v) (ambient . ,amb)
                                (moved . ,q) (unit . ,u)
                                (from-stock . ,resource-id) (to-stock . ,trid)
                                (gone . ,(assq-ref (cdr gone) 'event)) (event . ,eid)
                                (word . ,said)))))))))))))))

;;; ── The planned count: the schedule, and the offers it lays ──────────
;;;
;;; What is counted is what the inventory shows, each thing that sits in no
;;; other as one target: a bin is counted on one visit with what is in it, a
;;; line for each. The cadence is counting.scm's; the rows' figures are read
;;; here, off the recipes (the price), the reading fold (the drift) and the
;;; ledger (when it was last counted).

(define (count-stocks root scope-id node)
  "The scope's count targets, as counting.scm's stock rows. NODE is the
   scope's reading node, for the drift; #f leaves every drift at the prior."
  (let* ((obs  ($ root 'observer))
         (rs   ($ root 'recipe-store))
         (inv  (or (assq-ref (build-inventory-snapshot root scope-id #f) 'resources) '()))
         (ids  (map (lambda (r) (assq-ref r 'id)) inv)))
    (filter-map
     (lambda (r)
       (let* ((rid  (assq-ref r 'id))
              (in   (assq-ref r 'contained-in))
              (spec (row-spec r)))
         ;; a thing inside another is a line of that other's visit
         (and (string? rid)
              (not (and (string? in) (member in ids)))
              (let* ((lines (count-lines obs rid))
                     (drift (and node (string? spec)
                                 (false-if-exception ($ node 'drift spec))))
                     (seen  (fold (lambda (id acc) (max acc (or (last-counted obs id) 0))) 0 lines))
                     (price (and (string? spec)
                                 (false-if-exception (crystallized-snlt-for-spec rs spec)))))
                `((id . ,rid)
                  (name . ,(assq-ref r 'name))
                  (spec . ,spec)
                  (onhand . ,(let ((q (assq-ref r 'onhand))) (if (number? q) (exact->inexact q) 0.0)))
                  (unit . ,(assq-ref r 'unit))
                  (place . ,(assq-ref r 'location))
                  (owner . ,(assq-ref r 'primary-accountable))
                  (price . ,price)
                  (drift-n . ,(if (pair? drift) (car drift) 0))
                  (drift-mean . ,(if (pair? drift) (cadr drift) 0.0))
                  (last-count . ,(and (> seen 0) seen))
                  (lines . ,(length lines)))))))
     inv)))

(define (scheduled-counts root scope-id node nowu regime)
  "The scope's count rows at NOWU under REGIME (counting.scm count-regime reads
   it), soonest due first. NODE is the scope's reading node."
  (count-schedule (count-stocks root scope-id node)
                  #:now nowu #:regime (count-regime regime)))

(define (offer-count root row counter regime nowu)
  "Offer the count of ROW's stock to COUNTER as a directed work offer, through
   the offer loop's own door (offers.scm offer-work), so it is held to the same
   bound on open offers as every other and the counter answers it where they
   answer any offered shift. The window opens when the count is due, or now when
   it is overdue. Returns the proposal id; throws 'offer-refused as offer-work
   does."
  (let* ((rid    (assq-ref row 'id))
         (opens  (max nowu (assq-ref row 'due-at)))
         (closes (count-window-close opens (assq-ref row 'interval))))
    (offer-work root
                `((name . ,(string-append "count " (or (assq-ref row 'name) rid)))
                  (input-of . ,(count-process regime rid))
                  (conforms-to . ,%count-skill)
                  (effort . ,(assq-ref row 'hours))
                  (when . ,(epoch->civil opens))
                  (until . ,(epoch->civil closes))
                  (at-location . ,(assq-ref row 'place)))
                counter)))

;; Lay the counts that are due as offers. Each target whose window is open and
;; asked of nobody yet is offered to a counter: COUNTER where one is named, else
;; the member whose turn it is (AGENT-ID when the scope has none). AT-MOST bounds
;; how many one call lays, and the offer loop's bound on open offers stops the
;; walk: counting never crowds the offers of other work, and `refused` says why
;; the walk stopped. A count due later is announced by the schedule read, and
;; offered when its window opens, since an offer cannot be accepted before the
;; work it asks for may begin.
(define (lay-counts root scope-id agent-id members node regime counter at-most nowu)
  "The counts due at NOWU under REGIME, laid as offers: ((laid ROW …) (due N)
   [(refused KIND)]). MEMBERS are the scope's member ids, NODE its reading
   node."
  (let* ((ps      ($ root 'plan-store))
         (regime  (count-regime regime))
         (limit   (limit-or at-most 3))
         (rows    (scheduled-counts root scope-id node nowu regime))
         (due     (filter (lambda (r)
                            (and (<= (assq-ref r 'due-at) nowu)
                                 (not (count-standing-for? ps (assq-ref r 'id)))))
                          rows)))
    (define (done laid refused)
      `((laid . ,(reverse laid))
        (due . ,(length due))
        ,@(if refused `((refused . ,(symbol->string refused))) '())))
    (let loop ((rs due) (laid '()))
      (if (or (null? rs) (>= (length laid) limit))
          (done laid #f)
          (let* ((row   (car rs))
                 (cycle (inexact->exact
                         (floor (/ nowu (max 1.0 (assq-ref row 'interval))))))
                 (who   (or (string-or-false counter)
                            (count-counter members (assq-ref row 'owner) cycle)
                            agent-id))
                 ;; the offer door refuses by throwing; a refusal ends the walk
                 (laid? (catch* 'offer-refused
                          (lambda () (cons 'laid (offer-count root row who regime nowu)))
                          (lambda (key kind . _) (cons 'refused kind)))))
            (if (eq? (car laid?) 'refused)
                (done laid (cdr laid?))
                (loop (cdr rs)
                      (cons `((proposal . ,(cdr laid?))
                              (target . ,(assq-ref row 'id))
                              (counter . ,who)
                              (regime . ,regime)
                              (hours . ,(assq-ref row 'hours)))
                            laid))))))))

;;; ── What the count and label doors answer ─────────────────────────────
;;;
;;; Each is the door's whole answer over a scope root, as an envelope (ok or
;;; error): the planner service answers its doors with these, and so does a
;;; scope held in a page (page-scope.scm), so the two cannot answer differently.

(define (count-schedule-reply root scope-id node regime)
  "The schedule of counts of SCOPE-ID as of now under REGIME. NODE is the scope's
   reading node for the drift, or #f."
  (catch-as-failure
   (lambda ()
     (success
      `((rows . ,(map count-row->wire
                      (scheduled-counts root scope-id node (instant->unix (clock-now)) regime))))))))

(define (count-history-reply root agent-id resource-id limit)
  "The counts of RESOURCE-ID, newest first, as AGENT-ID reads them; LIMIT rows, five when #f."
  (catch-as-failure
   (lambda ()
     (success
      `((rows . ,(count-history-rows ($ root 'observer) agent-id resource-id (limit-or limit 5))))))))

(define (label-stock-reply root scope-id agent-id resource-id)
  "The code RESOURCE-ID is known by, given on the first asking and the same after."
  (let* ((obs ($ root 'observer))
         (r   ($ obs 'get-resource resource-id)))
    (cond
     ((not r) (failure "no such stock"))
     ((not (count-standing? r scope-id agent-id)) (failure "not yours to label"))
     (else
      (catch-as-failure
       (lambda ()
         (let ((minted? (not (economic-resource-tracking-identifier r))))
           (success `((code . ,(ensure-label! obs resource-id))
                      (id . ,resource-id)
                      (name . ,(or (economic-resource-name r) resource-id))
                      (minted . ,minted?))))))))))

(define (read-label-reply root code)
  "What the label CODE names: the thing, where it is, and what is in it."
  (let* ((obs ($ root 'observer))
         (as  ($ root 'agent-store))
         (rs  ($ root 'recipe-store))
         (r   (resource-by-label obs code)))
    (cond
     ((not r) (failure "no stock is known by that code"))
     (else
      (catch-as-failure
       (lambda ()
         (success
          `((resource . ,(resource->inv-alist r obs as rs))
            (contents . ,(map (lambda (k) (resource->inv-alist k obs as rs))
                              (or ($ obs 'resources-contained-in (economic-resource-id r))
                                  '())))))))))))
