;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/utils/host.scm — what the process around the code can say, stated once for both builds.
;;;
;;; A module that reads a PLANNER_* switch or another fact of its host asks
;;; here. Under Guile each is the host's own procedure; under Hoot (the browser's
;;; family and scope workers compile the solve whole) the page has no process
;;; environment, so every switch reads as unset. `#:replace` says the Guile
;;; binding is meant to be shadowed, so the import is silent.

(define-module (localchimera utils host)
  #:export (define-lazy)
  #:replace (getenv get-internal-real-time internal-time-units-per-second string-contains hash-get-handle))

;; A module's top level runs on the HOST when the browser build compiles it
;; (Hoot evaluates each library once at expand time, on the machine that
;; compiles), where a primitive only the wasm has, the clock first of all,
;; refuses. A value whose building reads one is built on its first reach
;; instead: NAME reads as EXPR's value, computed once, the same on both
;; builds. A seed world that stands on today's month is one (knowledge/
;; recipes/bread-commune-seed.scm).
(define-syntax define-lazy
  (lambda (x)
    (syntax-case x ()
      ((_ name expr)
       (with-syntax ((cell (datum->syntax #'name (string->symbol (string-append "%lazy-" (symbol->string (syntax->datum #'name)))))))
         #'(begin
             (define cell (delay expr))
             (define-syntax name (identifier-syntax (force cell)))))))))

(cond-expand
 (guile
  (define getenv (@ (guile) getenv))
  (define get-internal-real-time (@ (guile) get-internal-real-time))
  (define internal-time-units-per-second (@ (guile) internal-time-units-per-second))
  (define string-contains (@ (srfi srfi-13) string-contains))
  (define hash-get-handle (@ (guile) hash-get-handle)))
 (else
  (define (getenv name) #f)
  ;; a report line's seconds: whole seconds is what a page has
  (define (get-internal-real-time) (current-time))
  (define internal-time-units-per-second 1)
  (define (string-contains s pat)          ; the first index of PAT in S, or #f (Hoot has no srfi-13)
    (let ((n (string-length s)) (m (string-length pat)))
      (let loop ((i 0))
        (cond ((> (+ i m) n) #f)
              ((string=? (substring s i (+ i m)) pat) i)
              (else (loop (+ i 1)))))))
  (define %no-entry (list 'no-entry))
  (define (hash-get-handle h key)          ; the (key . value) pair of KEY in H, or #f (Hoot has no handles)
    (let ((v (hash-ref h key %no-entry)))
      (and (not (eq? v %no-entry)) (cons key v))))))
