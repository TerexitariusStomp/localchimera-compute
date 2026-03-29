#!/usr/bin/env -S guile
!#
;;; xorg-relay.scm — Mailbox relay for xorg
;;; Routes signed S-expressions by public key.
;;; Queues messages for offline recipients.
;;;
;;; Also handles (signup username email ssh-pubkey) requests via
;;; ^signup-agent. Run from project root so primitive-load paths resolve.

(use-modules (web socket server)
             (web socket frame)
             (ice-9 match)
             (ice-9 format)
             (ice-9 hash-table)
             (ice-9 threads)
             (rnrs bytevectors)
             (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap))

;; Load ^signup-agent definition (must run from project root)
(primitive-load "server/signup-agent.scm")

;; Spawn a dedicated vat + signup-agent for account registration
(define *signup-vat*   (spawn-vat #:name "signup"))
(define *signup-agent* (with-vat *signup-vat* (spawn ^signup-agent (hashmap))))

;;; ── Key-pool transcription ─────────────────────────────────────────────────
;;; Donated OpenRouter keys fund community transcription via Gemini Flash.
;;; The key-pool handles round-robin, rate limiting, and health tracking.
;;; Each donor is an agent; each pool is a scope; usage is tracked as cost.

(add-to-load-path "key-pool")
(use-modules (key-pool)
             (json))

(define *pool-vat* (spawn-vat #:name "key-pool"))
(define *key-pool*
  (let ((keys-env (or (getenv "OPENROUTER_KEYS") "")))
    (if (string=? keys-env "")
        (begin
          (format (current-error-port)
                  "  [key-pool] No OPENROUTER_KEYS set — transcription disabled\n")
          #f)
        (with-vat *pool-vat*
          (let ((pool (make-key-pool *pool-vat* keys-env)))
            (format (current-error-port)
                    "  [key-pool] Loaded — community transcription enabled\n")
            pool)))))

(define (transcribe-audio! base64-audio)
  "Send base64 audio to Gemini Flash via key-pool for transcription.
   Returns the transcript string or raises an error."
  (unless *key-pool*
    (error "transcription not available — no API keys configured"))
  (let* ((body (scm->json-string
                `((model . "google/gemini-2.0-flash-001")
                  (messages . #(((role . "user")
                                 (content . #(((type . "text")
                                               (text . "Transcribe this audio exactly, word for word. Return only the transcript text, nothing else."))
                                              ((type . "image_url")
                                               (image_url . ((url . ,(string-append
                                                                      "data:audio/webm;base64,"
                                                                      base64-audio))))))))))))))
         (response-str (with-vat *pool-vat*
                         ($ *key-pool* 'request "/chat/completions" body)))
         (json (json-string->scm response-str))
         (choices (assoc-ref json "choices")))
    (if (and choices (> (vector-length choices) 0))
        (let* ((choice (vector-ref choices 0))
               (message (assoc-ref choice "message"))
               (content (assoc-ref message "content")))
          (or content ""))
        (error "transcription returned no choices"))))

;; pubkey-string → port
(define *sessions* (make-hash-table))
;; pubkey-string → list of queued message strings
(define *mailboxes* (make-hash-table))
;; pubkey-string → display name (set via announce)
(define *presence* (make-hash-table))
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
    (hash-remove! *sessions* pk-str)
    (hash-remove! *presence* pk-str)))

(define (get-online-users)
  "Return list of (name . pubkey-prefix) for all connected users with names."
  (with-mutex *lock*
    (hash-fold (lambda (pk name acc)
                 (if (hash-ref *sessions* pk)
                     (cons (list name (substring pk 0 (min 20 (string-length pk))))
                           acc)
                     acc))
               '() *presence*)))

(define (broadcast! msg-sexp)
  "Send a message to all connected sessions."
  (let ((text (call-with-output-string (lambda (p) (write msg-sexp p)))))
    (with-mutex *lock*
      (hash-for-each
       (lambda (pk port)
         (catch #t
           (lambda ()
             (write-frame (make-text-frame text) port)
             (force-output port))
           (lambda args #f)))  ;; ignore send errors
       *sessions*))))

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

          ;; Announce: set display name for this session
          (('announce (? string? name))
           (unless (null? my-keys)
             (with-mutex *lock*
               (hash-set! *presence* (car my-keys) name))
             (log! "  announce: ~a\n" name)
             (broadcast! `(presence ,(get-online-users)))))

          ;; Who: list connected users
          (('who)
           (let* ((users (get-online-users))
                  (reply (call-with-output-string
                           (lambda (p) (write `(who-list ,users) p)))))
             (write-frame (make-text-frame reply) port)
             (force-output port)
             (log! "  who: ~a users\n" (length users))))

          ;; Route: (to <target-pk-str> payload)
          (('to target-pk payload)
           (let ((sender-pk (if (null? my-keys) "unknown" (car my-keys))))
             (route-message! sender-pk target-pk payload)))

          ;; Signup request: (signup username email ssh-pubkey)
          ;; Replies directly to this client: (signup-ok) or (signup-error msg)
          (('signup (? string? username) (? string? email) (? string? ssh-pubkey))
           (log! "  signup request from ~a for username=~a\n"
                 (if (null? my-keys) "unknown" (substring (car my-keys) 0 (min 20 (string-length (car my-keys)))))
                 username)
           (let* ((result (with-vat *signup-vat*
                            ($ *signup-agent* 'register! username email ssh-pubkey)))
                  (reply  (call-with-output-string
                            (lambda (p)
                              (write (if (eq? result 'ok)
                                         '(signup-ok)
                                         (list 'signup-error (cadr result)))
                                     p)))))
             (write-frame (make-text-frame reply) port)
             (force-output port)
             (log! "  signup result: ~a\n" (if (eq? result 'ok) "ok" (cadr result)))))

          ;; Transcribe request: (transcribe base64-audio-string)
          ;; Uses donated OpenRouter keys via key-pool → Gemini Flash.
          ;; Replies: (transcribe-ok "transcript") or (transcribe-error "reason")
          (('transcribe (? string? audio-b64))
           (log! "  transcribe request (~a bytes b64)\n" (string-length audio-b64))
           (let* ((result (catch #t
                            (lambda () (transcribe-audio! audio-b64))
                            (lambda (key . args)
                              (list 'error (format #f "~a: ~a" key args)))))
                  (reply  (call-with-output-string
                            (lambda (p)
                              (write (if (string? result)
                                         (list 'transcribe-ok result)
                                         (list 'transcribe-error (cadr result)))
                                     p)))))
             (write-frame (make-text-frame reply) port)
             (force-output port)
             (log! "  transcribe result: ~a\n"
                   (if (string? result)
                       (substring result 0 (min 50 (string-length result)))
                       (cadr result)))))

          ;; Express: convert natural language to a Scheme S-expression
          ;; Uses donated key-pool → Gemini Flash. Returns the expression
          ;; as a string for the user to review before evaluating.
          (('express (? string? nl-text))
           (log! "  express request: ~a\n" (substring nl-text 0 (min 60 (string-length nl-text))))
           (let* ((result
                   (catch #t
                     (lambda ()
                       (unless *key-pool*
                         (error "express not available — no API keys"))
                       (let* ((body (scm->json-string
                                     `((model . "google/gemini-2.0-flash-001")
                                       (messages
                                        . #(((role . "system")
                                             (content . "You are inside xorg, a Scheme-based programmable organization. Convert the user's natural language into a single valid Scheme S-expression. Respond with ONLY the raw S-expression, no markdown, no explanation, no code fences. Use (modify! 'name value) for bindings, (define name value) for definitions, (lambda (args) body) for functions."))
                                            ((role . "user")
                                             (content . ,nl-text)))))))
                              (resp (with-vat *pool-vat*
                                      ($ *key-pool* 'request "/chat/completions" body)))
                              (json (json-string->scm resp))
                              (choices (assoc-ref json "choices")))
                         (if (and choices (> (vector-length choices) 0))
                             (let ((content (assoc-ref
                                            (assoc-ref (vector-ref choices 0) "message")
                                            "content")))
                               (or content ""))
                             (error "no choices in response"))))
                     (lambda (key . args)
                       (list 'error (format #f "~a: ~a" key args)))))
                  (reply (call-with-output-string
                           (lambda (p)
                             (write (if (string? result)
                                        (list 'express-ok result)
                                        (list 'express-error (cadr result)))
                                    p)))))
             (write-frame (make-text-frame reply) port)
             (force-output port)
             (log! "  express result: ~a\n"
                   (if (string? result)
                       (substring result 0 (min 60 (string-length result)))
                       (cadr result)))))

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
  (catch #t (lambda () (close-port port)) (lambda args #f))
  ;; Broadcast updated presence after disconnect
  (broadcast! `(presence ,(get-online-users))))

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
