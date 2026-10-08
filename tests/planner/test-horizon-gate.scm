;;; test-horizon-gate.scm — the accept gate at the plan-store's doors.
;;;
;;; docs/planning/solve/commitment-horizon.md: a work intent's window may reach at
;;; most the recipe chain's own duration plus a governed margin; further out,
;;; the accept is refused and the stability belongs to the standing
;;; declaration. The gate is a standing callback (`set-gate`), consulted at
;;; BOTH doors — promote-to-commitment and accept-proposal — and installed on
;;; every scope by rewire-callbacks, so a fresh spawn-scope-root carries it.

(use-modules (playnet test harness)
             (playnet planner vf schemas)
             (playnet planner plan store)
             (playnet planner plan horizon-gate)
             (playnet planner scope root)
             (playnet planner knowledge dsl shorthand)
             ((playnet utils clock) #:select (now instant->civil civil->instant))
             (goblins) (goblins vat)
             (srfi srfi-1)
             (ice-9 format))

(define vat (spawn-vat #:name "horizon-gate"))

(define (iso-in days) (instant->civil (inexact->exact (round (+ (now) (* days 86400))))))

(define (work-intent id proc end)
  (make-intent #:id id #:action 'work #:input-of proc #:resource-conforms-to "skill-bake"
               #:effort-quantity (make-measure 2.0 "hours") #:has-end end #:at-location "town" #:planned-within "plan-1"))

(define (raises? thunk) (catch #t (lambda () (thunk) #f) (lambda _ #t)))

;; the shape offer-work lays: a shift with BOTH ends stated
(define (shift-intent id proc from until)
  (make-intent #:id id #:action 'work #:input-of proc #:resource-conforms-to "skill-bake"
               #:effort-quantity (make-measure 2.0 "hours")
               #:has-beginning from #:has-end until #:at-location "town" #:planned-within "plan-1"))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. The gate function: reach against L + governed margin
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. the ceiling: chain duration + the agent's notice, floors wider ──\n")

(define (^mock bcom table)
  (lambda (msg . args) (let ((p (assq msg table))) (if p (apply (cdr p) args) (error "mock: no method" msg)))))

(with-vat vat
  (let* ((bake (rp* "bake" "Bake" 3.0))
         (rs (spawn ^mock `((all-recipes . ,(lambda () (list (make-recipe #:id "r1" #:name "Bread"
                                                                          #:primary-output "bread"
                                                                          #:recipe-processes '()
                                                                          #:recipe-exchanges '()))))
                            (get-process-chain . ,(lambda (rid) (list bake))))))
         (gate (make-horizon-gate rs))
         ;; the latest solve's own read, as plan-scope caches it: bake
         ;; defends a floor, and the drought branch stretches its chain
         ;; 96× (3 h → 12 d) — the worst defended branch's longer chain
         ;; IS the floor's extra reach, derived, no margin knob
         (derived '((floor-procs . ("bake"))
                    (duration-factors . (("drought" . (("bake" . 96.0)))))))
         (dps (spawn ^mock `((get-meta . ,(lambda (k) (and (equal? k "horizon-derived") derived))))))
         (floor-gate (make-horizon-gate rs #:plan-store dps)))
    (check "within L: a bake ending inside the chain's own lead passes"
           (eq? #t (gate (work-intent "i1" "bake" (iso-in 0.1)))))
    (check "beyond the ceiling: a 10-day lock-in is refused, with the reason named"
           (string? (gate (work-intent "i2" "bake" (iso-in 10)))))
    (check "an unwindowed intent passes (epoch-scoped by default)"
           (eq? #t (gate (work-intent "i3" "bake" #f))))
    (check "a floor process reaches as far as its worst defended branch — derived, not governed"
           (eq? #t (floor-gate (work-intent "i4" "bake" (iso-in 10)))))
    (check "the branch-maxed ceiling is the drought chain itself: 0.125 · 96 = 12"
           (< (abs (- (forcing-ceiling-days (horizon-ctx rs #f dps (now)) "bake") 12.0))
              1e-9))
    (check "…and past even that branch, the floor gate still refuses (14 d > 12)"
           (string? (floor-gate (work-intent "i4b" "bake" (iso-in 14)))))
    ;; the reach is to the START: a shift under way, or one beginning within
    ;; the chain's lead, is the decision feasibility forces now — however
    ;; long it runs. This is the very shape offer-work presents (today's
    ;; 09:00–17:00 row, offered mid-morning), which the end-measured read
    ;; refused for the whole of its window.
    (check "a shift already under way passes, whatever its remaining length"
           (eq? #t (gate (shift-intent "i6" "bake" (iso-in -0.05) (iso-in 0.3)))))
    (check "a shift beginning within L passes, though it ends well past L"
           (eq? #t (gate (shift-intent "i7" "bake" (iso-in 0.1) (iso-in 0.4)))))
    (check "a shift beginning past the ceiling is refused by its START, not its end"
           (string? (gate (shift-intent "i8" "bake" (iso-in 10) (iso-in 10.3)))))
    (check "an action that is not work passes untouched"
           (eq? #t (gate (make-intent #:id "i5" #:action 'transfer #:resource-conforms-to "deed"
                                      #:has-end (iso-in 90)))))
    (check "the chain duration reads off the recipe store (3h bake = 0.125 d)"
           (< (abs (- (chain-duration-days rs "bake") 0.125)) 1e-9))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Both doors: promote-to-commitment and accept-proposal refuse loudly
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. the doors: a refused accept raises, a passing one promotes ──\n")

(with-vat vat
  (let ((ps (spawn ^plan-store (empty-plan-store-state) '())))
    ($ ps 'add-intent (work-intent "near" "bake" (iso-in 0.5)))
    ($ ps 'add-intent (work-intent "far"  "bake" (iso-in 60)))
    ($ ps 'set-gate (lambda (it) (if (equal? (intent-id it) "far")
                                     "horizon: too far out" #t)))
    (check "promote door: the near accept promotes"
           (string? ($ ps 'promote-to-commitment "near" '((provider . "ada") (receiver . "town")))))
    (check "promote door: the far accept is refused, loudly"
           (raises? (lambda () ($ ps 'promote-to-commitment "far" '((provider . "ada") (receiver . "town"))))))
    ($ ps 'add-proposal (make-proposal #:id "prop-far" #:name "p" #:purpose 'request
                                       #:in-scope-of '("scope") #:publishes '("far") #:reciprocal '() #:proposed-to '()))
    (check "proposal door: acceptance over a refused intent raises"
           (raises? (lambda () ($ ps 'accept-proposal "prop-far" '((provider . "ada") (receiver . "town"))))))
    ($ ps 'add-intent (work-intent "near2" "bake" (iso-in 0.5)))
    ($ ps 'add-proposal (make-proposal #:id "prop-near" #:name "p" #:purpose 'request
                                       #:in-scope-of '("scope") #:publishes '("near2") #:reciprocal '() #:proposed-to '()))
    (check "proposal door: acceptance over a passing intent completes"
           (assq-ref ($ ps 'accept-proposal "prop-near" '((provider . "ada") (receiver . "town"))) 'agreement-id))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Every scope carries the gate: rewire-callbacks installs it
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. spawn-scope-root: the gate stands by default ──\n")

(with-vat vat
  (let* ((sr (spawn-scope-root "gate-town"))
         (ps ($ sr 'plan-store)))
    ($ ps 'add-intent (shift-intent "soon" "bake" (iso-in -0.1) (iso-in 0.2)))
    ($ ps 'add-intent (work-intent "comfort" "bake" (iso-in 90)))
    (check "a shift under way promotes under the default gate"
           (string? ($ ps 'promote-to-commitment "soon" '((provider . "ada") (receiver . "town")))))
    (check "a 90-day comfort lock-in is refused by default — the dangerous case"
           (raises? (lambda () ($ ps 'promote-to-commitment "comfort" '((provider . "ada") (receiver . "town")))))))
  )


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. The booking-augmented ceiling: an input's window widens the reach
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. booking edges: CP = max(L, B_i + L_suffix), MIN over suppliers ──\n")

;; a fixed Thursday noon, so the weekday arithmetic is deterministic
(define t0 (civil->instant "2026-08-20T12:00:00"))
(define (at-t0-in days) (instant->civil (inexact->exact (round (+ t0 (* days 86400))))))
(define monday-window (weekday-window "09:00" "17:00" '(monday)))

(with-vat vat
  (let* ((bake (rp* "bake" "Bake" 3.0))
         (flour-in (consume* "ff" "flour" 1.0 "bake"))
         (rs (spawn ^mock `((all-recipes . ,(lambda () (list (make-recipe #:id "r1" #:name "Bread"
                                                                          #:primary-output "bread"
                                                                          #:recipe-processes '()
                                                                          #:recipe-exchanges '()))))
                            (get-process-chain . ,(lambda (rid) (list bake)))
                            (flows-for-process . ,(lambda (pid) (cons (list flour-in) '()))))))
         (flour (lambda (win) (er "flour-1" "flour" #f #:qty 5.0 #:unit "kg" #:window win)))
         (obs (spawn ^mock `((all-resources . ,(lambda () (list (flour monday-window)))))))
         (obs2 (spawn ^mock `((all-resources . ,(lambda () (list (flour monday-window) (flour #f)))))))
         (gate  (make-horizon-gate rs #:observer obs
                                   #:now-thunk (lambda () t0))))
    (check "Thursday → Monday flour: B = 4 days, CP = 4 + 0.125"
           (< (abs (- (augmented-ceiling-days rs obs "bake" t0) 4.125)) 1e-9))
    (check "the widened ceiling passes what bare L refused (4 d out)"
           (eq? #t (gate (work-intent "w1" "bake" (at-t0-in 4)))))
    (check "…and still refuses past it (5 d out)"
           (string? (gate (work-intent "w2" "bake" (at-t0-in 5)))))
    (check "an always-open second supplier collapses the notice: MIN over suppliers"
           (< (abs (- (augmented-ceiling-days rs obs2 "bake" t0) 0.125)) 1e-9))
    (check "no observer ⇒ the bare chain duration, as before"
           (< (abs (- (augmented-ceiling-days rs #f "bake" t0) 0.125)) 1e-9))))

(test-summary!)
