;;; test-response-solve.scm — the plan responds to a recipe's record, in proportion.
;;;
;;; Two ways to grow grain from one store of seed. `quick` makes half again as
;;; much per seed; `steady` makes less. In calm weather and in drought alike
;;; the weather allows both the same share — and `quick`'s own record shows it
;;; capturing less of that share the harder the drought presses. The record
;;; reaches the solve as a shock on `quick`'s act in each future, read off its
;;; curve at that future's stress (solve/recipe-response.scm response-shocks), and
;;; the floor is held in every future (engine/robust.scm).
;;;
;;; The plan leans on `quick` by what its record says it delivers, and the lean
;;; moves with the record.
;;;
;;; THE UNTRIED MARGIN. With no record at all `quick` is untried. Beside a
;;; tried `steady`, the floor is held without it — in the future defended
;;; without a forecast `quick` yields nothing — and `quick` still takes every
;;; seed the floor leaves free: its downside is bounded, its upside open.
;;;
;;; Run: guile -L module tests/solve/test-response-solve.scm

(use-modules (playnet test planner prelude)
             (playnet solve engine)
             (playnet vf schemas) (playnet vf beyond scenario)
             (playnet vf formulas shocks)
             (playnet solve recipe-response)
             (playnet knowledge dsl shorthand)
             (srfi srfi-1)
             (ice-9 format))

(define spatials  (list (place* "z")))
(define resources (list (er "seed1" "seed" #f #:place "z" #:qty 4.0 #:unit "u")))
(define procs (list (rp* "quick" "Quick") (rp* "steady" "Steady")))
(define flows
  (list (consume* "qs" "seed" 1.0 "quick" "u")  (out* "qg" "grain" 1.5 "quick" "u")
        (consume* "ss" "seed" 1.0 "steady" "u") (out* "sg" "grain" 1.0 "steady" "u")))

(define futures
  (list (make-planning-scenario "calm"    #f 0.8 '() "no shock")
        (make-planning-scenario "drought" #f 0.2 '(("grain" . 0.4)) "the sky allows four parts in ten")))

;; QUICK's record: what it captured of what the weather allowed, by stress
(define* (response proc curve #:key (position 'observed))
  `((procs . (,proc)) (flows . ((consume ,proc "seed") (produce ,proc "grain")))
    (curves . ,(if (null? curve) '() `(((produce . "grain") . ,curve))))
    (position . ,position) (output . "grain")))
(define (record-of at-drought)
  (list (response "quick" (response-curve `((0 . 100) (3 . 95) (6 . ,at-drought))))))

(define (planted responses)
  "→ (quick . steady): the acts planted before the weather is known"
  (call-with-values
    (lambda ()
      (plan-robust-from-records resources '() spatials procs flows
        #:scenarios (futures-under-record futures responses)
        #:first-stage-procs '("quick" "steady") #:raws '("seed")
        #:demand '(("grain#z@0" . 10.0)) #:repro-floors '(("grain#z@0" . 1.5)) #:per-agent? #f))
    (lambda (x fs . _)
      (cons (first-stage-activity x fs "quick") (first-stage-activity x fs "steady")))))

;; grain in the drought: what the sky allows, times what each act captures of it
(define (drought-grain plan capture)
  (+ (* 1.5 0.4 capture (car plan)) (* 1.0 0.4 (cdr plan))))

(define blind   (planted '()))
(define holds   (planted (record-of 100)))
(define slips   (planted (record-of 50)))
(define breaks  (planted (record-of 30)))

(format #t "~%── the plan leans on a recipe by what its record says it delivers ──~%")
(for-each (lambda (n p) (format #t "  ~12a quick ~,2f   steady ~,2f~%" n (car p) (cdr p)))
          '("no record" "holds 100%" "slips to 50%" "breaks to 30%")
          (list blind holds slips breaks))

(check "with no record, the plan plants the act that makes more per seed"
       (and (> (car blind) 3.0) (< (cdr blind) 0.5)))
(check "a record that holds under drought changes nothing"
       (and (< (abs (- (car holds) (car blind))) 0.1) (< (abs (- (cdr holds) (cdr blind))) 0.1)))
(check "a record that slips under drought moves seed to the act that holds"
       (> (cdr slips) (+ (cdr blind) 1.0)))
(check "…and one that breaks further moves more: the response is in proportion"
       (> (cdr breaks) (cdr slips)))
(check "the floor is held in the drought, by the record's own arithmetic"
       (and (>= (drought-grain slips 0.5) 1.49) (>= (drought-grain breaks 0.3) 1.49)))
(check "the plan that ignored the record would have breached it"
       (< (drought-grain blind 0.3) 1.5))
(check "nothing is gated: the act that breaks still runs where it pays"
       (> (car breaks) 0.1))
;; ── the live case: the record is of work, the forecast is of the crop ────────
;; Every run so far was filed under the skill `quick` works; the shed forecasts
;; the harvest. A flow pressed for the first time reads the most adverse
;; response the recipe has shown at that stress, so the record still speaks.
(define by-hand
  (planted `(((procs . ("quick"))
              (flows . ((work "quick" "farming") (consume "quick" "seed") (produce "quick" "grain")))
              (curves . (((work . "farming") . ,(response-curve '((0 . 100) (3 . 95) (6 . 50))))))
              (position . observed) (output . "grain")))))
(format #t "~%── a record of work meets a forecast on the crop ──~%")
(format #t "  ~12a quick ~,2f   steady ~,2f~%" "by hand" (car by-hand) (cdr by-hand))
(check "a record filed under the skill moves the plan under a forecast on the harvest"
       (and (< (abs (- (car by-hand) (car slips))) 0.1) (< (abs (- (cdr by-hand) (cdr slips))) 0.1)))

;; ── the untried margin ───────────────────────────────────────────────────────
(define tried-steady (response "steady" (response-curve '((0 . 100) (3 . 100) (6 . 100)))))
(define untried-quick (response "quick" '() #:position 'experimental))
(define bounded (planted (list untried-quick tried-steady)))
(define bare    (planted (list untried-quick (response "steady" '() #:position 'experimental))))

(format #t "~%── needs stand without the untried; the untried takes what they leave free ──~%")
(for-each (lambda (n p) (format #t "  ~22a quick ~,2f   steady ~,2f~%" n (car p) (cdr p)))
          '("quick untried, bounded" "both untried")
          (list bounded bare))

(check "beside a tried recipe, the floor is held by the tried one alone"
       (>= (* 1.0 (cdr bounded)) 1.49))
(check "…and no more seed than the floor asks is moved: the margin costs surplus only"
       (< (cdr bounded) 1.7))
(check "the untried recipe still runs wherever it pays: upside open"
       (> (car bounded) 2.0))
(check "where every recipe is untried the plan stands as it did"
       (and (< (abs (- (car bare) (car blind))) 0.1) (< (abs (- (cdr bare) (cdr blind))) 0.1)))
;; ── a trial, by consent: the hold is its slice, the floor stays outside it ───
;; `old` is run and makes more per seed; `new` has never run and makes less,
;; so nothing in the objective plants it and no run ever earns it a record.
;; A person offering to try it is a hold on its column (offers.scm offer-work
;; takes any process; accepts.scm standing-holds). The hold gives the trial
;; its seed. In the future the floor is defended in, `new` yields nothing, so
;; the floor is `old`'s alone to hold: a trial the floor can spare runs, and
;; one that would take the floor's seed is refused.
(define trial-procs (list (rp* "old" "Old") (rp* "new" "New")))
(define trial-flows
  (list (consume* "os" "seed" 1.0 "old" "u") (out* "og" "grain" 1.5 "old" "u")
        (consume* "ns" "seed" 1.0 "new" "u") (out* "ng" "grain" 1.0 "new" "u")))
(define trial-record
  (list `((procs . ("old")) (flows . ((consume "old" "seed") (produce "old" "grain")))
          (curves . (((produce . "grain") . ,(response-curve '((0 . 100) (3 . 100) (6 . 100))))))
          (position . observed) (output . "grain"))
        `((procs . ("new")) (flows . ((consume "new" "seed") (produce "new" "grain")))
          (curves . ()) (position . experimental) (output . "grain"))))
(define (tried-and-trial holds)
  "→ (old . new) runs, with HOLDS on the shared columns"
  (call-with-values
    (lambda ()
      (plan-robust-from-records resources '() spatials trial-procs trial-flows
        #:scenarios (futures-under-record futures trial-record)
        #:first-stage-procs '("old" "new") #:raws '("seed") #:holds holds
        #:demand '(("grain#z@0" . 10.0)) #:repro-floors '(("grain#z@0" . 1.5)) #:per-agent? #f))
    (lambda (x fs . _)
      (cons (first-stage-activity x fs "old") (first-stage-activity x fs "new")))))
(define unasked (tried-and-trial '()))
(define offered (tried-and-trial '(("p|new|z@0" . 1.0))))
(format #t "~%── a trial, by consent ──~%")
(for-each (lambda (n p) (format #t "  ~22a old ~,2f   new ~,2f~%" n (car p) (cdr p)))
          '("nobody offers" "one run offered") (list unasked offered))
(check "unasked, the plan never runs the recipe that makes less: it would never earn a record"
       (< (cdr unasked) 0.05))
(check "an offer to try it holds its column: the trial runs"
       (>= (cdr offered) 0.99))
(check "…on seed the floor can spare: the tried recipe alone still holds the floor where it is defended"
       (>= (* 1.5 0.4 (car offered)) 1.49))
(check "a trial that would take the floor's seed is refused: the floor stays outside every trial"
       (catch #t
         (lambda () (tried-and-trial '(("p|new|z@0" . 3.5))) #f)
         (lambda _ #t)))
(check-done)
