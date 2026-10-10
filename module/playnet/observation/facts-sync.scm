;;; facts-sync.scm — retained host snapshots → the scope's live-registry
;;;
;;; The consumer half of the host-facts loop. tools/dev/host-facts.scm
;;; --publish (on deploy/os.scm's five-minute mcron timer) leaves each
;;; host's reading as a RETAINED message on playnet/facts/host/<hostname>;
;;; this module subscribes that subtree and lands every snapshot in a
;;; scope's live-registry via sync-host-facts!, so the registry the live
;;; solve reads (plan-scope threads it as #:live-avail) tracks the
;;; machines' real free capacity. Retention means the freshest reading
;;; arrives the moment the subscription opens — a gateway restart is
;;; current before the next timer tick.
;;;
;;; The subscription runs in its own OS thread (mqtt-subscribe blocks,
;;; reconnects on EOF, never returns) and crosses into the scope's vat
;;; with with-vat per message — the same thread→vat pattern the gateway
;;; already uses for its other background work. The payload is the facts
;;; sexp read with `read` — safe here because the topic is write-ACL'd
;;; to the host-facts mosquitto user alone, and `read` evaluates nothing.
;;;
;;; The scope is resolved LAZILY, per message, inside the vat: the
;;; gateway boots its communes after its vats, and a resolver returning
;;; #f simply skips the snapshot until the steward scope is up.

(define-module (playnet observation facts-sync)
  #:use-module (playnet observation host-facts)
  #:use-module (playnet mqtt subscriber)
  #:use-module (playnet mqtt publish)      ; mqtt-password-file
  #:use-module (goblins)
  #:use-module (ice-9 threads)
  #:export (start-host-facts-sync! handle-snapshot!))

(define* (handle-snapshot! vat resolve-scope msg-topic payload
                           #:key (log-prefix "[host-facts-sync]"))
  "One snapshot, end to end: parse PAYLOAD as a facts sexp, resolve the
   steward scope inside VAT, sync. Returns 'synced, 'no-scope, or
   'unreadable — the subscriber loop discards the value; tests read it."
  (catch #t
    (lambda ()
      (let ((facts (call-with-input-string payload read)))
        (if (and (pair? facts) (assq-ref facts 'host))
            (with-vat vat
              (let ((scope (resolve-scope)))
                (if scope
                    (begin
                      (sync-host-facts! scope facts)
                      (format #t "~a synced ~a (~a services)~%"
                              log-prefix (assq-ref facts 'host)
                              (length (or (assq-ref facts 'services) '())))
                      'synced)
                    (begin
                      (format #t "~a steward scope not up yet — snapshot from ~a held for the next reading~%"
                              log-prefix msg-topic)
                      'no-scope))))
            (begin
              (format (current-error-port)
                      "~a unreadable snapshot on ~a (not a facts alist)~%"
                      log-prefix msg-topic)
              'unreadable))))
    (lambda (key . args)
      (format (current-error-port) "~a sync failed on ~a: ~a ~s~%"
              log-prefix msg-topic key args)
      'unreadable)))

(define* (start-host-facts-sync! vat resolve-scope
                                 #:key
                                 (host "localhost")
                                 (port 1883)
                                 (topic "playnet/facts/host/#")
                                 (username "gateway")
                                 (password-file (mqtt-password-file "gateway"))
                                 (log-prefix "[host-facts-sync]"))
  "Subscribe to the host snapshot subtree and sync each reading into the
   scope RESOLVE-SCOPE returns. RESOLVE-SCOPE is a thunk called inside
   VAT per message; #f skips the snapshot (steward scope not up yet).
   Returns the subscriber thread."
  (call-with-new-thread
   (lambda ()
     ;; a long-running process's stdout is fully buffered once it's not
     ;; a tty (a shepherd log-file redirect), and this thread's own line
     ;; volume is thin — a handful of syncs a day next to the gateway's
     ;; constant KERI chatter on the main thread. Without this, its
     ;; lines can sit unflushed for a very long time (the exact bug
     ;; dev-bridge.scm hit before its own setvbuf fix; proven here: a
     ;; standalone run of this same thunk showed both lines immediately
     ;; because THAT process exited and flushed at exit, where the
     ;; gateway never does).
     (setvbuf (current-output-port) 'line)
     (mqtt-subscribe
      #:host host #:port port #:topic topic
      #:username username #:password-file password-file
      #:log-prefix log-prefix
      #:handler
      (lambda (msg-topic payload)
        (handle-snapshot! vat resolve-scope msg-topic payload
                          #:log-prefix log-prefix))))))
