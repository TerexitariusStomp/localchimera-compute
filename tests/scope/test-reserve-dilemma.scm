;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-reserve-dilemma.scm — the calamity has arrived: bare need vs the stock
;;; kept for exactly this.
;;;
;;; In a scenario tree the reserve yields to the p=0 tail by construction
;;; (solve/robust.scm reserve-yields-to; test-granary-under-uncertainty G7). In ONE world
;;; there is no tail to name: a shock now — a season's labour collapsing to a few
;;; hours — shows up as a program with no answer, the subsistence floor and the
;;; reserve both hard against a supply that cannot carry both. reserve-dilemma
;;; (live.scm) prices the two ways out, the same move as plan-dilemma:
;;;   HORN A — hold the reserve, people go short (the floor becomes a desire);
;;;   HORN B — eat the reserve, people are fed (the reserve becomes a soft want).
;;; The planner does not choose; it puts both numbers in front of whoever does.
;;;
;;;   R1  with labour for both, the two hold together — no dilemma
;;;   R2  with labour for one, they cannot — feasible-together? #f, both horns real plans
;;;   R3  horn A keeps the reserve and reports the household's shortfall
;;;   R4  horn B feeds the household and reports how much of the reserve is drawn
;;;   R5  the two numbers are the SAME scarcity read from either side (shortfall ≈ drawn)
;;;
;;; Run: guile --no-auto-compile -L module tests/scope/test-reserve-dilemma.scm

(use-modules ((localchimera utils units) #:select (%effort-unit)))
(use-modules (localchimera test harness) (localchimera vf schemas) (localchimera vf beyond schedules) (localchimera scope live)
             (srfi srfi-1) (ice-9 format))
(use-modules ((localchimera solve engine) #:select (set-period-length!)))
;; A period here is a WEEK: `hours h` names Monday 00:00–h:00, so a period holding the week holds h hours, on any date.
(set-period-length! 1.0 "week")

(define (hours h) (make-availability-window #f #f
                    (list (make-day-schedule '(monday) (list (make-time-range "00:00" (format #f "~2,'0d:00" h))))) #f))
(define spatials (list (make-spatial-thing #:id "town" #:lat 0.0 #:long 0.0)))
(define resources (list (make-economic-resource #:id "sk" #:conforms-to "farming" #:classified-as '()
    #:accounting-quantity (make-measure 1.0 "kg") #:onhand-quantity (make-measure 1.0 "kg") #:current-location "town" #:primary-accountable "ada")))
(define procs (list (make-recipe-process #:id "grow" #:name "Grow")))
;; 1 h → 10 kg food
(define flows
  (list (make-recipe-flow #:id "g1" #:action 'produce #:resource-conforms-to "food"
                          #:resource-quantity (make-measure 10.0 "kg") #:recipe-output-of "grow"
                          #:is-primary #t)
        (make-recipe-flow #:id "g2" #:action 'work #:resource-conforms-to "farming"
                          #:effort-quantity (make-measure 1.0 %effort-unit) #:recipe-input-of "grow")))

(define FLOOR 100.0) (define RES 25.0)
(define FLOORS `(("food#town@0" . ,FLOOR)))
(define INS    `(("food#town@0" ,RES ,(* 1.3 RES) 0.5 5.0)))    ; the calamity stock behind food
(define (dilemma h)
  (reserve-dilemma resources (list (make-agent #:id "ada" #:type 'person #:name "Ada"
                                               #:primary-location "town" #:classified-as '()
                                               #:availability-window (hours h))) spatials procs flows
                   #:repro-floors FLOORS #:insurance INS))

(define ok (dilemma 20))                    ; 200 kg of labour: floor 100 + reserve 25 both hold
(define d  (dilemma 11))                    ; 110 kg: one or the other, not both
(define a (assq-ref d 'horn-a)) (define b (assq-ref d 'horn-b))
(define shortfall (assoc-ref (assq-ref a 'shortfall) "food#town@0"))
(define drawn     (assoc-ref (assq-ref b 'drawn) "food#town@0"))

(format #t "~%── the season's labour collapses to 11 h (110 kg); floor 100 + reserve 25 ──~%")
(format #t "  HORN A — hold the reserve: the household is short by ~,1f of ~,0f~%" shortfall FLOOR)
(format #t "  HORN B — eat the reserve:  ~,1f of the ~,0f is drawn to feed the floor~%" drawn RES)

(check "R1 with labour for both, they hold together" (assq-ref ok 'feasible-together?) #t)
(check "R2 with labour for one, they cannot" (assq-ref d 'feasible-together?) #f)
(check-pred "R2' both horns are real plans" (and (eq? #t (assq-ref (assq-ref a 'plan) 'feasible))
                                                 (eq? #t (assq-ref (assq-ref b 'plan) 'feasible))))
(check-pred "R3 horn A keeps the reserve and the household is short (≈ 15)" (and (> shortfall 10.0) (< shortfall 20.0)))
(check-pred "R4 horn B feeds the household by drawing the reserve (≈ 15 of 25)" (and (> drawn 10.0) (< drawn 20.0)))
(check-pred "R5 one scarcity, read from either side: shortfall ≈ drawn" (< (abs (- shortfall drawn)) 2.0))
(test-summary!)
