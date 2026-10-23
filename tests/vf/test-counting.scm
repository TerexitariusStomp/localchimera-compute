;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-counting.scm — the planned count's cadence, regime and grammar
;;; (module/playnet/vf/formulas/counting.scm; docs/observation/capture.md §4).
;;;
;;; What this pins, as properties of the schedule:
;;;
;;;   • a stock the plan stakes more on is counted more often;
;;;   • a ledger that counts find further off is counted more often, and one
;;;     nobody has counted drifts at the prior;
;;;   • a count that costs more is run less often;
;;;   • every interval lies between a day and a year, and a stock the plan
;;;     stakes nothing on is still counted within the year;
;;;   • the class reads the interval against four, two and one counts a year;
;;;   • a stock never counted is due now;
;;;   • a random run's window has the interval as its mean, stays within half
;;;     an interval of it, and is the same whoever asks;
;;;   • a process names its regime and its target, and its event's technique
;;;     leaves the target off.
;;;
;;; Run from project root:
;;;   tools/test/own-ccache.sh guile --no-auto-compile -q -L module tests/vf/test-counting.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)
(add-to-load-path "module")
(use-modules (playnet test harness)
             (playnet vf formulas counting)
             (srfi srfi-1))

(define week 604800.0)
(define day 86400.0)
(define (near? a b) (< (abs (- a b)) 1e-6))

(display "\n── 1. what the plan stakes ──\n")

(check-pred "reliance is the price over the quantity"
            (near? (stock-reliance 2.0 10.0) 20.0))
(check-pred "…over what the plan draws, where it draws more than is there"
            (near? (stock-reliance 2.0 10.0 #:draw 25.0) 50.0))
(check-pred "a good no recipe prices is weighed at the default"
            (near? (stock-reliance #f 10.0) 10.0))
(check-pred "…and so is one priced at infinity"
            (near? (stock-reliance +inf.0 10.0) 10.0))
(check-pred "a stock with nothing on hand and nothing drawn stakes nothing"
            (near? (stock-reliance 2.0 0.0) 0.0))

(display "\n── 2. how fast the figure drifts ──\n")

(check-pred "a ledger nobody has counted drifts at the prior"
            (near? (drift-rate 0 0.0 40.0) 0.05))
(check-pred "counts that found it off by a tenth give a tenth"
            (near? (drift-rate 3 4.0 40.0) 0.1))
(check-pred "counts that found it barely off leave the prior standing"
            (near? (drift-rate 3 0.4 40.0) 0.05))
(check-pred "the share is bounded by one"
            (near? (drift-rate 2 90.0 40.0) 1.0))
(check-pred "further off is faster"
            (> (drift-rate 3 8.0 40.0) (drift-rate 3 4.0 40.0)))

(display "\n── 3. the interval ──\n")

(define (iv d k h) (count-interval d k h))
(check-pred "the interval is T* = sqrt(2K/(Dκ)) periods"
            (near? (iv 40.0 0.05 0.15) (* week (sqrt (/ (* 2 0.15) (* 40.0 0.05))))))
(check-pred "a stock the plan stakes more on is counted more often"
            (< (iv 400.0 0.05 0.15) (iv 40.0 0.05 0.15)))
(check-pred "a ledger that drifts faster is counted more often"
            (< (iv 40.0 0.2 0.15) (iv 40.0 0.05 0.15)))
(check-pred "a count that costs more is run less often"
            (> (iv 40.0 0.05 0.6) (iv 40.0 0.05 0.15)))
(check-pred "no interval is shorter than a day"
            (near? (iv 1e9 1.0 0.15) day))
(check-pred "no interval is longer than a year"
            (near? (iv 1e-9 0.05 0.15) (* 52 week)))
(check-pred "a stock the plan stakes nothing on is counted within the year"
            (near? (iv 0.0 0.05 0.15) (* 52 week)))

(display "\n── 4. the class ──\n")

(check "four times a year or more is A" (count-class (* 13 week)) 'A)
(check "a week is A" (count-class week) 'A)
(check "twice a year is B" (count-class (* 26 week)) 'B)
(check "once a year is C" (count-class (* 52 week)) 'C)
(check-pred "the class never runs against the interval"
            (every (lambda (pair)
                     (let ((a (count-class (car pair))) (b (count-class (cdr pair))))
                       (not (and (eq? a 'C) (eq? b 'A)))))
                   (list (cons week (* 52 week)) (cons (* 2 week) (* 20 week)))))

(display "\n── 5. what a visit costs ──\n")

(check-pred "a visit costs its walk and a line"
            (near? (count-hours 1) (+ %count-hours-per-visit %count-hours-per-line)))
(check-pred "every line more costs a line more"
            (near? (- (count-hours 9) (count-hours 8)) %count-hours-per-line))
(check-pred "a visit counting nothing still costs a line"
            (near? (count-hours 0) (count-hours 1)))

(display "\n── 6. the window of a run ──\n")

(define now 1790000000)
(check "a stock never counted is due now"
       (count-window #f (* 4 week) "announced" "bin/1" #:now now) now)
(check-pred "an announced run falls one interval after the last"
            (near? (count-window 1000.0 (* 4 week) "announced" "bin/1" #:now now)
                   (+ 1000.0 (* 4 week))))
(check-pred "an undisclosed run falls when an announced one would"
            (near? (count-window 1000.0 (* 4 week) "undisclosed" "bin/1" #:now now)
                   (+ 1000.0 (* 4 week))))

(define (rand rid cycle)
  (count-window 1000.0 (* 4 week) "random" rid #:now now #:cycle cycle))
(check-pred "a random run is the same whoever asks"
            (= (rand "bin/1" 7) (rand "bin/1" 7)))
(check-pred "…and differs from cycle to cycle"
            (not (= (rand "bin/1" 7) (rand "bin/1" 8))))
(check-pred "…and from stock to stock"
            (not (= (rand "bin/1" 7) (rand "bin/2" 7))))
(define draws (map (lambda (c) (- (rand "bin/1" c) 1000.0)) (iota 400)))
(check-pred "every random window lies between half an interval and one and a half"
            (every (lambda (d) (and (>= d (* 2 week)) (< d (* 6 week)))) draws))
(check-pred "their mean is the interval, to within a tenth of it"
            (< (abs (- (/ (apply + draws) (length draws)) (* 4 week))) (* 0.4 week)))

(display "\n── 7. the schedule ──\n")

(define stocks
  `(((id . "rice")  (name . "rice")  (onhand . 40.0) (price . 0.5) (last-count . ,(- now (* 30 day))))
    ((id . "drill") (name . "drill") (onhand . 1.0)  (price . 60.0) (last-count . ,(- now (* 2 day))))
    ((id . "salt")  (name . "salt")  (onhand . 2.0)  (price . 0.1))
    ((id . "flour") (name . "flour") (onhand . 40.0) (price . 0.5)
     (drift-n . 4) (drift-mean . 10.0) (last-count . ,(- now (* 30 day))))))
(define sched (count-schedule stocks #:now now))
(define (row id) (find (lambda (r) (equal? id (assq-ref r 'id))) sched))

(check "every stock has a row" (length sched) 4)
(check-pred "the schedule runs soonest due first"
            (let ((dues (map (lambda (r) (assq-ref r 'due-at)) sched)))
              (equal? dues (sort dues <))))
(check-pred "a stock never counted is overdue" (assq-ref (row "salt") 'overdue?))
(check-pred "a row keeps the stock's own fields"
            (and (equal? "rice" (assq-ref (row "rice") 'name))
                 (near? 40.0 (assq-ref (row "rice") 'onhand))))
(check-pred "flour, which counts found further off than rice, is counted more often"
            (< (assq-ref (row "flour") 'interval) (assq-ref (row "rice") 'interval)))
(check-pred "the drill, which the plan stakes more on than the rice, is counted more often"
            (< (assq-ref (row "drill") 'interval) (assq-ref (row "rice") 'interval)))
(check-pred "every interval lies between a day and a year"
            (every (lambda (r) (let ((i (assq-ref r 'interval)))
                                 (and (>= i day) (<= i (* 52 week)))))
                   sched))
(check-pred "every row names its class"
            (every (lambda (r) (memq (assq-ref r 'class) '(A B C))) sched))
(check-pred "every row names its regime"
            (every (lambda (r) (equal? "announced" (assq-ref r 'regime))) sched))
(check-pred "a container counted with what is in it costs a line for each"
            (> (assq-ref (count-row '((id . "bin") (onhand . 1.0) (lines . 9)) #:now now) 'hours)
               (assq-ref (count-row '((id . "bin") (onhand . 1.0) (lines . 1)) #:now now) 'hours)))

(display "\n── 8. the process grammar ──\n")

(define p (count-process "random" "bin/1"))
(check "a process names its regime and its target" p "count~random~bin/1")
(check-pred "it is a count process" (count-process? p))
(check "its regime reads back" (count-process-regime p) "random")
(check "its target reads back" (count-process-target p) "bin/1")
(check "a target with a tilde in it reads back whole"
       (count-process-target (count-process "announced" "means:ada:oven~2")) "means:ada:oven~2")
(check "its event's technique leaves the target off" (count-technique p) "count~random")
(check "a regime the grammar does not know is announced"
       (count-process-regime (count-process "loud" "bin/1")) "announced")
(check-pred "an announced count shows the ledger's figure" (not (count-blind? (count-process "announced" "x"))))
(check-pred "an undisclosed count is counted blind" (count-blind? (count-process "undisclosed" "x")))
(check-pred "a random count is counted blind" (count-blind? (count-process "random" "x")))
(check-pred "a recipe's process is no count" (not (count-process? "bake")))
(check-pred "an unplanned count's technique is no planned count"
            (not (count-process-regime "count:stated")))
(check "…and names no target" (count-process-target "count:stated") #f)
(check "nothing names no target" (count-process-target #f) #f)

;;; ── what a count is of ─────────────────────────────────────────────────

(display "\n── the stock a count is of ──\n")
(check "an adjustment is of the stock it lands on" (count-target "crate" '()) "crate")
(check "a record is of the stock its tag names" (count-target #f (list (count-of-tag "crate"))) "crate")
(check "the stock wins over a tag" (count-target "jar" (list (count-of-tag "crate"))) "jar")
(check "an event of no stock is of none" (count-target #f '("evidence:x")) #f)
(check "no tags is none" (count-target #f #f) #f)

;;; ── a count's family is named in one place ──────────────────────────────

(display "\n── the family of a count ──\n")
(check "a count's id is named by who, what, when and the figure" (count-id-at "ada" "r1" "2026-09-20T08:00:00Z" 27.5) "evt-count-ada-r1-2026-09-20T08:00:00Z-27.5")
(check "a whole figure is spelled once, however it was written" (list (count-figure-text 8) (count-figure-text 8.0)) '("8" "8"))
(check "…and 8 and 8.0 name one count" (equal? (count-id-at "a" "r" "t" 8) (count-id-at "a" "r" "t" 8.0)) #t)
(check "a reading is named by who read, the form found and when" (count-reading-id "ada" "batch+6K" "2026-09-20T08:00:00Z") "evt-read-ada-batch+6K-2026-09-20T08:00:00Z")
(check "the record is named from the adjustment" (count-record-id "evt-count-7-9") "evt-count-7-9-record")
(check "the hours are named from the adjustment" (count-hours-id "evt-count-7-9") "evt-count-7-9-hours")
(check "a name built is a name recognised: the record's base is the adjustment"
       (count-base-id (count-record-id "evt-count-7-9")) "evt-count-7-9")
(check "…and the hours'" (count-base-id (count-hours-id "evt-count-7-9")) "evt-count-7-9")
(check "an id with neither suffix is its own base" (count-base-id "evt-count-7-9") "evt-count-7-9")
(check-pred "the family holds the adjustment, the record and the hours"
            (every (lambda (id) (count-family-id? "evt-count-7-9" id))
                   (list "evt-count-7-9" (count-record-id "evt-count-7-9") (count-hours-id "evt-count-7-9"))))
(check-pred "…and nothing of another count, nor the cascade the observer owns"
            (not (any (lambda (id) (count-family-id? "evt-count-7-9" id))
                      (list "evt-count-7-90" "evt-count-7-91-record" "evt-count-8"
                            "evt-count-7-9~contains~jar"))))
(check "a count's figure is read back off its tag"
       (count-figure (list "evidence:x" (count-figure-tag 42 "kg"))) '(42.0 . "kg"))
(check "…and an event without one states none" (count-figure '("evidence:x")) #f)
(check "a contest of any part is the count's ballot"
       (list (contest-ballot-id (count-record-id "evt-count-7-9") #t) (contest-ballot-id "evt-count-7-9" #t))
       '("contest:evt-count-7-9" "contest:evt-count-7-9"))
(check "a contest of work names the event itself, whatever its suffix"
       (contest-ballot-id "ev-1-hours" #f) "contest:ev-1-hours")

(test-summary!)
