;;; test-fragility-scales.scm — one form for every limit, read at a different scale.
;;;
;;; playnet.typ §"Worker, soil, and tool: one field" holds that the burnout
;;; ratio, the regenerative envelope and the design limit are ONE form — "the
;;; same convex possibility-tension φ(s) = −w log s, READ AT A DIFFERENT SCALE."
;;; engine/fragility.scm makes the scale sayable, as two orthogonal fields:
;;;
;;;     EXTENT  which draws are measured (good | spec | contained | within)
;;;     WINDOW  over what they are summed ('rate per period | 'horizon in total)
;;;
;;; The tests below check that each cell of that grid measures what it claims,
;;; by putting the SAME draw under different scales and reading what binds.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-fragility-scales.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve ingest) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (near? a b tol) (< (abs (- a b)) tol))

(define profile (list 80.0 120.0 0.5 50.0))   ; tip 100
(define tip 100.0)

;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. The declaration says its own scale
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 1. a fragility names its extent and its window ──~%~%")

(check "a rate is a spec measured per period"
       (let ((f (frag-rate "groundwater" profile)))
         (and (eq? 'spec (fragility-kind f)) (eq? 'rate (fragility-window f)))))
(check "a budget is the same spec measured over the horizon"
       (eq? 'horizon (fragility-window (frag-budget "groundwater" profile))))
(check "the two differ ONLY in window — same extent, same profile"
       (let ((r (frag-rate "x" profile)) (b (frag-budget "x" profile)))
         (and (equal? (fragility-extent r) (fragility-extent b))
              (equal? (fragility-profile r) (fragility-profile b))
              (not (eq? (fragility-window r) (fragility-window b))))))
(check "a commons names the specs it covers"
       (equal? '("water") (fragility-specs (frag-within "shed" '("water") profile))))
(check "a commons may be a rate or a tipping point"
       (and (eq? 'rate (fragility-window (frag-within "s" '("w") profile)))
            (eq? 'horizon (fragility-window
                           (frag-within "s" '("w") profile #:window 'horizon)))))

;; The old shape stays legal — a bare (spec . profile) pair has always meant a
;; per-period rate, and lifting it is what lets one list carry both shapes.
(check "a bare (spec . profile) pair lifts to a rate, unchanged"
       (let ((f (as-fragility (cons "topsoil" profile))))
         (and (eq? 'spec (fragility-kind f))
              (eq? 'rate (fragility-window f))
              (equal? profile (fragility-profile f)))))
(check "a list may MIX pairs and records — the gap that blocked tipping points"
       (let ((fs (as-fragilities (list (cons "topsoil" profile)
                                       (frag-within "shed" '("timber") profile
                                                    #:window 'horizon)))))
         (and (= 2 (length fs))
              (eq? 'rate    (fragility-window (car fs)))
              (eq? 'horizon (fragility-window (cadr fs))))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. RATE vs HORIZON — a limit that resets, and one that does not
;;; ════════════════════════════════════════════════════════════════════════════

(define P '(0 1 2))

(define (forest-run frag)
  (set-templates! (compile-recipe (list (rp "log" "Log"))
                        (list (out "o1" "timber" 1.0 "log") (wrk "o2" 0.01 "log")
                              (in "o3" "tree" 1.0 "log"))))
  (ingest-located! (list (er "m" "tree" #f #:place #f #:qty 0.0 #:unit "kg" #:contained-in "forest"))
                   '() (list (place* "forest"))
    #:periods P #:raws '("tree")
    #:eco-spec-frag (if frag (list frag) '())
    #:demand (map (lambda (t) (cons (lg "timber" (cell "forest" t)) 1000.0)) P))
  (for-each (lambda (t) (hash-set! *A* (cell "forest" t) 1000000.0)) P)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values
                      (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))))
        (fold + 0.0 (map (lambda (t) (V (format #f "p|log|forest@~a" t))) P))))))

(format #t "~%── 2. the same spec, two windows, three periods ──~%~%")

(define free  (forest-run #f))
(define rated (forest-run (frag-rate "tree" profile)))
(define total (forest-run (frag-budget "tree" profile)))

(format #t "    unbarriered      ~8,2f~%    rate boundary    ~8,2f~%    horizon budget   ~8,2f~%~%"
        free rated total)

(check "unbarriered logging runs to demand"        (> free (* 20 tip)))
;; A fragility eases off BEFORE its wall — that is what distinguishes it from a
;; hard cap — so each period settles below the tip rather than at it. What makes
;; it a RATE is that the headroom RESETS: the total is the per-period draw times
;; the horizon, not one tip shared across it.
(check "a RATE resets each period, so the total scales with the horizon"
       (near? rated (* (length P) (/ rated (length P))) 1.0))
(check "…and each period settles BELOW the tip, easing off before the wall"
       (< (/ rated (length P)) tip))
(check "…so three periods of a rate draw far more than one tip"
       (> rated (* 1.8 tip)))
(check "a HORIZON budget holds the TOTAL near one tip — it does not reset"
       (near? total tip (* 0.4 tip)))
(check "so a tipping point binds strictly harder than a rate over deep time"
       (< total (* 0.6 rated)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. WITHIN — the commons: one limit, many drawers
;;; ════════════════════════════════════════════════════════════════════════════
;;
;; `contained` reads its specs at the CONTAINER'S OWN cell, so draws made by
;; separate places under it are invisible. That is measured below, not supposed:
;; two farms pump identically with and without a `contained` barrier on the
;; shed. `within` walks the containment tree instead — the federation's own
;; `containment-chain`, asked from the other end — so the shed feels the SUM.
;;
;; This is what playnet.typ §bioregion requires of custody: the steward is
;; "whoever feels the pull as the draw nears the limit", and an over-draw must
;; be "felt by exactly the scope that can ease it".

(define plots '("farm-a" "farm-b"))

(define (commons-run mode)
  (set-templates! (compile-recipe (list (rp "pump" "Pump"))
                        (list (out "o1" "crop" 1.0 "pump") (wrk "o2" 0.01 "pump")
                              (in "o3" "water" 1.0 "pump"))))
  (apply ingest-located!
         (map (lambda (p) (er (string-append "m-" p) "water" #f #:place p #:qty 0.0 #:unit "m3"))
              plots)
         '()
         (cons (place* "shed" #:name "the watershed")
               (map (lambda (p) (place* p #:name p #:parent "shed")) plots))
         #:periods '(0) #:raws '("water")
         #:demand (map (lambda (p) (cons (lg "crop" (cell p 0)) 1000.0)) plots)
         (case mode
           ((within)    (list #:eco-spec-frag (list (frag-within "shed" '("water") profile))))
           ((contained) (list #:eco-container (list (cons "shed" profile))))
           (else        (list #:eco-spec-frag '()))))
  (for-each (lambda (p) (hash-set! *A* (cell p 0) 1000000.0)) plots)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values
                      (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))))
        (map (lambda (p) (V (format #f "p|pump|~a@0" p))) plots)))))

(format #t "~%── 3. two farms, one aquifer ──~%~%")

(define c-free (commons-run 'none))
(define c-cont (commons-run 'contained))
(define c-with (commons-run 'within))
(define (tot xs) (fold + 0.0 xs))

(format #t "    no barrier                  ~a  total ~8,2f~%"
        (map (lambda (v) (format #f "~,1f" v)) c-free) (tot c-free))
(format #t "    contained (shed's own cell) ~a  total ~8,2f~%"
        (map (lambda (v) (format #f "~,1f" v)) c-cont) (tot c-cont))
(format #t "    within (at or under shed)   ~a  total ~8,2f~%~%"
        (map (lambda (v) (format #f "~,1f" v)) c-with) (tot c-with))

(check "unbarriered, each farm pumps to its own demand"
       (> (tot c-free) (* 10 tip)))
(check "a `contained` barrier is BLIND to draws made at places under it"
       (near? (tot c-cont) (tot c-free) 1.0))
(check "`within` makes the shed feel the SUM of its farms"
       (near? (tot c-with) tip (* 0.4 tip)))
(check "the commons is shared symmetrically — neither farm is starved for the other"
       (near? (car c-with) (cadr c-with) 1.0))
(check "each farm alone draws well under the tip it now shares"
       (< (car c-with) tip))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. The pooled budget is a LEVEL, not a threshold
;;; ════════════════════════════════════════════════════════════════════════════
;;
;; playnet.typ §"Shared budgets": "the budget itself is a stock on the surface,
;; with its own gap signal, held in stewardship custody at the scope that speaks
;; for the agent." A `within` fragility alone takes its headroom from the
;; governance-set tip; a pooled BUDGET takes it from a measurement — so a shed
;; with more water in it can carry more drawing, and one already drawn down
;; starts drawn down. Same barrier, same fixed weight, a level that is a fact.

(define (budget-run level)
  (set-templates! (compile-recipe (list (rp "pump" "Pump"))
                        (list (out "o1" "crop" 1.0 "pump") (wrk "o2" 0.01 "pump")
                              (in "o3" "water" 1.0 "pump"))))
  (ingest-located!
   (map (lambda (p) (er (string-append "m-" p) "water" #f #:place p #:qty 0.0 #:unit "m3"))
        plots)
   '()
   (cons (place* "shed" #:name "the watershed")
         (map (lambda (p) (place* p #:name p #:parent "shed")) plots))
   #:periods '(0) #:raws '("water")
   #:eco-spec-frag (list (pooled-budget "shed" '("water") level profile))
   #:demand (map (lambda (p) (cons (lg "crop" (cell p 0)) 1000.0)) plots))
  (for-each (lambda (p) (hash-set! *A* (cell p 0) 1000000.0)) plots)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values
                      (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))))
        (fold + 0.0 (map (lambda (p) (V (format #f "p|pump|~a@0" p))) plots))))))

(format #t "~%── 4. the pooled budget as a measured level ──~%~%")

(define b-low  (budget-run 50.0))
(define b-mid  (budget-run 200.0))
(define b-high (budget-run 800.0))

(format #t "    level  50 → total draw ~8,2f~%" b-low)
(format #t "    level 200 → total draw ~8,2f~%" b-mid)
(format #t "    level 800 → total draw ~8,2f~%~%" b-high)

(check "a pooled budget is a constructor over the same record"
       (let ((b (pooled-budget "shed" '("water") 200.0 profile)))
         (and (eq? 'within (fragility-kind b))
              (= 200.0 (fragility-level b))
              (eq? 'carry (fragility-window b)))))
(check "more water in the shed carries more drawing"
       (and (< b-low b-mid) (< b-mid b-high)))
(check "the level, not the tip, is what binds — a shed below the tip draws less"
       (< b-low tip))
(check "a shed far above the tip still eases off before its own level"
       (< b-high 800.0))
(check "a fragility with no level falls back to the governance tip"
       (not (fragility-level (frag-within "shed" '("water") profile))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. A LEVEL carries forward — and cannot borrow from the future
;;; ════════════════════════════════════════════════════════════════════════════
;;
;; playnet.typ §"One program": the temporal axis is "a chain, linked only forward
;; by storage", and "you can only carry stock FORWARD — there is no activity that
;; moves a good from the future to the present. Space is symmetric; time is not."
;;
;; A pooled budget stated as one HORIZON total cannot express that asymmetry: the
;; solve sees a single constraint over every period at once, so a recharge in a
;; late period pays for a draw in an early one. An aquifer emptied in year 1 and
;; refilled in year 5 reads as never having been empty.
;;
;; 'carry states the level at EVERY period, counting only what happened up to it.
;; Below, recharge is possible ONLY in the last period (its input exists only
;; there). Under 'horizon the plan may pump hard in period 0 against a repair it
;; has not made yet; under 'carry it may not.

(define (carry-run window)
  (set-templates! (compile-recipe
         (list (rp "pump" "Pump") (rp "recharge" "Recharge"))
         (list (out "o1" "crop" 1.0 "pump") (wrk "o2" 0.01 "pump")
               (in  "o3" "water" 1.0 "pump")
               ;; recharge needs `rain`, which exists only in the last period
               (out "r1" "water" 1.0 "recharge") (wrk "r2" 0.01 "recharge")
               (in  "r3" "rain" 1.0 "recharge"))))
  (ingest-located!
   (list (er "m" "water" #f #:place "farm" #:qty 0.0 #:unit "m3"))
   '()
   (list (place* "shed" #:name "the watershed")
         (place* "farm" #:name "farm" #:parent "shed"))
   #:periods P #:raws '("water")
   #:eco-spec-frag (list (pooled-budget "shed" '("water") 100.0 profile #:window window))
   ;; the crop is wanted in the FIRST period — before any repair is possible
   #:demand (list (cons (lg "crop" (cell "farm" 0)) 1000.0)))
  (for-each (lambda (t) (hash-set! *A* (cell "farm" t) 1000000.0)) P)
  ;; rain only in the last period ⇒ recharge can only run then
  (hash-set! *init* (lg "rain" (cell "farm" (last P))) 100000.0)
  ;; The aquifer starts full: `water` gains a producer (recharge), so it is no
  ;; longer a free raw and must come from somewhere. A generous starting level
  ;; makes supply a non-issue, leaving the POOLED BARRIER as the only thing that
  ;; can hold pumping back — which is what this section is measuring.
  (hash-set! *init* (lg "water" (cell "farm" 0)) 100000.0)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values
                      (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))))
        (list (V "p|pump|farm@0")
              (V (format #f "p|recharge|farm@~a" (last P))))))))

(format #t "~%── 5. a level carried forward vs one total over the horizon ──~%~%")

(define h-run (carry-run 'horizon))
(define c-run (carry-run 'carry))

(format #t "    horizon  pump@0 ~8,2f   recharge@~a ~,2f~%" (car h-run) (last P) (cadr h-run))
(format #t "    carry    pump@0 ~8,2f   recharge@~a ~,2f~%~%" (car c-run) (last P) (cadr c-run))

(check "under one HORIZON total, an early draw is paid for by a later repair"
       (> (car h-run) (* 1.2 tip)))
(check "…and the plan does make that later repair"
       (> (cadr h-run) 0.0))
(check "a CARRIED level refuses to borrow from the future"
       (< (car c-run) (car h-run)))
(check "…holding the early draw within the level actually standing then"
       (< (car c-run) (* 1.05 tip)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. The grid routes without new tables
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 6. every scale lands in the collector that reads it ──~%~%")

(define (routed f table) (route-fragility! f) (hash-ref table (fragility-key f) #f))

(check "a rate routes to the per-period spec boundary"
       (routed (frag-rate "a" profile) *frag-spec*))
(check "a budget routes to the cumulative spec barrier"
       (routed (frag-budget "b" profile) *frag-budget*))
(check "a container routes to the contents roll-up"
       (routed (frag-contained "c" profile) *frag-container*))
(check "a commons routes to the containment roll-up, carrying its window"
       (let ((r (routed (frag-within "d" '("w") profile #:window 'horizon) *frag-within*)))
         (and r (eq? 'horizon (caddr r)) (equal? '("w") (cadr r)))))
(check "an unknown extent is refused rather than silently dropped"
       (not (false-if-exception
             (route-fragility! (make-fragility profile #:over (cons 'nonsense "x"))))))

(format #t "~%~a passed, ~a failed~%~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
