;;; module/playnet/mqtt/publish.scm — shared MQTT publish helper
;;;
;;; The publish-side sibling to (playnet mqtt subscriber)'s mqtt-subscribe:
;;; reads a Mosquitto service user's password from its 0600 credential file
;;; the same way (deploy/os.scm's activation snippet writes one per service
;;; to /var/lib/playnet/mosquitto/pw-<user>.txt) and shells out to
;;; mosquitto_pub. Used by server/dev-bridge.scm (its own alerts, as the
;;; read-only "dev-bridge" user — that ACL grants it a narrow
;;; playnet/alerts/dev-bridge write, see deploy/os.scm) and by
;;; tools/dev-signal-cycle.scm + tools/dev-loop-close.scm (as "publisher",
;;; whose ACL already grants `topic write playnet/signals/#`).

(define-module (playnet mqtt publish)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:export (mqtt-publish! mqtt-password-file))

(define (mqtt-password-file user . cred-dir)
  (string-append (if (pair? cred-dir) (car cred-dir) "/var/lib/playnet/mosquitto")
                 "/pw-" user ".txt"))

(define (read-mqtt-password password-file)
  (and password-file (file-exists? password-file)
       (call-with-input-file password-file
         (lambda (port) (string-trim-both (read-line port))))))

(define* (mqtt-publish! #:key
                        (host "localhost")
                        (port 1883)
                        topic
                        message
                        (username #f)
                        (password-file #f)
                        (retain? #f))
  "Publish MESSAGE (a string) to TOPIC via mosquitto_pub. Returns the
   process's real exit code (status:exit-val, not the raw wait status — an
   easy, real bug: system*/waitpid's raw status is not the exit code).
   USERNAME/PASSWORD-FILE mirror mqtt-subscribe's: an absent or unreadable
   password-file falls back to an anonymous publish rather than erroring,
   since a local/workstation broker with no auth configured is a real,
   valid deployment shape too. RETAIN? sets the MQTT retained flag — the
   broker keeps the last message on the topic, so a later subscriber reads
   the freshest snapshot immediately (the natural shape for a periodic
   reading like tools/host-facts.scm --publish)."
  (let* ((pw (read-mqtt-password password-file))
         (auth-args (if (and username pw) (list "-u" username "-P" pw) '()))
         (argv (append (list "-h" host "-p" (number->string port))
                       auth-args
                       (if retain? (list "-r") '())
                       (list "-t" topic "-m" message))))
    (status:exit-val (apply system* "mosquitto_pub" argv))))
