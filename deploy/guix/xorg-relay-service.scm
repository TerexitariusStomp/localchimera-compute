;;; deploy/guix/xorg-relay-service.scm — Shepherd service for the xorg relay
;;;
;;; Runs the WebSocket relay from the xorg Guix package (immutable store).
;;; Handles message routing, signup, transcription, and terminal sessions.
;;;
;;; Usage in machines.scm:
;;;   (service xorg-relay-service-type
;;;            (xorg-relay-configuration
;;;             (package xorg)
;;;             (port 9090)))

(define-module (xorg-relay-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (xorg-relay-configuration
            xorg-relay-configuration?
            xorg-relay-configuration-package
            xorg-relay-configuration-port
            xorg-relay-configuration-user
            xorg-relay-configuration-environment
            xorg-relay-service-type))

;;; ── Configuration record ───────────────────────────────────────────────────

(define-record-type* <xorg-relay-configuration>
  xorg-relay-configuration make-xorg-relay-configuration
  xorg-relay-configuration?
  ;; The xorg Guix package (provides bin/xorg-relay)
  (package xorg-relay-configuration-package)
  ;; WebSocket listen port
  (port    xorg-relay-configuration-port    (default 9090))
  ;; User to run as
  (user    xorg-relay-configuration-user    (default "xorg"))
  ;; Environment variables (alist of string . string pairs)
  (environment xorg-relay-configuration-environment (default '())))

;;; ── Shepherd service definition ────────────────────────────────────────────

(define (xorg-relay-shepherd-service config)
  (let ((package (xorg-relay-configuration-package config))
        (port    (xorg-relay-configuration-port config))
        (user    (xorg-relay-configuration-user config))
        (env     (xorg-relay-configuration-environment config)))
    (list
     (shepherd-service
      (provision '(xorg-relay))
      (documentation "xorg WebSocket relay — message routing, signup, terminal sessions")
      (requirement '(networking user-processes))
      (start
       #~(make-forkexec-constructor
          (list (string-append #$package "/bin/xorg-relay")
                #$(number->string port))
          #:user #$user
          #:directory (string-append #$package "/share/xorg")
          #:environment-variables
          (append
           (list (string-append "HOME=/var/lib/" #$user))
           (list #$@(map (lambda (kv)
                           #~(string-append #$(car kv) "=" #$(cdr kv)))
                         env)))
          #:log-file "/var/log/xorg-relay.log"))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

;;; ── Service type ───────────────────────────────────────────────────────────

(define xorg-relay-service-type
  (service-type
   (name 'xorg-relay)
   (extensions
    (list (service-extension shepherd-root-service-type
                             xorg-relay-shepherd-service)))
   (description "Run the xorg WebSocket relay as a Shepherd service.")))
