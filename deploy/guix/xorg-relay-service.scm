;;; deploy/guix/playnet-relay-service.scm — Shepherd service for the playnet relay
;;;
;;; Runs the WebSocket relay from the playnet Guix package (immutable store).
;;; Handles message routing, signup, transcription, and terminal sessions.
;;;
;;; Usage in machines.scm:
;;;   (service playnet-relay-service-type
;;;            (playnet-relay-configuration
;;;             (package playnet)
;;;             (port 9090)))

(define-module (playnet-relay-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (playnet-relay-configuration
            playnet-relay-configuration?
            playnet-relay-configuration-package
            playnet-relay-configuration-port
            playnet-relay-configuration-user
            playnet-relay-configuration-environment
            playnet-relay-service-type))

;;; ── Configuration record ───────────────────────────────────────────────────

(define-record-type* <playnet-relay-configuration>
  playnet-relay-configuration make-playnet-relay-configuration
  playnet-relay-configuration?
  ;; The playnet Guix package (provides bin/playnet-relay)
  (package playnet-relay-configuration-package)
  ;; WebSocket listen port
  (port    playnet-relay-configuration-port    (default 9090))
  ;; User to run as
  (user    playnet-relay-configuration-user    (default "playnet"))
  ;; Environment variables (alist of string . string pairs)
  (environment playnet-relay-configuration-environment (default '())))

;;; ── Shepherd service definition ────────────────────────────────────────────

(define (playnet-relay-shepherd-service config)
  (let ((package (playnet-relay-configuration-package config))
        (port    (playnet-relay-configuration-port config))
        (user    (playnet-relay-configuration-user config))
        (env     (playnet-relay-configuration-environment config)))
    (list
     (shepherd-service
      (provision '(playnet-relay))
      (documentation "playnet WebSocket relay — message routing, signup, terminal sessions")
      (requirement '(networking user-processes))
      (start
       #~(make-forkexec-constructor
          (list (string-append #$package "/bin/playnet-relay")
                #$(number->string port))
          #:user #$user
          #:directory (string-append #$package "/share/playnet")
          #:environment-variables
          (append
           (list (string-append "HOME=/var/lib/" #$user))
           (list #$@(map (lambda (kv)
                           #~(string-append #$(car kv) "=" #$(cdr kv)))
                         env)))
          #:log-file "/var/log/playnet-relay.log"))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

;;; ── Service type ───────────────────────────────────────────────────────────

(define playnet-relay-service-type
  (service-type
   (name 'playnet-relay)
   (extensions
    (list (service-extension shepherd-root-service-type
                             playnet-relay-shepherd-service)))
   (description "Run the playnet WebSocket relay as a Shepherd service.")))
