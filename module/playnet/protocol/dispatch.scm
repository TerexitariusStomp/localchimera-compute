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
  #:export (declared-methods declared-methods* declared-doors compose-doors
            fragment-heads fragment-dispatch
            check-declared-heads! heads-drift))

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

;; An object's doors may be written in more than one module: the identity
;; doors of the lobby and the session live in (playnet identity doors) as
;; FRAGMENTS, and the object composes them with its own clauses.
;;
;;   (declared-doors OBJECT clause …)            a fragment: its heads, with
;;                                               the `methods` dispatcher of
;;                                               its clauses
;;   (declared-methods* OBJECT (fragment …) clause …)
;;                                               the object: ONE check over
;;                                               the union of heads, ONE
;;                                               dispatcher — a message goes
;;                                               to the fragment whose heads
;;                                               name it, else to the object's
;;                                               own clauses
;;
;; tools/protocol-extract.scm reads both forms, so the offline lint sees the
;; same union the boot-time check does.
(define-syntax declared-doors
  (syntax-rules ()
    ((_ object ((name . args) body ...) ...)
     (cons '((name . args) ...) (methods ((name . args) body ...) ...)))))

(define (fragment-heads f) (car f))
(define (fragment-dispatch f) (cdr f))

(define (compose-doors fragments own)
  "The dispatcher of an object: FRAGMENTS (each a declared-doors value) in
   front of its OWN clauses."
  (lambda (method . args)
    (let ((f (find (lambda (fr) (assq method (fragment-heads fr))) fragments)))
      (apply (if f (fragment-dispatch f) own) method args))))

(define-syntax declared-methods*
  (syntax-rules ()
    ((_ object (fragment ...) ((name . args) body ...) ...)
     (let ((fragments (list fragment ...)))
       (check-declared-heads! 'object
                              (append '((name . args) ...)
                                      (append-map fragment-heads fragments)))
       (compose-doors fragments (methods ((name . args) body ...) ...))))))
