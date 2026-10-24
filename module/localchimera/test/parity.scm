;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/test/parity.scm — the parity-suite helpers.
;;;
;;; spec/oss-inventory.md's gate: a Tier-2 module may only shrink after a
;;; tests/parity/<suite>.scm proves the OSS adapter reproduces its
;;; semantics. A parity suite has two legs:
;;;
;;;   invariant leg — runs always: the custom code's answer on a fixture,
;;;                   or the contract the upstream must reproduce (a wire
;;;                   shape, a golden result, a semantic invariant).
;;;   live leg      — runs when the environment names the service
;;;                   (LOCALCHIMERA_<SERVICE>_URL): the same fixture through the
;;;                   delegate's real transport, answers diffed against the
;;;                   custom side. Skips loudly, never silently.
;;;
;;; These helpers keep every suite to the same two-leg shape so the gate's
;;; "all suites present" means all suites ran the same contract.

(define-module (localchimera test parity)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (localchimera delegates)
  #:use-module (localchimera test harness)
  #:export (live-endpoint parity-live parity-live-delegate))

(define (live-endpoint env-name)
  "The upstream endpoint the environment names, or #f — the live leg's
   on/off switch. Same convention as %env-transport: unset means the
   service isn't there and the suite says so."
  (let ((v (getenv env-name)))
    (and v (not (string-null? v)) v)))

(define* (parity-live env-name label thunk #:optional (equal equal?))
  "The live leg: when ENV-NAME names an endpoint, run THUNK and report the
   result as a check-style line; when it doesn't, say 'skipped' so the
   suite's output is honest about which leg ran. Returns #t when the live
   leg passed or was correctly skipped, #f only on a real mismatch."
  (if (live-endpoint env-name)
      (check (string-append label " [live " env-name "]")
             (thunk (live-endpoint env-name)) #t)
      (begin
        (format #t "  --: ~a [skipped — ~a unset]~%" label env-name)
        #t)))

(define* (parity-live-delegate env-name label make-delegate call
                               #:optional (ok? (lambda (a) (and (pair? a) (< (car a) 300)))))
  "Live leg over a delegate: build MAKE-DELEGATE with the env transport,
   run CALL against it, and judge the answer under OK? — a predicate over
   the transport's (status . body) cons (default: an HTTP success). An
   'unavailable from the delegate counts as a live-leg failure: the
   endpoint was named, so it should answer."
  (parity-live env-name label
    (lambda (endpoint)
      (let* ((transport (%json-http-transport endpoint))
             (answer (call (make-delegate transport))))
        (and (not (eq? answer 'unavailable))
             (ok? answer))))))
