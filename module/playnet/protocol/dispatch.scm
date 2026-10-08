;;; module/playnet/protocol/dispatch.scm — an object's methods are its declared doors
;;;
;;; `declared-methods` is Goblins' `methods` with one addition: the first time
;;; an object of that kind is spawned, the heads written in the code are
;;; compared with the doors (playnet protocol) declares for it, and any
;;; difference — a head the declaration lacks, a declared door the code
;;; lacks, an argument list that differs — stops the spawn with a message
;;; naming every difference. The gateway therefore refuses to boot on drift,
;;; which is the property tools/protocol-lint.scm checks offline; here it
;;; holds at run time too, on the box, with no tool in the loop.
;;;
;;;   (declared-methods lobby
;;;     ((signup username email aid-prefix oobi-url) …)
;;;     …)
;;;
;;; The heads still appear in the code: a body binds its arguments there and
;;; nowhere else. What no longer exists is a second, unchecked copy of them.

(define-module (playnet protocol dispatch)
  #:use-module (playnet protocol)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:export (declared-methods check-declared-heads! heads-drift))

(define (heads-drift object heads)
  "The differences between HEADS ((name . args) …) written for OBJECT and the
declaration: a list of strings, empty when they agree."
  (let* ((declared (map (lambda (d) (cons (door-name d) (door-args d))) (doors-of object)))
         (names-code (map car heads))
         (names-decl (map car declared))
         (out '()))
    (for-each (lambda (h)
                (let ((d (assq (car h) declared)))
                  (cond
                   ((not d) (set! out (cons (format #f "~a: ~a is in the code and not declared" object (car h)) out)))
                   ((not (equal? (cdr h) (cdr d)))
                    (set! out (cons (format #f "~a: ~a takes ~s in the code, ~s in the declaration"
                                            object (car h) (cdr h) (cdr d))
                                    out))))))
              heads)
    (for-each (lambda (d)
                (unless (memq (car d) names-code)
                  (set! out (cons (format #f "~a: ~a is declared and not in the code" object (car d)) out))))
              declared)
    (reverse out)))

(define %checked '())

(define (check-declared-heads! object heads)
  "Once per OBJECT per process: refuse when HEADS drift from the declaration."
  (unless (memq object %checked)
    (let ((drift (heads-drift object heads)))
      (unless (null? drift)
        (error (string-append "protocol: the code's doors drift from (playnet protocol):\n  "
                              (string-join drift "\n  ")))))
    (set! %checked (cons object %checked))))

;; (declared-methods OBJECT clause …) — each clause is a `methods` clause,
;; ((name . args) body …). The heads are quoted out of the clauses for the
;; check; the clauses themselves go to `methods` untouched.
(define-syntax declared-methods
  (syntax-rules ()
    ((_ object ((name . args) body ...) ...)
     (begin
       (check-declared-heads! 'object '((name . args) ...))
       (methods ((name . args) body ...) ...)))))
