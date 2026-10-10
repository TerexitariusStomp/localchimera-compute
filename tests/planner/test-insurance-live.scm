;;; test-insurance-live.scm — the governed calamity reserve, on a LIVE scope.
;;;
;;; The mechanism (held per scenario, the granary banked before the monsoon) was
;;; proven on plan-from-records. This is the live seam: a real plan-scope->alist
;;; solve with #:insure? #t reads the GOVERNED insurance catalogue
;;; (knowledge/insurance-catalogue.scm, q^res = ι·q*), stands a `held` reserve
;;; behind every demanded good whose spec carries a row, and reports the cell's
;;; tab — desired q*, reserve q^res, their sum the target, and the level held.
;;;
;;;   L1  a scope wanting 100 food holds q* + q^res: the reserve sits UNDER the want
;;;   L2  the tab is reported: (good desired reserve target level) per reserved good
;;;   L3  a good with no catalogue row carries no reserve (and no tab entry)
;;;   L4  #:insure? #f opts out: the plan the scope had, want alone (no reserve)
;;;   L5  an explicit #:insurance row rides beside the governed ones
;;;   L6  under scarcity the WANT yields first, the reserve holds (need before want)
;;;   L7  a reserve labour cannot reach ⇒ INFEASIBLE, said out loud, never shrunk
;;;   L8  a subsistence floor and a reserve on one good STACK: need + calamity stock
;;;       are both held, the want above both
;;;   L9  a reserve is a LEVEL: at the horizon's last period it stands (nothing
;;;       spends it in the final period), where a floor is a flow re-asked each period
;;;   L7' …and the plan carries the reserve's DILEMMA, priced on the same world:
;;;       hold the stock and go short, or eat it and be fed
;;;   L11 the tab as the wheel reads it (reserve-controls): a reserve wedge whose
;;;       slack is the room above the calamity stock — 1 at the target, ~0.4 when
;;;       scarcity ate most of the want, the stock intact
;;;   L10 federation parity: a commune's scope record (engine/federation-solve.scm) carries
;;;       #:insurance the same way — a `held` among its forms
;;; Pure solver (no ACDCs) ⇒ no blake3.
;;; Run: guile -L module tests/planner/test-insurance-live.scm

(use-modules (playnet test harness) (playnet test scope)
             (playnet vf schemas) (srfi srfi-1)
             (playnet scope live)
             (goblins) (goblins vat) (srfi srfi-1))

;; A period here is a WEEK: the roster's window is read over its seven days, so
;; `weekday-window` is a working week and `hours-of h` is h hours, on any date.
(use-modules ((playnet solve engine) #:select (set-period-length!)))
(set-period-length! 1.0 "week")
(define win (all-week-window "00:00" "23:00"))

;; two goods: food (a governed reserve row) and cloth (none); one hour each per unit
(define procs (list (rp* "grow" "Grow food") (rp* "weave" "Weave cloth")))
(define flows (list (out* "o1" "food"  1.0 "grow")  (wk* "w1" "farming" 0.1 "grow")
                    (out* "o2" "cloth" 1.0 "weave") (wk* "w2" "weaving" 0.1 "weave")))
(define recipes (list (make-recipe #:id "grow-r" #:name "Grow" #:primary-output "food"
                                   #:recipe-processes '() #:recipe-exchanges '())
                      (make-recipe #:id "weave-r" #:name "Weave" #:primary-output "cloth"
                                   #:recipe-processes '() #:recipe-exchanges '())))
(define chain `(("grow-r" ,(list-ref procs 0)) ("weave-r" ,(list-ref procs 1))))
(define resources (list (er "r-f" "farming" "ann") (er "r-w" "weaving" "ann")))
(define agents (list (make-agent #:id "ann" #:type 'person #:primary-location "town"
                                 #:classified-as '() #:availability-window win)))
(define spatials (list (make-spatial-thing #:id "town" #:lat 40.0 #:long -74.0)))

(define vat (spawn-vat #:name "insurance-live"))
(define* (solve #:key (hours-window win) (demand '(("food#town@0" . 100.0) ("cloth#town@0" . 20.0)))
                #:allow-other-keys #:rest opts)
  (let ((agents (list (make-agent #:id "ann" #:type 'person #:primary-location "town"
                                  #:classified-as '() #:availability-window hours-window)))
        (opts (let loop ((o opts) (acc '()))       ; strip our own keys, forward the rest
                (cond ((null? o) (reverse acc))
                      ((memq (car o) '(#:hours-window #:demand)) (loop (cddr o) acc))
                      (else (loop (cddr o) (cons (cadr o) (cons (car o) acc))))))))
  (with-vat vat
    (let ((scope (mock-scope #:resources resources #:agents agents #:spatials spatials
                             #:recipes recipes #:flows flows #:chain chain)))
      (apply plan-scope->alist scope #:demand demand #:backend 'native-c #:allow-infeasible? #t opts)))))
(define (produced plan spec)
  (fold (lambda (m a) (if (and (eq? (assq-ref m 'action) 'produce) (equal? (assq-ref m 'conforms-to) spec))
                          (+ a (assq-ref m 'quantity)) a))
        0.0 (assq-ref plan 'material)))
(define (tab plan good) (find (lambda (r) (equal? (assq-ref r 'good) good)) (assq-ref plan 'reserves)))

(define off (solve #:insure? #f))
(define on  (solve #:insure? #t))
(define row (insurance-profile "food" 100.0))                     ; the governed profile at q* = 100
(define both (solve #:insure? #t #:insurance '(("cloth#town@0" 5.0 8.0 0.5 5.0))))

(display "\n── the governed reserve, live ──\n")
(format #t "  catalogue: food ι=~a ⇒ at q*=100 the held profile is ~a\n" (ins-iota (insurance-row "food")) row)
(format #t "  insure? #f: food produced ~,2f   reserves ~a\n" (produced off "food") (assq-ref off 'reserves))
(format #t "  insure? #t: food produced ~,2f   tab ~a\n" (produced on "food") (tab on "food#town@0"))
(format #t "              cloth produced ~,2f  tab ~a\n" (produced on "cloth") (tab on "cloth#town@0"))

(define food-tab (tab on "food#town@0"))
(check-pred "L1 the reserve sits UNDER the want: food held ≥ q* + q^res (100 + 25)"
            (>= (produced on "food") (- (+ 100.0 (car row)) 0.5)))
(check-pred "L1' …and not past the margin's comfort (≤ q* + hi)"
            (<= (produced on "food") (+ 100.0 (cadr row) 0.5)))
(check-pred "L2 the tab is reported: desired 100, reserve 25, target 125"
            (and food-tab (= (assq-ref food-tab 'desired) 100.0)
                 (< (abs (- (assq-ref food-tab 'reserve) (car row))) 1e-9)
                 (< (abs (- (assq-ref food-tab 'target) (+ 100.0 (car row)))) 1e-9)))
(check-pred "L2' the level on the tab is what the plan holds (≈ produced)"
            (< (abs (- (assq-ref food-tab 'level) (produced on "food"))) 0.5))
(check-pred "L3 a good with no catalogue row carries no reserve, no tab entry"
            (and (not (tab on "cloth#town@0")) (< (abs (- (produced on "cloth") 20.0)) 0.5)))
(check-pred "L4 insure? #f: no reserve, food at its want alone"
            (and (null? (assq-ref off 'reserves)) (< (abs (- (produced off "food") 100.0)) 0.5)))
(check-pred "L5 an explicit #:insurance row rides beside the governed ones (cloth gains a tab)"
            (and (tab both "cloth#town@0") (>= (produced both "cloth") 24.5) (tab both "food#town@0")))

;; ── scarcity: the want yields, the reserve holds; below the reserve, INFEASIBLE ──
;; food costs 0.1 h/unit: 125 food + 20 cloth = 14.5 h. Give Ann 8 h → 80 units of
;; work-time; the reserve (25) is a need, the want (100) is not.
(define scarce (solve #:insure? #t #:hours-window (hours-of 8)))
(define scarce-tab (tab scarce "food#town@0"))
(format #t "  scarce (8 h): feasible ~a  food ~,2f  cloth ~,2f  tab ~a
"
        (assq-ref scarce 'feasible) (produced scarce "food") (produced scarce "cloth") scarce-tab)
(check-pred "L6 under scarcity the WANT yields first: food falls below q* + q^res but never below q^res"
            (and (eq? (assq-ref scarce 'feasible) #t)
                 (< (produced scarce "food") 124.0)
                 (>= (produced scarce "food") (- 25.0 0.5))))
(check-pred "L6' the tab still reports the reserve and target it aimed at"
            (and scarce-tab (= (assq-ref scarce-tab 'target) 125.0)))
;; below the reserve itself: 1 h buys 10 units, the reserve wants 25 ⇒ no plan
(define starved (solve #:insure? #t #:hours-window (hours-of 1)))
(format #t "  starved (1 h): feasible ~a  food ~,2f
" (assq-ref starved 'feasible) (produced starved "food"))
(check-pred "L7 a reserve labour cannot reach is INFEASIBLE, said out loud — never quietly shrunk"
            (eq? (assq-ref starved 'feasible) #f))
(define dil (assq-ref starved 'reserve-dilemma))
(format #t "  dilemma: together? ~a  horn A short ~a  horn B drawn ~a
"
        (and dil (assq-ref dil 'feasible-together?))
        (and dil (assq-ref (assq-ref dil 'horn-a) 'shortfall))
        (and dil (assq-ref (assq-ref dil 'horn-b) 'drawn)))
(check-pred "L7' the infeasible plan carries the reserve's dilemma, priced on the same world: here so deep that holding the reserve is no plan at all and only eating it is"
            (and dil (eq? #f (assq-ref dil 'feasible-together?))
                 (eq? #f (assq-ref (assq-ref dil 'horn-a) 'feasible))
                 (eq? #t (assq-ref (assq-ref dil 'horn-b) 'feasible))))
(check-pred "L7'' the feasible plan carries no dilemma"
            (not (assq-ref on 'reserve-dilemma)))

;; ── a subsistence floor and a reserve on ONE good stack: need + calamity stock ──
(define stacked (solve #:insure? #t #:repro-floors '(("food#town@0" . 40.0))))
(format #t "  floor 40 + reserve 25 + want 100: food ~,2f
" (produced stacked "food"))
(check-pred "L8 floor + reserve + want on one good: the plan holds all three (≈ 165)"
            (>= (produced stacked "food") (- 165.0 0.5)))

;; ── a reserve is a LEVEL: it stands at the horizon's edge ──
(define two (solve #:insure? #t #:periods '(0 1) #:storable '("food")
                   #:demand '(("food#town@0" . 100.0) ("food#town@1" . 100.0))))
(define t1 (tab two "food#town@1"))
(format #t "  two periods: tabs ~a
" (assq-ref two 'reserves))
(check-pred "L9 the reserve stands at the LAST period too — a level, carried out of the horizon"
            (and t1 (>= (assq-ref t1 'level) (- (assq-ref t1 'target) 0.5))))

;; ── federation parity: the commune's scope record pours the same band ──
(define agents1 (list (make-agent #:id "ann" #:type 'person #:primary-location "town"
                                  #:classified-as '() #:availability-window win)))
(define rec (commune->scope-record resources agents1 spatials procs flows
              #:id "town" #:demand '(("food#town@0" . 100.0))
              #:insurance '(("food#town@0" 25.0 32.5 0.5 5.0))))
(define kinds (map (lambda (f) (car f)) (assq-ref rec 'forms)))
(check-pred "L10 commune->scope-record #:insurance: a `held` stands among the commune's forms"
            (memq 'held kinds))

;; ── the wire: the tab as a wheel family ──
(define w-on (car (reserve-controls (assq-ref on 'reserves))))
(define w-scarce (car (reserve-controls (assq-ref scarce 'reserves))))
(format #t "  wire: at target s=~,3f · scarce s=~,3f (kind ~a, tip ~a, target ~a)
"
        (assq-ref w-on 's) (assq-ref w-scarce 's) (assq-ref w-on 'kind) (assq-ref w-on 'tip) (assq-ref w-on 'target))
(check-pred "L11 the reserve wedge: kind reserve, tip = the stock, target = want + stock, s = 1 at the target"
            (and (equal? (assq-ref w-on 'kind) "reserve")
                 (= (assq-ref w-on 'tip) 25.0) (= (assq-ref w-on 'target) 125.0)
                 (> (assq-ref w-on 's) 0.99)))
(check-pred "L11' under scarcity the wedge shows the room the plan kept above the stock (≈ 0.375)"
            (< (abs (- (assq-ref w-scarce 's) 0.375)) 0.02))
(test-summary!)
