;;; utils/keywords.scm — a keyword list and an alist, one grammar.
;;;
;;; A door's arguments arrive as keywords, a scope's standing settings live as
;;; an alist, and a solve is called with keywords again. The four moves
;;; between the two shapes are written here once: every caller that laid its
;;; own `append-map (lambda (kv) (list (symbol->keyword …)))` or its own
;;; drop-these-keys loop reads these instead.

(define-module (playnet utils keywords)
  #:use-module (srfi srfi-1)
  #:export (alist->kw kw->alist kw-without kw-ref))

(define (alist->kw alist)
  "((key . value) …) → (#:key value …)."
  (append-map (lambda (kv) (list (symbol->keyword (car kv)) (cdr kv))) alist))

(define (kw->alist kw)
  "(#:key value …) → ((key . value) …), in order."
  (let loop ((k kw) (acc '()))
    (if (null? k) (reverse acc)
        (loop (cddr k) (cons (cons (keyword->symbol (car k)) (cadr k)) acc)))))

(define (kw-without kw keys)
  "KW with every pair whose keyword is in KEYS removed."
  (let loop ((k kw) (acc '()))
    (cond ((null? k) (reverse acc))
          ((memq (car k) keys) (loop (cddr k) acc))
          (else (loop (cddr k) (cons (cadr k) (cons (car k) acc)))))))

(define (kw-ref kw key)
  "The value after keyword KEY in KW, or #f."
  (let ((m (memq key kw))) (and m (pair? (cdr m)) (cadr m))))
