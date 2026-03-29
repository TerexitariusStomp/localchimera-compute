;;; deploy/guix/reticulum-service.scm — Guix services for Reticulum + OCapN bridge
;;;
;;; Provides two Shepherd services:
;;;   rnsd             — Reticulum network daemon
;;;   reticulum-bridge — Python bridge between Goblins OCapN and Reticulum
;;;
;;; Usage in a Guix system declaration:
;;;
;;;   (service rnsd-service-type)
;;;   (service reticulum-bridge-service-type
;;;            (reticulum-bridge-configuration
;;;             (control-socket "/var/run/reticulum-bridge.sock")))

(define-module (reticulum-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages python)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (rnsd-service-type
            reticulum-bridge-configuration
            reticulum-bridge-service-type))

;;; ── rnsd (Reticulum daemon) ───────────────────────────────────────────────

(define (rnsd-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(rnsd))
    (documentation "Reticulum network daemon")
    (requirement '(networking))
    (start #~(make-forkexec-constructor
              ;; TODO: replace with (file-append python-reticulum "/bin/rnsd")
              ;; once python-reticulum is packaged for Guix
              (list "rnsd" "--verbose")
              #:log-file "/var/log/rnsd.log"))
    (stop #~(make-kill-destructor))
    (respawn? #t))))

(define rnsd-service-type
  (service-type
   (name 'rnsd)
   (extensions
    (list (service-extension shepherd-root-service-type
                             rnsd-shepherd-service)))
   (default-value #f)
   (description "Run the Reticulum network daemon (rnsd).")))

;;; ── Reticulum bridge ──────────────────────────────────────────────────────

(define-record-type* <reticulum-bridge-configuration>
  reticulum-bridge-configuration make-reticulum-bridge-configuration
  reticulum-bridge-configuration?
  (control-socket reticulum-bridge-configuration-control-socket
                  (default "/var/run/reticulum-bridge.sock"))
  (socket-dir     reticulum-bridge-configuration-socket-dir
                  (default "/tmp/goblins-reticulum"))
  (bridge-script  reticulum-bridge-configuration-bridge-script
                  (default (local-file "../../server/reticulum-bridge.py"))))

(define (reticulum-bridge-shepherd-service config)
  (let ((control-socket (reticulum-bridge-configuration-control-socket config))
        (socket-dir     (reticulum-bridge-configuration-socket-dir config))
        (bridge-script  (reticulum-bridge-configuration-bridge-script config)))
    (list
     (shepherd-service
      (provision '(reticulum-bridge))
      (documentation "Python bridge between Goblins OCapN and Reticulum")
      (requirement '(rnsd))
      (start #~(make-forkexec-constructor
                (list #$(file-append python-3 "/bin/python3")
                      #$bridge-script
                      "--control-socket" #$control-socket
                      "--socket-dir" #$socket-dir)
                #:log-file "/var/log/reticulum-bridge.log"))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

(define reticulum-bridge-service-type
  (service-type
   (name 'reticulum-bridge)
   (extensions
    (list (service-extension shepherd-root-service-type
                             reticulum-bridge-shepherd-service)))
   (default-value (reticulum-bridge-configuration))
   (description "Bridge between Goblins OCapN and Reticulum network.")))
