;;; test-robust-forwards-world.scm — a scenario ingests the same world as a solve
;;;
;;; `plan-from-records` sends any scope carrying scenarios down the robust branch,
;;; and every bioregion-placed scope carries them (Berlin, Bay Area, Doon,
;;; Cascadia). So anything that describes the WORLD has to survive that branch —
;;; and for a long time two things did not: #:manners and #:arc-table were absent
;;; from the robust keyword list, so for every shed the mode vocabulary reached
;;; nothing and travel time fell back to rate×haversine no matter what the routing
;;; layer had learned. Nothing failed; the world was simply quieter.
;;;
;;; The fix was structural — the robust layers forward their whole keyword list
;;; verbatim, and engine/robust.scm's `%world-keywords` is the single place that says
;;; which of those keywords `ingest-records!` understands. This test is the guard
;;; on that: it asserts the property (a robust solve ingests the world) rather
;;; than any one keyword, so the next option added to `ingest-records!` and
;;; forgotten in `%world-keywords` is caught here.
;;;
;;; Run:  guile --no-auto-compile -q -L module \
;;;         tests/solve/test-robust-forwards-world.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve robust) (playnet solve plan) (playnet solve world)
             (playnet vf schemas) (playnet vf beyond scenario)
             (playnet knowledge dsl shorthand)
             ((playnet knowledge recipes transport) #:select (mode-recipe)))
;; engine/robust.scm arrives with the engine — (playnet solve engine) loads it into
;; itself and exports its names, so the load that stood here was a second copy
;; of the same text into this module (retired with the engine-as-module arc).

(define *pass* 0) (define *fail* 0)
(define (check label ok)
  (if ok (set! *pass* (+ *pass* 1)) (set! *fail* (+ *fail* 1)))
  (format #t "  [~a] ~a~%" (if ok "✓" "✗") label))

;; ── the smallest world that still has every channel in it ───────────────────
(define specs (list (make-resource-specification #:id "grain" #:name "Grain"
                                                 #:resource-classified-as '()
                                                 #:default-unit-of-resource "kg")))
(define agents (list (person* "ann" #:name "Ann" #:place "A")))
(define spatials (list (place* "A" #:name "A")
                       (place* "B" #:name "B" #:lon 0.18)))
(define resources (list (er "r1" "grain" "ann" #:name "grain" #:place "A" #:qty 100.0 #:unit "kg")))
(define procs (list (rp* "p" "Make")))
(define flows (list (out* "f1" "grain" 1.0 "p")))

;; a travel mode is one of the scope's recipes, and reaches the solve with them
(define UBAHN (mode-recipe "ubahn" #:skill "transit-access" #:pace 0.05 #:manner "multimodal"
                           #:uses '(("spec-u" . 0.05))))
(define MANNERS '((pace . (("multimodal" . 0.05)))))
(define ARC-TABLE '(("A|B|bus" . 0.25)))
(define SCEN (list (make-planning-scenario "normal" #f 1.0 '() #f)))

(define (solve-with . opts)
  (apply plan-from-records resources agents spatials (cons (car UBAHN) procs) (append (cadr UBAHN) flows)
         #:demand '(("grain#B@0" . 10.0)) #:movable '("grain")
         #:manners MANNERS #:arc-table ARC-TABLE
         opts))

;; ── 1. deterministic and robust must land the same world in the engine ──────
(format #t "~%── the same world, both branches ──~%")
(solve-with)                                     ; no scenarios ⇒ deterministic
(define det (list (length *mode-recipes*) (length *manner-pace*)
                  *material-manner* *commute-manner*
                  (hash-ref *arc-hours* "A|B|bus" #f)))
(solve-with #:scenarios SCEN)                    ; scenarios ⇒ robust branch
(define rob (list (length *mode-recipes*) (length *manner-pace*)
                  *material-manner* *commute-manner*
                  (hash-ref *arc-hours* "A|B|bus" #f)))
(format #t "  deterministic: modes ~a · paces ~a · material ~s · commute ~s · arc ~a~%"
        (first det) (second det) (third det) (fourth det) (fifth det))
(format #t "  robust:        modes ~a · paces ~a · material ~s · commute ~s · arc ~a~%"
        (first rob) (second rob) (third rob) (fourth rob) (fifth rob))
(check "a robust solve ingests the same movement vocabulary as a plain one"
       (equal? det rob))
(check "the mode recipes survive the robust branch"    (= 1 (length *mode-recipes*)))
(check "the arc table survives the robust branch"      (equal? 0.25 (hash-ref *arc-hours* "A|B|bus" #f)))

;; ── 2. the world list stays honest against ingest-records! ──────────────────
;; %world-keywords is a hand-written list; what keeps it true is that every
;; keyword in it is one ingest-records! actually accepts. A stale entry would be
;; forwarded into an error the first time a caller passed it.
(format #t "~%── every world keyword is one ingest-records! accepts ──~%")
;; Ask only "is this keyword RECOGNISED" — a bad value for a real keyword raises
;; something else entirely, and #:periods '() is exactly that (it needs at least
;; one period). So the probe looks for the unknown-keyword error specifically.
(define (unknown-keyword? kw)
  (catch #t
    (lambda () (apply ingest-records! '() '() '() '() '() (list kw '())) #f)
    (lambda (key . args)
      (and (memq key '(keyword-argument-error wrong-type-arg))
           (any (lambda (a) (and (string? a) (string-contains a "keyword"))) args)))))
(define rejected (filter unknown-keyword? %world-keywords))
(format #t "  ~a world keywords, ~a rejected by ingest-records!~%"
        (length %world-keywords) (length rejected))
(when (pair? rejected) (format #t "  rejected: ~s~%" rejected))
(check "no world keyword is unknown to ingest-records!" (null? rejected))
(check "the world covers the movement channels this fix was about"
       (every (lambda (kw) (memq kw %world-keywords)) '(#:manners #:arc-table #:arc-topology?)))

(format #t "~%  ~a a scenario is the same world under different weather — so the robust~%    branch forwards all of it, and this test fails if one goes missing again.~%~%"
        (if (= *fail* 0) "✓" "✗"))
(when (> *fail* 0) (exit 1))
