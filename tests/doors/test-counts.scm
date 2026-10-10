;;; test-counts.scm — what the ledger says of counts, and the shapes it reads
;;; (module/playnet/doors/counts.scm, observation/adjustment.scm).
;;;
;;; What this pins:
;;;   • an event is a part of a count by the one rule the contest reads
;;;     (count-event?), and names the stock it counts (count-event-of);
;;;   • the record a planned count lands is a produce of one, held nowhere,
;;;     carrying the count-of tag, the counter's act and the commitment it
;;;     fulfils;
;;;   • the members take turns at a planned count, and its owner is passed over;
;;;   • a door's optional bound reads as a whole number above zero or its default;
;;;   • a door's optional regime reads as a regime or announced;
;;;   • the civil and the epoch reading of an instant are each other's inverse;
;;;   • take-up-to bounds a list;
;;;   • a door answers (ok . x) or (error . words), and a raise becomes the second;
;;;   • the clock states the present instant as a civil string.
;;;
;;; Run: tools/test/own-ccache.sh guile --no-auto-compile -q -L module tests/doors/test-counts.scm

(add-to-load-path "module")
(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness)
             (playnet vf schemas)
             (playnet vf formulas counting)
             (playnet doors counts)
             (playnet utils envelope)
             (playnet observation adjustment)
             (playnet utils clock)
             (playnet utils common))

(display "\n── 1. what a count event is ──\n")

(define adj (adjustment-event "evt-count-1" "bin/1" "jam" 2.0 %count-unit
                              #:provider "ada" #:receiver "ada" #:process "count:stated"))
(define rec (count-record-event "evt-count-1" "bin/1" "count-record"
                                #:provider "ada" #:process "count:stated"
                                #:at "place:shelf" #:when "2026-10-01T09:00:00Z"
                                #:created "2026-10-01T09:00:01Z" #:fulfills "cmt-9"
                                #:note "count stated" #:in-scope-of '("org:commune")
                                #:classified-as '("evidence:sha256:x")))
(define plain (adjustment-event "evt-9" "bin/1" "jam" 2.0 %count-unit
                                #:provider "ada" #:receiver "ada" #:process "ride.ada.walk"))

(check-pred "an adjustment of a count is a part of one" (count-event? adj))
(check-pred "so is its record" (count-event? rec))
(check-pred "an adjustment of something else is not" (not (count-event? plain)))
(check "the adjustment names the stock it lands on" (count-event-of adj) "bin/1")
(check "the record names it by its tag" (count-event-of rec) "bin/1")
(check "something else names nothing" (count-event-of plain) #f)

(display "\n── 2. the record ──\n")

(check "it is a produce" (economic-event-action rec) 'produce)
(check "its id derives from the adjustment's" (economic-event-id rec) (count-record-id "evt-count-1"))
(check "the technique is its process" (economic-event-output-of rec) "count:stated")
(check "held nowhere" (economic-event-resource-inventoried-as rec) #f)
(check "the counter's own act" (list (economic-event-provider rec) (economic-event-receiver rec)) '("ada" "ada"))
(check "one record" (measure-has-numerical-value (economic-event-resource-quantity rec)) 1.0)
(check "the commitment it fulfils" (economic-event-fulfills rec) "cmt-9")
(check "the count-of tag leads, the evidence follows"
       (economic-event-resource-classified-as rec)
       (list (count-of-tag "bin/1") "evidence:sha256:x"))
(check "the instants ride it" (list (economic-event-has-point-in-time rec) (economic-event-created rec))
       '("2026-10-01T09:00:00Z" "2026-10-01T09:00:01Z"))

(display "\n── 3. whose turn ──\n")

(define members '("cy" "ada" "bo"))
(check "the members take turns, by id" (map (lambda (c) (count-counter members #f c)) '(0 1 2 3)) '("ada" "bo" "cy" "ada"))
(check "the owner is passed over while another can count" (count-counter members "ada" 0) "bo")
(check "…every turn" (map (lambda (c) (count-counter members "ada" c)) '(0 1 2)) '("bo" "cy" "bo"))
(check "a scope of one counts its own" (count-counter '("ada") "ada" 5) "ada")
(check "no members, no counter" (count-counter '() #f 0) #f)

(display "\n── 4. the optional arguments ──\n")

(check "a bound above zero is its floor" (limit-or 2.7 3) 2)
(check "a missing bound is the default" (limit-or #f 3) 3)
(check "zero is the default" (limit-or 0 3) 3)
(check "a negative bound is the default" (limit-or -4 5) 5)
(check "a regime is itself" (count-regime "undisclosed") "undisclosed")
(check "an unknown regime is announced" (count-regime "whenever") "announced")
(check "an absent regime is announced" (count-regime #f) "announced")
(check "…and the process reads it the same" (count-process "whenever" "bin/1") (count-process "announced" "bin/1"))

(display "\n── 5. the clock's two readings ──\n")

(check "an epoch reads as civil" (epoch->civil 1700000000) "2023-11-14T22:13:20Z")
(check "a fractional epoch floors" (epoch->civil 1700000000.9) "2023-11-14T22:13:20Z")
(check "civil reads as an epoch" (civil->epoch "2023-11-14T22:13:20Z") 1700000000)
(check "a bare date is its midnight" (civil->epoch "2023-11-14") 1699920000)
(check "no civil string is no epoch" (civil->epoch "tuesday") #f)
(check "…nor a non-string" (civil->epoch #f) #f)

(display "\n── 6. take-up-to ──\n")

(check "the first n" (take-up-to '(1 2 3 4) 2) '(1 2))
(check "all of a shorter list" (take-up-to '(1 2) 5) '(1 2))
(check "none for zero" (take-up-to '(1 2) 0) '())
(check "a non-list passes through" (take-up-to #f 3) #f)

(display "\n── 7. the door's answer, and the present instant ──\n")

(check "success is ok" (success 3) '(ok . 3))
(check "failure is error with words" (failure "no") '(error . "no"))
(check "a thunk's value passes through" (catch-as-failure (lambda () 7)) 7)
(check-pred "a raise is an error answer"
            (let ((r (catch-as-failure (lambda () (error "boom")))))
              (and (eq? (car r) 'error) (string? (cdr r)))))
(check-pred "the present instant is a civil string"
            (and (string? (iso-now)) (civil->epoch (iso-now)) #t))
(check-pred "…and reads as an instant not before the epoch of this file's writing"
            (> (civil->epoch (iso-now)) 1790000000))
(check "a planned count's process is shown as the count of its thing" 
       (count-process-name (let ((o (make-hash-table))) o) "ride.ada.walk") #f)

(test-summary!)
