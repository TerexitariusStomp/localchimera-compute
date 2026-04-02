;;; deploy/guix/playnet-gateway-service.scm — Shepherd service for the OCapN gateway
;;;
;;; Runs the playnet OCapN gateway from the Guix package (immutable store).
;;; Replaces playnet-relay-service.scm.  Provides capability-secure access
;;; to signup, transcription, presence, terminal, and messaging via
;;; OCapN CapTP over WebSocket and Reticulum.
;;;
;;; Usage in machines.scm:
;;;   (service playnet-gateway-service-type
;;;            (playnet-gateway-configuration
;;;             (package playnet)
;;;             (port 9090)))

(define-module (playnet-gateway-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (playnet-gateway-configuration
            playnet-gateway-configuration?
            playnet-gateway-configuration-package
            playnet-gateway-configuration-port
            playnet-gateway-configuration-user
            playnet-gateway-configuration-data-dir
            playnet-gateway-configuration-reticulum?
            playnet-gateway-configuration-environment
            playnet-gateway-service-type))

;;; ── Configuration record ───────────────────────────────────────────────────

(define-record-type* <playnet-gateway-configuration>
  playnet-gateway-configuration make-playnet-gateway-configuration
  playnet-gateway-configuration?
  ;; The playnet Guix package (provides bin/playnet-gateway)
  (package  playnet-gateway-configuration-package)
  ;; WebSocket listen port
  (port     playnet-gateway-configuration-port     (default 9090))
  ;; User to run as
  (user     playnet-gateway-configuration-user     (default "playnet"))
  ;; Persistent data directory (designator key, sturdyref, etc.)
  (data-dir playnet-gateway-configuration-data-dir (default "/var/lib/playnet"))
  ;; Enable Reticulum netlayer (requires reticulum-bridge service)
  (reticulum? playnet-gateway-configuration-reticulum? (default #f))
  ;; Environment variables (alist of string . string pairs)
  (environment playnet-gateway-configuration-environment (default '())))

;;; ── Shepherd service definition ────────────────────────────────────────────

(define (playnet-gateway-shepherd-service config)
  (let ((package     (playnet-gateway-configuration-package config))
        (port        (playnet-gateway-configuration-port config))
        (user        (playnet-gateway-configuration-user config))
        (data-dir    (playnet-gateway-configuration-data-dir config))
        (reticulum?  (playnet-gateway-configuration-reticulum? config))
        (env         (playnet-gateway-configuration-environment config)))
    (list
     (shepherd-service
      (provision '(playnet-gateway))
      (documentation "playnet OCapN gateway — capability-secure communication hub")
      (requirement (if reticulum?
                       '(networking user-processes reticulum-bridge)
                       '(networking user-processes)))
      (start
       #~(make-forkexec-constructor
          (list (string-append #$package "/bin/playnet-gateway")
                "--port" #$(number->string port)
                #$@(if reticulum? '("--reticulum") '()))
          #:user #$user
          #:directory (string-append #$package "/share/playnet")
          #:environment-variables
          (append
           (list (string-append "HOME=" #$data-dir)
                 (string-append "PLAYNET_DATA_DIR=" #$data-dir))
           (list #$@(map (lambda (kv)
                           #~(string-append #$(car kv) "=" #$(cdr kv)))
                         env)))
          #:log-file "/var/log/playnet-gateway.log"))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

(define (playnet-gateway-activation config)
  "Create the persistent data directory for the gateway."
  (let ((data-dir (playnet-gateway-configuration-data-dir config))
        (user     (playnet-gateway-configuration-user config)))
    #~(begin
        (use-modules (guix build utils))
        (let ((pw (getpwnam #$user)))
          (mkdir-p #$data-dir)
          (chown #$data-dir (passwd:uid pw) (passwd:gid pw))))))

;;; ── Service type ───────────────────────────────────────────────────────────

(define playnet-gateway-service-type
  (service-type
   (name 'playnet-gateway)
   (extensions
    (list (service-extension shepherd-root-service-type
                             playnet-gateway-shepherd-service)
          (service-extension activation-service-type
                             playnet-gateway-activation)))
   (description "Run the playnet OCapN gateway as a Shepherd service.")))
