;;; test-adjustment.scm — a count lands the difference
;;; (module/playnet/observation/adjustment.scm).
;;;
;;; What this pins:
;;;   • a figure that agrees with the ledger is no difference, and a figure
;;;     within the tolerance of it is the same;
;;;   • a stock never seen holds nothing, so any figure above nothing is a raise;
;;;   • a difference lands as a `raise` above nothing and a `lower` below, of
;;;     its size, in the stock's unit, on that stock;
;;;   • an agreeing count lands no event at all;
;;;   • the technique, the place, the instants, the people and the note ride the
;;;     event where the caller put them, and the rest is absent;
;;;   • the four places that count a stock land through it.
;;;
;;; Run: tools/test/own-ccache.sh guile --no-auto-compile -q -L module tests/observation/test-adjustment.scm

(add-to-load-path "module")
(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness)
             (playnet vf schemas)
             (playnet observation adjustment))

(define (near? a b) (< (abs (- a b)) 1e-12))

(display "\n── 1. the difference ──\n")

(check-pred "a count above the ledger is the excess" (near? (count-difference 10.0 12.5) 2.5))
(check-pred "a count below the ledger is the shortfall, negative" (near? (count-difference 10.0 8.5) -1.5))
(check-pred "a count that agrees is nothing" (zero? (count-difference 10.0 10.0)))
(check-pred "…and so is one within the tolerance" (zero? (count-difference 10.0 (+ 10.0 (/ %count-tolerance 10)))))
(check-pred "…but not one beyond it" (not (zero? (count-difference 10.0 (+ 10.0 (* 10 %count-tolerance))))))
(check-pred "a stock never seen holds nothing" (near? (count-difference #f 4.0) 4.0))
(check-pred "an exact figure reads like an inexact one" (near? (count-difference 3 5) 2.0))
(check "…and stays exact: a stock counted in whole units stays in whole units" (count-difference 3 5) 2)
(check "…whose agreeing count is an exact nothing" (count-difference 3 3) 0)
(check "the tolerance is a billionth" %count-tolerance 1e-9)

(display "\n── 2. the event ──\n")

(define raised
  (adjustment-event "e1" "bin/1" "jam" 2.5 %count-unit
                    #:provider "ada" #:receiver "ada" #:process "count:stated"
                    #:at "place:shelf" #:when "2026-10-01T09:00:00Z" #:created "2026-10-01T09:00:01Z"
                    #:note "count stated: 12.5 each" #:in-scope-of '("org:commune")
                    #:classified-as '("evidence:x")))
(check "a difference above nothing is a raise" (economic-event-action raised) 'raise)
(check "of its size" (measure-has-numerical-value (economic-event-resource-quantity raised)) 2.5)
(check "in the stock's unit" (measure-has-unit (economic-event-resource-quantity raised)) %count-unit)
(check "on the stock counted" (economic-event-resource-inventoried-as raised) "bin/1")
(check "the technique is its process" (economic-event-output-of raised) "count:stated")
(check "the spec rides it" (economic-event-resource-conforms-to raised) "jam")
(check "the counter is provider" (economic-event-provider raised) "ada")
(check "…and receiver" (economic-event-receiver raised) "ada")
(check "the place it was counted at" (economic-event-at-location raised) "place:shelf")
(check "the instant it was counted" (economic-event-has-point-in-time raised) "2026-10-01T09:00:00Z")
(check "the instant it was written" (economic-event-created raised) "2026-10-01T09:00:01Z")
(check "the note" (economic-event-note raised) "count stated: 12.5 each")
(check "the scope" (economic-event-in-scope-of raised) '("org:commune"))
(check "its classifications" (economic-event-resource-classified-as raised) '("evidence:x"))
(check "it fulfils nothing" (economic-event-fulfills raised) #f)

(define lowered (adjustment-event "e2" "bin/1" "jam" -1.5 %count-unit))
(check "a difference below nothing is a lower" (economic-event-action lowered) 'lower)
(check "of its size, never negative" (measure-has-numerical-value (economic-event-resource-quantity lowered)) 1.5)
(check "what the caller left out is absent" (economic-event-output-of lowered) #f)

(check "an agreeing count lands no event" (adjustment-event "e3" "bin/1" "jam" 0.0 %count-unit) #f)
(check "…nor one inside the tolerance" (adjustment-event "e4" "bin/1" "jam" (/ %count-tolerance 10) %count-unit) #f)
(check "…nor a figure that is no number" (adjustment-event "e5" "bin/1" "jam" #f %count-unit) #f)

(display "\n── 3. the places that count ──\n")

(define (source-of f)
  (call-with-input-file f (lambda (p) (let loop ((acc '())) (let ((l (read-line p))) (if (eof-object? l) (apply string-append (reverse acc)) (loop (cons (string-append l "\n") acc))))))))
(use-modules (ice-9 rdelim))
(define (uses? file) (string-contains (source-of file) "adjustment-event"))
(check-pred "a host's probe lands through it" (uses? "module/playnet/observation/host-facts.scm"))
(check-pred "a person's count, a re-declared means and a skill land through it"
            (>= (apply + (map (lambda (file)
                                (let loop ((s (source-of file)) (n 0))
                                  (let ((i (string-contains s "(adjustment-event")))
                                    (if i (loop (substring s (+ i 1)) (+ n 1)) n))))
                              '("module/playnet/doors/service.scm"
                                "module/playnet/doors/count-door.scm"
                                "module/playnet/doors/slots.scm")))
                4))
(check-pred "no place builds a raise or lower by hand any more"
            (not (string-contains (source-of "module/playnet/doors/service.scm") "(if (> delta 0) 'raise 'lower)")))

(use-modules ((playnet vf formulas counting) #:select (count-figure))
             (srfi srfi-1))
(check "an adjustment states the figure that was counted"
       (count-figure (economic-event-resource-classified-as
                      (adjustment-event "e" "r" "flour" -1.5 "kg" #:counted 8.5
                                        #:classified-as '("evidence:x"))))
       '(8.5 . "kg"))
(check "…beside the tags it was given"
       (economic-event-resource-classified-as
        (adjustment-event "e" "r" "flour" -1.5 "kg" #:counted 8.5 #:classified-as '("evidence:x")))
       '("counted:8.5 kg" "evidence:x"))
(check "one that states none carries no tags"
       (economic-event-resource-classified-as (adjustment-event "e" "r" "flour" -1.5 "kg")) #f)
(test-summary!)
