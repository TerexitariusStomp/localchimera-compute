;;; test-use-unit-register.scm — a non-time `use` effort, recorded rather than rumoured.
;;;
;;; A `use` states HOW MANY are engaged (resourceQuantity) and FOR HOW LONG
;;; (effortQuantity). Below compile-process the solver is unit-free — `mqty`
;;; takes a measure's number and drops its unit — so a wrong denomination still
;;; compiles, still solves, and is off by the length of a period.
;;;
;;; compile-process has diagnosed this for a long time, in a sentence naming the
;;; exact failure, behind PLANNER_UNIT_LINT=1 and printed to stderr. It reached
;;; only someone who already suspected a unit problem AND knew the variable's
;;; name. Two comms fixtures carried the defect for months: a publish drawing
;;; 1.0 "slot" against a channel capped in hours, on a process stating no
;;; duration, occupied that channel for a whole period, so reach saturated at
;;; 100/24 = 4.17 whatever the demand — which reads as an unmet want, not a unit
;;; bug, and was filed as a fixture expectation until 2026-08-13.
;;;
;;; WHY THIS FILE EXISTS SEPARATELY FROM tests/scope/test-use-unit-lint.scm.
;;;
;;; It used to be a necessity: the (playnet boot prelude) umbrella did not carry
;;; `compile-process` or `compile-recipe` at all — they lived only in
;;; planner/planner.scm, reached by primitive-load — so the file holding the
;;; use-unit invariant sat on the one path that could not run the compile step
;;; the register is filled by, and the invariant had to be split in two.
;;;
;;; That is no longer true. compile.scm is included by BOTH loaders now (see the
;;; note above the include in planner.scm: "Same text, both loaders"), and
;;; svc-good moved into it so the umbrella path can actually compile a `use`
;;; flow. `(use-modules (playnet boot prelude))` carries both procedures today.
;;;
;;; So the split is now a CHOICE, not a necessity, and the two halves still
;;; exercise genuinely different things:
;;;
;;;   test-use-unit-lint.scm  — needs the CATALOGUE (a spec counted in time,
;;;                             drawn with no duration). Umbrella path.
;;;   this file               — needs only the FLOW (a non-time effort unit).
;;;                             Monolith path, and keeps that path honest.
;;;
;;; Whoever owns this invariant may now merge them; nothing forces two files.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/solve/test-use-unit-register.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve compile)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define (gaps-for effort-measure)
  "The register's contents after compiling one `use` carrying EFFORT-MEASURE."
  (clear-use-unit-gaps!)
  (compile-recipe
   (list (rp "rp-probe" "Probe"))
   (list (out* "o" "spec-out" 1.0 "rp-probe" %count-unit)
         (make-recipe-flow #:id "u" #:action 'use #:resource-conforms-to "spec-chan" #:resource-quantity (make-measure 1.0 %count-unit)
                           #:effort-quantity effort-measure #:recipe-input-of "rp-probe")))
  (use-unit-gaps))

(format #t "~%── a non-time `use` effort is RECORDED, not merely printable ──~%")
(define slot-gaps  (gaps-for (make-measure 1.0 "slot")))
(define hour-gaps  (gaps-for (make-measure 1.0 %effort-unit)))
(define min-gaps   (gaps-for (make-measure 30.0 "minutes")))
(format #t "    effort 1.0 \"slot\"     → ~s~%" slot-gaps)
(format #t "    effort 1.0 \"hours\"    → ~s~%" hour-gaps)
(format #t "    effort 30 \"minutes\"   → ~s~%" min-gaps)

(check "a non-time effort lands in a register a caller can assert on"
       (equal? slot-gaps '(("rp-probe" "spec-chan" "slot"))))
(check "…and hours do not — the register is a work-list, not noise"
       (null? hour-gaps))
(check "…nor any other time unit the engine understands"
       (null? min-gaps))
(check "the register is resettable, so a sweep can scope itself"
       (begin (clear-use-unit-gaps!) (null? (use-unit-gaps))))

;; THE REGRESSION THIS EXISTS FOR: the shape the comms fixtures carried.
(format #t "~%── the shape that cost two fixtures months ──~%")
(let ((g (gaps-for (make-measure 1.0 "slot"))))
  (format #t "    a `use` drawn in \"slot\" against an hours-denominated cap: ~a entry~%"
          (length g))
  (check "the comms shape is reported the moment it is compiled"
         (= 1 (length g))))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — a gap you can query is a work-list;~%  a gap you can only print is a rumour.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
