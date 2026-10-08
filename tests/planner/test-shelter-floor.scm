;;; test-shelter-floor.scm — the two housing claims the first test deferred.
;;;
;;; 1. THE NIGHT PINS THE BED. At abstract day bands an unwindowed bed
;;;    time-multiplexes (24 h / 8 h = 3 sleepers a day — test-housing-
;;;    socialization's met 0.60). The bed's own NIGHT WINDOW is what makes a
;;;    night a night: offered 00:00–08:00, it stands for 8 hours of each day,
;;;    its socialized capacity reads 8 bed-hours (resource-window-hours →
;;;    holding-capacity, the same conversion every held durable gets), and one
;;;    8-hour shelter run per bed per day is all the plan can draw — one
;;;    sleeper per bed per night, with no new mechanism.
;;;
;;; 2. A FLOOR IS A NEED, A DEMAND IS A WANT. Shelter is reproduction, so a
;;;    scope states it as #:repro-floors — defended by the solve — while the
;;;    demand above the floor stays preference. The floor rides through
;;;    plan-commune-scope verbatim, like every other plan-scope keyword.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/planner/test-shelter-floor.scm

(use-modules (playnet test harness)
             (playnet planner knowledge recipes dwelling) (playnet planner scope root) (playnet planner vf schemas) (playnet planner beyond schedules) (srfi srfi-1)
             (playnet planner doors service)
             (playnet governance socialization) (playnet keri acdc-store)
             (goblins) (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

(define OWNER   "EAlice")
(define COMMUNE "ECommune")
(define FUTURE  "2099-12-31T00:00:00Z")
(define DAYS '(monday tuesday wednesday thursday friday saturday sunday))

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Shelter Floor Test"))
    store))

;; the night: a bed offered 00:00–08:00, every day — 8 h of presence per band
(define night-window
  (make-availability-window #f #f
    (list (make-day-schedule DAYS (list (make-time-range "00:00" "08:00"))))
    #f))

(define (alice-flat)
  (make-economic-resource #:id "res:flat" #:name "Alice's flat" #:image "🏠"
                          #:conforms-to "spec-dwelling" #:classified-as '() #:onhand-quantity (make-measure 1 "each")
                          #:current-location "town" #:primary-accountable OWNER))
(define (alice-beds)
  (make-economic-resource #:id "res:beds" #:name "Alice's guest room" #:image "🏠"
                          #:conforms-to "spec-bed" #:classified-as '() #:onhand-quantity (make-measure 2 "each") #:primary-accountable OWNER #:contained-in "res:flat"
                          #:availability-window night-window))

(define acdc #f)
(define resolve #f)

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    (seed-dwelling-specs rs)
    (seed-dwelling-recipe rs))
  ($ ($ scope 'spatial-thing-store) 'add-location
     (make-spatial-thing #:id "town" #:name "Town" #:lat 52.5 #:long 13.4))
  (let* ((m-obs  (spawn ^mock `((all-resources . ,(lambda () (list (alice-flat) (alice-beds)))))))
         (m-root (spawn ^mock `((observer   . ,(lambda () m-obs)))))
         (m-comm (spawn ^mock `((scope-root . ,(lambda () m-root)))))
         (fed    (spawn ^mock `((members    . ,(lambda () (hashmap-set (hashmap) "commA" m-comm)))))))
    (set! resolve (federation-resource-resolver fed)))
  (set! acdc (spawn-acdc-store))
  (socialize-private-resource acdc OWNER COMMUNE "spec-dwelling" 1 #:until FUTURE))

(define* (solve #:key (floors '()))
  (with-vat vat
    (apply plan-commune-scope scope acdc COMMUNE
           #:resolve resolve
           #:demand '(("spec-shelter#town@0" . 10.0))
           #:backend 'native-c
           (if (pair? floors) (list #:repro-floors floors) '()))))

(display "\n── 1. the night window pins one sleeper per bed per night ──\n")
(define res (solve))
(define met (assq-ref res 'met))
(format #t "  2 beds offered 00:00–08:00 ⇒ shelter demand met ~,2f~%" met)
(check-pred "windowed beds house exactly 2 of the 10 (no time-multiplexing)"
            (and (number? met) (> met 0.15) (< met 0.25)))

(display "\n── 2. the floor is DEFENDED; the want above it stays a want ──\n")
(define res-f (solve #:floors '(("spec-shelter#town@0" . 2.0))))
(define met-f (assq-ref res-f 'met))
(define delivered
  (fold (lambda (m acc)
          (if (and (equal? "spec-shelter" (assq-ref m 'conforms-to))
                   (memq (assq-ref m 'action) '(produce deliver-service)))
              (+ acc (abs (or (assq-ref m 'quantity) 0)))
              acc))
        0 (or (assq-ref res-f 'material) '())))
(format #t "  floor 2 person-nights ⇒ delivered ~,2f, met ~,2f~%" delivered met-f)
(check-pred "the floor is met in full — reproduction defended, not preferred"
            (>= delivered 1.99))
;; the two bed-nights all went to the floor, so the want above it reads ~0:
;; the need was served FIRST, and preference gets only what remains
(check-pred "…and the want above the floor gets only what remains (here: nothing)"
            (and (number? met-f) (< met-f 0.05)))

(test-summary!)
