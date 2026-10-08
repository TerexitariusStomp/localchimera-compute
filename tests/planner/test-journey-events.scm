;;; test-journey-events.scm — the observed arc-time table starts breathing.
;;;
;;; A map journey becomes VF records through the planner service. It is one
;;; performed Process, `based-on` the scope's mode for the way it was made, with
;;; two commitments and the two events that fulfil them:
;;;
;;;   journey-begin → the trip's Process (held by the observer, written to the log)
;;;                   + the pickup commitment (the trip as input-of, at the origin)
;;;                   + the dropoff commitment (the trip as output-of, at the destination)
;;;                   + the pickup event, fulfilling the first
;;;   journey-end   → the dropoff event, fulfilling the second
;;;
;;; and the observer's arc-observations, the SAME derived view the live arc-time
;;; table folds, yields the trip as (from to process hours begin): the observer
;;; reports the raw trip, and the manner is resolved where the policy lives, off
;;; the mode recipe the process is based on (live.scm trip-manner-of).
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-journey-events.scm

(use-modules (playnet test harness))
(use-modules (playnet planner knowledge recipes transport) (playnet planner scope root) (playnet planner vf schemas) (playnet planner observation states) (srfi srfi-1))
(use-modules (playnet planner doors service))
(use-modules (playnet planner scope live))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

(display "\n── Setup: scope + planner service ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Journey Test"))
    store))

(with-vat vat
  (define svc (spawn ^planner-service (hashmap-set (hashmap) "org:test" scope)))
  (define obs ($ scope 'observer))
  (define ps  ($ scope 'plan-store))
  (seed-baseline-modes! ($ scope 'recipe-store))      ; every scope's own ways to travel

  ;; ── depart ────────────────────────────────────────────────────────────────
  (define began ($ svc 'journey-begin "org:test" "ana" "depot" "clinic" "bicycle"))
  (check "journey-begin returns ok" (car began) 'ok)
  (define cid (assq-ref (cdr began) 'commitment))
  (define dcid (assq-ref (cdr began) 'arrival))
  (check-pred "a commitment id was minted for each end" (and (string? cid) (string? dcid) (not (equal? cid dcid))))

  (define pickups ($ obs 'events-with-action 'pickup))
  (check "one pickup event recorded" (length pickups) 1)
  (define pid (economic-event-input-of (car pickups)))
  (check-pred "the pickup carries the trip's process, an opaque id" (and (string? pid) (not (string-prefix? "ride." pid))))
  (check "pickup fulfills the pickup commitment" (economic-event-fulfills (car pickups)) cid)
  (check "the pickup is of the origin, and goes nowhere" (list (economic-event-at-location (car pickups)) (economic-event-to-location (car pickups)))
         '("depot" #f))
  (check "it moves one rider, as the mode's pickup flow says"
         (list (economic-event-resource-conforms-to (car pickups))
               (measure-has-numerical-value (economic-event-resource-quantity (car pickups))))
         '("spec-rider" 1))

  ;; the trip is a Process the books hold, based on the mode for the way it was made
  (let ((p ($ obs 'get-process pid)))
    (check "the observer holds the trip's process" (and p #t) #t)
    (check "…based on the scope's bicycle mode" (and p (process-based-on p)) "pspec-bike")
    (check-pred "…classified by the costing it was made under" (and p (member "manner:bicycle" (process-classified-as p)))))
  (let ((c ($ ps 'get-commitment cid)) (d ($ ps 'get-commitment dcid)))
    (check "the pickup commitment is the trip's input, at the origin"
           (list (commitment-action c) (commitment-input-of c) (commitment-at-location c)) (list 'pickup pid "depot"))
    (check "the dropoff commitment is the trip's output, at the destination"
           (list (commitment-action d) (commitment-output-of d) (commitment-at-location d)) (list 'dropoff pid "clinic")))

  ;; mid-journey: no completed trip yet
  (check "no trip before arrival" ($ obs 'arc-observations) '())

  (sleep 1)                                  ; iso-now is second-granular

  ;; ── arrive ────────────────────────────────────────────────────────────────
  (define ended ($ svc 'journey-end "org:test" "ana" cid "depot" "clinic" "bicycle"))
  (check "journey-end returns ok" (car ended) 'ok)
  (define dropoffs ($ obs 'events-with-action 'dropoff))
  (check "one dropoff event recorded" (length dropoffs) 1)
  (check "it is the trip's output, fulfilling the dropoff commitment"
         (list (economic-event-output-of (car dropoffs)) (economic-event-input-of (car dropoffs)) (economic-event-fulfills (car dropoffs)))
         (list pid #f dcid))
  (check "it arrives at the destination" (list (economic-event-at-location (car dropoffs)) (economic-event-to-location (car dropoffs)))
         '("clinic" "clinic"))
  (check "both commitments are finished"
         (map (lambda (k) (fulfillment-state-finished ($ obs 'get-fulfillment k))) (list cid dcid)) '(#t #t))

  ;; ── the table's food: a positive-duration trip, and its manner off the recipe ──
  (define trips ($ obs 'arc-observations))
  (check "exactly one trip observed" (length trips) 1)
  (let ((tr (car trips)))
    (check "trip from"   (first tr)  "depot")
    (check "trip to"     (second tr) "clinic")
    (check "the observer reports the trip's process, not a vocabulary" (third tr) pid)
    (check "…whose manner the live boundary reads off the mode recipe" ((trip-manner-of scope) pid) "bicycle")
    (check-pred "trip duration positive hours"
                (and (> (fourth tr) 0.0) (< (fourth tr) 0.01)))
    (check-pred "begin epoch rides as 5th element (for period-classing)"
                (and (= (length tr) 5) (number? (fifth tr)))))

  ;; ── a second journey by the same agent+mode is its own process ────────────
  (define b2 ($ svc 'journey-begin "org:test" "ana" "clinic" "depot" "bicycle"))
  (sleep 1)
  ($ svc 'journey-end "org:test" "ana" (assq-ref (cdr b2) 'commitment)
     "clinic" "depot" "bicycle")
  (check "recurring rides are one trip each" (length ($ obs 'arc-observations)) 2)
  (check "…each its own process" (length (delete-duplicates (map third ($ obs 'arc-observations)))) 2)

  ;; ── a costing no mode carries still files a trip, under its own costing ───
  (let* ((b3 ($ svc 'journey-begin "org:test" "ana" "depot" "clinic" "motor_scooter"))
         (pid3 (economic-event-input-of
                (find (lambda (e) (equal? (economic-event-fulfills e) (assq-ref (cdr b3) 'commitment)))
                      ($ obs 'events-with-action 'pickup)))))
    (sleep 1)
    ($ svc 'journey-end "org:test" "ana" (assq-ref (cdr b3) 'commitment) "depot" "clinic" "motor_scooter")
    (check "a costing with no mode of its own reads as itself" ((trip-manner-of scope) pid3) "motor_scooter"))
) ;; end with-vat

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
