;;; host-facts.scm — the machine reads itself: running services as VF facts
;;;
;;; Visibility first, actuation second. This module turns a host's real
;;; state — shepherd's running services (`herd status`), their process
;;; trees (`ps`), the kernel's own capacity numbers (/proc/meminfo,
;;; /proc/loadavg) — into the planner's existing observation vocabulary:
;;; one ^live-resource per capacity kind (compute, memory), registered in
;;; the scope's live-registry, with EACH RUNNING SERVICE APPEARING AS A
;;; NAMED RESERVATION against those resources. The reservation ledger IS
;;; the placement fact: `($ live 'reservations)` answers "what occupies
;;; this machine", `($ live 'available)` answers "what is free for a new
;;; placement" — the same two questions a placement solve asks, read off
;;; the same actor the engine's §6b ingest already names as the door for
;;; reservation-aware capacity.
;;;
;;; The specs are the ones the infrastructure recipes already `use`
;;; (spec:compute, spec:memory from knowledge/recipes/infrastructure.scm),
;;; so a solve that draws on these resources speaks the vocabulary this
;;; probe fills. Denomination: the probe reports what the kernel reports —
;;; compute in CORES, memory in GB. A recipe flow denominated in cpu-hours
;;; meets cores at ingest time as cores × period-hours; the conversion is
;;; the ingest seam's job (a period's length is a scope's declaration),
;;; not the probe's.
;;;
;;; Attribution algebra (placement-ledger): the kernel's availability
;;; number is the truth (MemAvailable; cores − load); the per-service
;;; process-tree usage is the attribution. What the kernel says is in use
;;; beyond what the service trees account for becomes one "<host>:other"
;;; reservation, so the ^live-resource invariant
;;;     total = available + Σ reservations
;;; holds exactly. (Per-service RSS over-counts shared pages, so the
;;; residual is clamped at zero and availability yields to the sum — the
;;; conservative reading.)
;;;
;;; Every parser here is pure text → data, so the whole ledger is testable
;;; in the pure test environment from fixture strings; only read-host-facts
;;; touches the live system.
;;;
;;; Relation to the observer: the observer is the event-sourced ledger of
;;; what HAPPENED (produce/consume/transfer events moving durable stock);
;;; the live-registry is the reservation-aware picture of what is free NOW.
;;; A probe snapshot is a reading, not an event — it lands here. The day a
;;; placement actually MOVES a service, that movement is an economic event
;;; and belongs in the observer.

(define-module (playnet observation host-facts)
  #:use-module (playnet observation live-resource)
  #:use-module ((playnet observation adjustment) #:select (count-difference adjustment-event))
  #:use-module ((playnet vf schemas) #:select (make-economic-event make-measure economic-resource-onhand-quantity measure-has-numerical-value))
  #:use-module ((playnet utils clock) #:select ((now . clock-now) instant->civil))
  #:use-module (playnet knowledge recipes infrastructure)
  #:use-module (goblins)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 threads)          ; current-processor-count
  #:use-module (ice-9 regex)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:export (count-host-stock! parse-meminfo parse-loadavg parse-herd-running parse-running-value
            parse-ps-table process-tree-usage
            placement-ledger read-host-facts sync-host-facts!))

(define KB->GB (/ 1.0 1048576.0))

;; ─── Pure parsers ───────────────────────────────────────────────────────────

(define (meminfo-field text field)
  ;; "MemTotal:        7456320 kB" → kB as number, #f when absent
  (let ((m (string-match (string-append field ":[ \t]+([0-9]+)") text)))
    (and m (string->number (match:substring m 1)))))

(define (parse-meminfo text)
  "/proc/meminfo text → ((total-gb . x) (available-gb . y))."
  (let ((total (meminfo-field text "MemTotal"))
        (avail (meminfo-field text "MemAvailable")))
    `((total-gb     . ,(and total (* total KB->GB)))
      (available-gb . ,(and avail (* avail KB->GB))))))

(define (parse-loadavg text)
  "/proc/loadavg text → the 1-minute load average."
  (string->number (car (string-tokenize text))))

(define (parse-herd-running text)
  "`herd status` text → running service names, as strings.
   Reads both shepherd shapes: the sectioned listing

       Started:
        + mosquitto
        + dev-bridge

   and the older one-line `Started: (root mosquitto …)`."
  (let ((lines (string-split text #\newline)))
    (let loop ((lines lines) (in-started #f) (acc '()))
      (if (null? lines)
          (reverse acc)
          (let ((line (car lines)))
            (cond
             ;; one-line form: everything inside the parens
             ((string-match "^Started:[ \t]*\\((.*)\\)" line)
              => (lambda (m)
                   (loop (cdr lines) #f
                         (append (reverse (string-tokenize (match:substring m 1)))
                                 acc))))
             ((string-match "^Started:" line)
              (loop (cdr lines) #t acc))
             ;; a new section heading ends the Started block
             ((string-match "^[A-Za-z].*:" line)
              (loop (cdr lines) #f acc))
             ((and in-started (string-match "^[ \t]*\\+[ \t]+([^ \t]+)" line))
              => (lambda (m)
                   (loop (cdr lines) #t (cons (match:substring m 1) acc))))
             (else (loop (cdr lines) in-started acc))))))))

(define (parse-running-value text)
  "`herd status <svc>` text → the service's PID, #f for a non-process
   value (one-shots, #t-valued services). Reads both shepherd shapes:
   `Main PID: 11711` (0.10-style) and `Running value is 11711.`"
  (let ((m (or (string-match "Main PID: ([0-9]+)" text)
               (string-match "Running value is ([0-9]+)" text))))
    (and m (string->number (match:substring m 1)))))

(define (parse-ps-table text)
  "`ps -e -o pid=,ppid=,rss=,pcpu=` text → list of (pid ppid rss-kb pcpu)."
  (filter-map
   (lambda (line)
     (let ((toks (string-tokenize line)))
       (and (= 4 (length toks))
            (let ((nums (map string->number toks)))
              (and (every number? nums) nums)))))
   (string-split text #\newline)))

(define (process-tree-usage table root-pid)
  "Fold ROOT-PID and its descendants in TABLE → (rss-gb . cpu-cores).
   pcpu is percent-of-one-core, so /100 makes it cores.
   TABLE is indexed once here (pid → row, ppid → children), not rescanned in
   full per node visited — read-host-facts calls this once per shepherd
   service against the SAME host-wide table, so an O(table) scan per step
   was O(descendants × table-size) per service."
  (let* ((by-pid (let ((h (make-hash-table)))
                   (for-each (lambda (r) (hash-set! h (first r) r)) table)
                   h))
         (children (let ((h (make-hash-table)))
                     (for-each (lambda (r)
                                 (hash-set! h (second r) (cons (first r) (hash-ref h (second r) '()))))
                               table)
                     h)))
    (let loop ((frontier (list root-pid)) (seen '()) (rss 0) (cpu 0.0))
      (if (null? frontier)
          (cons (* rss KB->GB) (/ cpu 100.0))
          (let* ((pid  (car frontier))
                 (row  (hash-ref by-pid pid #f))
                 (kids (filter (lambda (k) (not (memv k seen))) (hash-ref children pid '()))))
            (loop (append (cdr frontier) kids)
                  (cons pid seen)
                  (+ rss (if row (third row) 0))
                  (+ cpu (if row (fourth row) 0.0))))))))

;; ─── The placement ledger (pure) ────────────────────────────────────────────

(define (attribute kind total kernel-available services usage-of)
  ;; One capacity kind → ((total …) (available …) (reservations …)) with the
  ;; live-resource invariant total = available + Σ reservations exact.
  (let* ((svc-rsv (map (lambda (svc)
                         (cons (assq-ref svc 'name) (usage-of svc)))
                       services))
         (svc-sum (fold + 0 (map cdr svc-rsv)))
         (other   (max 0.0 (- total kernel-available svc-sum)))
         (avail   (max 0.0 (- total svc-sum other))))
    `(,kind (total . ,total)
            (available . ,avail)
            (reservations . ,(if (> other 0.0)
                                 (append svc-rsv `(("other" . ,other)))
                                 svc-rsv)))))

(define (placement-ledger facts)
  "Host FACTS (read-host-facts' shape) → the two-resource placement ledger:
   ((compute (total …) (available …) (reservations …)) (memory …))."
  (let ((cores    (assq-ref facts 'cores))
        (load-1m  (or (assq-ref facts 'load-1m) 0.0))
        (services (or (assq-ref facts 'services) '())))
    (list
     (attribute 'compute cores (max 0.0 (- cores load-1m)) services
                (lambda (svc) (assq-ref svc 'cpu-cores)))
     (attribute 'memory
                (assq-ref facts 'mem-total-gb)
                (assq-ref facts 'mem-available-gb)
                services
                (lambda (svc) (assq-ref svc 'rss-gb))))))

;; ─── Live readers (the only impure part) ────────────────────────────────────

(define (capture cmd)
  ;; stdout of CMD as a string; #f on any failure
  (catch #t
    (lambda ()
      (let* ((port (open-input-pipe cmd))
             (out  (get-string-all port))
             (st   (close-pipe port)))
        (and (zero? (or (status:exit-val st) 1)) out)))
    (lambda _ #f)))

(define (slurp path)
  (catch #t
    (lambda () (call-with-input-file path get-string-all))
    (lambda _ #f)))

(define (read-host-facts)
  "Read THIS host: hostname, cores, kernel memory numbers, 1-minute load,
   and every running shepherd service with its process-tree usage.
   Degrades gracefully — a host without shepherd reports (services . ())."
  (let* ((mem      (parse-meminfo (or (slurp "/proc/meminfo") "")))
         (loadtext (slurp "/proc/loadavg"))
         (ps-text  (capture "ps -e -o pid=,ppid=,rss=,pcpu="))
         (table    (if ps-text (parse-ps-table ps-text) '()))
         (herd     (capture "herd status 2>/dev/null"))
         (services
          (if herd
              (filter-map
               (lambda (name)
                 (let* ((status (capture (string-append "herd status " name
                                                        " 2>/dev/null")))
                        (pid    (and status (parse-running-value status))))
                   ;; pid 1 is shepherd itself — its "tree" is every process
                   ;; on the machine, so counting it would double-attribute
                   ;; all other services. The init IS the machine, not a
                   ;; placement on it; its own footprint lands in "other".
                   (and pid (> pid 1)
                        (let ((usage (process-tree-usage table pid)))
                          `((name . ,name) (pid . ,pid)
                            (rss-gb . ,(car usage))
                            (cpu-cores . ,(cdr usage)))))))
               (parse-herd-running herd))
              '())))
    `((host . ,(gethostname))
      (cores . ,(current-processor-count))
      (mem-total-gb . ,(assq-ref mem 'total-gb))
      (mem-available-gb . ,(assq-ref mem 'available-gb))
      (load-1m . ,(and loadtext (parse-loadavg loadtext)))
      (services . ,services))))

;; ─── Into the scope (call within the scope's vat) ───────────────────────────

(define %facts-seq 0)                    ; two snapshots in one second are two events
(define (count-host-stock! obs host rid spec total unit)
  "A probe's TOTAL is a COUNT of the host's capacity stock RID, and ValueFlows'
   rule for a count applies (docs/observation/readings-are-counts.md §1.1): one
   that agrees with the ledger leaves no adjustment, one that disagrees lands a
   `raise` or `lower` of the difference, the first count minting the resource.
   The event log then holds the history of what changed, and the reading fold
   reads the drift. Returns the difference landed, 0 when nothing did."
  (let* ((r (and rid ($ obs 'get-resource rid)))
         (onhand (and r (economic-resource-onhand-quantity r)
                      (measure-has-numerical-value (economic-resource-onhand-quantity r))))
         ;; a probe reports a measurement, so its arithmetic is inexact
         (delta (count-difference (exact->inexact (or onhand 0)) (exact->inexact total))))
    (if (zero? delta) 0.0
        (let ((now (instant->civil (clock-now))))
          (set! %facts-seq (+ %facts-seq 1))
          ($ obs 'record-event
             (adjustment-event
              (string-append "evt-facts-" rid "-" now "-" (number->string %facts-seq))
              rid spec delta unit
              #:provider host #:receiver host #:at host #:when now #:created now
              #:counted total
              #:note "host facts: a probe's count of the capacity stock"))
          delta))))

(define (sync-host-facts! scope facts)
  "Snapshot FACTS into SCOPE: ensure the infrastructure specs are on the
   recipe-store, spawn one ^live-resource per capacity kind with the
   running services as its named reservations, and register both in the
   scope's live-registry under stable ids (<host>:compute, <host>:memory).
   Re-syncing registers a fresh snapshot under the same ids — the registry
   overwrite IS the refresh, the fast read of the current state. Each kind's
   total is also COUNTED on the scope's observer (`count-host-stock!`), so a
   change of capacity lands as an adjustment event and the event log carries
   the history the registry does not. Returns ((id . ref) …)."
  (let ((host   (assq-ref facts 'host))
        (ledger (placement-ledger facts))
        (rs     ($ scope 'recipe-store))
        (lr     ($ scope 'live-registry))
        (obs    (false-if-exception ($ scope 'observer))))
    ($ rs 'add-resource-spec infra-machine-spec)
    ($ rs 'add-resource-spec infra-memory-spec)
    (map (lambda (kind spec unit)
           (let* ((entry (assq-ref ledger kind))
                  (rid   (string-append host ":" (symbol->string kind)))
                  (ref   (spawn ^live-resource rid spec
                                (assq-ref entry 'total)
                                (assq-ref entry 'available)
                                unit host
                                (assq-ref entry 'reservations))))
             ($ lr 'register rid ref)
             (when obs (count-host-stock! obs host rid spec (assq-ref entry 'total) unit))
             (cons rid ref)))
         '(compute memory)
         '("spec:compute" "spec:memory")
         '("cores" "GB"))))
