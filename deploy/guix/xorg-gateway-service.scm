;;; deploy/guix/xorg-gateway-service.scm — Shepherd service for the OCapN gateway
;;;
;;; Runs the xorg OCapN gateway from the Guix package (immutable store).
;;; Replaces xorg-relay-service.scm.  Provides capability-secure access
;;; to signup, transcription, presence, terminal, and messaging via
;;; OCapN CapTP over WebSocket and Reticulum.
;;;
;;; Usage in machines.scm:
;;;   (service xorg-gateway-service-type
;;;            (xorg-gateway-configuration
;;;             (package xorg)
;;;             (port 9090)))

(define-module (xorg-gateway-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (xorg-gateway-configuration
            xorg-gateway-configuration?
            xorg-gateway-configuration-package
            xorg-gateway-configuration-port
            xorg-gateway-configuration-user
            xorg-gateway-configuration-data-dir
            xorg-gateway-configuration-environment
            xorg-gateway-service-type))

;;; ── Configuration record ───────────────────────────────────────────────────

(define-record-type* <xorg-gateway-configuration>
  xorg-gateway-configuration make-xorg-gateway-configuration
  xorg-gateway-configuration?
  ;; The xorg Guix package (provides bin/xorg-gateway)
  (package  xorg-gateway-configuration-package)
  ;; WebSocket listen port
  (port     xorg-gateway-configuration-port     (default 9090))
  ;; User to run as
  (user     xorg-gateway-configuration-user     (default "xorg"))
  ;; Persistent data directory (designator key, sturdyref, etc.)
  (data-dir xorg-gateway-configuration-data-dir (default "/var/lib/xorg"))
  ;; Environment variables (alist of string . string pairs)
  (environment xorg-gateway-configuration-environment (default '())))

;;; ── Shepherd service definition ────────────────────────────────────────────

(define (xorg-gateway-shepherd-service config)
  (let ((package  (xorg-gateway-configuration-package config))
        (port     (xorg-gateway-configuration-port config))
        (user     (xorg-gateway-configuration-user config))
        (data-dir (xorg-gateway-configuration-data-dir config))
        (env      (xorg-gateway-configuration-environment config)))
    (list
     (shepherd-service
      (provision '(xorg-gateway))
      (documentation "xorg OCapN gateway — capability-secure communication hub")
      (requirement '(networking user-processes reticulum-bridge))
      (start
       #~(make-forkexec-constructor
          (list (string-append #$package "/bin/xorg-gateway")
                "--port" #$(number->string port))
          #:user #$user
          #:directory (string-append #$package "/share/xorg")
          #:environment-variables
          (append
           (list (string-append "HOME=" #$data-dir)
                 (string-append "XORG_DATA_DIR=" #$data-dir))
           (list #$@(map (lambda (kv)
                           #~(string-append #$(car kv) "=" #$(cdr kv)))
                         env)))
          #:log-file "/var/log/xorg-gateway.log"))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

(define (xorg-gateway-activation config)
  "Create the persistent data directory for the gateway."
  (let ((data-dir (xorg-gateway-configuration-data-dir config))
        (user     (xorg-gateway-configuration-user config)))
    #~(begin
        (use-modules (guix build utils))
        (let ((pw (getpwnam #$user)))
          (mkdir-p #$data-dir)
          (chown #$data-dir (passwd:uid pw) (passwd:gid pw))))))

;;; ── Service type ───────────────────────────────────────────────────────────

(define xorg-gateway-service-type
  (service-type
   (name 'xorg-gateway)
   (extensions
    (list (service-extension shepherd-root-service-type
                             xorg-gateway-shepherd-service)
          (service-extension activation-service-type
                             xorg-gateway-activation)))
   (description "Run the xorg OCapN gateway as a Shepherd service.")))
