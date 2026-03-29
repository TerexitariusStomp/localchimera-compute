;;; org.scm — Org management and inner REPL
;;;
;;; Two ways to create an org:
;;;   make-open-org     — everyone gets a proxy, shared logger
;;;   make-governed-org — read-only ref + 3 revocable proxies + logger
;;;
;;; Follows the Heart of Spritely accountability pattern (section 3.3.4):
;;;   ^logger + spawn-logged-revocable-proxy-pair

(define-module (xorg org)
  #:use-module (goblins)
  #:use-module (goblins actor-lib cell)
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
            org-log
            org-bindings
            enter!
            list-orgs
            default-base-bindings))

;;; ── Org record ────────────────────────────────────────────────────────────

(define-record-type <org>
  (%make-org name vat ref log)
  org?
  (name org-name)
  (vat  org-vat)
  (ref  org-ref)
  (log  org-log))

;;; ── Registry ──────────────────────────────────────────────────────────────

(define *orgs* '())
(define (register-org! org) (set! *orgs* (cons org *orgs*)))
(define (list-orgs)
  (if (null? *orgs*)
      (display "  (no orgs created yet)\n")
      (for-each (lambda (o) (format #t "  ~a\n" (org-name o)))
                (reverse *orgs*))))

;;; ── Default base bindings ─────────────────────────────────────────────────

(define default-base-bindings
  `((+ . ,+) (- . ,-) (* . ,*) (/ . ,/)
    (> . ,>) (< . ,<) (= . ,=) (>= . ,>=) (<= . ,<=)
    (abs . ,abs) (max . ,max) (min . ,min)
    (modulo . ,modulo) (remainder . ,remainder) (expt . ,expt)
    (not . ,not) (equal? . ,equal?) (eq? . ,eq?)
    (cons . ,cons) (car . ,car) (cdr . ,cdr)
    (list . ,list) (append . ,append) (reverse . ,reverse) (length . ,length)
    (map . ,map) (filter . ,filter) (for-each . ,for-each) (fold . ,fold)
    (assoc . ,assoc) (member . ,member) (apply . ,apply)
    (null? . ,null?) (pair? . ,pair?) (list? . ,list?)
    (number? . ,number?) (string? . ,string?) (symbol? . ,symbol?)
    (procedure? . ,procedure?) (boolean? . ,boolean?)
    (zero? . ,zero?) (positive? . ,positive?) (negative? . ,negative?)
    (even? . ,even?) (odd? . ,odd?)
    (string-append . ,string-append) (string-length . ,string-length)
    (substring . ,substring) (string->symbol . ,string->symbol)
    (symbol->string . ,symbol->string) (string->number . ,string->number)
    (number->string . ,number->string)
    (sqrt . ,sqrt) (floor . ,floor) (ceiling . ,ceiling) (round . ,round)
    (string=? . ,string=?) (string<? . ,string<?) (string>? . ,string>?)
    (string-ref . ,string-ref)
    (cadr . ,cadr) (caddr . ,caddr) (cddr . ,cddr)
    (caar . ,caar) (cdar . ,cdar) (eqv? . ,eqv?) (char? . ,char?)
    (void . ,(lambda () (if #f #f)))))

;;; ── Org creation ──────────────────────────────────────────────────────────

(define* (make-open-org name #:optional (base-bindings default-base-bindings))
  "Create an open org. Returns (values org-record proxy).
   A single logged proxy for 'genesis'. Log is on the org record."
  (let ((vat (spawn-vat)))
    (with-vat vat
      (let* ((out (spawn ^output-port (current-output-port)))
             (raw-org (spawn ^org base-bindings out))
             (log (spawn ^logger)))
        (define-values (genesis-proxy _revoked?)
          (spawn-logged-revocable-proxy-pair 'genesis raw-org log))
        ;; Bind the log into the org so (rollback!) can find it
        ($ raw-org 'modify! '*log* log)
        (let ((org (%make-org name vat genesis-proxy log)))
          (register-org! org)
          (values org genesis-proxy))))))

(define* (make-governed-org name #:optional (base-bindings default-base-bindings))
  "Create a governed org. Returns:
     (values org-record read-ref log
             gov-proxy gov-revoked?
             infra-proxy infra-revoked?
             member-proxy member-revoked?)

   read-ref:   ^facet — can only lookup, bindings, snapshot
   gov/infra/member: logged revocable proxies (Heart of Spritely pattern)
   log:        ^logger — the accountability record"
  (let ((vat (spawn-vat)))
    (with-vat vat
      (let* ((out (spawn ^output-port (current-output-port)))
             (raw-org (spawn ^org base-bindings out))
             (log (spawn ^logger))
             (read-ref (facet raw-org 'lookup 'bindings 'snapshot)))
        (define-values (gov-proxy gov-revoked?)
          (spawn-logged-revocable-proxy-pair 'governance raw-org log))
        (define-values (infra-proxy infra-revoked?)
          (spawn-logged-revocable-proxy-pair 'infrastructure raw-org log))
        (define-values (member-proxy member-revoked?)
          (spawn-logged-revocable-proxy-pair 'membership raw-org log))
        ;; Bind the log into the org so (rollback!) can find it
        ($ raw-org 'modify! '*log* log)
        (let ((org (%make-org name vat read-ref log)))
          (register-org! org)
          (values org read-ref log
                  gov-proxy gov-revoked?
                  infra-proxy infra-revoked?
                  member-proxy member-revoked?))))))

;;; ── Accessors ─────────────────────────────────────────────────────────────

(define (org-bindings org)
  (with-vat (org-vat org) ($ (org-ref org) 'bindings)))

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

(define (handle-comma-command cmd ref log)
  (case cmd
    ((env)
     (pretty-print ($ ref 'bindings)) #t)
    ((log)
     (for-each (lambda (entry)
                 (format #t "  [~a] ~s\n"
                         (cadr (memq 'user entry))
                         (cadr (memq 'args entry))))
               (reverse ($ log 'get-log)))
     #t)
    ((help)
     (display "  ,env   -- show current bindings\n")
     (display "  ,log   -- show accountability log\n")
     (display "  ,help  -- show this help\n")
     (display "  (exit!) -- return to outer REPL\n")
     #t)
    (else #f)))

(define (enter! org)
  "Drop into the inner REPL for ORG."
  (let ((name (org-name org))
        (vat (org-vat org))
        (ref (org-ref org))
        (log (org-log org)))
    (format #t "Entering org '~a'. Type (exit!) to return.\n\n" name)
    (with-vat vat
      (let loop ()
        (catch #t
          (lambda ()
            (display "play> ")
            (force-output)
            (let ((raw (read)))
              (cond
               ((eof-object? raw)
                (newline) (format #t "Leaving org '~a'.\n" name))
               ((equal? raw '(exit!))
                (format #t "Leaving org '~a'.\n" name))
               ((comma-command? raw)
                => (lambda (cmd)
                     (if (handle-comma-command cmd ref log)
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
