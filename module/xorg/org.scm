;;; org.scm — Org management and inner REPL for xorg (Goblins actor-based)
;;;
;;; Three ways to create an org:
;;;   make-org          — explicit: you provide output-cap, validator, bindings
;;;   make-open-org     — open org with stdout and default-validator
;;;   make-governed-org — canonical cap-governed org with three governance domains

(define-module (xorg org)
  #:use-module (goblins)
  #:use-module (xorg gplay)
  #:use-module (xorg endorsement)
  #:use-module (xorg capabilities)
  #:use-module (ice-9 match)
  #:use-module (ice-9 pretty-print)
  #:use-module (ice-9 receive)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (make-org
            make-open-org
            make-governed-org
            org?
            org-name
            org-vat
            org-ref
            org-bindings
            org-history
            enter!
            list-orgs
            default-base-bindings))

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
    ;; I/O — wired per-org via ^output-port capability (see make-org)
    ;; Convenience
    (void           . ,(lambda () (if #f #f)))
    ;; Endorsement / capability governance
    (make-endorsement-authority . ,make-endorsement-authority)
    (endorse                    . ,endorse)
    (endorsed-with?             . ,endorsed-with?)
    (endorsed-value             . ,endorsed-value)
    (make-facet                 . ,make-facet)
    (make-faceted-validator     . ,make-faceted-validator)
    (make-attenuated-authority  . ,make-attenuated-authority)
    (name-prefix-predicate      . ,name-prefix-predicate)
    (name-set-predicate         . ,name-set-predicate)
    ;; Crypto — for expressor keypair generation
    (generate-key-pair          . ,generate-key-pair)))

;;; ── Org creation ───────────────────────────────────────────────────────────

(define (make-org name vat output-cap validator base-bindings)
  "Create an org. Must be called within (with-vat vat ...) context.
   output-cap: ^output-port actor ref — stored directly in ^org, not in bindings.
   IO primitives (display, write, newline, format) are delegated to output-cap
   at lookup time, not baked into bindings as closures."
  (let ((ref (make-initial-org base-bindings
                               #:validator validator
                               #:output-cap output-cap)))
    (let ((org (%make-org name vat ref)))
      (register-org! org)
      org)))

(define (make-open-org name)
  "Create an open org with default validator and stdout output.
   Everything is freely modifiable. Good for experimentation."
  (let ((vat (spawn-vat)))
    (with-vat vat
      (let ((out (spawn ^output-port (current-output-port))))
        (make-org name vat out default-validator default-base-bindings)))))

;;; ── Governed org factory ──────────────────────────────────────────────────

(define (make-governed-org name)
  "Create a capability-governed org.

   Returns (values org gov-seal infra-seal member-seal)

   Three governance domains:
   - gov-seal:    governs 'validator and 'rollback — constitutional amendments
   - infra-seal:  governs 'infra-* names — deployment, services, servers
   - member-seal: governs 'member-* names — expressors, roles, admissions

   Ungoverned names: freely modifiable by anyone.
   Governed names: require endorsed value (endorse value seal-actor).

   All sealers and validators are Goblins actor refs — fully serializable
   by Goblins persistence. No closure wrappers.

   Example:
     (define-values (org gov infra member) (make-governed-org \"my-org\"))
     (with-vat (org-vat org)
       (evaluate '(modify! 'infra-deploy (endorse deploy-cap infra))
                 (org-ref org) '() genesis-id))"
  (let ((vat (spawn-vat)))
    (with-vat vat
      (receive (seal-gov _unseal-gov sealed-gov?)
        (make-endorsement-authority)
        (receive (seal-infra _unseal-infra sealed-infra?)
          (make-endorsement-authority)
          (receive (seal-member _unseal-member sealed-member?)
            (make-endorsement-authority)
            (let* ((gov-pred    (name-set-predicate '(validator rollback)))
                   (infra-pred  (name-prefix-predicate "infra-"))
                   (member-pred (name-prefix-predicate "member-"))
                   (gov-facet    (make-facet gov-pred    sealed-gov?))
                   (infra-facet  (make-facet infra-pred  sealed-infra?))
                   (member-facet (make-facet member-pred sealed-member?))
                   (validator    (spawn ^faceted-validator
                                        (list gov-facet infra-facet member-facet)))
                   (out (spawn ^output-port (current-output-port)))
                   (org (make-org name vat out validator default-base-bindings)))
              (values org seal-gov seal-infra seal-member))))))))

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
  "Handle ,command in the inner REPL."
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
               ((eof-object? raw)
                (newline)
                (format #t "Leaving org '~a'.\n" name))

               ((equal? raw '(exit!))
                (format #t "Leaving org '~a'.\n" name))

               ((equal? raw '(quit))
                (format #t "Leaving org '~a'.\n" name))

               ((comma-command? raw)
                => (lambda (cmd)
                     (if (handle-comma-command cmd ref)
                         (loop)
                         (begin
                           (format #t "Unknown command: ,~a\n" cmd)
                           (loop)))))

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
