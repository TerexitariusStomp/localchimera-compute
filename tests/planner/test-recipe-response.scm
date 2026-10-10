;;; test-recipe-response.scm — a recipe's response, read off its runs.
;;;
;;; The comparator hands the plan a CURVE, and a future reads it at the stress
;;; it delivers (docs/playnet.typ: every wall is approached on a curve; observed
;;; ratios become the next forecasts). The words — fragile, antifragile,
;;; robust, proportional — describe the curve's bend (the lecture's picture,
;;; docs/antifragile/DarwinCollege.pdf §VII) and steer nothing.
;;;
;;; Pure: no world, no solve.
;;;
;;; Run: guile -L module tests/planner/test-recipe-response.scm

(use-modules (srfi srfi-1) (ice-9 format)
             (playnet solve recipe-response)
             (playnet vf formulas shocks)
             (playnet vf schemas) (playnet vf beyond scenario))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (~= a b) (< (abs (- a b)) 1e-9))
(define (word-of pts) (car (response-word (response-curve pts))))

;; the lecture's picture: held under light stress, then falling faster
(define jump        '((0 . 100) (2 . 98) (4 . 90) (6 . 70) (8 . 30)))
(define proportion  '((1 . 85) (3 . 67.5) (5 . 50) (7 . 32.5) (9 . 15)))
(define windfall    '((1 . 20) (3 . 23) (5 . 35) (7 . 58) (9 . 95)))
(define indifferent '((1 . 70) (3 . 73) (5 . 69) (7 . 72) (9 . 70)))

;; ── the curve ────────────────────────────────────────────────────────────────
(format #t "~%── the curve: the record, read in proportion ──~%~%")
(let ((c (response-curve jump)))
  (check "one reading per stress level observed, lightest first"
         (equal? (map car c) '(0 2 4 6 8)))
  (check "at an observed level, the reading witnessed"        (~= 90 (capture-at c 4)))
  (check "between two levels, in proportion"                   (~= 80 (capture-at c 5)))
  (check "heavier than the record, harm continues at the last observed rate"
         (~= 10 (capture-at c 9)))
  (check "…and never under nothing"                            (~= 0 (capture-at c 10))))
(let ((c (response-curve '((3 . 80) (5 . 70) (8 . 40)))))
  (check "lighter than the record, the lightest reading holds" (~= 80 (capture-at c 0))))
(check "a gain holds where it stood beyond the record: no gain is forecast unseen"
       (~= 95 (capture-at (response-curve windfall) 10)))
(check "one level observed reads that level everywhere"
       (let ((c (response-curve '((4 . 75)))))
         (and (~= 75 (capture-at c 0)) (~= 75 (capture-at c 9)))))
(check "no runs, no curve, no reading" (not (capture-at (response-curve '()) 5)))

;; ── the regime picks the reading ─────────────────────────────────────────────
(format #t "~%── several witnesses of one stress level ──~%~%")
(define thrice '((2 . 95) (6 . 90) (6 . 40) (6 . 80) (9 . 35)))
(check "probability-free, the default: the most adverse capture witnessed"
       (~= 40 (capture-at (response-curve thrice) 6)))
(check "statistical, licensed: their mean — every run counts in it"
       (~= 70 (capture-at (response-curve thrice #:regime 'statistical) 6)))
(check "one witness: the two regimes read alike"
       (~= (capture-at (response-curve thrice) 2)
           (capture-at (response-curve thrice #:regime 'statistical) 2)))
(check "across the stress observed, the default reading is the more cautious of the two"
       (every (lambda (s) (>= (capture-at (response-curve thrice #:regime 'statistical) s)
                              (capture-at (response-curve thrice) s)))
              '(0 2 4 6 7 9)))

;; ── the shocks a record lays over a future ───────────────────────────────────
(format #t "~%── in each future, a recipe yields what its record says there ──~%~%")
(define (scn id p mults) (make-planning-scenario id #f p mults #f))
(define calm    (scn "calm" 0.8 '()))
(define drought (scn "drought" 0.2 '(("grain" . 0.4))))          ; stress 6 on what makes grain
(define tail    (scn "tail" 0.0 '(("grain" . 0.1))))             ; stress 9, beyond the record
(define grain '(produce . "grain"))
;; a response as a solve takes it: one act per PROCS making OUTPUT, its curve on that flow
(define* (response procs curve #:key (position 'observed) (output "grain")
                   (flows (map (lambda (p) (list 'produce p output)) procs))
                   (curves (if (null? curve) '() (list (cons (cons 'produce output) curve)))))
  `((procs . ,procs) (flows . ,flows) (curves . ,curves) (position . ,position) (output . ,output)))
(define brittle (response '("mill-b") (response-curve jump)))
(define steady  (response '("mill-a") (response-curve '((0 . 100) (4 . 100) (8 . 100)))))
(define (factor-in future who)
  (scenario-factor-on (normalize-shocks (response-shocks (list brittle steady) future))
                      'produce who #f))
(check "calm weather: the brittle recipe yields the whole of what is allowed"
       (~= 1.0 (factor-in calm "mill-b")))
(check "drought, stress 6: it yields the 70% its record shows there"
       (~= 0.7 (factor-in drought "mill-b")))
(check "the tail, beyond its record: its harm continued, 10%"
       (~= 0.1 (factor-in tail "mill-b")))
(check "a recipe that holds lays no shock in any future"
       (and (null? (response-shocks (list steady) drought))
            (null? (response-shocks (list steady) tail))))
(check "the response is in proportion: a harder future, a smaller yield, by the curve"
       (> (factor-in calm "mill-b") (factor-in drought "mill-b") (factor-in tail "mill-b")))
(check "every process of the recipe carries the shock"
       (equal? '("grow" "mill")
               (map cadr (response-shocks (list (response '("grow" "mill") (response-curve jump))) drought))))
(check "the shock composes with the weather's own by the one matcher"
       (let ((f (branch-flow-factor
                 (scenario-shocks (scenario-with-shocks drought (response-shocks (list brittle) drought))))))
         (~= (* 0.4 0.7) (f 'produce "mill-b" "grain" 0 "z"))))
(check "a record reading above the whole leaves the map where it stands"
       (~= 1.0 (response-factor `((,grain . ,(response-curve '((0 . 100) (6 . 130))))) `((,grain . 6)))))
(check "a recipe with no record yields what the weather allows"
       (~= 1.0 (response-factor '() `((,grain . 6)))))
(check "across channels, the most adverse reading"
       (~= 0.5 (response-factor `((,grain . ,(response-curve '((0 . 100) (6 . 80))))
                                   ((work . "milling") . ,(response-curve '((0 . 100) (4 . 50)))))
                                 `((,grain . 6) ((work . "milling") . 4)))))
(check "a channel the future leaves calm is read at no stress"
       (~= 0.9 (response-factor `(((work . "milling") . ,(response-curve '((0 . 90) (5 . 20))))
                                   (,grain . ,(response-curve '((0 . 90) (6 . 90)))))
                                 `((,grain . 6)))))
(check "a flow pressed for the first time reads the most adverse response the recipe has shown at that stress"
       (~= 0.34 (response-factor `(((work . "milling") . ,(response-curve '((0 . 90) (5 . 20))))
                                    ((consume . "seed") . ,(response-curve '((0 . 90) (4 . 80)))))
                                  `((,grain . 4)))))
(check "one run under stress is a flow pressed: its own reading stands, however short the curve"
       ;; grain met stress 4 once and held 75; the work curve would read 34 there
       (~= 0.75 (response-factor `(((work . "milling") . ,(response-curve '((0 . 90) (5 . 20))))
                                    (,grain . ,(response-curve '((4 . 75)))))
                                  `((,grain . 4)))))
(check "…and one that has only ever seen calm does too"
       (~= 0.34 (response-factor `(((work . "milling") . ,(response-curve '((0 . 90) (5 . 20))))
                                    (,grain . ,(response-curve '((0 . 90)))))
                                  `((,grain . 4)))))

;; ── a channel is one of the recipe's own flows ───────────────────────────────
(format #t "~%── a record meets a future on the recipe's own flows ──~%~%")
(define bake-flows '((work "bake" "skill-bake") (consume "bake" "flour") (produce "bake" "bread")))
(define (stress-under . shocks) (flows-stress (normalize-shocks shocks) bake-flows))
(define (on ch stresses) (assoc-ref stresses ch))
(check "one channel per flow, named by the flow itself"
       (equal? '((work . "skill-bake") (consume . "flour") (produce . "bread")) (map car (stress-under))))
(check "calm weather delivers no stress on any"
       (every (lambda (cs) (~= 0 (cdr cs))) (stress-under)))
(check "a shock on its output's spec presses its output, and nothing else"
       (let ((s (stress-under '("bread" . 0.4))))
         (and (~= 6 (on '(produce . "bread") s)) (~= 0 (on '(work . "skill-bake") s)) (~= 0 (on '(consume . "flour") s)))))
(check "a shock on its act presses its output"
       (~= 3 (on '(produce . "bread") (stress-under '(produce "bake" 0.7)))))
(check "a shock on the skill it works presses its work"
       (~= 5 (on '(work . "skill-bake") (stress-under '(work "skill-bake" 0.5)))))
(check "a shock on an input it draws presses that input"
       (~= 2 (on '(consume . "flour") (stress-under '(consume "flour" 1.2)))))
(check "a shock on another recipe's good passes it by"
       (every (lambda (cs) (~= 0 (cdr cs))) (stress-under '("rice" . 0.1))))
(check "a shock at one place, or in one period, reaches the act that runs there"
       (and (~= 4 (on '(produce . "bread") (stress-under '(produce ("bake" . "kreuzberg") 0.6))))
            (~= 8 (on '(produce . "bread") (stress-under '(produce "bread" 2 0.2))))))
(check "a used service is pressed by a shock on its use"
       (~= 5 (on '(use . "oven") (flows-stress (normalize-shocks '((use "oven" 1.5))) '((use "bake" "oven"))))))

(format #t "~%── a run is filed under the flow its weather pressed hardest ──~%~%")
(check "the heaviest channel takes the run"
       (equal? '(((produce . "bread") . 6.0)) (file-run '(((work . "skill-bake") . 1.0) ((produce . "bread") . 6.0)))))
(check "a tie files it under each"
       (= 2 (length (file-run '(((work . "skill-bake") . 4.0) ((produce . "bread") . 4.0))))))
(check "a calm run is a reading at no stress on every channel"
       (= 3 (length (file-run (stress-under)))))

;; one recipe, two kinds of weather: short of hands it holds; short of harvest it breaks
(define grow-flows '((work "grow" "farming") (produce "grow" "wheat")))
(define (run-under capture . shocks)
  (cons capture (file-run (flows-stress (normalize-shocks shocks) grow-flows))))
(define grower-runs
  (list (run-under 100)
        (run-under 99 '(work "farming" 0.7)) (run-under 98 '(work "farming" 0.4)) (run-under 97 '(work "farming" 0.2))
        (run-under 95 '("wheat" . 0.7))      (run-under 60 '("wheat" . 0.4))      (run-under 10 '("wheat" . 0.2))))
(define grower-rows (recipe-response-report grower-runs))
(define (row-of rows ch) (find (lambda (r) (equal? ch (assq-ref r 'channel))) rows))
(define grower
  (response '("grow") '() #:output "wheat" #:flows grow-flows
            #:curves (map (lambda (r) (cons (assq-ref r 'channel) (assq-ref r 'curve))) grower-rows)))
(define (grower-yield . shocks)
  (scenario-factor-on (normalize-shocks (response-shocks (list grower) (scn "f" 0.2 shocks))) 'produce "grow" #f))
(check "its character is per flow: robust to a shortage of hands, fragile to a failed harvest"
       (and (eq? 'robust  (assq-ref (row-of grower-rows '(work . "farming")) 'word))
            (eq? 'fragile (assq-ref (row-of grower-rows '(produce . "wheat")) 'word))))
(check "the calm run is the first reading of both curves"
       (and (= 4 (assq-ref (row-of grower-rows '(work . "farming")) 'n))
            (= 4 (assq-ref (row-of grower-rows '(produce . "wheat")) 'n))))
(check "a future short of hands leaves it near whole"      (~= 0.98 (grower-yield '(work "farming" 0.4))))
(check "a future of failed harvest reads the harm it showed" (~= 0.60 (grower-yield '("wheat" . 0.4))))
(check "a future of both reads the more adverse"
       (~= 0.60 (grower-yield '(work "farming" 0.4) '("wheat" . 0.4))))
(check "a record made under one kind of weather still meets a forecast keyed another way"
       ;; the forecast names the act, the record was read off the spec
       (~= 0.60 (grower-yield '(produce "grow" 0.4))))
(check "a record of work alone meets a forecast on the crop: the live case"
       ;; every run so far was filed under the skill; the shed forecasts the harvest
       (let ((hand (response '("grow") '() #:output "wheat" #:flows grow-flows
                             #:curves `(((work . "farming") . ,(response-curve '((0 . 100) (3 . 90) (6 . 50))))
                                        ((produce . "wheat") . ,(response-curve '((0 . 100))))))))
         (~= 0.5 (scenario-factor-on
                  (normalize-shocks (response-shocks (list hand) (scn "failure" 0.2 '(("wheat" . 0.4)))))
                  'produce "grow" #f))))

;; ── a run, read: what reached it is its weather, what it made is its capture ─
(format #t "~%── a run alone under its sky still has one: its own inputs ──~%~%")
(define (reading raw . sky) (run-reading "bake" raw (normalize-shocks sky)))
(define (filed-on r ch) (assoc-ref (cadr r) ch))
(let ((r (reading '((work "skill-bake" 10.0 5.0) (consume "flour" 8.0 8.0) (produce "bread" 20.0 10.0)))))
  (check "half the hours arrived: stress 5 on the work it draws"
         (~= 5 (filed-on r '(work . "skill-bake"))))
  (check "…and half the bread from half the hours is a full capture"
         (~= 100 (car r)))
  (check "the tuples say what was allowed: the bread due, scaled by the scarcest input"
         (equal? '(produce "bread" 10.0 10.0) (car (caddr r)))))
(let ((r (reading '((work "skill-bake" 10.0 5.0) (produce "bread" 20.0 6.0)))))
  (check "less than its inputs allowed is the recipe's own shortfall: 60%"
         (~= 60 (car r))))
(let ((r (reading '((work "skill-bake" 10.0 10.0) (consume "flour" 8.0 12.0) (produce "bread" 20.0 20.0)))))
  (check "inputs arriving whole, or over, are calm weather"
         (every (lambda (cs) (~= 0 (cdr cs))) (cadr r)))
  (check "…and drawing more than was due leaves the capture where the output puts it"
         (~= 100 (car r))))
(let ((r (reading '((work "skill-bake" 10.0 8.0) (consume "flour" 8.0 4.0) (produce "bread" 20.0 10.0)))))
  (check "the scarcest input sets what the run could make, and takes the run"
         (and (~= 100 (car r)) (~= 5 (filed-on r '(consume . "flour")))
              (not (filed-on r '(work . "skill-bake"))))))
(let ((r (reading '((work "skill-bake" 10.0 10.0) (produce "bread" 20.0 8.0)) '("bread" . 0.5))))
  (check "the day's sky on its output presses the output: stress 5, and 8 of the 10 allowed is 80%"
         (and (~= 5 (filed-on r '(produce . "bread"))) (~= 80 (car r)))))
(let ((r (reading '((work "skill-bake" 10.0 5.0) (produce "bread" 20.0 5.0)) '("bread" . 0.5))))
  (check "sky and shortfall compose: half the hours under half the yield allow a quarter"
         (~= 100 (car r))))
(let ((r (reading '((work "skill-bake" 10.0 10.0) (produce "bread" 20.0 20.0)) '(work "skill-bake" 0.4))))
  (check "its own hours arrived whole: the neighbours' shortage of hands was not its weather"
         (every (lambda (cs) (~= 0 (cdr cs))) (cadr r))))
(let ((r (reading '((work "skill-bake" 10.0 10.0) (produce "bread" 20.0 10.0)
                    (transfer "bread" 20.0 2.0) (cite "recipe-book" 1.0 0.0)))))
  (check "which side a claim stands on is the action table's: a citation is an input, a transfer neither"
         (and (~= 10 (filed-on r '(cite . "recipe-book")))                   ; an input that never arrived
              (not (find (lambda (t) (eq? 'transfer (car t))) (caddr r)))))
  (check "…so the transfer is no part of what the run made: 10 of 20 loaves, with nothing cited, is all of nothing allowed"
         ;; the citation arrived at nothing of what was due: the scarcest input allows nothing
         (~= 0 (car r))))
(let ((r (reading '((work "skill-bake" 10.0 10.0) (produce "bread" 20.0 10.0) (transfer "bread" 20.0 2.0)))))
  (check "a transfer beside the run leaves its capture where the output puts it"
         (~= 50 (car r))))
(let ((r (reading '((work "skill-bake" 10.0 10.0) (produce "bread" 20.0 8.0)) '(produce "bake" 0.5))))
  (check "a sky keyed on the act presses the output and allows by the same factor: one reading, read twice"
         (and (~= 5 (filed-on r '(produce . "bread"))) (~= 80 (car r)))))
(let ((r (reading '((work "skill-bake" 10.0 4.0)) '(work "skill-bake" 0.4))))
  (check "a run that recorded no output is read on what it did record, against the day's sky"
         (and (~= 100 (car r)) (~= 6 (filed-on r '(work . "skill-bake"))))))

;; ── reach: a record is a proof up to the heaviest stress it has met ──────────
(format #t "~%── needs rest on a recipe by how far its record reaches ──~%~%")
(define tried   (response '("old-mill") (response-curve jump)))                       ; met stress 8
(define untried (response '("new-mill") '() #:position 'experimental))                ; never run
(define forming (response '("young-mill") (response-curve '((0 . 100) (4 . 90)))))    ; met stress 4
(define turkey  (response '("calm-mill") (response-curve '((0 . 100) (0.3 . 100) (0.5 . 100)))))
(define lone    (response '("press") '() #:position 'experimental #:output "oil"))
(define everyone (list tried untried forming turkey lone))
(check "a curve reaches as far as the heaviest stress it has a reading at"
       (and (~= 8 (curve-reach (response-curve jump))) (~= 0 (curve-reach '()))
            (~= 0 (curve-reach (response-curve '((0 . 100)))))))
(define (covers r . shocks)
  (response-coverage r (flows-stress (normalize-shocks shocks) (assq-ref r 'flows))))
(check "a future inside the record is covered whole"      (~= 1.0 (covers tried '("grain" . 0.4))))
(check "a future beyond it, by the share the record reaches" (~= (/ 8 9) (covers tried '("grain" . 0.1))))
(check "three calm days cover a storm by a sixteenth: the turkey"
       (~= (/ 0.5 8) (covers turkey '("grain" . 0.2))))
(check "a recipe that has run covers a calm future; one that never has covers nothing"
       (and (~= 1.0 (covers forming)) (~= 0.0 (covers untried))))
(check "a flow never pressed covers nothing of a future that presses it"
       (~= 0.0 (response-coverage forming '(((work . "milling") . 5.0)))))
(define (share-in future who)
  (scenario-factor-on (normalize-shocks (margin-shocks everyone future)) 'produce who #f))
(check "in the tail the furthest-reaching recipe stands whole"
       (~= 1.0 (share-in tail "old-mill")))
(check "…a shorter record by its share of that reach: 4 of 8"
       (~= 0.5 (share-in tail "young-mill")))
(check "…the calm record by a sixteenth, and one never run yields nothing"
       (and (~= (/ 0.5 8) (share-in tail "calm-mill")) (~= 0.0 (share-in tail "new-mill"))))
(check "a future every record covers lays the margin on the never-run alone"
       (equal? '((produce "new-mill" 0.0)) (margin-shocks everyone (scn "mild" 0.0 '(("grain" . 0.97))))))
(check "where no recipe for an output has run, it stands as it is: a new commune plans"
       (and (~= 1.0 (share-in tail "press"))
            (null? (margin-shocks (list untried lone) tail))))
(check "an act a further-reaching recipe shares takes the larger share"
       (null? (margin-shocks (list tried (response '("old-mill") '() #:position 'experimental)) tail)))
(check "the face's word for it: bounded beside a further reach, bare where nothing has been pressed, none for the furthest"
       (and (eq? 'bounded (response-margin untried everyone)) (eq? 'bounded (response-margin forming everyone))
            (eq? 'bare (response-margin lone everyone)) (not (response-margin tried everyone))))
(let ((laid (futures-under-record (list calm drought tail) everyone)))
  (check "the margin is laid in the future a floor is defended in without a forecast, and no other"
         (equal? '(1.0 1.0 0.0)
                 (map (lambda (s) (scenario-factor-on (scenario-shocks s) 'produce "new-mill" #f)) laid))))
(let ((laid (futures-under-record (list calm drought) everyone)))
  (check "a set with no such future gains a calm one, at no weight, for the never-run"
         (and (= 3 (length laid)) (zero? (planning-scenario-probability (last laid)))
              (~= 0.0 (scenario-factor-on (scenario-shocks (last laid)) 'produce "new-mill" #f))
              (~= 1.0 (scenario-factor-on (scenario-shocks (last laid)) 'produce "young-mill" #f)))))
(check "with every recipe run, the futures stand as given"
       (= 2 (length (futures-under-record (list calm drought) (list tried forming lone)))))

;; ── the words ────────────────────────────────────────────────────────────────
(format #t "~%── the words describe the bend ──~%~%")
(check "three levels: the gap is the middle reading's distance from the straight line"
       ;; 100 at stress 0, 30 at stress 8: in proportion, 65 at stress 4. It held 90.
       (equal? '(harm . 25) (triple-reading '(0 . 100) '(4 . 90) '(8 . 30))))
(check "harm that accelerates with intensity is FRAGILE"   (eq? 'fragile (word-of jump)))
(check "a gain that accelerates is ANTIFRAGILE"            (eq? 'antifragile (word-of windfall)))
(check "harm in proportion is PROPORTIONAL: capture moves with the stress, in a line"
       (eq? 'proportional (word-of proportion)))
(check "indifference is ROBUST: capture holds across the stress observed"
       (eq? 'robust (word-of indifferent)))
(check "a harm with little left to lose bends the other way, and is no gain"
       (not (eq? 'antifragile (word-of '((0 . 100) (3 . 40) (6 . 0) (8 . 0) (9 . 0))))))
(check "a gain pressing on full capture bends the other way, and is no harm"
       (not (eq? 'fragile (word-of '((0 . 60) (2 . 82) (4 . 94) (6 . 99) (8 . 100))))))
(check "gains under light stress, breaks under heavy: it breaks"
       (eq? 'fragile (word-of '((0 . 60) (2 . 66) (4 . 85) (6 . 80) (8 . 25)))))
(let ((bend (cdr (response-word (response-curve jump)))))
  (check "the word names the stretch of stress it was read over"
         (and (eq? 'harm (assq-ref bend 'kind)) (~= 25 (assq-ref bend 'gap))
              (= 0 (assq-ref bend 'from)) (= 4 (assq-ref bend 'at)) (= 8 (assq-ref bend 'to)))))
(check "two stress levels: no three runs to read — unobserved"
       (eq? 'unobserved (word-of '((2 . 90) (2 . 88) (8 . 40) (8 . 42)))))
(check "the reading stands however the stress axis is scaled"
       (let ((stretched (map (lambda (p) (cons (+ 3 (* 7 (car p))) (cdr p))) jump)))
         (and (eq? (word-of jump) (word-of stretched))
              (~= (assq-ref (cdr (response-word (response-curve jump))) 'gap)
                  (assq-ref (cdr (response-word (response-curve stretched))) 'gap)))))
(check "a bend smaller than the tolerance is no word"
       (eq? 'robust (word-of '((0 . 100) (4 . 98) (8 . 92)))))

;; ── the profile ──────────────────────────────────────────────────────────────
(format #t "~%── the profile: one row per channel ──~%~%")
(define (runs-on ch pts) (map (lambda (p) (cons (cdr p) (list (cons ch (car p))))) pts))
(check "no runs, no rows" (null? (recipe-response-report '())))
(let ((stat  (car (recipe-response-report (runs-on grain jump) #:regime 'statistical)))
      (pfree (car (recipe-response-report (runs-on grain jump)))))
  (check "statistical regime licenses the fitted acceleration and its standard error"
         (let ((l (assq-ref stat 'licensed)))
           (and l (number? (assq-ref l 'accel)) (number? (assq-ref l 'se)))))
  (check "probability-free attaches NO statistic — by design"
         (not (assq-ref pfree 'licensed)))
  (check "the raw points ride under either regime, unchanged"
         (equal? (assq-ref stat 'points) (assq-ref pfree 'points)))
  (check "a row carries the curve the plan reads"
         (equal? (assq-ref pfree 'curve) (response-curve jump)))
  (check "…its channel and its word"
         (and (equal? grain (assq-ref pfree 'channel)) (eq? 'fragile (assq-ref pfree 'word))))
  (check "…and counts its runs" (= 5 (assq-ref pfree 'n))))

(check "observed-capture reads the calibrate-shocks tuple shape"
       (= 75.0 (observed-capture '((produce "grain" 100.0 80.0)
                                   (produce "straw"  20.0 10.0)))))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — a recipe's response is a curve read off~%  its runs, and each future reads it at the stress it delivers.~%" *pass*)
    (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)))
(format #t "════════════════════════════════════════════~%")
(exit (if (> *fail* 0) 1 0))
