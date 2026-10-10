;;; test-units-fallback.scm — unit conversion where GNU units is absent, and where
;;; it is present (module/playnet/utils/units.scm).
;;;
;;; The gateway's box has no GNU units. A conversion used to ask the operating
;;; system for it every time: a failed fork and a line on stderr per conversion,
;;; sixty at every boot, burying the log's real warnings. The program is looked
;;; for once now, on first use, and the answer is kept.
;;;
;;; What this pins:
;;;
;;;   • with no `units` on PATH it is not available, it is looked for once, and a
;;;     conversion through it answers #f without trying;
;;;   • every one of the module's known units still converts to its base, from the
;;;     curated tables alone, bar the two CO2e spellings that no table or GNU units
;;;     knows and so pass through unchanged either way (the audit that found the box
;;;     fine covered all 92);
;;;   • the tables agree with GNU units to better than 1e-4 on the values that
;;;     differ at all (month and year are the widest, at about 2e-5);
;;;   • a unit outside the tables passes through unchanged, as it always did;
;;;   • with a `units` on PATH it is found, used, and its answers are kept.
;;;
;;; Run from project root:
;;;   tools/test/own-ccache.sh guile --no-auto-compile -q -L module tests/utils/test-units-fallback.scm

;; PATH is read when the module first needs it, so it is emptied BEFORE anything
;; loads: this process starts with no GNU units whatever the machine has.
(setenv "PATH" "")

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)

(add-to-load-path "module")
(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness)
             (playnet utils units)
             (srfi srfi-1)
             (ice-9 format))

(define state (@@ (playnet utils units) %units-state))
(define categories (@@ (playnet utils units) *substance-categories*))
(define table (@@ (playnet utils units) *unit->base*))

(display "\n── No GNU units on PATH ──\n")
(check "it is not available" (units-available?) #f)
(check "it was looked for, once, and the answer is kept" (hash-ref state 'program 'unknown) #f)
(check "a conversion through it answers #f" (units-convert "kg" "g") #f)

(display "\n── Every unit the module knows converts from the tables ──\n")
(define all-units
  (append-map (lambda (c) (map (lambda (p) (symbol->string (car p))) (cdr c))) categories))
(check "the audit's count: ninety-two known units" (length all-units) 92)
;; Two category members are in no table: co2e and CO2e pass through unchanged. GNU units
;; does not know them either (the audit compared every unit both ways), so they behave
;; the same on the box and off it. A unit joining them would show up here.
(define unknown (remove unit-known? all-units))
(check "all but the two CO2e spellings are known without GNU units"
       (sort unknown string<?) '("CO2e" "co2e"))
(define (positive? x) (and (number? x) (> x 0)))
(check "each converts to a positive factor of its base"
       (remove (lambda (u) (positive? (convert-unit 1 u))) all-units) '())

(display "\n── The tables agree with GNU units where they differ ──\n")
(define (near? a b) (< (abs (/ (- a b) b)) 1e-4))
(for-each (lambda (u gnu)
            (check (format #f "~a: the table is within 1e-4 of GNU units (~a)" u gnu)
                   (near? (convert-unit 1 u) gnu) #t))
          '("lb" "acre" "gal" "month" "year" "ton" "oz" "min")
          '(0.45359237 0.40468564 3.7854118 730.4844 8765.8128 907.18474 0.028349523 0.016666667))

(display "\n── A unit outside the tables ──\n")
(check "passes through unchanged" (convert-unit 3 "furlong") 3)

(display "\n── Two units of one substance, from the curated tables alone ──\n")
(define (near? a b) (and a b (< (abs (- a b)) 1e-4)))
(check "500 g is half a kilogram"                      (near? (unit-to "g" "kg") 0.001) #t)
(check "a pound in grams, through the base"            (near? (unit-to "lb" "g") 453.592) #t)
(check "a minute in hours"                             (near? (unit-to "minutes" %effort-unit) (/ 1.0 60)) #t)
(check "hour and hours are one unit"                   (near? (unit-to %effort-unit %effort-unit) 1.0) #t)
(check "h reads as an hour"                            (near? (unit-to "h" %effort-unit) 1.0) #t)
(check "a mass and a volume do not convert"            (unit-to "kg" "litre") #f)
(check "a name the tables do not know does not convert" (unit-to "loaf" "kg") #f)
(check "a rate is no substance"                        (unit-to "hours/week" %effort-unit) #f)
(check "a measurable unit names its substance"         (unit-measurable-substance "kg") 'mass)
(check "…a time unit too"                              (unit-measurable-substance "min") 'time)
(check "…a count and a name are measurable in nothing" (unit-measurable-substance "loaf") #f)
(check "…and a rate is not either"                     (unit-measurable-substance "hours/week") #f)

(display "\n── With a units on PATH ──\n")
(define dir (string-append (or (getenv "TMPDIR") "/tmp") "/units-fallback-" (number->string (getpid))))
(mkdir dir)
(define fake (string-append dir "/units"))
(call-with-output-file fake
  (lambda (p) (display "#!/bin/sh\necho 2.5\n" p)))
(chmod fake #o755)
(setenv "PATH" dir)
(hash-remove! state 'program)             ; the answer was "none"; PATH has changed
(check "it is found" (units-available?) #t)
(check "…and used" (units-convert "x-a" "x-b") 2.5)
(delete-file fake) (rmdir dir)
(check "…and its answer is kept after it goes" (units-convert "x-a" "x-b") 2.5)

(test-summary!)
