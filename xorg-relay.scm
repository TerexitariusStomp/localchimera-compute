#!/usr/bin/env -S guile
!#
;;; xorg-relay.scm — Mailbox relay for xorg
;;; Routes signed S-expressions by public key.
;;; Queues messages for offline recipients.
;;; Run with: guile xorg-relay.scm [port]

(use-modules (web socket server)
             (web socket frame)
             (ice-9 match)
             (ice-9 format)
             (ice-9 hash-table)
             (ice-9 threads)
             (rnrs bytevectors))

;; Sessions: pubkey-string → port
(define *sessions* (make-hash-table))

;; Mailboxes: pubkey-string → list of queued messages
(define *mailboxes* (make-hash-table))

(define (queue-message! target-pk msg)
  "Queue a message for an offline recipient."
  (let ((existing (hash-ref *mailboxes* target-pk '())))
    (hash-set! *mailboxes* target-pk (append existing (list msg)))))

(define (flush-mailbox! target-pk port)
  "Deliver all queued messages to a newly connected recipient."
  (let ((queued (hash-ref *mailboxes* target-pk '())))
    (for-each (lambda (msg)
                (write-frame (make-text-frame msg) port)
                (force-output port))
              queued)
    (when (not (null? queued))
      (format #t "  delivered ~a queued message(s) to ~a\n"
              (length queued) (truncate-pk target-pk))
      (force-output))
    (hash-set! *mailboxes* target-pk '())))

(define (truncate-pk pk-str)
  "Shorten a public key string for display."
  (if (> (string-length pk-str) 20)
      (string-append (substring pk-str 0 20) "...")
      pk-str))

(define (handle-client port)
  "Handle a WebSocket client connection."
  (define my-pk #f)
  (define (process-message text)
    (let ((msg (catch #t
                 (lambda () (call-with-input-string text read))
                 (lambda args #f))))
      (when msg
        (match msg
          ;; Register by public key
          (('register pk)
           (let ((pk-str (call-with-output-string (lambda (p) (write pk p)))))
             (set! my-pk pk-str)
             (hash-set! *sessions* pk-str port)
             (format #t "  + ~a\n" (truncate-pk pk-str))
             (force-output)
             ;; Deliver any queued messages
             (flush-mailbox! pk-str port)))

          ;; Route: (to <target-pk-str> payload)
          (('to (? string? target-pk) payload)
           (let ((target-port (hash-ref *sessions* target-pk)))
             (let ((fwd (call-with-output-string
                          (lambda (p) (write `(from ,my-pk ,payload) p)))))
               (if target-port
                   ;; Online — deliver immediately
                   (begin
                     (write-frame (make-text-frame fwd) target-port)
                     (force-output target-port))
                   ;; Offline — queue
                   (begin
                     (queue-message! target-pk fwd)
                     (format #t "  queued for ~a\n" (truncate-pk target-pk))
                     (force-output))))))

          ;; Unknown
          (x (format #t "  ? ~a\n" x)
             (force-output))))))

  ;; Main read loop
  (catch #t
    (lambda ()
      (let loop ()
        (let ((frame (read-frame port)))
          (when frame
            (cond
             ((text-frame? frame) (process-message (frame-text frame)))
             ((ping-frame? frame)
              (write-frame (make-pong-frame (frame-data frame)) port)
              (force-output port))
             ((close-frame? frame)
              (write-frame (make-close-frame #vu8()) port)
              (set! frame #f)))
            (when frame (loop))))))
    (lambda args #f))

  ;; Cleanup
  (when my-pk
    (hash-remove! *sessions* my-pk)
    (format #t "  - ~a\n" (truncate-pk my-pk))
    (force-output))
  (catch #t (lambda () (close-port port)) (lambda args #f)))

(define (main args)
  (let ((port (if (> (length args) 1)
                  (string->number (cadr args))
                  9090)))
    (format #t "\n  xorg relay on ws://localhost:~a\n\n" port)
    (force-output)
    (run-websocket-server
     handle-client
     #:server-socket (make-server-socket #:host "0.0.0.0" #:port port)
     #:max-clients 64
     #:spawn-client (lambda (thunk) (call-with-new-thread thunk)))))

(main (command-line))
