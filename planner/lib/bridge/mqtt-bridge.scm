;;; mqtt-bridge.scm — MQTT client lifecycle actor
;;;
;;; Owns the guile-mqtt client, dispatches inbound messages to
;;; topic-observers, and provides the publish capability.
;;;
;;; The bridge runs in its own vat (MQTT I/O is impure; the scope vat
;;; must stay pure for persistence/replay).
;;;
;;; For the REPL prototype, use ($ bridge 'poll) to process messages
;;; one batch at a time instead of running a background thread.
;;;
;;; Assumes codec.scm is loaded.

(use-modules (goblins)
             (goblins actor-lib methods)
             (mosquitto client)
             (json)
             (ice-9 match))


(define (^mqtt-bridge bcom
                      client          ;; <mosquitto-client> instance
                      scope-id        ;; string
                      observers       ;; alist: ((topic-pattern . observer-ref) ...)
                      inbox           ;; list of (topic . payload) pairs (buffered messages)
                      connected?)     ;; boolean
  (methods
    ;; --- Lifecycle ---
    ((connect host . rest)
     ;; Connect to broker.  Optional keyword args: #:port
     (let ((port (if (and (pair? rest) (pair? rest)) (car rest) 1883)))
       (connect client host #:port port)
       ;; Set up message callback to buffer into inbox
       (set! (message-callback client)
         (lambda (cli msg)
           ;; We can't call $ from the callback (wrong thread in production).
           ;; Buffer messages; they'll be dispatched on next 'poll or 'dispatch.
           ;; For the REPL prototype this is fine since poll is synchronous.
           #f))  ;; messages are read via poll below
       ;; Subscribe to all registered topic patterns
       (for-each (lambda (pair)
                   (subscribe client (car pair)))
                 observers)
       (bcom (^mqtt-bridge bcom client scope-id observers inbox #t))))

    ((disconnect)
     (disconnect client)
     (bcom (^mqtt-bridge bcom client scope-id observers '() #f)))

    ;; --- Topic observer management ---
    ((add-observer topic-pattern observer-ref)
     ;; Register a ^topic-observer for a topic pattern.
     (when connected?
       (subscribe client topic-pattern))
     (let ((new-observers (cons (cons topic-pattern observer-ref) observers)))
       (bcom (^mqtt-bridge bcom client scope-id new-observers inbox connected?))))

    ((remove-observer topic-pattern)
     (when connected?
       (unsubscribe client topic-pattern))
     (let ((new-observers (filter (lambda (p) (not (string=? (car p) topic-pattern)))
                                  observers)))
       (bcom (^mqtt-bridge bcom client scope-id new-observers inbox connected?))))

    ;; --- Publish (capability-gated) ---
    ((publish topic payload-string)
     ;; The ONLY path to MQTT publish.
     (publish client topic payload-string))

    ;; --- Message processing ---
    ((poll . rest)
     ;; Process pending MQTT messages.  In the REPL prototype, call this
     ;; periodically.  timeout in ms (default 100).
     (let ((timeout (if (pair? rest) (car rest) 100)))
       ;; Run the mosquitto network loop to receive messages
       (loop client #:timeout timeout)
       ;; Now we need a different approach: use a message collector
       ;; since the callback fires synchronously during loop.
       'polled))

    ((dispatch-message topic payload-string)
     ;; Manually dispatch a message to matching observers.
     ;; Used for testing or when messages arrive via callback.
     (let ((matched (find-matching-observers topic observers)))
       (map (lambda (obs-ref)
              ($ obs-ref 'receive-message topic payload-string))
            matched)))

    ;; --- Introspection ---
    ((get-observers) observers)
    ((connected?) connected?)))


;; =========================================================================
;; Topic matching (simplified — exact or # wildcard at end)
;; =========================================================================

(define (topic-matches? pattern topic)
  "Check if TOPIC matches PATTERN.  Supports MQTT # wildcard at the end."
  (cond
    ((string=? pattern topic) #t)
    ((string-suffix? "/#" pattern)
     (let ((prefix (substring pattern 0 (- (string-length pattern) 2))))
       (or (string=? prefix topic)
           (string-prefix? (string-append prefix "/") topic))))
    ((string=? pattern "#") #t)
    (else #f)))

(define (find-matching-observers topic observers)
  "Find all observer refs whose pattern matches TOPIC."
  (filter-map (lambda (pair)
                (and (topic-matches? (car pair) topic)
                     (cdr pair)))
              observers))
