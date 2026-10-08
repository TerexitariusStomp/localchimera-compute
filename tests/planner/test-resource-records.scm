;;; test-resource-records.scm — a stock the books were told of survives a restore.
;;;
;;; A resource comes into the books by an event (a `raise`, a `produce`) or, for what
;;; the scope already held and described (a name, a tracking label, an availability
;;; window, where it sits, who keeps it), by a resource RECORD. Both are entries of
;;; the portable event log, replayed in the order they were written, so a gateway
;;; restored from the log alone holds the same books. These properties hold:
;;;
;;;   KEPT      a record carries every field of the resource, and a replay returns
;;;             them; the events after it apply to it as they did the first time
;;;   ONCE      recording what the books already hold, unchanged, writes nothing
;;;   FOLLOWS   recording a changed record writes it; the replay holds the latest
;;;   BACKFILL  a scope that predates its log writes its events and then its
;;;             resources as they stand, and a replay lands on the same books
;;;   SILENT    the fixture door (seed-resource) writes no entry
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-resource-records.scm

(use-modules (playnet test harness)
             (playnet test books)
             ((playnet test events) #:select (ev positional-snapshot))
             (playnet planner observation observer) (playnet planner scope root) (playnet planner vf schemas)
             ((playnet governance acdc-bridge) #:select (install-event-log!))
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

(define resource->list (@@ (playnet planner observation observer) economic-resource->list))
(define (fresh-dir tag)
  (let ((d (string-append "/tmp/pel-res-" (number->string (getpid)) "-" tag)))
    (system* "rm" "-rf" d) (mkdir d) d))

(define (flour-sack)
  (copy-economic-resource (res "sack" "flour" 10.0 "A" #:unit "kg")
                          #:name "Flour sack" #:tracking-identifier "L-17" #:custodian-scope "T"))
(define (consume3) (ev "c1" 'consume #:rid "sack" #:spec "flour" #:q 3.0 #:unit "kg" #:input "P"))

(define vat (spawn-vat))

(display "\n── KEPT: a restore holds the record's fields and the events after it ──\n")
(with-vat vat
  (let* ((dir (fresh-dir "kept"))
         (o1  ($ (spawn-scope-root "One") 'observer))
         (l1  (install-event-log! o1 "EScope" #:dir dir)))
    ($ o1 'record-resource (flour-sack))
    ($ o1 'record-event (consume3))
    (check "the log holds the record and the event" ($ l1 'seq) 2)
    (let* ((o2 ($ (spawn-scope-root "Two") 'observer))
           (l2 (install-event-log! o2 "EScope" #:dir dir))
           (a  ($ o1 'get-resource "sack"))
           (b  ($ o2 'get-resource "sack")))
      (check "the restored books hold the sack" (and b #t) #t)
      (check "…with seven left after the consume" (onhand-of o2 "sack") 7.0)
      (check "…and every field as it was"
             (and b (equal? (resource->list a) (resource->list b))) #t)
      (check "…named and labelled" (and b (list (economic-resource-name b) (economic-resource-tracking-identifier b)))
             '("Flour sack" "L-17"))
      (check "the replay appended nothing" ($ l2 'seq) 2))))

(display "\n── ONCE / FOLLOWS: only a change is written ──\n")
(with-vat vat
  (let* ((dir (fresh-dir "once"))
         (o1  ($ (spawn-scope-root "One") 'observer))
         (l1  (install-event-log! o1 "EScope" #:dir dir)))
    ($ o1 'record-resource (flour-sack))
    ($ o1 'record-resource (flour-sack))
    (check "the same record again writes nothing" ($ l1 'seq) 1)
    ($ o1 'record-resource (copy-economic-resource (flour-sack) #:name "Rye sack"))
    (check "a changed record is written" ($ l1 'seq) 2)
    (let* ((o2 ($ (spawn-scope-root "Two") 'observer)))
      (install-event-log! o2 "EScope" #:dir dir)
      (check "the replay holds the latest" (economic-resource-name ($ o2 'get-resource "sack")) "Rye sack"))))

(display "\n── a restored books are not seeded over ──\n")
(with-vat vat
  (let* ((dir (fresh-dir "gate"))
         (o1  ($ (spawn-scope-root "One") 'observer))
         (l1  (install-event-log! o1 "EScope" #:dir dir)))
    ($ o1 'record-resource (flour-sack))
    (let ((o2 ($ (spawn-scope-root "Two") 'observer)))
      ($ o2 'record-resource (copy-economic-resource (flour-sack) #:name "Already here"))
      (install-event-log! o2 "EScope" #:dir dir)
      (check "a scope that already holds a record is not replayed over"
             (economic-resource-name ($ o2 'get-resource "sack")) "Already here"))))

(display "\n── BACKFILL: a scope that predates its log lands on the same books ──\n")
(with-vat vat
  (let* ((dir (fresh-dir "back"))
         (o1  ($ (spawn-scope-root "One") 'observer)))
    ($ o1 'seed-resource (flour-sack))
    ($ o1 'record-event (consume3))
    (let ((l1 (install-event-log! o1 "EScope" #:dir dir)))
      (check "the log was written from the books as they stood" (> ($ l1 'seq) 0) #t)
      (let ((o2 ($ (spawn-scope-root "Two") 'observer)))
        (install-event-log! o2 "EScope" #:dir dir)
        (check "a replay holds the seven left"           (onhand-of o2 "sack") 7.0)
        (check "…and the sack as it was"
               (equal? (resource->list ($ o1 'get-resource "sack")) (resource->list ($ o2 'get-resource "sack"))) #t)))))

(display "\n── PROCESS: a performed process is a record of the books too ──\n")
;; A trip's process is `based-on` its mode's specification; the observer holds the
;; record so a performed ride finds its recipe, and the log carries it so a restore does.
(define (trip) (make-process #:id "trip|1" #:name "ride" #:based-on "pspec-bike"
                             #:classified-as '("manner:bicycle")))
(with-vat vat
  (let* ((dir (fresh-dir "proc"))
         (o1  ($ (spawn-scope-root "One") 'observer))
         (l1  (install-event-log! o1 "EScope" #:dir dir)))
    ($ o1 'record-process (trip))
    ($ o1 'record-process (trip))
    (check "the observer holds the process, and its specification reads off it"
           (list (and ($ o1 'get-process "trip|1") #t) ($ o1 'process-spec "trip|1")) '(#t "pspec-bike"))
    (check "the same record again writes nothing" ($ l1 'seq) 1)
    (let ((o2 ($ (spawn-scope-root "Two") 'observer)))
      (install-event-log! o2 "EScope" #:dir dir)
      (check "a restore from the log holds it, with its classification"
             (let ((p ($ o2 'get-process "trip|1"))) (and p (list (process-based-on p) (process-classified-as p))))
             '("pspec-bike" ("manner:bicycle"))))
    (let ((o3 ($ (spawn-scope-root "Three") 'observer)))
      ($ o3 'load-snapshot ($ o1 'serialize))
      (check "a snapshot round-trips it" ($ o3 'process-spec "trip|1") "pspec-bike"))))
(with-vat vat
  (let* ((o1 ($ (spawn-scope-root "One") 'observer))
         (snap ($ o1 'serialize))
         ;; a snapshot from before processes were records: process id → specification id
         (legacy (append (positional-snapshot (deserialize-observer-state-portable snap) #:slots 6)
                         (list (hashmap-set (hashmap) "p1" "pspec-old"))))
         (o4 ($ (spawn-scope-root "Four") 'observer)))
    ($ o4 'load-snapshot legacy)
    (check "a snapshot that held a process as its specification id still reads" ($ o4 'process-spec "p1") "pspec-old")))

(display "\n── SILENT: the fixture door writes no entry ──\n")
(with-vat vat
  (let* ((dir (fresh-dir "silent"))
         (o1  ($ (spawn-scope-root "One") 'observer))
         (l1  (install-event-log! o1 "EScope" #:dir dir)))
    ($ o1 'seed-resource (flour-sack))
    (check "seed-resource leaves the log alone" ($ l1 'seq) 0)))

(test-summary!)
