;;; org.scm — Org management and inner REPL for meta-org
;;; Provides org record type, base bindings, and the two-tier REPL inner loop.

(define-module (metaorg org)
  #:use-module (metaorg play)
  #:use-module (ice-9 match)
  #:use-module (ice-9 pretty-print)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (make-org
            org?
            org-name
            org-env
            update-org-env!
            org-bindings
            org-history
            enter!
            list-orgs
            default-base-bindings))

;;; ── Org record type ────────────────────────────────────────────────────────

(define-record-type <org>
  (%make-org name env)
  org?
  (name org-name)
  (env org-env set-org-env!))

;;; ── Org registry ───────────────────────────────────────────────────────────

(define *orgs* '())

(define (register-org! org)
  (set! *orgs* (cons org *orgs*)))

(define (list-orgs)
  (if (null? *orgs*)
      (display "  (no orgs created yet)\n")
      (for-each (lambda (org)
                  (format #t "  ~a\n" (org-name org)))
                (reverse *orgs*))))

;;; ── Default base bindings ──────────────────────────────────────────────────

(define default-base-bindings
  `(;; Arithmetic
    (+              . ,+)
    (-              . ,-)
    (*              . ,*)
    (/              . ,/)
    (>              . ,>)
    (<              . ,<)
    (=              . ,=)
    (>=             . ,>=)
    (<=             . ,<=)
    (abs            . ,abs)
    (max            . ,max)
    (min            . ,min)
    (modulo         . ,modulo)
    (remainder      . ,remainder)
    (expt           . ,expt)
    ;; Boolean / logic
    (not            . ,not)
    (equal?         . ,equal?)
    (eq?            . ,eq?)
    ;; Pairs / lists
    (cons           . ,cons)
    (car            . ,car)
    (cdr            . ,cdr)
    (list           . ,list)
    (append         . ,append)
    (reverse        . ,reverse)
    (length         . ,length)
    (map            . ,map)
    (filter         . ,filter)
    (for-each       . ,for-each)
    (fold           . ,fold)
    (assoc          . ,assoc)
    (member         . ,member)
    (apply          . ,apply)
    ;; Predicates
    (null?          . ,null?)
    (pair?          . ,pair?)
    (list?          . ,list?)
    (number?        . ,number?)
    (string?        . ,string?)
    (symbol?        . ,symbol?)
    (procedure?     . ,procedure?)
    (boolean?       . ,boolean?)
    (zero?          . ,zero?)
    (positive?      . ,positive?)
    (negative?      . ,negative?)
    (even?          . ,even?)
    (odd?           . ,odd?)
    ;; Strings
    (string-append  . ,string-append)
    (string-length  . ,string-length)
    (substring      . ,substring)
    (string->symbol . ,string->symbol)
    (symbol->string . ,symbol->string)
    (string->number . ,string->number)
    (number->string . ,number->string)
    ;; Math (extended)
    (sqrt           . ,sqrt)
    (floor          . ,floor)
    (ceiling        . ,ceiling)
    (round          . ,round)
    ;; Strings (extended)
    (string=?       . ,string=?)
    (string<?       . ,string<?)
    (string>?       . ,string>?)
    (string-ref     . ,string-ref)
    ;; Pairs (extended)
    (cadr           . ,cadr)
    (caddr          . ,caddr)
    (cddr           . ,cddr)
    (caar           . ,caar)
    (cdar           . ,cdar)
    ;; Predicates (extended)
    (eqv?           . ,eqv?)
    (char?          . ,char?)
    ;; I/O
    (display        . ,display)
    (newline        . ,newline)
    (write          . ,write)
    (format         . ,format)
    ;; Convenience
    (void           . ,(lambda () (if #f #f)))
    ;; Environment introspection
    (env-history    . ,env-history)
    (env-bindings   . ,env-bindings)))

;;; ── Org creation ───────────────────────────────────────────────────────────

(define* (make-org name #:optional (bindings default-base-bindings))
  (let ((org (%make-org name (make-initial-env bindings))))
    (register-org! org)
    org))

;;; ── Org accessors ──────────────────────────────────────────────────────────

(define (update-org-env! org env)
  (set-org-env! org env))

(define (org-bindings org)
  (env-bindings (org-env org)))

(define (org-history org)
  (env-history (org-env org)))

;;; ── Last-result tracking ───────────────────────────────────────────────────

(define *1 (if #f #f))
(define *2 (if #f #f))
(define *3 (if #f #f))

(define (shift-results! val)
  (set! *3 *2)
  (set! *2 *1)
  (set! *1 val))

;;; ── Inner REPL helpers ─────────────────────────────────────────────────────

(define (current-identity env)
  (or (expressor-name (env-expressor env)) '?))

(define (inner-prompt env)
  (string-append "play[" (symbol->string (current-identity env)) "]> "))

(define (comma-command? raw)
  "If RAW is a comma-command (read as unquote), return the command symbol."
  (match raw
    (('unquote (? symbol? cmd)) cmd)
    (_ #f)))

(define (handle-comma-command cmd env)
  "Handle ,command in the inner REPL. CMD is a symbol. Returns #t if handled."
  (case cmd
    ((env)
     (pretty-print (env-bindings env))
     #t)
    ((history)
     (for-each (lambda (entry)
                 (format #t "  v~a [~a]: ~s\n"
                         (history-version entry)
                         (or (expressor-name (history-expressor entry)) '?)
                         (history-expr entry)))
               (reverse (env-history env)))
     #t)
    ((expressors)
     (evaluate '(show-expressors) env)
     #t)
    ((help)
     (display "  ,env         -- show current bindings\n")
     (display "  ,history     -- show environment history\n")
     (display "  ,expressors  -- show registered expressors\n")
     (display "  ,help        -- show this help\n")
     (display "  (exit!)      -- return to outer REPL\n")
     #t)
    (else #f)))

(define (format-error key args)
  "Format an error for display."
  (format #t "error: ~a" key)
  (for-each (lambda (a) (format #t " ~a" a)) args)
  (newline))

;;; ── Inner REPL ─────────────────────────────────────────────────────────────

(define (enter! org)
  "Drop into the inner REPL for ORG. Returns when the user types (exit!) or Ctrl-D."
  (let ((name (org-name org)))
    (format #t "Entering org '~a'. Type (exit!) to return.\n\n" name)
    (let loop ((env (org-env org)))
      (catch #t
        (lambda ()
          (display (inner-prompt env))
          (force-output)
          (let ((raw (read)))
            (cond
             ;; EOF (Ctrl-D)
             ((eof-object? raw)
              (newline)
              (set-org-env! org env)
              (format #t "Leaving org '~a'.\n" name))

             ;; (exit!) — return to outer REPL
             ((equal? raw '(exit!))
              (set-org-env! org env)
              (format #t "Leaving org '~a'.\n" name))

             ;; (quit) — also exit
             ((equal? raw '(quit))
              (set-org-env! org env)
              (format #t "Leaving org '~a'.\n" name))

             ;; Comma-commands (,env, ,history, etc.)
             ((comma-command? raw)
              => (lambda (cmd)
                   (if (handle-comma-command cmd env)
                       (loop env)
                       (begin
                         (format #t "Unknown command: ,~a\n" cmd)
                         (loop env)))))

             ;; Normal expression evaluation
             (else
              (let ((result (evaluate raw env)))
                (cond
                 ((env? result)
                  (loop result))
                 (else
                  (shift-results! result)
                  (display "=> ")
                  (pretty-print result)
                  (loop env))))))))
        (lambda (key . args)
          (format-error key args)
          (loop env))))))
