#!/usr/bin/env -S guile
!#
;;; xorg-relay.scm — Mailbox relay for xorg
;;; Routes signed S-expressions by public key.
;;; Queues messages for offline recipients.

(use-modules (web socket server)
             (web socket frame)
             (ice-9 match)
             (ice-9 format)
             (ice-9 hash-table)
             (ice-9 threads)
             (rnrs bytevectors))

;; pubkey-string → port
(define *sessions* (make-hash-table))
;; pubkey-string → list of queued message strings
(define *mailboxes* (make-hash-table))
;; Lock for thread safety
(define *lock* (make-mutex))

(define (log! . args)
  (with-mutex *lock*
    (apply format (current-error-port) args)
    (force-output (current-error-port))))

(define (register-key! pk-str port)
  (with-mutex *lock*
    (hash-set! *sessions* pk-str port))
  ;; Deliver queued messages
  (let ((queued (with-mutex *lock* (hash-ref *mailboxes* pk-str '()))))
    (unless (null? queued)
      (for-each (lambda (msg)
                  (write-frame (make-text-frame msg) port)
                  (force-output port))
                queued)
      (with-mutex *lock*
        (hash-set! *mailboxes* pk-str '()))
      (log! "  delivered ~a queued msg(s)\n" (length queued)))))

(define (unregister-key! pk-str)
  (with-mutex *lock*
    (hash-remove! *sessions* pk-str)))

(define (route-message! sender-pk target-pk payload-str)
  (let ((target-port (with-mutex *lock* (hash-ref *sessions* target-pk))))
    (let ((fwd (call-with-output-string
                 (lambda (p) (write `(from ,sender-pk ,payload-str) p)))))
      (if target-port
          (begin
            (write-frame (make-text-frame fwd) target-port)
            (force-output target-port)
            (log! "  ~a -> online\n" (substring target-pk 0 (min 30 (string-length target-pk)))))
          (begin
            (with-mutex *lock*
              (let ((q (hash-ref *mailboxes* target-pk '())))
                (hash-set! *mailboxes* target-pk (append q (list fwd)))))
            (log! "  ~a -> queued\n" (substring target-pk 0 (min 30 (string-length target-pk)))))))))

(define (handle-client port)
  (define my-keys '())  ;; list of pubkey strings registered by this client

  (define (process-message text)
    (log! "  raw msg: ~a\n" (substring text 0 (min 100 (string-length text))))
    (let ((msg (catch #t
                 (lambda () (call-with-input-string text read))
                 (lambda args
                   (log! "  parse error: ~a\n" args)
                   #f))))
      (log! "  parsed: ~a\n" (if msg "ok" "FAILED"))
      (when msg
        (match msg
          ;; Register multiple keys: (register-keys (pk1 pk2 ...))
          (('register-keys keys)
           (let ((pk-strs (map (lambda (k)
                                 (call-with-output-string (lambda (p) (write k p))))
                               keys)))
             (set! my-keys pk-strs)
             (for-each (lambda (pk-str) (register-key! pk-str port)) pk-strs)
             (log! "  + ~a key(s) registered\n" (length pk-strs))))

          ;; Route: (to <target-pk-str> payload)
          (('to target-pk payload)
           (let ((sender-pk (if (null? my-keys) "unknown" (car my-keys))))
             (route-message! sender-pk target-pk payload)))

          ;; Unknown
          (x (log! "  ? ~a\n" x))))))

  ;; Read loop
  (log! "  client connected\n")
  (catch #t
    (lambda ()
      (let loop ()
        (let ((frame (read-frame port)))
          (when frame
            (let ((keep-going #t))
              (catch #t
                (lambda ()
                  (log! "  frame type: ~a data-len: ~a\n"
                        (cond ((text-frame? frame) "text")
                              ((binary-frame? frame) "binary")
                              ((ping-frame? frame) "ping")
                              ((close-frame? frame) "close")
                              (else "unknown"))
                        (bytevector-length (frame-data frame)))
                  (cond
                   ((or (text-frame? frame) (binary-frame? frame))
                    (let ((text (utf8->string (frame-data frame))))
                      (log! "  msg: ~a\n" (substring text 0 (min 80 (string-length text))))
                      (process-message text)))
                   ((ping-frame? frame)
                    (write-frame (make-pong-frame (frame-data frame)) port)
                    (force-output port))
                   ((close-frame? frame)
                    (write-frame (make-close-frame #vu8()) port)
                    (set! keep-going #f))))
                (lambda args
                  (log! "  FRAME ERROR: ~a\n" args)))
              (when keep-going (loop)))))))
    (lambda args #f))

  ;; Cleanup
  (for-each unregister-key! my-keys)
  (log! "  client disconnected (~a keys)\n" (length my-keys))
  (catch #t (lambda () (close-port port)) (lambda args #f)))

(define (main args)
  (let ((port (if (> (length args) 1)
                  (string->number (cadr args))
                  9090)))
    (log! "\n  xorg relay on ws://localhost:~a\n\n" port)
    (run-websocket-server
     handle-client
     #:server-socket (make-server-socket #:host "0.0.0.0" #:port port)
     #:max-clients 64
     #:spawn-client (lambda (thunk) (call-with-new-thread thunk)))))

(main (command-line))
