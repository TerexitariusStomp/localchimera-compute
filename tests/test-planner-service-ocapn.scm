;;; test-planner-service-ocapn.scm — wire-format integration test
;;;
;;; This is the highest-confidence integration test for the calendar's
;;; server-side: it spawns a real gateway with the planner, then opens
;;; a separate OCapN client process, enlivens the lobby across a real
;;; WebSocket, fetches the planner cap, and exercises scope-list and
;;; scope-snapshot. Catches any wire-format issue (symbol round-trip,
;;; alist serialization, syrup encoding) that the in-process test in
;;; test-planner-service.scm cannot.
;;;
;;; This test requires PLAYNET_DATA_DIR to be writable; defaults to
;;; /tmp/playnet-test if unset.
;;;
;;; Run from project root:
;;;   guile -L module -L key-pool tests/test-planner-service-ocapn.scm

(use-modules (fibers)
             (fibers conditions)
             (goblins)
             (goblins ocapn ids)
             (goblins ocapn captp)
             (goblins ocapn netlayer websocket)
             (goblins utils crypto)
             (ice-9 textual-ports)
             (ice-9 popen)
             (ice-9 rdelim))

(define %project-root (string-append (dirname (current-filename)) "/.."))
(chdir %project-root)

(define %data-dir
  (or (getenv "PLAYNET_DATA_DIR") "/tmp/playnet-test-ocapn"))
(setenv "PLAYNET_DATA_DIR" %data-dir)
(unless (file-exists? %data-dir) (mkdir %data-dir))

(define %sref-path (string-append %data-dir "/gateway-sref.txt"))
;; Force fresh sref so we don't read a stale one from a previous run.
(when (file-exists? %sref-path) (delete-file %sref-path))

(define %port 19191)


;;; ── Boot the gateway in a child process ───────────────────────────────────

(display "Booting gateway in background...\n")
(force-output)

(define gateway-pid
  (let ((pid (primitive-fork)))
    (cond
      ((zero? pid)
       ;; Child: replace with the gateway process
       (execlp "guile" "guile" "-L" "module" "-L" "key-pool"
               "server/gateway.scm" "--port" (number->string %port)))
      (else pid))))

;; Wait for the sref file to appear (gateway has finished booting)
(define (wait-for-sref deadline)
  (cond
    ((file-exists? %sref-path)
     (string-trim-right
       (call-with-input-file %sref-path get-string-all)
       #\newline))
    ((<= deadline 0)
     (kill gateway-pid 15)
     (error "gateway never wrote sref file"))
    (else
     (sleep 1)
     (wait-for-sref (- deadline 1)))))

(define sref-uri (wait-for-sref 15))
(display (string-append "gateway up; sref: " sref-uri "\n"))
(force-output)


;;; ── Harness ────────────────────────────────────────────────────────────────

(define pass-count 0)
(define fail-count 0)
(define (check label got expected)
  (if (equal? got expected)
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")) (force-output))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n"))
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write got) (newline)
             (force-output))))
(define (check-pred label pred)
  (if pred
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")) (force-output))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n")) (force-output))))


;;; ── Run the OCapN client ──────────────────────────────────────────────────

(define exit-code 1)

(catch #t
  (lambda ()
    (run-fibers
      (lambda ()
        (define dk (generate-key-pair))
        (define vat (spawn-vat #:name "client"))
        (define netlayer
          (with-vat vat
            (spawn ^websocket-netlayer
                   #:host "127.0.0.1" #:port 0
                   #:encrypted? #f
                   #:designator-key dk
                   #:max-peers 16)))
        (define mycapn (with-vat vat (spawn-mycapn netlayer)))
        (define done (make-condition))

        (with-vat vat
          (on (<- mycapn 'enliven (string->ocapn-id sref-uri))
              (lambda (lobby)
                (check-pred "enlivened lobby" lobby)
                (on (<- lobby 'planner)
                    (lambda (planner)
                      (check-pred "fetched planner cap" planner)
                      (on (<- planner 'scope-list)
                          (lambda (scopes)
                            (check "scope-list returns one entry"
                                   (length scopes) 1)
                            (check "scope id is org:meeting"
                                   (assq-ref (car scopes) 'id) "org:meeting")
                            (on (<- planner 'scope-snapshot "org:meeting" "plan-meeting")
                                (lambda (snap)
                                  (check "snapshot scope-id"
                                         (assq-ref snap 'scope-id) "org:meeting")
                                  (check "snapshot scope-name"
                                         (assq-ref snap 'scope-name) "Meeting Commune")
                                  (let ((intents (assq-ref snap 'intents)))
                                    (check-pred "intents are a list" (list? intents))
                                    (check-pred "intents non-empty" (pair? intents))
                                    (when (pair? intents)
                                      (let ((it (car intents)))
                                        (check-pred "intent has match-status field"
                                                    (assq 'match-status it))
                                        (check-pred "intent date is a string"
                                                    (string? (assq-ref it 'date))))))
                                  (signal-condition! done))
                                #:catch (lambda (err)
                                          (display "snapshot ERR: ")
                                          (write err) (newline) (force-output)
                                          (signal-condition! done))))
                          #:catch (lambda (err)
                                    (display "scope-list ERR: ")
                                    (write err) (newline) (force-output)
                                    (signal-condition! done))))
                    #:catch (lambda (err)
                              (display "planner cap ERR: ")
                              (write err) (newline) (force-output)
                              (signal-condition! done))))
              #:catch (lambda (err)
                        (display "enliven ERR: ")
                        (write err) (newline) (force-output)
                        (signal-condition! done))))

        (wait done)
        (newline)
        (display (string-append "══ OCapN integration: "
                                (number->string pass-count) " passed, "
                                (number->string fail-count) " failed ══\n"))
        (force-output)
        (set! exit-code (if (> fail-count 0) 1 0)))))
  (lambda (key . args)
    (display "TEST CRASHED: ") (write (cons key args)) (newline)
    (force-output)))


;;; ── Cleanup ───────────────────────────────────────────────────────────────

(kill gateway-pid 15)
(catch 'system-error
  (lambda () (waitpid gateway-pid))
  (lambda args #f))
(exit exit-code)
