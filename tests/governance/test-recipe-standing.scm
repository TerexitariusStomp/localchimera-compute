;;; test-recipe-standing.scm — the response's live adapter, end to end.
;;;
;;; recipe-response-test pins the pure half — the curve, and what a future
;;; reads off it; response-solve-test measures the plan leaning on a recipe
;;; by its record. This pins the OTHER half: real economic events recorded into a real ^observer,
;;; runs assembled off its indexes (events-for-process + fulfillment links),
;;; the claim side injected as commitment-of, the sky each run lived under a
;;; scenario — and the recipe's response falling out read, per flow of its
;;; own, as the curve every future of a solve takes (docs/playnet.typ, "Character
;;; is a measurement").

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness))
(use-modules (playnet observation observer) (playnet scope root) (playnet solve recipe-response) (playnet vf schemas) (playnet vf beyond scenario) (srfi srfi-1))
(use-modules ((playnet scope live) #:select (gather-recipes)))
(use-modules (playnet credentials declarations) (playnet governance recipe-standing) (playnet keri acdc-store) (playnet solve recipe-response))
(use-modules ((playnet solve recipe-response) #:select (capture-at response-shocks response-margin margin-shocks curve-reach
                                                          recipe-response-report standing-position)))
(use-modules ((playnet vf formulas shocks) #:select (scenario-factor-on normalize-shocks flows-stress flows-factor scenario-shocks)))
(define (row-of rows ch) (find (lambda (r) (equal? ch (assq-ref r 'channel))) rows))
(define (word-of rows ch) (assq-ref (row-of rows ch) 'word))
(define (~= a b) (< (abs (- a b)) 1e-6))
;; a recipe's profile off its runs (pid capture stresses tuples), as scope-standing reads it
(define (profile-of runs) (recipe-response-report (map (lambda (r) (cons (cadr r) (caddr r))) runs)))
;; the scope's records that have run, as (id rows position yield runs)
(define (shown standing)
  (filter-map (lambda (r)
                (and (pair? (assq-ref r 'runs))
                     (list (assq-ref r 'id) (assq-ref r 'rows) (standing-position (assq-ref r 'rows))
                           (assq-ref r 'yield) (assq-ref r 'runs))))
              (assq-ref standing 'responses)))
(define baking  '(work . "skill-bake"))
(define milling '(work . "skill-mill"))
(define grain   '(produce . "grain"))
(use-modules (goblins))
(use-modules (srfi srfi-1))

;; one WORK event fulfilling a commitment: realized hours against claimed hours
(define (work-ev eid pid cid hours)
  (make-economic-event #:id eid #:action 'work #:output-of pid #:resource-conforms-to "skill-bake" #:provider "EAda" #:effort-quantity (make-measure hours %effort-unit) #:has-point-in-time "2026-03-01T08:00:00Z"
    #:fulfills cid))

;; the injected claim side: every commitment claimed 10 hours of baking
(define (commitment-of cid) (and (string-prefix? "c" cid) '(work "skill-bake" 10.0)))

;; the injected realized weather: calm, then harder run by run — each run's
;; sky a scenario that withheld that share of the baking
(define (sky-of pid)
  (make-planning-scenario "sky" #f 1.0
    `((work "skill-bake" ,(assoc-ref '(("p1" . 1.0) ("p2" . 0.8) ("p3" . 0.6) ("p4" . 0.4) ("p5" . 0.2)) pid)))
    #f))
;; THE JUMP (the lecture's picture): capture held under light stress, then
;; falling faster the harder the stress — harm that accelerates
(define %jump '(100.0 98.0 90.0 70.0 30.0))
;; the sky of five periods: what the weather allowed, 1.0 down to 0.2
(define %sky  '(1.0 0.8 0.6 0.4 0.2))

(define vat (spawn-vat))

(display "\n── runs off the observer, character computed ──\n")

(with-vat vat
  (let ((obs (spawn ^observer (empty-observer-state) (quote ()))))
    ;; five runs of one recipe; of the hours its sky allowed, the share
    ;; delivered holds under light stress and falls faster the harder it presses
    (for-each (lambda (i sky capture)
                ($ obs 'record-event (work-ev (format #f "e~a" i) (format #f "p~a" i) (format #f "c~a" i)
                                              (* sky (/ capture 10.0)))))
              '(1 2 3 4 5) %sky %jump)
    ;; …and one unplanned event: fulfills nothing, claims nothing
    ($ obs 'record-event (work-ev "e6" "p3" #f    2.0))

    (let ((runs (observer-runs obs '("p1" "p2" "p3" "p4" "p5")
                               #:commitment-of commitment-of #:sky-of sky-of)))
      (check-pred "one run per process: capture = realized over what its sky allowed"
                  (every (lambda (r j) (~= (cadr r) j)) runs %jump))
      (check-pred "…filed under the flow that sky pressed, at the stress it delivered there"
                  (every (lambda (r s) (and (equal? baking (caar (caddr r))) (~= (cdar (caddr r)) s))) runs '(0 2 4 6 8)))
      (check-pred "an unfulfilled event claims nothing — it never enters a run"
                  (= 5 (length runs))))

    (let ((standing (profile-of (observer-runs obs '("p1" "p2" "p3" "p4" "p5")
                                               #:commitment-of commitment-of #:sky-of sky-of))))
      (check-pred "the record is a curve: at stress 6 it captured 70, and a future at 5 reads 80"
                  (let ((curve (assq-ref (row-of standing baking) 'curve)))
                    (and (~= 70.0 (capture-at curve 6)) (~= 80.0 (capture-at curve 5)))))
      (check-pred "the word for it is FRAGILE: its harm accelerates — read, not declared"
                  (eq? 'fragile (word-of standing baking)))
      (check-pred "probability-free by default: no statistic attached"
                  (not (assq-ref (row-of standing baking) 'licensed))))

    (check-pred "two stress levels carry a curve and no word — awaiting observation"
                (let ((rows (profile-of (observer-runs obs '("p1" "p2")
                                                       #:commitment-of commitment-of #:sky-of sky-of))))
                  (and (eq? 'unobserved (word-of rows baking))
                       (= 2 (length (assq-ref (row-of rows baking) 'curve))))))
    (check-pred "with no sky handed in, a run reads calm: capture is realized over claimed"
                (let ((run (car (observer-runs obs '("p3") #:commitment-of commitment-of))))
                  (and (~= 54.0 (cadr run)) (equal? `((,baking . 0.0)) (caddr run)))))))

(display "\n── the weather falls out of the observer: nobody writes the scenario ──\n")
;; Five periods, three recipes working grain under the SAME sky. The sky is
;; read off everyone's runs (calibrate-shocks): period 1 calm, each one after
;; harder (%sky). Recipes A and C hold their REGRET-normalised capture as the
;; weather worsens; recipe B falls faster than the weather, and faster still
;; the worse it gets (%jump). No scenario is injected.
(define (grain-ev eid pid cid kg)
  (make-economic-event #:id eid #:action 'produce #:output-of pid #:resource-conforms-to "grain" #:provider "EAda"
    #:resource-quantity (make-measure kg "kg") #:has-point-in-time "2026-03-01T08:00:00Z"
    #:fulfills cid))
(define (grain-claim cid) (and (string-prefix? "g" cid) '(produce "grain" 10.0)))
(with-vat vat
  (let ((obs (spawn ^observer (empty-observer-state) (quote ()))))
    (for-each
     (lambda (i sky jump)
       ;; what the sky allowed of the 10 kg claimed; B takes %jump of that
       (for-each (lambda (who kg)
                   ($ obs 'record-event (grain-ev (format #f "e-~a~a" who i) (format #f "~a~a" who i)
                                                  (format #f "g-~a~a" who i) kg)))
                 '("a" "b" "c") (list (* 10.0 sky) (* 10.0 sky (/ jump 100.0)) (* 10.0 sky))))
     '(1 2 3 4 5) %sky %jump)
    (let* ((pids-of (lambda (who) (map (lambda (i) (format #f "~a~a" who i)) '(1 2 3 4 5))))
           ;; a run's period: the three runs sharing its number
           (period-of (lambda (pid) (let ((i (string-take-right pid 1)))
                                      (map (lambda (who) (string-append who i)) '("a" "b" "c")))))
           (storm (realized-scenario obs '("a3" "b3" "c3") #:commitment-of grain-claim #:except '("a3")))
           ;; a recipe's runs, each read against the sky its period delivered — the
           ;; period's runs, a key this recipe alone witnessed left out
           (against (lambda (pids period-of)
                      (profile-of
                       (observer-runs obs pids #:commitment-of grain-claim
                                      #:sky-of (lambda (pid)
                                                 (realized-scenario obs (period-of pid) #:commitment-of grain-claim
                                                                    #:except (filter (lambda (p) (member p pids))
                                                                                     (period-of pid))))))))
           (A (against (pids-of "a") period-of))
           (B (against (pids-of "b") period-of)))
      (check-pred "the storm is read off its period's runs at the BEST of them: grain 0.6, not B's 0.54 nor the mean"
                  (~= 0.6 (assoc-ref (flows-factor (scenario-shocks storm) '((produce "b3" "grain"))) grain)))
      (check-pred "…and as stress on a run's own flows, 4 of 10, the same record read twice"
                  (~= 4.0 (assoc-ref (flows-stress (scenario-shocks storm) '((produce "b3" "grain"))) grain)))
      (check-pred "A, read against what its weather allowed, is ROBUST — not blamed for the storm"
                  (eq? 'robust (word-of A grain)))
      (check-pred "B, falling faster the harder its weather presses, is FRAGILE — read, nobody declared it"
                  (eq? 'fragile (word-of B grain)))
      ;; a recipe alone on its channel has no weather but itself
      (check-pred "alone under its sky, a recipe is not its own weather: every run reads calm, and no word is read"
                  (let* ((only (lambda (pid) (list pid)))
                         (rows (against (pids-of "b") only)))
                    (and (eq? 'unobserved (word-of rows grain))
                         (equal? '(0.0) (map car (assq-ref (row-of rows grain) 'curve)))))))))

(display "\n── the scope's standing, as the gateway injects it ──\n")
;; A real scope root: three bread recipes under one sky (A holds, B breaks
;; faster the harder it presses, C slips a little), commitments in the
;; plan-store as plan-scope would leave them, work events recorded over five
;; days at the live grain (input-of = the act, the day off the event's
;; instant). scope-standing reads the stores and nothing else. Two more
;; recipes have never run: D alone makes its bread, E makes the bread A makes.
(define (day-ev eid proc cid hours day)
  (make-economic-event #:id eid #:action 'work #:output-of proc #:resource-conforms-to "skill-mill" #:provider "EAda" #:effort-quantity (make-measure hours "hour") #:has-point-in-time (string-append day "T10:00:00Z")
    #:fulfills cid))
(define %days '("2026-03-01" "2026-03-02" "2026-03-03" "2026-03-04" "2026-03-05"))
(define (mill-claim cid proc)      ; 10 hours of milling claimed, per act
  (make-commitment #:id cid #:action 'work #:input-of proc #:resource-conforms-to "skill-mill"
                   #:effort-quantity (make-measure 10.0 %effort-unit)))
(with-vat vat
  (let* ((sr (spawn-scope-root "Standing Scope"))
         (rs ($ sr 'recipe-store)) (ps ($ sr 'plan-store)) (obs ($ sr 'observer)))
    ;; three recipes, one act each, all milling: 2 hours of skill-mill per run
    (for-each (lambda (id nm spec)
                ($ rs 'add-recipe-process (make-recipe-process #:id id #:name nm))
                ($ rs 'add-recipe-flow (make-recipe-flow #:id (string-append id "-w") #:action 'work #:resource-conforms-to "skill-mill"
                                                         #:effort-quantity (make-measure 2.0 %effort-unit) #:recipe-input-of id))
                ($ rs 'add-recipe (make-recipe #:id (string-append "r-" id) #:name nm
                                               #:primary-output spec #:recipe-processes (list id))))
              '("mill-a" "mill-b" "mill-c") '("A" "B" "C") '("bread-a" "bread-b" "bread-c"))
    ;; a fourth, never run
    ($ rs 'add-recipe-process (make-recipe-process #:id "mill-d" #:name "D"))
    ($ rs 'add-recipe (make-recipe #:id "r-mill-d" #:name "D" #:primary-output "bread-d"
                                   #:recipe-processes (list "mill-d")))
    ($ rs 'add-recipe-process (make-recipe-process #:id "mill-e" #:name "E"))
    ($ rs 'add-recipe (make-recipe #:id "r-mill-e" #:name "E" #:primary-output "bread-a"
                                   #:recipe-processes (list "mill-e")))
    ;; five days; each day one commitment per act, then the work that fulfilled it
    (for-each
     (lambda (day sky jump)
       (let ((s (* 10.0 (- 1.0 sky))))                        ; the day's stress
         (for-each (lambda (proc hours)
                     (let ((cid (string-append "c-" proc "-" day)))
                       ($ ps 'add-commitment (mill-claim cid proc))
                       ($ obs 'record-event (day-ev (string-append "e-" proc "-" day) proc cid hours day))))
                   '("mill-a" "mill-b" "mill-c")
                   (list (* 10.0 sky)                                    ; A: delivers what the sky allows
                         (* 10.0 sky (/ jump 100.0))                     ; B: the jump
                         (* 10.0 sky (/ (- 100.0 (* 0.1 s s)) 100.0))))))  ; C: 100 − 0.1·s² of it
     %days %sky %jump)
    (let* ((standing (scope-standing sr))
           (seen (shown standing))
           (responses (assq-ref standing 'responses))
           (response-of (lambda (rid) (find (lambda (r) (equal? rid (assq-ref r 'id))) responses)))
           (curve-of (lambda (proc) (assoc-ref (assq-ref (response-of (string-append "r-" proc)) 'curves) milling)))
           (of (lambda (rid i) (list-ref (assoc rid seen) i))))
      (check-pred "every recipe that ran was read, off the stores alone"
                  (equal? '("r-mill-a" "r-mill-b" "r-mill-c") (sort (map car seen) string<?)))
      (check-pred "ONE record per recipe, run or not: its acts, its own flows, what it makes, a curve per flow"
                  (and (= 5 (length responses))
                       (equal? '("mill-b") (assq-ref (response-of "r-mill-b") 'procs))
                       (equal? '((work "mill-b" "skill-mill")) (assq-ref (response-of "r-mill-b") 'flows))
                       (equal? "bread-b" (assq-ref (response-of "r-mill-b") 'output))))
      (check-pred "a recipe that never ran has no curve, and is experimental"
                  (and (not (assoc "r-mill-d" seen))
                       (null? (assq-ref (response-of "r-mill-d") 'curves))
                       (eq? 'experimental (standing-position (assq-ref (response-of "r-mill-d") 'rows)))
                       (= 1.0 (assq-ref (response-of "r-mill-d") 'yield))))
      (check-pred "the untried margin: E, beside the tried A for one bread, is bounded; D, alone on its bread, stands bare"
                  (and (eq? 'bounded (response-margin (response-of "r-mill-e") responses))
                       (eq? 'bare (response-margin (response-of "r-mill-d") responses))
                       (equal? '((produce "mill-e" 0.0))
                               (margin-shocks responses (make-planning-scenario "calm" #f 0.0 '() #f)))))
      (check-pred "…and in a tail beyond every record, each recipe by its reach beside the best for its bread: E still nothing"
                  (let ((laid (normalize-shocks
                               (margin-shocks responses (make-planning-scenario "tail" #f 0.0 '((work "skill-mill" 0.05)) #f)))))
                    (and (= 0.0 (scenario-factor-on laid 'produce "mill-e" #f))
                         (= 1.0 (scenario-factor-on laid 'produce "mill-a" #f))
                         (= 1.0 (scenario-factor-on laid 'produce "mill-b" #f)))))
      (check-pred "A's curve holds at the whole across the stress the days delivered"
                  (every (lambda (p) (< (abs (- 100.0 (cdr p))) 1e-6)) (curve-of "mill-a")))
      (check-pred "B's curve is the jump, stress by stress"
                  (every (lambda (p j) (< (abs (- j (cdr p))) 1e-6)) (curve-of "mill-b") %jump))
      (check-pred "the words: A robust, B fragile, C robust — descriptions, off the same rows"
                  (equal? '(robust fragile robust)
                          (map (lambda (rid) (word-of (of rid 1) milling))
                               '("r-mill-a" "r-mill-b" "r-mill-c"))))
      (check-pred "each has run under stress, up to 8: the records are observed"
                  (every (lambda (rid) (and (eq? 'observed (of rid 2))
                                             (~= 8.0 (curve-reach (assq-ref (row-of (of rid 1) milling) 'curve)))))
                         '("r-mill-a" "r-mill-b" "r-mill-c")))
      ;; the last day delivered stress 8
      (check-pred "under the weather live now, A yields the whole of what it allows"
                  (< (abs (- 1.0 (of "r-mill-a" 3))) 1e-6))
      (check-pred "…B yields the 30% its record shows at that stress"
                  (< (abs (- 0.3 (of "r-mill-b" 3))) 1e-6))
      (check-pred "…and C the 93.6% of its own: in proportion, recipe by recipe"
                  (< (abs (- 0.936 (of "r-mill-c" 3))) 1e-6))
      ;; the same curves, read by a FUTURE: a forecast drought on the skill they work
      (let* ((drought (make-planning-scenario "drought" #f 0.2 '((work "skill-mill" 0.4)) #f))   ; stress 6
             (laid (normalize-shocks (response-shocks responses drought)))
             (factor (lambda (proc) (scenario-factor-on laid 'produce proc #f))))
        (check-pred "a future at stress 6 reads each curve there: A whole, B 70%, C 96.4%"
                    (and (= 1.0 (factor "mill-a"))
                         (< (abs (- 0.70 (factor "mill-b"))) 1e-6)
                         (< (abs (- 0.964 (factor "mill-c"))) 1e-6)))
        (check-pred "a future beyond the record continues B's harm, and holds A where it stood"
                    (let* ((tail (make-planning-scenario "tail" #f 0.0 '((work "skill-mill" 0.05)) #f))   ; stress 9.5
                           (laid (normalize-shocks (response-shocks responses tail))))
                      (and (= 1.0 (scenario-factor-on laid 'produce "mill-a" #f))
                           (< (abs (- 0.0 (scenario-factor-on laid 'produce "mill-b" #f))) 1e-6)))))
      ;; the observer log the curve traces back to: one row per day the act ran
      (let ((runs-a (of "r-mill-a" 4)))
        (check-pred "A ran five days — the log has one row per day" (= 5 (length runs-a)))
        (check-pred "each row names its own day" (equal? (sort (map car runs-a) string<?) %days))
        (let ((first (find (lambda (r) (equal? (car r) "2026-03-01")) runs-a)))
          (check-pred "…its capture" (number? (cadr first)))
          (check-pred "…the flow it is filed under and the stress there: the first day was calm"
                      (equal? `((,milling . 0.0)) (caddr first)))
          (check-pred "…and the raw claim tuples observed-capture divided to get it"
                      (let ((tuples (cadddr first)))
                        (and (pair? tuples)
                             (every (lambda (t) (and (symbol? (car t)) (string? (cadr t)) (number? (caddr t)) (number? (cadddr t)))) tuples))))))
      ;; the regime picks the reading: a licensed domain reads its witnesses at their mean
      (let ((licensed (map (lambda (row) (cons (car row) (cadr row)))
                           (shown (scope-standing sr #:regime-of (lambda (rid) (if (equal? rid "r-mill-b") 'statistical 'probability-free)))))))
        (check-pred "a licensed domain carries the fitted statistic; the rest carry none"
                    (and (assq-ref (row-of (cdr (assoc "r-mill-b" licensed)) milling) 'licensed)
                         (not (assq-ref (row-of (cdr (assoc "r-mill-a" licensed)) milling) 'licensed))))))))

(display "\n── a recipe alone in its scope: what reached it is its weather ──\n")
;; One bakery, nobody beside it. Each day the plan claims 10 hours of baking
;; (a commitment in the plan-store) and 20 loaves (a material row, registered
;; on the observer where its events land, as `hold-row!` leaves it). The hours
;; arrive whole, then short; the loaves made of what arrived fall faster.
(define (loaf-ev eid proc cid n day)
  (make-economic-event #:id eid #:action 'produce #:output-of proc #:resource-conforms-to "bread"
    #:resource-quantity (make-measure n "unit") #:has-point-in-time (string-append day "T18:00:00Z")
    #:fulfills cid))
(with-vat vat
  (let* ((sr (spawn-scope-root "Lone Bakery"))
         (rs ($ sr 'recipe-store)) (ps ($ sr 'plan-store)) (obs ($ sr 'observer)))
    ($ rs 'add-recipe-process (make-recipe-process #:id "bake" #:name "Bake"))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id "bake-w" #:action 'work #:resource-conforms-to "skill-bake"
                                             #:effort-quantity (make-measure 2.0 %effort-unit) #:recipe-input-of "bake"))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id "bake-o" #:action 'produce
                                             #:resource-conforms-to "bread"
                                             #:resource-quantity (make-measure 4.0 "unit")
                                             #:recipe-output-of "bake"))
    ($ rs 'add-recipe (make-recipe #:id "r-bake" #:name "Bake" #:primary-output "bread"
                                   #:recipe-processes (list "bake")))
    (for-each
     (lambda (day hours-share capture)
       (let ((wc (string-append "w-" day)) (mc (string-append "m-" day)))
         ($ ps 'add-commitment
            (make-commitment #:id wc #:action 'work #:input-of "bake"
                             #:resource-conforms-to "skill-bake"
                             #:effort-quantity (make-measure 10.0 %effort-unit)))
         ($ obs 'register-commitment
            (make-commitment #:id mc #:action 'produce #:output-of "bake"
                             #:resource-conforms-to "bread"
                             #:resource-quantity (make-measure 20.0 "unit")))
         ($ obs 'record-event (make-economic-event #:id (string-append "ew-" day) #:action 'work #:input-of "bake" #:resource-conforms-to "skill-bake" #:provider "EAda" #:effort-quantity (make-measure (* 10.0 hours-share) "hour") #:has-point-in-time (string-append day "T10:00:00Z")
                                #:fulfills wc))
         ;; the loaves land as two events on the one claim: a claim met in parts is one claim
         (let ((made (* 20.0 hours-share (/ capture 100.0))))
           ($ obs 'record-event (loaf-ev (string-append "el-" day) "bake" mc (* 0.5 made) day))
           ($ obs 'record-event (loaf-ev (string-append "el2-" day) "bake" mc (* 0.5 made) day)))))
     '("2026-04-01" "2026-04-02" "2026-04-03" "2026-04-04")
     '(1.0 0.8 0.5 0.2)
     '(100.0 95.0 80.0 40.0))
    (let* ((seen (car (shown (scope-standing sr))))
           (rows (cadr seen))
           (curve (assq-ref (row-of rows baking) 'curve)))
      (check-pred "its material events reach the record: a claim held on the observer is a claim"
                  (and (pair? seen) (= 4 (length (list-ref seen 4)))))
      (check-pred "with nobody beside it, it still has a sky: the hours that reached it"
                  (equal? '(0.0 2.0 5.0 8.0) (map (lambda (p) (/ (round (* 10 (car p))) 10)) curve)))
      (check-pred "…and the loaves it made of them are its capture, a claim met in two events read once"
                  (every (lambda (p c) (~= c (cdr p))) curve '(100.0 95.0 80.0 40.0)))
      (check-pred "the calm day is a reading on its output too; the short days are filed under the work"
                  (equal? '((0.0 . 100.0)) (assq-ref (row-of rows '(produce . "bread")) 'curve)))
      (check-pred "it has met stress, up to 8: observed, and read FRAGILE off its own days"
                  (and (eq? 'observed (caddr seen)) (eq? 'fragile (word-of rows baking)))))
    ;; the books are told, a week on, that half of the first day's loaves were
    ;; never baked: a correction, dated the day it is made
    ($ obs 'record-event
       (make-economic-event #:id "el-fix" #:action 'produce #:output-of "bake" #:resource-conforms-to "bread"
         #:resource-quantity (make-measure -10.0 "unit") #:has-point-in-time "2026-04-09T09:00:00Z"
         #:fulfills "m-2026-04-01" #:corrects "el-2026-04-01"))
    ;; a fifth day, its books kept in other units: the hours stated in
    ;; minutes, and the bake recorded as a use of the oven that states both a
    ;; count and its hours
    ($ ps 'add-commitment
       (make-commitment #:id "w-2026-04-05" #:action 'work #:input-of "bake"
                        #:resource-conforms-to "skill-bake"
                        #:effort-quantity (make-measure 10.0 %effort-unit)))
    ($ obs 'register-commitment
       (make-commitment #:id "m-2026-04-05" #:action 'produce #:output-of "bake"
                        #:resource-conforms-to "bread"
                        #:resource-quantity (make-measure 20.0 "unit")))
    ($ obs 'record-event (make-economic-event #:id "ew-2026-04-05" #:action 'work #:input-of "bake" #:resource-conforms-to "skill-bake" #:provider "EAda" #:effort-quantity (make-measure 300.0 "minute") #:has-point-in-time "2026-04-05T10:00:00Z"
                           #:fulfills "w-2026-04-05"))
    ($ obs 'record-event (loaf-ev "el-2026-04-05" "bake" "m-2026-04-05" 10.0 "2026-04-05"))
    (let* ((seen (car (shown (scope-standing sr))))
           (run (find (lambda (r) (equal? "2026-04-05" (car r))) (list-ref seen 4))))
      (check-pred "an event answers its claim in the claim's unit: 300 minutes are 5 of the 10 hours, stress 5"
                  (~= 5.0 (assoc-ref (caddr run) baking)))
      (check-pred "…and half the loaves from half the hours is a full capture"
                  (~= 100.0 (cadr run))))
    (let* ((seen (car (shown (scope-standing sr))))
           (runs (filter (lambda (r) (not (equal? "2026-04-05" (car r)))) (list-ref seen 4))))
      (check-pred "a correction is no run of its own: the record still has its four days"
                  (equal? '("2026-04-01" "2026-04-02" "2026-04-03" "2026-04-04") (sort (map car runs) string<?)))
      (check-pred "…it amends the run it corrects: the first day made 10 of its 20 loaves"
                  (~= 50.0 (cadr (find (lambda (r) (equal? "2026-04-01" (car r))) runs)))))))

(display "\n── the two sources, live: scenario → severity + allowance ──\n")

;; a drought scenario: work on skill-bake multiplied by 0.4 (a 60% cut)
(define drought (make-planning-scenario "drought" #f 0.3 '((work "skill-bake" 0.4)) #f))

(check-pred "the realized scenario reads as delivered stress on the flows it touches"
            (~= 6.0 (assoc-ref (flows-stress (scenario-shocks drought) '((work "bake" "skill-bake"))) baking)))

(check-pred "…and as the regret denominator, from the SAME record"
            (~= 0.4 (assoc-ref (flows-factor (scenario-shocks drought) '((work "bake" "skill-bake"))) baking)))

(with-vat vat
  (let ((obs (spawn ^observer (empty-observer-state) (quote ()))))
    ;; 4 of 10 claimed hours delivered — but the drought only ALLOWED 4:
    ;; regret-normalised capture is 100%, not 40%. The recipe is not blamed
    ;; for the weather.
    ($ obs 'record-event (work-ev "e9" "p9" "c9" 4.0))
    (let ((runs (observer-runs obs '("p9")
                               #:commitment-of commitment-of
                               #:sky-of (lambda (pid) drought))))
      (check-pred "capture is measured against what the scenario allowed"
                  (~= 100.0 (cadr (car runs)))))))

(display "\n── the regime, read as a witnessed fact ──\n")

(with-vat vat
  (let ((store (spawn-acdc-store)))
    (check-pred "no claim: probability-free — the dangerous default"
                (eq? 'probability-free (live-regime-of store "bread-domain")))
    ($ store 'issue (make-regime-claim-credential "EWitness" "bread-domain" 'thin 'stable))
    (check-pred "thin + stable, live: statistics is licensed"
                (eq? 'statistical (live-regime-of store "bread-domain")))
    ($ store 'issue (make-regime-claim-credential "EWitness" "wild-domain" 'fat 'stable))
    (check-pred "fat tails: no licence, whatever the process"
                (eq? 'probability-free (live-regime-of store "wild-domain")))
    ($ store 'issue (make-regime-claim-credential "EWitness" "vague-domain" 'unknown 'stable))
    (check-pred "honest ignorance reads as the dangerous case"
                (eq? 'probability-free (live-regime-of store "vague-domain")))))

(display "\n── the position: a record still forming, or one that speaks ──\n")

(check-pred "every run so far was calm: the record is still forming, however many there are"
            (eq? 'experimental (standing-position '(((curve . ((0.0 . 100.0)))) ((curve . ((0.0 . 96.0))))))))
(check-pred "one flow has met stress: observed, though another has yet to be pressed"
            (eq? 'observed (standing-position '(((curve . ((0.0 . 100.0) (4.0 . 80.0)))) ((curve . ((0.0 . 100.0))))))))
(check-pred "no rows at all: still forming"
            (eq? 'experimental (standing-position '())))

(display "\n── the admission seam: a recipe the policy does not admit never reaches the solve ──\n")


(with-vat vat
  (let* ((sr (spawn-scope-root "Barbell Scope"))
         (rs ($ sr 'recipe-store)))
    ($ rs 'add-recipe-process (make-recipe-process #:id "rp-a" #:name "A"
                                                   #:process-conforms-to "ps-a"))
    ($ rs 'add-recipe (make-recipe #:id "recipe-good" #:name "Good" #:primary-output "good"
                                   #:recipe-processes (list "rp-a")))
    ($ rs 'add-recipe-process (make-recipe-process #:id "rp-b" #:name "B"
                                                   #:process-conforms-to "ps-b"))
    ($ rs 'add-recipe (make-recipe #:id "recipe-bad" #:name "Bad" #:primary-output "bad"
                                   #:recipe-processes (list "rp-b")))
    (let ((admit? (lambda (r) (not (equal? "recipe-bad" (recipe-id r))))))
      (call-with-values (lambda () (gather-recipes rs #:admit? admit?))
        (lambda (procs flows)
          (check-pred "the recipe the policy keeps out contributes no processes"
                      (and (= 1 (length procs))
                           (equal? "rp-a" (recipe-process-id (car procs)))))))
      (call-with-values (lambda () (gather-recipes rs))
        (lambda (procs flows)
          (check-pred "absent the policy, the whole patchwork stands"
                      (= 2 (length procs))))))))

(test-summary!)
