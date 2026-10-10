;;; test-shocks.scm — the shock algebra (playnet vf formulas shocks), read against
;;; docs/antifragile/: one matcher behind every branch, the adverse direction,
;;; and a tail that stands beyond its record by construction.
;;;
;;; Pure: no world, no solve.
;;;
;;; Run: guile -L module tests/planner/test-shocks.scm

(use-modules (playnet vf formulas shocks)
             (playnet vf schemas) (playnet vf beyond scenario)
             (srfi srfi-1)
             (ice-9 format))

(define fails 0)
(define (check name ok)
  (format #t "  ~a ~a~%" (if ok "✓" "✗") name)
  (unless ok (set! fails (+ fails 1))))
(define (~= a b) (< (abs (- a b)) 1e-9))
(define (scn id p mults) (make-planning-scenario id #f p mults #f))

;; ── A. ONE MATCHER: the factor a branch puts on a column ─────────────────────
(format #t "~%── A. the one matcher ──~%")
(define mix (branch-flow-factor
             (normalize-shocks '((produce "heat" 0.5) (consume "fuel" 1.5) (work "stoke-skill" 2.0)
                                 ("bread" . 0.25)))))
(check "a produce shock scales an OUTPUT, keyed by spec"      (~= (mix 'produce "warm" "heat" 0 "z") 0.5))
(check "a consume shock scales an INPUT's intensity"          (~= (mix 'consume "warm" "fuel" 0 "z") 1.5))
(check "a work shock scales the hours"                        (~= (mix 'work "warm" "stoke-skill" 0 "z") 2.0))
(check "a bare (key . factor) is a produce shock"             (~= (mix 'produce "bake" "bread" 0 "z") 0.25))
(check "a produce shock leaves the inputs of its key alone"   (~= (mix 'consume "bake" "bread" 0 "z") 1.0))
(check "an unlisted key reads 1.0"                            (~= (mix 'produce "bake" "cake" 0 "z") 1.0))
(check "a shock keys by PROCESS as well as by spec"
       (~= ((branch-flow-factor (normalize-shocks '((consume "warm" 3.0)))) 'consume "warm" "fuel" 0 "z") 3.0))
(check "no shocks ⇒ the identity"                             (~= ((branch-flow-factor '()) 'produce "p" "s" 0 "z") 1.0))

;; every shock a flow matches multiplies in — the site, the weather and the
;; witness compose as the independent responses they are
(define stacked (branch-flow-factor
                 (normalize-shocks '(("rice" . 0.5) (produce "grow" 0.8) (produce ("rice" . "north") 0.5)))))
(check "shocks on one flow compose by product (spec × process)" (~= (stacked 'produce "grow" "rice" 0 "south") 0.4))
(check "…and a LOCATED shock joins at its own place alone"      (~= (stacked 'produce "grow" "rice" 0 "north") 0.2))

;; a period-tagged shock holds at its period
(define seasonal (branch-flow-factor (normalize-shocks '((produce "rice" 1 0.3)))))
(check "a tagged shock applies at its period"                 (~= (seasonal 'produce "grow" "rice" 1 "z") 0.3))
(check "…and the same process at another period is unshocked" (~= (seasonal 'produce "grow" "rice" 0 "z") 1.0))

;; the build asks of every input as 'consume, a used service under "Svc|spec"
(define van (branch-flow-factor (normalize-shocks '((use "van" 2.0)))))
(check "a USE shock reaches the service draw it names"        (~= (van 'consume "haul" "Svc|van" 0 "z") 2.0))
(check "…by process too"
       (~= ((branch-flow-factor (normalize-shocks '((use "haul" 2.0)))) 'consume "haul" "Svc|van" 0 "z") 2.0))
(check "…and leaves a consumed good of the same name alone"   (~= (van 'consume "sell" "van" 0 "z") 1.0))

(define avail (branch-avail-factor (normalize-shocks '((avail "fuel" 0.5) (avail "fuel" 0.5) (produce "fuel" 0.1)))))
(check "an avail shock scales the raw's supply, composing"    (~= (avail "fuel#z@0") 0.25))
(check "…matched on the whole spec"                           (~= (avail "fuel-oil#z@0") 1.0))

;; ── B. THE ADVERSE DIRECTION ─────────────────────────────────────────────────
(format #t "~%── B. the adverse direction ──~%")
(check "an output is worse lower"          (~= (more-adverse 'produce 0.4 0.7) 0.4))
(check "a supply is worse lower"           (~= (more-adverse 'avail 0.4 0.7) 0.4))
(check "an input's intensity is worse higher" (~= (more-adverse 'consume 1.2 1.6) 1.6))
(check "hours are worse higher"            (~= (more-adverse 'work 1.2 1.6) 1.6))
(check "a duration is worse longer"        (~= (more-adverse 'duration 1.0 4.0) 4.0))
(check "an output reads no better than the map"  (~= (cautious-reading 'produce 10.0 12.0) 10.0))
(check "…and falls to what was witnessed"        (~= (cautious-reading 'produce 10.0 6.0) 6.0))
(check "…never below nothing"                    (~= (cautious-reading 'produce 10.0 -3.0) 0.0))
(check "an input reads no lighter than the map"  (~= (cautious-reading 'consume 10.0 6.0) 10.0))
(check "…and rises to what was witnessed"        (~= (cautious-reading 'consume 10.0 14.0) 14.0))

(define (factor-of shocks a k) (scenario-factor-on (normalize-shocks shocks) a k #f))
(define seen (observed-shocks '(("bake" produce 10.0 6.0) ("bake" produce 10.0 8.0)     ; two witnesses
                                ("bake" produce 10.0 14.0)                              ; a flattering one
                                ("bake" work 2.0 3.0) ("bake" work 2.0 1.0))))
(check "witnesses are equal, and a flattering reading folds as the map"
       (~= (factor-of seen 'produce "bake") (/ (+ 0.6 0.8 1.0) 3)))
(check "hours rise to the witnessed mean, a lighter reading folding as the map"
       (~= (factor-of seen 'work "bake") (/ (+ 1.5 1.0) 2)))

;; ── C. THE MEAN: one fold, two adapters ──────────────────────────────────────
(format #t "~%── C. the mean ──~%")
(define cal (calibrate-shocks '((produce "rice" 100.0 45.0) (produce "rice" 100.0 55.0)
                                (consume "fuel" 100.0 150.0) (work "surgery" 0.0 5.0))))
(check "calibration is the unweighted mean ratio"   (~= (factor-of cal 'produce "rice") 0.5))
(check "…per (action, spec)"                        (~= (factor-of cal 'consume "fuel") 1.5))
(check "…over the intents that asked for something" (= (length cal) 2))

(define ce (certainty-equivalent-scenario
            (list (scn "normal"  0.75 '())
                  ;; a future carrying two shocks on one coefficient — its own
                  ;; weather and a witnessed reading laid over it
                  (scn "drought" 0.25 '(("rice" . 0.5) (produce "rice" 0.8) (produce "rice" 1 0.2))))))
(define ce-shocks (scenario-shocks ce))
(check "the certainty-equivalent reads a future's shocks as the build composes them"
       (~= (scenario-factor-on ce-shocks 'produce "rice" #f) (+ (* 0.75 1.0) (* 0.25 0.4))))
(check "…a season's shock stays that season's"
       (~= (scenario-factor-on ce-shocks 'produce "rice" 1) (+ (* 0.75 1.0) (* 0.25 0.2))))

;; ── D. THE TAIL STANDS BEYOND THE RECORD ─────────────────────────────────────
(format #t "~%── D. the tail beyond the record ──~%")
(define record
  (map normalize-shocks
       '((("rice" . 1.0) ("maize" . 1.0))
         (("rice" . 0.45) ("maize" . 0.55) ("pulses" . 0.80) (consume "water" 1.4))
         (("rice" . 1.05) ("maize" . 0.85) ("pulses" . 0.70) (consume "water" 0.9) (produce "rice" 1 0.6)))))
(define env (record-envelope record))
(define (env-of a k t) (scenario-factor-on env a k t))
(check "the envelope is the worst year, channel by channel"
       (and (~= (env-of 'produce "rice" #f) 0.45) (~= (env-of 'produce "maize" #f) 0.55)
            (~= (env-of 'produce "pulses" #f) 0.70)))
(check "…an input's worst is its highest"   (~= (env-of 'consume "water" #f) 1.4))
(check "…a season's shock keeps its season" (~= (env-of 'produce "rice" 1) 0.6))

(define stated '(("rice" . 0.15) ("maize" . 0.70)))
(define tail (tail-beyond-record record stated))
(define (tail-of a k t) (scenario-factor-on (normalize-shocks tail) a k t))
(check "a tail stated beyond the record stands as written" (equal? (car tail) '("rice" . 0.15)))
(check "a tail milder than the record takes the record's worst" (~= (tail-of 'produce "maize" #f) 0.55))
(check "a channel the tail leaves unstated enters at the record's worst"
       (and (~= (tail-of 'produce "pulses" #f) 0.70) (~= (tail-of 'consume "water" #f) 1.4)
            (~= (tail-of 'produce "rice" 1) 0.6)))
(check "a crop table stays a crop table: a lifted yield is found by crop"
       (~= (assoc-ref tail "maize") 0.55))
(check "on every channel the record shocks, the tail is at least as adverse"
       (every (lambda (e)
                (let ((t (tail-of (shock-action e) (shock-key e) (shock-period e))))
                  (= t (more-adverse (shock-action e) t (shock-factor e)))))
              env))
(check "a tail already beyond the record is the list it was" (equal? (tail-beyond-record record '(("rice" . 0.1) ("maize" . 0.1) ("pulses" . 0.1) (consume "water" 2.0) (produce "rice" 1 0.1)))
                                                                     '(("rice" . 0.1) ("maize" . 0.1) ("pulses" . 0.1) (consume "water" 2.0) (produce "rice" 1 0.1))))

;; every seeded shed: the future its floors are defended in lies beyond its record
(use-modules (playnet knowledge worlds berlin) (playnet knowledge worlds cascadia)
             (playnet knowledge worlds bay-area) (playnet knowledge worlds doon-valley))
(for-each
 (lambda (named)
   (let* ((set (cdr named)) (rec (map scenario-shocks (drop-right set 1)))
          (tl (scenario-shocks (last set))))
     (check (format #f "~a: the p=0 tail is beyond the record on every channel" (car named))
            (and (<= (planning-scenario-probability (last set)) 0.0)
                 (every (lambda (e)
                          (let ((t (scenario-factor-on tl (shock-action e) (shock-key e) (shock-period e))))
                            (= t (more-adverse (shock-action e) t (shock-factor e)))))
                        (record-envelope rec))))))
 `(("berlin" . ,*berlin-scenarios/tail-robust*) ("cascadia" . ,*cascadia-scenarios/tail-robust*)
   ("bay-area" . ,*bay-area-scenarios/tail-robust*) ("doon" . ,*doon-valley-scenarios/tail-robust*)))

;; ── stress on a recipe's own flows ───────────────────────────────────────────
(format #t "~%── a shock list read as stress on a recipe's own flows ──~%~%")
(let* ((flows '((work "grow" "farming") (produce "grow" "wheat") (produce "thresh" "wheat")))
       (stress (lambda shocks (flows-stress (normalize-shocks shocks) flows))))
  (check "one channel per (action . spec) among the flows"
         (equal? '((work . "farming") (produce . "wheat")) (map car (stress))))
  (check "a yield multiplied by 0.4 is stress 6 on that output, by the build's own matcher"
         (~= 6.0 (assoc-ref (stress '("wheat" . 0.4)) '(produce . "wheat"))))
  (check "across the acts that share a channel, the heaviest reading stands"
         (~= 7.0 (assoc-ref (stress '(produce "grow" 0.8) '(produce "thresh" 0.3)) '(produce . "wheat"))))
  (check "the factor behind the stress is the same reading: what was allowed, and how hard it pressed"
         (let ((f (flows-factor (normalize-shocks '(("wheat" . 0.4))) flows)))
           (and (~= 0.4 (assoc-ref f '(produce . "wheat")))
                (~= 1.0 (assoc-ref f '(work . "farming")))
                (~= 6.0 (factor-stress (assoc-ref f '(produce . "wheat")))))))
  (check "the tail is the scenario of no weight"
         (and (tail-scenario? (make-planning-scenario "t" #f 0.0 '() #f))
              (not (tail-scenario? (make-planning-scenario "d" #f 0.2 '() #f)))))
  (check "stress stays within the band"
         (~= %stress-band (assoc-ref (stress '(work "farming" 3.0)) '(work . "farming")))))

(format #t "~%=== Results: ~a failed ===~%" fails)
(exit (if (zero? fails) 0 1))
