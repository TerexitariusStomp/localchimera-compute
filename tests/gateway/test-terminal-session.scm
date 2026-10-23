;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-terminal-session.scm — a shell's output reaches the client's inbox.
;;;
;;; ^terminal-session reads the child's output on a thread of its own and hands
;;; it to the client's inbox. The reader called `read!`, which nothing defines, so
;;; every read raised, was swallowed as end-of-file, and the session closed
;;; before it relayed a byte. This drives the session over plain pipes, the child
;;; end played by the test.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/gateway/test-terminal-session.scm

(use-modules (playnet test harness)
             (goblins)
             (ice-9 binary-ports) (rnrs bytevectors) (ice-9 rdelim)
             (playnet gateway terminal))

(setvbuf (current-output-port) (quote none))
(define vat (spawn-vat #:name "term-test"))

(define received '())
(define (^inbox bcom)
  (lambda (msg . args) (set! received (cons (cons msg args) received))))
(define inbox (with-vat vat (spawn ^inbox)))

(define (wait-for pred)
  (let loop ((n 0))
    (cond ((pred) #t) ((> n 60) #f) (else (usleep 50000) (loop (+ n 1))))))
(define (seen? msg . args) (lambda () (member (cons msg args) received)))

;; the "shell": a sleeper to stand in for the pid the session will signal on close
(define child ((@ (guile) spawn) "sleep" '("sleep" "30")))
(define to-child-pipe (pipe))     ; session writes the shell's stdin here
(define from-child-pipe (pipe))   ; the shell's output, written by the test

(define session
  (with-vat vat
    (spawn ^terminal-session child (cdr to-child-pipe) (car from-child-pipe) "alice" inbox vat)))

(display "\n── output reaches the client ──\n")
(put-bytevector (cdr from-child-pipe) (string->utf8 "hello from the shell\n"))
(force-output (cdr from-child-pipe))
(check-pred "a line the shell prints arrives as term-data"
            (wait-for (seen? 'term-data "hello from the shell\n")))

(put-bytevector (cdr from-child-pipe) (string->utf8 "naïve ✓\n"))
(force-output (cdr from-child-pipe))
(check-pred "multi-byte output arrives whole"
            (wait-for (seen? 'term-data "naïve ✓\n")))

(display "\n── input reaches the shell ──\n")
(with-vat vat ($ session 'write "ls\n"))
(check "what the client writes arrives on the shell's stdin"
       (read-line (car to-child-pipe)) "ls")

(display "\n── the shell exits ──\n")
(close-port (cdr from-child-pipe))
(check-pred "end of output closes the session with term-closed"
            (wait-for (seen? 'term-closed)))

(test-summary!)
