;;; module/xorg/gateway/terminal.scm — PTY sessions over OCapN
;;;
;;; Spawns login shells as provisioned Unix users and bridges
;;; stdin/stdout through Goblins actor messages.  The client holds
;;; a ^terminal-session ref for writing; output streams to the
;;; client's inbox via fire-and-forget <-np.
;;;
;;; Migrated from relay.scm open-pty-session! / write-to-pty! / close-pty-session!

(define-module (xorg gateway terminal)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (ice-9 format)
  #:use-module (ice-9 hash-table)
  #:use-module (ice-9 threads)
  #:use-module (rnrs bytevectors)
  #:export (^terminal-service))

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

;;; ── ^terminal-session ──────────────────────────────────────────────────────

(define (^terminal-session bcom pid to-child from-child username client-inbox)
  (define closed? #f)

  (define (cleanup!)
    (unless closed?
      (set! closed? #t)
      (catch #t (lambda () (close-port to-child)) (lambda args #f))
      (catch #t (lambda () (close-port from-child)) (lambda args #f))
      (catch #t (lambda () (kill pid SIGTERM)) (lambda args #f))
      (format (current-error-port)
              "  [term] closed shell for ~a (pid ~a)~%" username pid)))

  ;; Background reader: sends PTY output to client's inbox
  (call-with-new-thread
   (lambda ()
     (let ((buf (make-bytevector 4096)))
       (let loop ()
         (let ((n (catch #t
                    (lambda () (read! from-child buf))
                    (lambda args 0))))
           (when (and n (> n 0))
             (let ((data (utf8->string (bytevector-copy buf 0 n))))
               (catch #t
                 (lambda () (<-np client-inbox 'term-data data))
                 (lambda args #f))
               (loop))))))
     ;; Child exited or read error
     (cleanup!)
     (catch #t
       (lambda () (<-np client-inbox 'term-closed))
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

(define (^terminal-service _bcom signup-vat signup-agent)
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
                           username client-inbox))))))))))
