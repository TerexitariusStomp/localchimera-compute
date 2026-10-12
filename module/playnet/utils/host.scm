;;; module/playnet/utils/host.scm — what the process around the code can say, stated once for both builds.
;;;
;;; A module that reads a PLANNER_* switch or another fact of its host asks
;;; here. Under Guile each is the host's own procedure; under Hoot (the browser's
;;; family and scope workers compile the solve whole) the page has no process
;;; environment, so every switch reads as unset. `#:replace` says the Guile
;;; binding is meant to be shadowed, so the import is silent.

(define-module (playnet utils host)
  #:replace (getenv get-internal-real-time internal-time-units-per-second string-contains))

(cond-expand
 (guile
  (define getenv (@ (guile) getenv))
  (define get-internal-real-time (@ (guile) get-internal-real-time))
  (define internal-time-units-per-second (@ (guile) internal-time-units-per-second))
  (define string-contains (@ (srfi srfi-13) string-contains)))
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
              (else (loop (+ i 1)))))))))
