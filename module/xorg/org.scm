;;; org.scm — Org factories and REPL
;;;
;;; Two ways to create an org:
;;;   make-open-org     — everyone gets a proxy, shared logger
;;;   make-governed-org — read-only ref + 3 revocable proxies + logger
;;;
;;; Follows the Heart of Spritely accountability pattern (section 3.3.4).
;;; IO is a capability injected via bindings, not an actor wrapper.
;;; No global registry — you hold a ref or you don't.

(define-module (xorg org)
  #:use-module (goblins)
  #:use-module (goblins actor-lib cell)
  #:use-module (goblins actor-lib facet)
  #:use-module (xorg gplay)
  #:use-module (ice-9 match)
  #:use-module (ice-9 pretty-print)
  #:use-module (srfi srfi-1)
  #:export (make-open-org
            make-governed-org
            default-base-bindings
            make-io-bindings
            enter!))

;;; ── Default base bindings ─────────────────────────────────────────────────
;;;
;;; Pure computation — no IO. IO is injected separately via make-io-bindings.

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

;;; ── IO bindings ───────────────────────────────────────────────────────────
;;;
;;; IO is a capability — you pass it in, just like Solitaire receives
;;; a window canvas in Heart of Spritely section 2. The org doesn't
;;; have ambient access to any port.

(define* (make-io-bindings #:optional (port (current-output-port)))
  "Create IO capability bindings for a specific port."
  `((display . ,(lambda (v) (display v port) (if #f #f)))
    (write   . ,(lambda (v) (write v port) (if #f #f)))
    (newline . ,(lambda () (newline port) (if #f #f)))
    (format  . ,(lambda (fmt . args) (apply format port fmt args) (if #f #f)))))

;;; ── Org creation ──────────────────────────────────────────────────────────

(define* (make-open-org name #:optional (base-bindings default-base-bindings))
  "Create an open org. Returns (values vat proxy log).
   A single logged proxy for 'genesis'. IO injected via bindings."
  (let ((vat (spawn-vat)))
    (with-vat vat
      (let* ((all-bindings (append (make-io-bindings) base-bindings))
             (raw-org (spawn ^org all-bindings))
             (log (spawn ^logger)))
        (define-values (genesis-proxy _revoked?)
          (spawn-logged-revocable-proxy-pair 'genesis raw-org log))
        ;; Bind the log so rollback! can find it
        ($ raw-org 'modify! '*log* log)
        (values vat genesis-proxy log)))))

(define* (make-governed-org name #:optional (base-bindings default-base-bindings))
  "Create a governed org. Returns:
     (values vat read-ref log
             gov-proxy gov-revoked?
             infra-proxy infra-revoked?
             member-proxy member-revoked?)

   Follows Heart of Spritely section 3.3.4:
   - read-ref: ^facet — can only lookup, bindings, snapshot
   - gov/infra/member: logged revocable proxies
   - log: ^logger — the accountability record
   - *-revoked?: ^cell — flip to #t to cut access"
  (let ((vat (spawn-vat)))
    (with-vat vat
      (let* ((all-bindings (append (make-io-bindings) base-bindings))
             (raw-org (spawn ^org all-bindings))
             (log (spawn ^logger))
             (read-ref (facet raw-org 'lookup 'bindings 'snapshot)))
        (define-values (gov-proxy gov-revoked?)
          (spawn-logged-revocable-proxy-pair 'governance raw-org log))
        (define-values (infra-proxy infra-revoked?)
          (spawn-logged-revocable-proxy-pair 'infrastructure raw-org log))
        (define-values (member-proxy member-revoked?)
          (spawn-logged-revocable-proxy-pair 'membership raw-org log))
        ;; Bind the log so rollback! can find it
        ($ raw-org 'modify! '*log* log)
        (values vat read-ref log
                gov-proxy gov-revoked?
                infra-proxy infra-revoked?
                member-proxy member-revoked?)))))

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
     (pretty-print
      (filter (lambda (p) (not (procedure? (cdr p))))
              ($ ref 'bindings)))
     #t)
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

(define (enter! vat ref log)
  "Drop into the inner REPL. REF is a proxy, LOG is the ^logger."
  (display "Entering org. Type (exit!) to return.\n\n")
  (with-vat vat
    (let loop ()
      (catch #t
        (lambda ()
          (display "play> ")
          (force-output)
          (let ((raw (read)))
            (cond
             ((eof-object? raw)
              (newline) (display "Leaving org.\n"))
             ((equal? raw '(exit!))
              (display "Leaving org.\n"))
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
          (loop))))))
