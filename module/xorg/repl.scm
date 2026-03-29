;;; module/playnet/repl.scm — Inner REPL and org factories for Hoot/WASM
;;;
;;; Convenience layer for the browser. On native Guile, use Goblins
;;; directly (,enter-vat) or build your own REPL.

(define-module (playnet repl)
  #:use-module (goblins)
  #:use-module (goblins actor-lib cell)
  #:use-module (goblins actor-lib facet)
  #:use-module (playnet actors)
  #:use-module (playnet evaluator)
  #:use-module (ice-9 match)
  #:use-module (ice-9 pretty-print)
  #:export (make-open-org
            make-governed-org
            enter!)
  #:re-export (evaluate
               default-base-bindings
               make-io-bindings))

;;; ── Org creation ──────────────────────────────────────────────────────────

(define* (make-open-org name #:optional (base-bindings default-base-bindings))
  "Create an open org. Returns (values vat proxy log)."
  (let ((vat (spawn-vat)))
    (with-vat vat
      (let* ((all-bindings (append (make-io-bindings) base-bindings))
             (raw-org (spawn ^org all-bindings))
             (log (spawn ^logger)))
        (define-values (proxy _revoked?)
          (spawn-logged-revocable-proxy-pair 'genesis raw-org log))
        ($ raw-org 'modify! '*log* log)
        (values vat proxy log)))))

(define* (make-governed-org name #:optional (base-bindings default-base-bindings))
  "Create a governed org. Returns:
     (values vat read-ref log
             gov-proxy gov-revoked?
             infra-proxy infra-revoked?
             member-proxy member-revoked?)"
  (let ((vat (spawn-vat)))
    (with-vat vat
      (let* ((all-bindings (append (make-io-bindings) base-bindings))
             (raw-org (spawn ^org all-bindings))
             (log (spawn ^logger))
             (read-ref (facet raw-org 'lookup 'bindings 'snapshot)))
        (define-values (gov gov-r)
          (spawn-logged-revocable-proxy-pair 'governance raw-org log))
        (define-values (infra infra-r)
          (spawn-logged-revocable-proxy-pair 'infrastructure raw-org log))
        (define-values (member member-r)
          (spawn-logged-revocable-proxy-pair 'membership raw-org log))
        ($ raw-org 'modify! '*log* log)
        (values vat read-ref log
                gov gov-r infra infra-r member member-r)))))

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
