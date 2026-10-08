;;; module/playnet/gateway/terminal.scm — PTY sessions over OCapN
;;;
;;; Spawns login shells as provisioned Unix users and bridges
;;; stdin/stdout through Goblins actor messages.  The client holds
;;; a ^terminal-session ref for writing; output streams to the
;;; client's inbox via fire-and-forget <-np.
;;;
;;; Migrated from relay.scm open-pty-session! / write-to-pty! / close-pty-session!

(define-module (playnet gateway terminal)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 format)
  #:use-module (ice-9 hash-table)
  #:use-module (ice-9 iconv)
  #:use-module (ice-9 threads)
  #:use-module (rnrs bytevectors)
  #:export (^terminal-service ^terminal-session))

;;; ── Key-to-username mapping ────────────────────────────────────────────────

(define (load-key-user-map)
  "Build a hash table mapping SSH public key -> username from users.scm."
  (let ((table (make-hash-table)))
    (catch #t
      (lambda ()
        (let ((users (primitive-load "deploy/guix/users.scm")))
          (for-each (lambda (entry)
                      (hash-set! table (cdr entry) (car entry)))
                    users)))
      (lambda args #f))
    table))

;;; ── Reader threads ────────────────────────────────────────────────────────
;;; A thread made inside a Goblins turn inherits that turn's syscaller, so the
;;; `with-vat` it later ran believed it was still inside the spawn and failed
;;; against the spawn's merged transaction. A reader runs with the syscaller
;;; cleared: it is a foreign thread, and each send is a turn of its own.
(define current-syscaller (@@ (goblins core) current-syscaller))

(define (launch-reader! thunk)
  "Run THUNK on a new thread that is outside every turn."
  (call-with-new-thread
   (lambda () (parameterize ((current-syscaller #f)) (thunk)))))

;;; ── ^terminal-session ──────────────────────────────────────────────────────

(define (^terminal-session bcom pid to-child from-child username client-inbox vat)
  (define closed? #f)

  (define (cleanup!)
    (unless closed?
      (set! closed? #t)
      (catch #t (lambda () (close-port to-child)) (lambda args #f))
      (catch #t (lambda () (close-port from-child)) (lambda args #f))
      (catch #t (lambda () (kill pid SIGTERM)) (lambda args #f))
      (format (current-error-port)
              "  [term] closed shell for ~a (pid ~a)~%" username pid)))

  ;; Background reader: sends PTY output to client's inbox. It runs on a thread
  ;; of its own, so each send re-enters the session's VAT for its turn.
  (launch-reader!
   (lambda ()
     (let loop ()
       (let ((bv (catch #t
                   (lambda () (get-bytevector-some from-child))
                   (lambda args (format (current-error-port) "[term] read failed: ~s~%" args) the-eof-object))))
         (when (and (bytevector? bv) (> (bytevector-length bv) 0))
           (let ((data (bytevector->string bv "UTF-8" 'substitute)))
             (catch #t
               (lambda () (with-vat vat (<-np client-inbox 'term-data data)))
               (lambda args (format (current-error-port) "[term] send failed: ~s~%" args) #f))
             (loop)))))
     ;; Child exited or read error
     (cleanup!)
     (catch #t
       (lambda () (with-vat vat (<-np client-inbox 'term-closed)))
       (lambda args #f))))

  (methods
   ((write data)
    (unless closed?
      (display data to-child)
      (force-output to-child)))

   ((resize cols rows)
    ;; Future: ioctl for PTY resize
    #f)

   ((close)
    (cleanup!)
    (<-np client-inbox 'term-closed))))

;;; ── ^terminal-service ──────────────────────────────────────────────────────

(define (^terminal-service _bcom signup-vat signup-agent vat)
  ;; signup-vat + signup-agent: for looking up browser-key → username
  (define key-user-map (load-key-user-map))

  (define (lookup-username pk-str)
    "Find Unix username for a public key.  Checks users.scm first,
     then falls back to signup-agent's membership records."
    (or (hash-ref key-user-map pk-str)
        (catch #t
          (lambda ()
            (with-vat signup-vat
              ($ signup-agent 'lookup-username pk-str)))
          (lambda args #f))))

  (methods
   ((open identity-key client-inbox)
    (let ((username (lookup-username identity-key)))
      (if (not username)
          (list 'error "no account found for this key")
          ;; Fork a login shell as the target user
          (let* ((pipe-in  (pipe))
                 (pipe-out (pipe))
                 (pid (primitive-fork)))
            (if (= pid 0)
                ;; Child
                (begin
                  (close-port (cdr pipe-in))
                  (close-port (car pipe-out))
                  (dup2 (fileno (car pipe-in)) 0)
                  (dup2 (fileno (cdr pipe-out)) 1)
                  (dup2 (fileno (cdr pipe-out)) 2)
                  (close-port (car pipe-in))
                  (close-port (cdr pipe-out))
                  (execl "/usr/bin/env" "env" "sudo" "-u" username "-i"))
                ;; Parent
                (begin
                  (close-port (car pipe-in))
                  (close-port (cdr pipe-out))
                  (let ((to-child  (cdr pipe-in))
                        (from-child (car pipe-out)))
                    (format (current-error-port)
                            "  [term] opened shell for ~a (pid ~a)~%"
                            username pid)
                    (spawn ^terminal-session
                           pid to-child from-child
                           username client-inbox vat))))))))))
