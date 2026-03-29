;;; org.scm — Org management and inner REPL
;;;
;;; Two ways to create an org:
;;;   make-open-org     — everyone gets a mutation ref (experimentation)
;;;   make-governed-org — read-only ref + 3 scoped mutation refs (governance)

(define-module (xorg org)
  #:use-module (goblins)
  #:use-module (goblins actor-lib facet)
  #:use-module (xorg gplay)
  #:use-module (ice-9 match)
  #:use-module (ice-9 pretty-print)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (make-open-org
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

;;; ── Registry ──────────────────────────────────────────────────────────────

(define *orgs* '())

(define (register-org! org)
  (set! *orgs* (cons org *orgs*)))

(define (list-orgs)
  (if (null? *orgs*)
      (display "  (no orgs created yet)\n")
      (for-each (lambda (o) (format #t "  ~a\n" (org-name o)))
                (reverse *orgs*))))

;;; ── Default base bindings ─────────────────────────────────────────────────

(define default-base-bindings
  `((+              . ,+)
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
    (not            . ,not)
    (equal?         . ,equal?)
    (eq?            . ,eq?)
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
    (string-append  . ,string-append)
    (string-length  . ,string-length)
    (substring      . ,substring)
    (string->symbol . ,string->symbol)
    (symbol->string . ,symbol->string)
    (string->number . ,string->number)
    (number->string . ,number->string)
    (sqrt           . ,sqrt)
    (floor          . ,floor)
    (ceiling        . ,ceiling)
    (round          . ,round)
    (string=?       . ,string=?)
    (string<?       . ,string<?)
    (string>?       . ,string>?)
    (string-ref     . ,string-ref)
    (cadr           . ,cadr)
    (caddr          . ,caddr)
    (cddr           . ,cddr)
    (caar           . ,caar)
    (cdar           . ,cdar)
    (eqv?           . ,eqv?)
    (char?          . ,char?)
    (void           . ,(lambda () (if #f #f)))))

;;; ── Org creation ──────────────────────────────────────────────────────────

(define* (make-open-org name #:optional (base-bindings default-base-bindings))
  "Create an open org. Returns (values org-record genesis-ref).
   The genesis-ref is an ^attributed-ref — identity is 'genesis."
  (let ((vat (spawn-vat)))
    (with-vat vat
      (let* ((out (spawn ^output-port (current-output-port)))
             (initial-history (list (list 0 'genesis '(quote initial) 0 base-bindings)))
             (raw-org (spawn ^org base-bindings initial-history 0 out))
             (genesis-ref (spawn ^attributed-ref raw-org 'genesis))
             (org (%make-org name vat genesis-ref)))
        (register-org! org)
        (values org genesis-ref)))))

(define* (make-governed-org name #:optional (base-bindings default-base-bindings))
  "Create a governed org. Returns (values org-record read-ref gov-ref infra-ref member-ref).

   read-ref:   can only lookup, bindings, history, head-version
   gov-ref:    can mutate as 'governance identity
   infra-ref:  can mutate as 'infrastructure identity
   member-ref: can mutate as 'membership identity

   The ref IS the identity. No sealers, no validators, no signing.
   Holding gov-ref means you ARE governance."
  (let ((vat (spawn-vat)))
    (with-vat vat
      (let* ((out (spawn ^output-port (current-output-port)))
             (initial-history (list (list 0 'genesis '(quote initial) 0 base-bindings)))
             (raw-org (spawn ^org base-bindings initial-history 0 out))
             (read-ref   (facet raw-org 'lookup 'bindings 'history 'head-version))
             (gov-ref    (spawn ^attributed-ref raw-org 'governance))
             (infra-ref  (spawn ^attributed-ref raw-org 'infrastructure))
             (member-ref (spawn ^attributed-ref raw-org 'membership))
             (org (%make-org name vat read-ref)))
        (register-org! org)
        (values org read-ref gov-ref infra-ref member-ref)))))

;;; ── Accessors ─────────────────────────────────────────────────────────────

(define (org-bindings org)
  (with-vat (org-vat org) ($ (org-ref org) 'bindings)))

(define (org-history org)
  (with-vat (org-vat org) ($ (org-ref org) 'history)))

;;; ── Inner REPL ────────────────────────────────────────────────────────────

(define *1 (if #f #f))
(define *2 (if #f #f))
(define *3 (if #f #f))

(define (shift-results! val)
  (set! *3 *2) (set! *2 *1) (set! *1 val))

(define (comma-command? raw)
  (match raw
    (('unquote (? symbol? cmd)) cmd)
    (_ #f)))

(define (handle-comma-command cmd ref)
  (case cmd
    ((env)
     (pretty-print ($ ref 'bindings)) #t)
    ((history)
     (for-each (lambda (entry)
                 (format #t "  v~a [~a]: ~s\n"
                         (list-ref entry 0) (list-ref entry 1)
                         (list-ref entry 2)))
               (reverse ($ ref 'history)))
     #t)
    ((help)
     (display "  ,env         -- show current bindings\n")
     (display "  ,history     -- show history\n")
     (display "  ,help        -- show this help\n")
     (display "  (exit!)      -- return to outer REPL\n")
     #t)
    (else #f)))

(define (enter! org)
  "Drop into the inner REPL for ORG."
  (let ((name (org-name org))
        (vat (org-vat org))
        (ref (org-ref org)))
    (format #t "Entering org '~a'. Type (exit!) to return.\n\n" name)
    (with-vat vat
      (let loop ()
        (catch #t
          (lambda ()
            (format #t "play[~a]> " ($ ref 'who))
            (force-output)
            (let ((raw (read)))
              (cond
               ((eof-object? raw)
                (newline) (format #t "Leaving org '~a'.\n" name))
               ((equal? raw '(exit!))
                (format #t "Leaving org '~a'.\n" name))
               ((comma-command? raw)
                => (lambda (cmd)
                     (if (handle-comma-command cmd ref)
                         (loop)
                         (begin (format #t "Unknown: ,~a\n" cmd) (loop)))))
               (else
                (let ((result (evaluate raw ref '())))
                  (unless (eq? result (if #f #f))
                    (shift-results! result)
                    (display "=> ")
                    (pretty-print result))
                  (loop))))))
          (lambda (key . args)
            (format #t "error: ~a" key)
            (for-each (lambda (a) (format #t " ~a" a)) args)
            (newline)
            (loop)))))))
