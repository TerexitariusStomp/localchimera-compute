;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/test/harness.scm — shared test infrastructure
;;;
;;; Extracts the pattern duplicated across all test files:
;;; check/check-error assertions, pick-free-port, mock server spawning,
;;; and test summary with exit code. Import this once instead of
;;; redefining the same ~30 lines in every test file.
;;;
;;; Usage:
;;;
;;;   (use-modules (localchimera test harness))
;;;
;;;   (check "2 + 2 = 4" (= 4 (+ 2 2)))
;;;   (check-error "division by zero throws"
;;;     (lambda () (/ 1 0)))
;;;
;;;   (define-values (port thread)
;;;     (spawn-mock-server my-handler))
;;;
;;;   (test-summary!)  ;; prints results, exits 0 or 1

(define-module (localchimera test harness)
  #:use-module (localchimera boot scope)   ;; load: a suite that reaches a scope finds it composed from its fragments
  #:use-module (localchimera boot governance)   ;; load: and the governance service likewise
  #:use-module (web server)
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (ice-9 threads)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:export (check
            check-pred
            check-error
            pick-free-port
            spawn-mock-server
            test-summary!
            pass-count
            fail-count
            ^mock
            raises?
            make-rng))

(define pass-count 0)
(define fail-count 0)

;; the ubiquitous method-table mock actor — spawn with a ((msg . proc) …)
;; table; an unknown message errors loudly. Dozens of planner tests
;; defined this locally before it moved here; a local copy simply
;; shadows this one.
;; The hooks a store is asked to register when a scope is wired (a listener on its
;; intents or agents, a change callback), and the two reads the wiring itself makes
;; of the observer, answer an empty reading on every mock: a suite that mocks a store
;; for what it is ABOUT does not list each hook the wiring grew since. Any other
;; unknown message still errors loudly.
(define %mock-defaults
  '((set-on-agent . #t) (set-on-agent-removed . #t)
    (add-event-listener . #t) (add-intent-listener . #t) (add-change-listener . #t)
    (skills-of . ()) (fold-by . ()) (open-fulfillments . ()) (fulfillments-for . ()) (hours-by . ()) (hours-on . 0)))

(define (^mock bcom table)
  (lambda (msg . args)
    (let ((p (or (assq msg table) (assq msg %mock-defaults))))
      (cond ((not p) (error "mock: no method" msg))
            ((procedure? (cdr p)) (apply (cdr p) args))
            (else (cdr p))))))

(define (raises? thunk)
  "True when THUNK raises — check-error's predicate twin, for checks
   that combine a raise with other conditions."
  (catch #t (lambda () (thunk) #f) (lambda _ #t)))

(define (make-rng seed)
  "A seeded linear-congruential stream, so a failing property test is a program
   someone can build again: a thunk answering the next state, an integer in
   [0, 2^31)."
  (let ((state seed))
    (lambda ()
      (set! state (modulo (+ (* state 1103515245) 12345) 2147483648))
      state)))

(define (check label . args)
  "Assert a test condition. Two forms:
  (check \"label\" pred)           — 2-arg: pred must be truthy
  (check \"label\" got expected)   — 3-arg: got must equal? expected"
  (let* ((pass? (if (null? (cdr args))
                    (car args)                          ; 2-arg: boolean
                    (equal? (car args) (cadr args)))))  ; 3-arg: equal?
    (cond
     (pass?
      (set! pass-count (+ pass-count 1))
      (format #t "  ok: ~a~%" label))
     (else
      (set! fail-count (+ fail-count 1))
      (if (null? (cdr args))
          (format #t "  FAIL: ~a~%" label)
          (begin
            (format #t "  FAIL: ~a~%" label)
            (format #t "    expected: ~s~%" (cadr args))
            (format #t "    got:      ~s~%" (car args))))))))

(define (check-pred label pred)
  "Alias for 2-arg check. Some planner tests use this name."
  (check label pred))

(define (check-error label thunk)
  "Assert that THUNK raises an exception."
  (check label
         (catch #t
           (lambda () (thunk) #f)
           (lambda _ #t))))

(define (pick-free-port)
  "Bind to port 0 on loopback, read the assigned port, close. Returns a port
that was free A MOMENT AGO — NOT one reserved for the caller. The socket has
to be closed before the real server can bind it, and anyone may take it in
between. Callers must therefore be prepared to lose the race; see
`spawn-mock-server`, which retries."
  (let ((s (socket PF_INET SOCK_STREAM 0)))
    (setsockopt s SOL_SOCKET SO_REUSEADDR 1)
    (bind s AF_INET INADDR_LOOPBACK 0)
    (let ((port (sockaddr:port (getsockname s))))
      (close-port s)
      port)))

(define (port-accepting? port)
  "True when something on loopback PORT accepts a connection.

NOTE WHAT THIS CANNOT SAY: whether the thing accepting is OURS. See
`ours-on-port?`, which is what readiness actually waits for."
  (catch #t
    (lambda ()
      (let ((s (socket PF_INET SOCK_STREAM 0)))
        (catch #t
          (lambda () (connect s AF_INET INADDR_LOOPBACK port) (close-port s) #t)
          (lambda _ (false-if-exception (close-port s)) #f))))
    (lambda _ #f)))

(define (ours-on-port? port nonce)
  "True when the server on loopback PORT answers /__ready/NONCE with NONCE.

A CONNECTION IS NOT AN IDENTITY. `pick-free-port` cannot reserve what it
reports, so under JOBS parallelism two tests are handed the same number; the
loser's `run-server` throws and retries, which is handled. The case that was
NOT handled is subtler and has the opposite sign: when the OTHER test's server
binds first, this one's readiness poll connects successfully — to a stranger —
concludes it is up, and then runs its whole body against a server that knows
nothing about its routes. Every request 404s and the test fails on its
assertions, looking exactly like a logic bug and only ever under load.

So readiness asks a question only our own handler can answer. Spoken over a
hand-rolled request rather than (web client) to keep the harness's dependencies
where they are, and because all this needs is one line and a substring."
  (catch #t
    (lambda ()
      (let ((s (socket PF_INET SOCK_STREAM 0)))
        (catch #t
          (lambda ()
            (connect s AF_INET INADDR_LOOPBACK port)
            (display (string-append "GET /__ready/" nonce " HTTP/1.0\r\n"
                                    "Host: 127.0.0.1\r\n\r\n") s)
            (force-output s)
            (let ((reply (get-string-all s)))
              (close-port s)
              (and (string? reply) (string-contains reply nonce) #t)))
          (lambda _ (false-if-exception (close-port s)) #f))))
    (lambda _ #f)))

(define* (spawn-mock-server handler #:key (attempts 6) (ready-timeout 10.0))
  "Start a mock HTTP server in a background thread on a free loopback port.
Returns (values port thread).

Two failure modes are handled here because both were observed as flaky
suite failures under JOBS parallelism, and both look like a bad test:

  LOST PORT RACE. `pick-free-port` cannot reserve the port it reports; when
  several tests start servers at once, two can be handed the same number and
  the loser's `run-server` throws on a background thread. The old code sent
  that to stderr and returned anyway, so the test ran its whole body against
  a socket nobody was listening on and failed with a plain exit 1. A lost
  race now retries on a fresh port.

  SLOW BIND. The old code slept a flat 200ms and assumed the server was up.
  That is a guess about machine load, not an observation, and on a loaded
  machine the first request can beat the bind. Readiness is now polled until
  the port actually accepts.

  WON THE CONNECTION, LOST THE PORT. The remaining flake, and the one that
  looked like a bad test rather than a race: when another test's server binds
  the shared number FIRST, this one's `run-server` may not have thrown yet, the
  readiness poll connects to the STRANGER, and the test proceeds against a
  server that has never heard of its routes. Every request 404s and it fails on
  its assertions — only under parallelism, and never when re-run alone, which
  is exactly the signature the runner reports as load-sensitive. Readiness now
  asks a question only our own handler can answer (`ours-on-port?`), so a
  stranger on the port reads as a lost race and retries on a fresh one."
  (let try ((n 1))
    (let* ((port (pick-free-port))
           (nonce (number->string (+ (* 1000000 (getpid)) n (random 1000000))))
           (died #f)
           ;; the readiness route is wrapped around the caller's handler rather
           ;; than asked of it: every mock server gets the handshake without a
           ;; single test knowing it exists
           (wrapped
            (lambda (request body)
              (if (string-suffix? (string-append "/__ready/" nonce)
                                  (uri-path (request-uri request)))
                  (values (build-response #:code 200) nonce)
                  (handler request body))))
           (thread (call-with-new-thread
                    (lambda ()
                      (catch #t
                        (lambda ()
                          (run-server wrapped 'http
                                      `(#:addr ,(inet-pton AF_INET "127.0.0.1")
                                        #:port ,port)))
                        (lambda (key . args) (set! died (cons key args))))))))
      (let wait ((waited 0.0))
        (cond
         ((ours-on-port? port nonce) (values port thread))
         ;; someone else holds the port: not our server, and it will not become
         ;; ours by waiting
         ((and (> waited 0.5) (port-accepting? port) (not died))
          (false-if-exception (cancel-thread thread))
          (if (< n attempts)
              (try (+ n 1))
              (error "mock server lost port" port "to another listener")))
         (died
          (if (< n attempts)
              (try (+ n 1))
              (error "mock server could not bind after" attempts "attempts:" died)))
         ((>= waited ready-timeout)
          (false-if-exception (cancel-thread thread))
          (if (< n attempts)
              (try (+ n 1))
              (error "mock server never accepted on port" port)))
         (else (usleep 20000) (wait (+ waited 0.02))))))))

(define (test-summary!)
  "Print the test results and exit with code 0 (all passed) or 1."
  (format #t "~%=== Results: ~a passed, ~a failed ===~%"
          pass-count fail-count)
  (exit (if (zero? fail-count) 0 1)))
