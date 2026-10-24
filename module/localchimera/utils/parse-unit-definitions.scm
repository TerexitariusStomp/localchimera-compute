;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; parse-unit-definitions.scm — Build-time parser for GNU units database
;;;
;;; SUPERSEDED by (localchimera utils units) which shells out to `units --terse`
;;; for runtime conversion. This file is retained for reference only.
;;;
;;; Original purpose: reads definitions.units (GNU Units format, ~9000 lines,
;;; GPLv3+), resolves every unit definition to its SI base dimension vector,
;;; maps dimension vectors to substance categories for metabolic accounting,
;;; and emits units-data.scm as a Guile-loadable module.
;;;
;;; Not needed at runtime — units.scm calls GNU Units directly.
;;;
;;; Usage:
;;;   guile parse-unit-definitions.scm [definitions.units] [units-data.scm]

(use-modules (srfi srfi-1) (srfi srfi-9) (ice-9 format)
             (ice-9 rdelim))   ; read-line, for the definitions.units scan

;; vector-map for the dimension arithmetic below, from R6RS rather than
;; SRFI-43: the SRFI-43 procedure of the same name passes the element INDEX
;; as its first argument, so (vector-map + a b) there computes a_i + b_i + i
;; and every dimension vector comes out wrong without erroring.
(use-modules ((rnrs base) #:select (vector-map)))

;;; ===========================================================================
;;; Dimension vectors — 7 SI bases: #(kg m s A K mol cd)
;;; ===========================================================================

(define (dim-make kg m s A K mol cd)
  (vector kg m s A K mol cd))

(define dim-identity #(0 0 0 0 0 0 0))

(define (dim-mul a b) (vector-map + a b))
(define (dim-div a b) (vector-map - a b))
(define (dim-pow d n) (vector-map (lambda (x) (* x n)) d))
(define (dim-key d) (vector->list d))

;;; Substance categories — named groups of dimension vectors

(define *substance-dims*
  (list
    (cons (dim-key (dim-make 1 0 0 0 0 0 0)) 'mass)
    (cons (dim-key (dim-make 0 3 0 0 0 0 0)) 'volume)
    (cons (dim-key (dim-make 0 2 0 0 0 0 0)) 'land)
    (cons (dim-key (dim-make 1 2 -2 0 0 0 0)) 'energy)
    (cons (dim-key (dim-make 0 0 1 0 0 0 0)) 'time)))

(define (dim->substance d)
  (let ((p (assoc (dim-key d) *substance-dims*)))
    (if p (cdr p) 'other)))

;;; ===========================================================================
;;; Parser state
;;; ===========================================================================

(define *raw* (make-hash-table 4000))    ;; name-string -> definition-string
(define *resolved* (make-hash-table 4000)) ;; name-symbol -> (dim . factor)

;;; ===========================================================================
;;; Phase 1 — Parse definitions.units
;;; ===========================================================================

(define (strip-comment line)
  (let ((i (string-index line #\#)))
    (if i (substring line 0 i) line)))

(define (parse-line line)
  (let* ((clean (string-trim-both (strip-comment line)))
         (i (string-index clean #\space)))
    (if (or (string=? clean "")
            (string-prefix? "!" clean)
            (string-prefix? "test" clean)
            (not i))
        #f
        (let ((name (substring clean 0 i))
              (def (string-trim-both (substring clean i))))
          (if (or (string=? name "") (string=? def ""))
              #f
              (cons name def))))))

(define (parse-units-file path)
  (with-input-from-file path
    (lambda ()
      (let loop ((line (read-line)) (pending #f))
        (cond
          ((eof-object? line)
           (when pending
             (let ((p (parse-line pending)))
               (when p (hash-set! *raw* (car p) (cdr p))))))
          (else
           (let* ((stripped (string-trim-right line #\return))
                  (cont? (and (> (string-length stripped) 0)
                              (char=? (string-ref stripped
                                       (- (string-length stripped) 1))
                                      #\\))))
             (if cont?
                 (let ((base (or pending ""))
                       (rest (substring stripped 0
                               (- (string-length stripped) 1))))
                   (loop (read-line) (string-append base " " rest)))
                 (let ((combined (if pending
                                    (string-append pending " " stripped)
                                    stripped)))
                   (let ((p (parse-line combined)))
                     (when p
                       (hash-set! *raw* (car p) (cdr p))))
                   (loop (read-line) #f))))))))))

;;; ===========================================================================
;;; Phase 2 — Resolve definitions to SI dimensions
;;; ===========================================================================

;; SI base units
(define *si-bases*
  '(("kg"  . #(1 0 0 0 0 0 0))
    ("m"   . #(0 1 0 0 0 0 0))
    ("s"   . #(0 0 1 0 0 0 0))
    ("A"   . #(0 0 0 1 0 0 0))
    ("K"   . #(0 0 0 0 1 0 0))
    ("mol" . #(0 0 0 0 0 1 0))
    ("cd"  . #(0 0 0 0 0 0 1))
    ("bit" . #(0 0 0 0 0 0 0))
    ("$"   . #(0 0 0 0 0 0 0))
    ("US$" . #(0 0 0 0 0 0 0))))

(define (si-base-dim name)
  (let ((p (assoc name *si-bases*)))
    (and p (cdr p))))

(define (resolve-unit name)
  (let ((sym (string->symbol name)))
    (cond
      ((hash-ref *resolved* sym #f) => identity)
      ((si-base-dim name)
       => (lambda (dim)
            (let ((r (cons dim 1)))
              (hash-set! *resolved* sym r)
              r)))
      (else
       (let ((def (hash-ref *raw* name #f)))
         (cond
           ((not def) #f)
           ((string=? def "!")
            (let ((dim (or (si-base-dim name) dim-identity)))
              (let ((r (cons dim 1)))
                (hash-set! *resolved* sym r)
                r)))
           ((or (string=? def "dimensionless")
                (string-prefix? "!dimensionless" def))
            (let ((r (cons dim-identity 1)))
              (hash-set! *resolved* sym r)
              r))
           (else
            (let ((r (resolve-expr def)))
              (when r (hash-set! *resolved* sym r))
              r))))))))

;;; Expression resolver — simplified recursive approach
;;; Handles: number, number|number, unit-name, A B, A/B, A^n

(define (tokenize str)
  (let ((clean (string-trim-both str)))
    (if (string=? clean "") '()
        (let loop ((cs (string->list clean)) (acc '()) (cur ""))
          (cond
           ((null? cs)
            (reverse (if (string=? cur "") acc (cons cur acc))))
           ((char-whitespace? (car cs))
            (loop (cdr cs)
                  (if (string=? cur "") acc (cons cur acc))
                  ""))
           (else
            (loop (cdr cs) acc (string-append cur (string (car cs))))))))))

(define (resolve-expr str)
  (catch #t
    (lambda ()
      (let ((tokens (tokenize str)))
        (if (null? tokens) (cons dim-identity 1)
            (resolve-tokens tokens))))
    (lambda _ #f)))

(define (resolve-tokens tokens)
  ;; Explicit operator precedence: walk left-to-right, accumulate dim*factor
  ;; Operators: implicit mul (space-separated), /, ^
  ;; Strategy: split on / first (highest precedence after ^), then *
  (let loop ((ts tokens) (dim dim-identity) (fact 1) (op 'mul))
    (if (null? ts)
        (cons dim fact)
        (let ((tok (car ts)))
          (cond
           ((string=? tok "/")
            (loop (cdr ts) dim fact 'div))
           ((string=? tok "*")
            (loop (cdr ts) dim fact 'mul))
           (else
            (let ((atom (resolve-atom tok (cdr ts))))
              (if (not atom)
                  (cons dim fact)
                  (let ((a-dim (car atom))
                        (a-fact (cdr atom)))
                    (cond
                     ((eq? op 'div)
                      (loop (cdr ts)
                            (dim-div dim a-dim)
                            (if (and (number? fact) (number? a-fact) (not (zero? a-fact)))
                                (/ fact a-fact) 1)
                            'mul))
                     (else ;; mul or first
                      (loop (cdr ts)
                            (dim-mul dim a-dim)
                            (if (and (number? fact) (number? a-fact))
                                (* fact a-fact) 1)
                            'mul))))))))))))

(define (resolve-atom tok rest)
  (cond
   ;; Fraction: a|b
   ((string-contains tok "|")
    (let* ((parts (string-split tok #\|))
           (num (and (= (length parts) 2) (string->number (list-ref parts 0))))
           (den (and (= (length parts) 2) (string->number (list-ref parts 1)))))
      (if (and num den (not (zero? den)))
          (cons dim-identity (/ num den))
          #f)))
   ;; Number (possibly with leading minus)
   ((and (> (string-length tok) 0)
         (or (char-numeric? (string-ref tok 0))
             (and (eq? (string-ref tok 0) #\-)
                  (> (string-length tok) 1)
                  (char-numeric? (string-ref tok 1)))))
    (let ((n (string->number tok)))
      (if n (cons dim-identity n) #f)))
   ;; Unit with exponent: tok ^ n
   ((and (pair? rest)
         (string=? (car rest) "^")
         (pair? (cdr rest)))
    (let ((base (resolve-unit tok))
          (exp (string->number (cadr rest))))
      (if (and base exp)
          (cons (dim-pow (car base) exp)
                (if (number? (cdr base)) (expt (cdr base) exp) 1))
          #f)))
   ;; Plain unit
   (else (resolve-unit tok))))

;;; ===========================================================================
;;; Phase 3 — Emit units-data.scm
;;; ===========================================================================

(define *substance-base-units*
  '((mass . kg)
    (volume . l)
    (energy . MJ)
    (time . hours)
    (land . ha)
    (emission . tCO2e)
    (water . m3)
    (nitrogen . kg-N)
    (phosphorus . kg-P)
    (dimensionless . each)
    (other . other)))

(define (substance-base sym)
  (or (assq-ref *substance-base-units* sym) 'other))

(define (base-factor substance raw-factor)
  (case substance
    ((mass)     raw-factor)
    ((volume)   (* raw-factor 1e3))       ;; m³ → l
    ((land)     (* raw-factor 1e-4))      ;; m² → ha
    ((energy)   (* raw-factor 1e-6))      ;; J → MJ
    ((time)     (/ raw-factor 3600))      ;; s → hours
    (else       raw-factor)))

(define (valid-factor? f)
  (and (number? f)
       (positive? f)
       (< f 1e30)
       (> f 1e-30)
       (finite? f)))

(define (emit output-path)
  (with-output-to-file output-path
    (lambda ()
      (display ";;; units-data.scm — Auto-generated from GNU units definitions.units\n")
      (display ";;; DO NOT EDIT — regenerate: guile parse-unit-definitions.scm\n\n")
      (display "(define-module (localchimera utils units-data)\n")
      (display "  #:export (*substance-bases* *unit-table*))\n\n")

      (display "(define *substance-bases*\n  '(\n")
      (for-each
        (lambda (p)
          (format #t "    (~a . ~a)~%" (car p) (cdr p)))
        *substance-base-units*)
      (display "))\n\n")

      (display ";; (unit-name-string substance base-unit factor-to-base)\n")
      (display "(define *unit-table*\n  '(\n")
      (let ((count 0))
        (for-each
          (lambda (name)
            (let* ((sym (string->symbol name))
                   (r (hash-ref *resolved* sym #f)))
              (when r
                (let* ((dim (car r))
                       (factor (cdr r))
                       (substance (dim->substance dim))
                       (base (substance-base substance))
                       (bf (and (number? factor) (base-factor substance factor))))
                  (when (and bf (valid-factor? bf)
                             (not (eq? substance 'other)))
                    (format #t "    (~s ~a ~s ~e)~%"
                            name substance base bf)
                    (set! count (+ count 1)))))))
          (sort (hash-map->list (lambda (k v) k) *raw*) string<?))
        (display "))\n")
        (format #t ";; ~a units~%" count)))))

;;; ===========================================================================
;;; Main
;;; ===========================================================================

(define (main args)
  (let* ((defs-path (if (> (length args) 1) (cadr args) "definitions.units"))
         (out-path  (if (> (length args) 2) (caddr args) "units-data.scm")))
    (format #t "Parsing ~a...~%" defs-path)
    (parse-units-file defs-path)
    (format #t "  ~a raw definitions~%"
            (hash-count (lambda _ #t) *raw*))
    (format #t "Resolving...~%")
    (for-each resolve-unit
               (sort (hash-map->list (lambda (k v) k) *raw*) string<?))
    (format #t "  ~a resolved~%"
            (hash-count (lambda _ #t) *resolved*))
    (format #t "Writing ~a...~%" out-path)
    (emit out-path)
    (format #t "Done.~%")))

(main (command-line))
