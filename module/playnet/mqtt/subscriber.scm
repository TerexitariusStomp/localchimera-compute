;;; module/playnet/mqtt/subscriber.scm — shared MQTT subscription loop
;;;
;;; Extracts the pattern shared by dev-bridge.scm, fleet-bridge.scm,
;;; and deploy-runner.scm: subscribe to a Mosquitto topic via
;;; mosquitto_sub, parse lines, dispatch to a handler. Handles
;;; reconnection on EOF, topic/payload splitting, and JSON parsing.
;;;
;;; Usage:
;;;
;;;   (use-modules (playnet mqtt subscriber))
;;;
;;;   (mqtt-subscribe
;;;     #:host "localhost"
;;;     #:port 1883
;;;     #:topic "playnet/signals/deficit/#"
;;;     #:handler (lambda (topic payload-json)
;;;                 (when (my-filter? payload-json)
;;;                   (do-something!)))
;;;     #:verbose? #t)    ; -v flag: lines are "topic payload"
;;;
;;; The handler receives the topic string and the raw payload string.
;;; JSON parsing is the handler's responsibility (use parse-signal-json
;;; if you want the standard catch-on-failure pattern).

(define-module (playnet mqtt subscriber)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 format)
  #:use-module (json)
  #:export (mqtt-subscribe
            parse-signal-json
            make-cooldown))

(define* (mqtt-subscribe #:key
                         (host "localhost")
                         (port 1883)
                         topic
                         handler
                         (verbose? #t)
                         (reconnect-delay 5)
                         (log-prefix "[mqtt]")
                         (username #f)
                         (password-file #f))
  "Subscribe to TOPIC on a Mosquitto broker and call HANDLER for each
message. HANDLER receives (topic-string payload-string) when verbose?
is #t, or just (payload-string) when #f. Reconnects on EOF after
RECONNECT-DELAY seconds. This procedure never returns.

USERNAME and PASSWORD-FILE are for authenticated Mosquitto brokers.
The password is read from the file (not from memory) to avoid
exposure in process args."
  (define (read-password)
    (and password-file (file-exists? password-file)
         (call-with-input-file password-file
           (lambda (port) (string-trim-both (read-line port))))))
  (format #t "~a subscribing to ~a on ~a:~a~a~%"
          log-prefix topic host port
          (if username (format #f " (user: ~a)" username) ""))
  (let loop ()
    (let* ((pw (read-password))
           (auth-args (if (and username pw)
                          (list "-u" username "-P" pw)
                          '()))
           (pipe (apply open-pipe*
                        OPEN_READ
                        "mosquitto_sub"
                        "-h" host
                        "-p" (number->string port)
                        "-t" topic
                        (append (if verbose? '("-v") '())
                                auth-args))))
      (let read-loop ()
        (let ((line (read-line pipe)))
          (cond
           ((eof-object? line)
            (format #t "~a mosquitto_sub EOF, reconnecting in ~as~%"
                    log-prefix reconnect-delay)
            (close-pipe pipe)
            (sleep reconnect-delay)
            (loop))
           (else
            (if verbose?
                ;; Line format: "topic payload"
                (let ((sp (string-index line #\space)))
                  (when sp
                    (handler (substring line 0 sp)
                             (substring line (+ sp 1)))))
                ;; Raw payload only
                (handler #f line))
            (read-loop))))))))

(define (parse-signal-json json-str)
  "Parse a JSON string into an alist. Returns #f on failure."
  (catch #t
    (lambda () (json-string->scm json-str))
    (lambda _ #f)))

(define* (make-cooldown #:key (seconds 300))
  "Return a pair of procedures: (cooldown-ok? record-use!).
cooldown-ok? returns #t if at least SECONDS have elapsed since the
last record-use! call."
  (let ((last-epoch 0))
    (values
     (lambda ()
       (> (- (car (gettimeofday)) last-epoch) seconds))
     (lambda ()
       (set! last-epoch (car (gettimeofday)))))))
