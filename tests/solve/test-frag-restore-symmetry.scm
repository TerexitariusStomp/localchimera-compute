;;; test-frag-restore-symmetry.scm — a fragility feels RESTORE as well as DRAW.
;;;
;;; A limit that only ever counts what is taken is a ratchet: the plan can spend
;;; the condition down and never earn it back, and every regenerative recipe in
;;; the codebase — compost rebuilding soil fertility, a legume fixing nitrogen,
;;; earthworks recharging a watershed — would be decorative. The whole point of
;;; worlds/doon-shed.scm calling its groundwater limit a "recharge ENVELOPE" is that
;;; the envelope has two sides.
;;;
;;; Nothing in the planner treats the two directions differently, which is
;;; exactly why this holds: `good-index` bins EVERY flow coefficient into the
;;; same index with its sign, and the fragility path reads that index. Draw is
;;; negative, restore positive, and they net. This test pins that, because it is
;;; a property no single line of code states and one careless sign would undo.
;;;
;;; Method. The stock is made abundant so ordinary supply never binds — the only
;;; thing that can hold pumping back is the fragility. Then pumping is compared
;;; with and without a recharge process, for BOTH fragility tables, against a
;;; control that produces something the limit does not cover.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-frag-restore-symmetry.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve ingest) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))

(define tip 100.0)          ; quantile_0.5(80,120)
(define profile (list 80.0 120.0 0.5 50.0))

;; Water contained-in the basin: its place IS the basin, and it is one of the
;; basin's contents. Abundant, so the ≥0 stock balance never binds.
(define (aquifer)
  (er "aquifer" "water" #f #:place #f #:qty 1000000.0 #:unit "m3" #:contained-in "basin"))

;; pump draws water for irrigation; the second process either RESTORES water
;; (recharge) or produces something the limit does not cover (the control).
(define (recipes second)
  (compile-recipe
   (append (list (rp "pump" "Pump"))
           (case second
             ((none) '())
             (else (list (rp "other" "Other")))))
   (append (list (out "p1" "irrigation" 1.0 "pump")
                 (wrk "p2" 0.01 "pump")
                 (in  "p3" "water" 1.0 "pump"))
           (case second
             ((none)     '())
             ((recharge) (list (out "s1" "water"  1.0 "other") (wrk "s2" 0.01 "other")))
             ((control)  (list (out "s1" "gravel" 1.0 "other") (wrk "s2" 0.01 "other")))))))

(define (run second table)
  (set-templates! (recipes second))
  (apply ingest-located!
         (list (aquifer)) '() (list (place* "basin"))
         #:periods '(0)
         #:demand (list (cons (lg "irrigation" (cell "basin" 0)) 1000.0))
         (case table
           ((container) (list #:eco-container (list (cons "basin" profile))))
           ((spec)      (list #:eco-spec-frag (list (cons "water" profile))))))
  (hash-set! *A* (cell "basin" 0) 1000000.0)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values
                      (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))))
        (cons (V "p|pump|basin@0") (V "p|other|basin@0"))))))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(format #t "~%── a fragility nets RESTORE against DRAW ──~%~%")

(for-each
 (lambda (table label)
   (let* ((alone    (car (run 'none     table)))
          (restored (run 'recharge table))
          (control  (car (run 'control  table))))
     (format #t "  ~a~%" label)
     (format #t "    pump alone            ~8,2f~%" alone)
     (format #t "    pump + recharge       ~8,2f   (recharged ~,2f)~%" (car restored) (cdr restored))
     (format #t "    pump + unrelated      ~8,2f~%~%" control)

     (check (format #f "~a: the limit holds pumping below demand on its own" label)
            (< alone 999.0))
     (check (format #f "~a: a RESTORE of the limited spec relieves it" label)
            (> (car restored) (+ alone 0.5)))
     (check (format #f "~a: the plan actually runs the restoring process" label)
            (> (cdr restored) 0.0))
     ;; The control is what makes the result mean something: an equally cheap
     ;; process producing a good the limit does not cover must change nothing.
     ;; Without it, "more activity available" would explain the relief just as
     ;; well as "restore nets".
     (check (format #f "~a: an unrelated cheap process relieves NOTHING" label)
            (< (abs (- control alone)) 0.5))))
 '(container spec)
 '("container fragility (a watershed, via contained-in)"
   "per-spec rate fragility (what a bioregion declares)"))

;;; ── the COMMONS: does a pooled budget feel a restore made by one drawer? ────
;;;
;;; playnet.typ §"Shared budgets and possibility-tension": an agent drawn on by
;;; many scopes has ONE pooled budget, and "every consume or use event from any
;;; scope is debited against this one shared stock". If debits pool but credits
;;; do not, the pool is a ratchet — one farm's recharge would relieve only
;;; itself, and no scope could ever repair the commons for the others.
;;;
;;; Two farms under one shed. Only farm-a can recharge. If the pool is
;;; symmetric, farm-a's recharge lifts the barrier BOTH farms are held by.

(define wprofile (list 80.0 120.0 0.5 50.0))

(define (commons-run recharge?)
  (set-templates! (compile-recipe
         (append (list (rp "pump" "Pump"))
                 (if recharge? (list (rp "recharge" "Recharge")) '()))
         (append (list (out "o1" "crop" 1.0 "pump") (wrk "o2" 0.01 "pump")
                       (in "o3" "water" 1.0 "pump"))
                 (if recharge?
                     (list (out "r1" "water" 1.0 "recharge") (wrk "r2" 0.01 "recharge"))
                     '()))))
  (ingest-located!
   (map (lambda (p) (er (string-append "m-" p) "water" #f #:place p #:qty 0.0 #:unit "m3"))
        '("farm-a" "farm-b"))
   '()
   (list (place* "shed" #:name "the watershed")
         (place* "farm-a" #:name "farm-a" #:parent "shed")
         (place* "farm-b" #:name "farm-b" #:parent "shed"))
   #:periods '(0) #:raws '("water")
   #:eco-spec-frag (list (frag-within "shed" '("water") wprofile))
   #:demand (map (lambda (p) (cons (lg "crop" (cell p 0)) 1000.0)) '("farm-a" "farm-b")))
  (for-each (lambda (p) (hash-set! *A* (cell p 0) 1000000.0)) '("farm-a" "farm-b"))
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values
                      (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))))
        (list (V "p|pump|farm-a@0") (V "p|pump|farm-b@0")
              (V "p|recharge|farm-a@0"))))))

(format #t "  pooled budget under one shed (two farms, only farm-a may recharge)~%")
(let* ((plain (commons-run #f))
       (fixed (commons-run #t))
       (tot   (lambda (r) (+ (car r) (cadr r)))))
  (format #t "    no recharge       pump a ~,2f  b ~,2f   total ~,2f~%"
          (car plain) (cadr plain) (tot plain))
  (format #t "    farm-a recharges  pump a ~,2f  b ~,2f   total ~,2f  (recharged ~,2f)~%~%"
          (car fixed) (cadr fixed) (tot fixed) (caddr fixed))

  (check "a restore inside the shed relieves the POOLED budget"
         (> (tot fixed) (+ (tot plain) 0.5)))
  (check "the plan runs the restoring process"
         (> (caddr fixed) 0.0))
  ;; The property that makes it a commons rather than a private allowance:
  ;; farm-b never touched the recharge, and is freed by it anyway.
  (check "farm-b, which cannot recharge, is freed by farm-a's repair"
         (> (cadr fixed) (+ (cadr plain) 0.5))))

;; Bioregion fragilities are per-spec, so that table is the one a shed-placed
;; scope inherits — and it is also the better-behaved of the two here: a
;; per-period rate boundary nets locally, so recharge comes out roughly matched
;; to the draw instead of overshooting across a horizon roll-up.
(let* ((spec-restored (run 'recharge 'spec))
       (ratio (/ (cdr spec-restored) (max 1e-9 (car spec-restored)))))
  (format #t "  recharge : pumping under the per-spec boundary = ~,2f~%~%" ratio)
  (check "per-spec restore is matched to draw, not an unbounded overshoot"
         (< ratio 10.0)))

(format #t "~a passed, ~a failed~%~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
