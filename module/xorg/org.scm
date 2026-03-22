;;; org.scm — Org management and inner REPL for xorg (Goblins actor-based)
;;; Provides org record type, base bindings, and the two-tier REPL inner loop.

(define-module (xorg org)
  #:use-module (goblins)
  #:use-module (xorg gplay)
  #:use-module (ice-9 match)
  #:use-module (ice-9 pretty-print)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (make-org
            org?
            org-name
            org-vat
            org-ref
            org-bindings
            org-history
            enter!
            list-orgs
            default-base-bindings
            make-org-ai-agent))

;;; ── Org record type ────────────────────────────────────────────────────────

(define-record-type <org>
  (%make-org name vat ref)
  org?
  (name org-name)
  (vat  org-vat)
  (ref  org-ref))

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
    (void           . ,(lambda () (if #f #f)))))

;;; ── Org creation ───────────────────────────────────────────────────────────

(define* (make-org name #:optional (bindings default-base-bindings))
  (let* ((vat (spawn-vat))
         (ref (with-vat vat (make-initial-org bindings))))
    (let ((org (%make-org name vat ref)))
      (register-org! org)
      org)))

;;; ── Org accessors ──────────────────────────────────────────────────────────

(define (org-bindings org)
  (with-vat (org-vat org) ($ (org-ref org) 'bindings)))

(define (org-history org)
  (with-vat (org-vat org) ($ (org-ref org) 'history)))

;;; ── Last-result tracking ───────────────────────────────────────────────────

(define *1 (if #f #f))
(define *2 (if #f #f))
(define *3 (if #f #f))

(define (shift-results! val)
  (set! *3 *2)
  (set! *2 *1)
  (set! *1 val))

;;; ── Inner REPL helpers ─────────────────────────────────────────────────────

(define (current-identity ref)
  (or ($ ref 'expressor-name ($ ref 'current-expressor)) '?))

(define (inner-prompt ref)
  (string-append "play[" (symbol->string (current-identity ref)) "]> "))

(define (comma-command? raw)
  "If RAW is a comma-command (read as unquote), return the command symbol."
  (match raw
    (('unquote (? symbol? cmd)) cmd)
    (_ #f)))

(define (handle-comma-command cmd ref)
  "Handle ,command in the inner REPL. CMD is a symbol. Returns #t if handled."
  (case cmd
    ((env)
     (pretty-print ($ ref 'bindings))
     #t)
    ((history)
     (for-each (lambda (entry)
                 (format #t "  v~a [~a]: ~s\n"
                         (car entry)
                         (or ($ ref 'expressor-name (cadr entry)) '?)
                         (caddr entry)))
               (reverse ($ ref 'history)))
     #t)
    ((expressors)
     (evaluate '(show-expressors) ref '() ($ ref 'current-expressor))
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
  (let ((name (org-name org))
        (vat (org-vat org))
        (ref (org-ref org)))
    (format #t "Entering org '~a'. Type (exit!) to return.\n\n" name)
    (with-vat vat
      (let loop ()
        (catch #t
          (lambda ()
            (display (inner-prompt ref))
            (force-output)
            (let ((raw (read)))
              (cond
               ;; EOF (Ctrl-D)
               ((eof-object? raw)
                (newline)
                (format #t "Leaving org '~a'.\n" name))

               ;; (exit!) — return to outer REPL
               ((equal? raw '(exit!))
                (format #t "Leaving org '~a'.\n" name))

               ;; (quit) — also exit
               ((equal? raw '(quit))
                (format #t "Leaving org '~a'.\n" name))

               ;; Comma-commands (,env, ,history, etc.)
               ((comma-command? raw)
                => (lambda (cmd)
                     (if (handle-comma-command cmd ref)
                         (loop)
                         (begin
                           (format #t "Unknown command: ,~a\n" cmd)
                           (loop)))))

               ;; Normal expression evaluation
               (else
                (let ((result (evaluate raw ref '() ($ ref 'current-expressor))))
                  (unless (eq? result (if #f #f))
                    (shift-results! result)
                    (display "=> ")
                    (pretty-print result))
                  (loop))))))
          (lambda (key . args)
            (format-error key args)
            (loop)))))))

;;; ── AI Expressor ─────────────────────────────────────────────────────────

(define* (make-org-ai-agent org name key system-prompt #:key (model #f))
  "Create an AI expressor with config bindings in the org.
Returns the sealer — use with (as sealer ...) to act as this agent.

The system prompt and model are stored as org bindings (name:prompt,
name:model) that (ai ...) and (ai-eval ...) automatically pick up.
These bindings are visible, subject to the validator, and modifiable
by any authorized expressor.

  Usage:
    (define my-org (make-org \"test\"))
    (define ai-sealer
      (make-org-ai-agent my-org 'ai-gov \"key\" \"You govern wisely.\"))
    ;; Then inside the org:
    (as ai-sealer (ai-eval \"Create a proposal\"))
    ;; Inspect or change the AI:
    ai-gov:prompt                                   ;=> \"You govern wisely.\"
    (modify! 'ai-gov:prompt \"Be cautious.\")"
  (with-vat (org-vat org)
    (let* ((ref (org-ref org))
           (genesis-id ($ ref 'current-expressor))
           (sealer (evaluate `(defexpressor ',name ,key)
                             ref '() genesis-id))
           (ai-id ($ ref 'authenticate-sealer sealer))
           (prompt-sym (string->symbol
                        (string-append (symbol->string name) ":prompt")))
           (model-sym  (string->symbol
                        (string-append (symbol->string name) ":model"))))
      (evaluate `(modify! ',prompt-sym ,system-prompt) ref '() ai-id)
      (when model
        (evaluate `(modify! ',model-sym ,model) ref '() ai-id))
      sealer)))
