;;; governed-row.scm — a scope's own word on a matter, kept as one row.
;;;
;;; A scope governs some of its own settings: how a person is recognised, which
;;; acts need a ballot, how much legally uncertain activity it will carry. Each
;;; is a row of the scope's plan-store (`get-meta` / `set-meta`): an alist of
;;; (key . value) under one name, beside defaults the code states. This module
;;; is the one reading and the one writing of such a row; a policy module names
;;; its row and its defaults (legal/policy.scm, first-person/personhood-policy.scm,
;;; voice/quorum.scm) and the scope's setters name what a value must be.
;;;
;;;   (governed-row plan-store "legal-policy" defaults 'uncertain-forbid explicit)
;;;   (merge-governed-row! plan-store "legal-policy" '((uncertain-forbid . …)))

(define-module (playnet utils governed-row)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:export (governed-row merge-governed-row!))

(define* (governed-row plan-store row-name defaults key #:optional (explicit #f))
  "The governed value for KEY: EXPLICIT when given, else the plan-store's
   ROW-NAME row, else DEFAULTS. A #f plan-store reads the defaults."
  (or explicit
      (let ((row (and plan-store
                      (false-if-exception ($ plan-store 'get-meta row-name)))))
        (and row (assq-ref row key)))
      (assq-ref defaults key)))

(define* (merge-governed-row! plan-store row-name changes
                              #:key (valid? (lambda (kv) (and (pair? kv) (symbol? (car kv)))))
                                    (who row-name) (shape "(key . value)"))
  "Write CHANGES into the ROW-NAME row: a partial alist updates only the keys it
   names. Each entry must satisfy VALID?, or the write is refused naming WHO and
   the SHAPE an entry has. Returns the row as written."
  (let* ((row (or (false-if-exception ($ plan-store 'get-meta row-name)) '()))
         (next (fold (lambda (kv acc)
                       (unless (valid? kv)
                         (error (format #f "~a: each entry is ~a" who shape) kv))
                       (cons kv (filter (lambda (p) (not (eq? (car p) (car kv)))) acc)))
                     row changes)))
    ($ plan-store 'set-meta row-name next)
    next))
