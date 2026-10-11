;;; test-confirm-doors.scm — the confirming doors say one thing about one plan row.
;;;
;;; The plan states its material rows; a person confirms a row, a whole plan is
;;; enacted, and both land on the books through the same reading of "which lot,
;;; which commitment". These properties hold for every row:
;;;
;;;   ROW      a row is found by its own coordinates however the wire spells an
;;;            absent value ("" for no process); rows that share coordinates are
;;;            one commitment sized by all of them
;;;   ONCE     a row enacted wholesale and then confirmed one by one is recorded
;;;            once: both doors name the plan row's own commitment
;;;   PLAN     enact records only rows the last plan states, and says why a row
;;;            that cannot yet happen waits
;;;   LOT      a lot is the plan's lot: what the stock key files under the row's
;;;            good is what a confirmation draws on (a loaf lent to the scope is
;;;            the commons' loaf, a loaf a citizen keeps is theirs)
;;;   AMBIENT  a good with stock behind it is drawn from the stock, whoever
;;;            declared it a raw
;;;
;;; Run: guile --no-auto-compile -q -L module tests/doors/test-confirm-doors.scm

(use-modules (playnet solve report))
(use-modules (playnet solve world) (playnet test harness)
             (playnet test books)
             (playnet vf schemas) (srfi srfi-11)
             (playnet scope live)
             (playnet doors service)
             ((playnet solve engine) #:select (declare-world! stock-vocabulary))
             ((playnet observation observer) #:select (event-interval))
             ((playnet utils clock) #:select (now civil->instant))
             (playnet knowledge dsl shorthand)
             (goblins) (goblins vat) (goblins persistence-store memory) (goblins utils hashmap)
             (srfi srfi-1) (srfi srfi-13))

(define %standing (@@ (playnet doors service) %standing))   ; the live service's reads
(define (cache-solve! sid demand alist)   ; a plan landed for the live service's SID
  ((@ (playnet doors planner solve-cache) cache-solve!) (%standing 'cache) sid demand alist))
(define* (row id act spec qty place #:key in out note)
  `((id . ,id) (action . ,act) (conforms-to . ,spec) (quantity . ,qty) (at-location . ,place)
    (input-of . ,in) (output-of . ,out) (when . "2026-10-02") (note . ,note)))

(display "\n── ROW: the wire's \"\" is an absent process; shared coordinates are one commitment ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let* ((obs ($ scope 'observer))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "org:t" scope))))
      ($ obs 'seed-resource (res "w1" "water" 100.0 "A"))
      (cache-solve! "org:t" '() `((material . (,(row "mc|produce|water||A||2026-10-02" 'produce "water" 20.0 "A")))))
      (check "a row that has no process is confirmed with the wire's empty process"
             (ok? ($ svc 'record-flow "org:t" "produce" "water" 20.0 20.0 "A" "2026-10-02" "" "")) #t)
      (check "…and the stock grew"
             (onhand-of obs "w1") 120.0))))

(display "\n── RELOCATION: the two rows of a carry chain through their run ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let* ((obs ($ scope 'observer))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "org:t" scope)))
           (pu  (row "mc|pickup|water|run|A||2026-10-02" 'pickup "water" 20.0 "A" #:in "run"))
           (do  (row "mc|dropoff|water|run|B||2026-10-02" 'dropoff "water" 20.0 "B" #:out "run")))
      ($ obs 'seed-resource (res "w1" "water" 100.0 "A"))
      (cache-solve! "org:t" '() `((material . (,pu ,do))))
      (check "a dropoff confirmed before its pickup is refused"
             (refused? ($ svc 'record-flow "org:t" "dropoff" "water" 20.0 20.0 "B" "2026-10-02" "run" "" "mc|dropoff|water|run|B||2026-10-02")) #t)
      (check "the pickup is confirmed by its id"
             (ok? ($ svc 'record-flow "org:t" "pickup" "water" 20.0 20.0 "A" "2026-10-02" "run" "" "mc|pickup|water|run|A||2026-10-02")) #t)
      (check "…and then the dropoff"
             (ok? ($ svc 'record-flow "org:t" "dropoff" "water" 20.0 20.0 "B" "2026-10-02" "run" "" "mc|dropoff|water|run|B||2026-10-02")) #t)
      (check "…and the stock moved"
             (list (onhand-of obs "w1") (onhand-of obs "res|water|B")) '(80.0 20.0)))))

(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let* ((obs ($ scope 'observer))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "org:t" scope)))
           (call (lambda (q) ($ svc 'record-flow "org:t" "consume" "water" q q "A" "2026-10-02" "P" #f))))
      ($ obs 'seed-resource (res "w1" "water" 100.0 "A"))
      (cache-solve! "org:t" '()
                    `((material . (,(row "mc|consume|water|P|A|2026-10-02" 'consume "water" 10.0 "A" #:in "P")
                                   ,(row "mc|consume|water|P|A|2026-10-02#2" 'consume "water" 5.0 "A" #:in "P")))))
      (check "two rows of one coordinate are one commitment of both quantities"
             (ok? (call 15.0)) #t)
      (check "…and a row finished answers already"
             (assq-ref (cdr (call 1.0)) 'already) #t)
      (check "…the stock took 15" (onhand-of obs "w1") 85.0))))

(display "\n── ONCE: enact and the row door name the same commitment ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let* ((obs ($ scope 'observer))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "org:t" scope)))
           (plan `((material . (,(row "mc|consume|water|P|A||2026-10-02" 'consume "water" 10.0 "A" #:in "P"))))))
      ($ obs 'seed-resource (res "w1" "water" 100.0 "A"))
      (cache-solve! "org:t" '() plan)
      (check "enact records the row" (length (assq-ref (cdr ($ svc 'enact "org:t" plan)) 'events)) 1)
      (check "the row confirmed afterwards answers already"
             (assq-ref (cdr ($ svc 'record-flow "org:t" "consume" "water" 10.0 10.0 "A" "2026-10-02" "P" #f)) 'already) #t)
      (check "…and the stock moved once" (onhand-of obs "w1") 90.0))))

(display "\n── PLAN: enact records what the plan states, and says why a row waits ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let* ((obs ($ scope 'observer))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "org:t" scope)))
           (stated (row "mc|consume|water|P|A||2026-10-02" 'consume "water" 10.0 "A" #:in "P"))
           (alien  (row "mc|consume|water|Q|A||2026-10-02" 'consume "water" 50.0 "A" #:in "Q"))
           (empty  (row "mc|consume|salt|P|Z||2026-10-02" 'consume "salt" 5.0 "Z" #:in "P")))
      ($ obs 'seed-resource (res "w1" "water" 100.0 "A"))
      (cache-solve! "org:t" '() `((material . (,stated ,empty))))
      (let ((r ($ svc 'enact "org:t" `((material . (,stated ,alien ,empty))))))
        (check "only the stated row is recorded"
               (list (length (assq-ref (cdr r) 'events)) (onhand-of obs "w1")) '(1 90.0))
        (check "a row the plan does not state is refused, with the reason"
               (let ((u (assoc "mc|consume|water|Q|A||2026-10-02" (assq-ref (cdr r) 'unmet))))
                 (and u (string-contains (cdr u) "plan") #t))
               #t)
        (check "a row the books cannot serve waits, and the reason is the message"
               (let ((u (assoc "mc|consume|salt|P|Z||2026-10-02" (assq-ref (cdr r) 'unmet))))
                 (and u (string-contains (cdr u) "no such stock") #t))
               #t)))))

(display "\n── LOT: the plan's lot is the one a confirmation draws on ──\n")
(declare-world! #:spans '((0 "2026-10-02" "2026-10-02"))
                #:templates (list (list "bake" '(("loaf" . 1.0)) '(("flour" . 1.0)) 0.0 '() '() '() '() '())))   ; id, outputs, inputs, …)
(let ((persons (let ((h (make-hash-table))) (hash-set! h "ana" #t) h))
      (kept   (res "kept" "loaf" 3.0 "P" #:acct "ana"))
      (lent   (copy-economic-resource (res "lent" "loaf" 3.0 "P" #:acct "ana") #:custodian-scope "T"))
      (water  (res "w" "water" 3.0 "P" #:acct "ana")))
  (check "a loaf a citizen keeps is theirs"        (list (lot-of? kept "loaf~ana" persons) (lot-of? kept "loaf" persons)) '(#t #f))
  (check "a loaf lent to the scope is the commons'" (list (lot-of? lent "loaf" persons) (lot-of? lent "loaf~ana" persons)) '(#t #f))
  (check "a raw a person holds is the scope's capacity" (list (lot-of? water "water" persons) (lot-of? water "water~ana" persons)) '(#t #f)))

(display "\n── AMBIENT: a good with stock behind it is drawn from the stock ──\n")
(let ((ambient? (@@ (playnet solve report) ambient-spec?))
      (raws *raws*)
      (cap  *cap*))
  (hash-clear! raws) (hash-clear! cap)
  (hash-set! raws "sunlight" #t) (hash-set! raws "salt" #t)
  (hash-set! cap (lg "salt" (cell "A" 0)) 40.0)
  (check "a raw declared boundless, with no stock, is ambient" (ambient? "sunlight") #t)
  (check "…a raw that carries stock is not"                    (ambient? "salt") #f)
  (check "…a good no one declared raw is not"                  (ambient? "flour") #f))

(display "\n── ID: a row confirmed by its own id needs no coordinates ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let* ((obs ($ scope 'observer))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "org:t" scope))))
      ($ obs 'seed-resource (res "w1" "water" 100.0 "A"))
      (cache-solve! "org:t" '()
                    `((material . (,(row "mc|consume|water|P|A||2026-10-02" 'consume "water" 10.0 "A" #:in "P")
                                   ,(row "mc|consume|water|P|A||2026-10-02#2" 'consume "water" 5.0 "A" #:in "P")))))
      (check "the schedule's row id confirms its own row, the label and the empty slot notwithstanding"
             (ok? ($ svc 'record-flow "org:t" "consume" "Drinking water" 5.0 5.0 "" "" "" #f "mc|consume|water|P|A||2026-10-02#2"))
             #t)
      (check "…and only that row: the first is untouched"
             (list (onhand-of obs "w1") (assq-ref (cdr ($ svc 'record-flow "org:t" "consume" "water" 5.0 5.0 "A" "2026-10-02" "P" #f
                                                          "mc|consume|water|P|A||2026-10-02#2")) 'already))
             '(95.0 #t))
      (check "an id the plan does not state is refused"
             (car ($ svc 'record-flow "org:t" "consume" "water" 1.0 1.0 "A" "" "P" #f "mc|nothing")) 'error))))

(display "\n── STAMP: a flow happened at its planned slot, or as it was confirmed if that is ahead ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let* ((obs ($ scope 'observer))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "org:t" scope)))
           (t0  (now))
           (slot-row (lambda (id when) (acons 'when when (alist-delete 'when (row id 'consume "water" 10.0 "A" #:in "P")))))
           (last-event (lambda () (car (reverse ($ obs 'all-events))))))
      ($ obs 'seed-resource (res "w1" "water" 100.0 "A"))
      (cache-solve! "org:t" '() `((material . (,(slot-row "mc|past" "2026-09-28T08:00:00")
                                               ,(slot-row "mc|ahead" "2099-01-01T08:00:00")))))
      (letrec ((door (lambda (when) ($ svc 'record-flow "org:t" "consume" "water" 4.0 4.0 "A" when "P" #f))))
        (door "2026-09-28T08:00:00")
        (check "a slot already past is when it happened"
               (event-interval (last-event)) (cons (civil->instant "2026-09-28T08:00:00") (civil->instant "2026-09-28T08:00:00")))
        (door "2099-01-01T08:00:00")
        (let ((iv (event-interval (last-event))))
          (check "a slot still ahead is not: it happens as it is confirmed"
                 (and iv (>= (cdr iv) (- t0 1)) (<= (cdr iv) (+ (now) 1))) #t))
        (check "either states when it was recorded" (and (economic-event-created (last-event)) #t) #t)))))

(test-summary!)
