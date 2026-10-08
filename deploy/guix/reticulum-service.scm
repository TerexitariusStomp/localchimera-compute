;;; deploy/guix/reticulum-service.scm — Guix service for Reticulum OCapN bridge
;;;
;;; Provides a single Shepherd service:
;;;   reticulum-bridge — Rust bridge between Goblins OCapN and Reticulum
;;;
;;; The bridge embeds an RNS node (via rns-net), so no separate rnsd is needed.
;;;
;;; Usage in a Guix system declaration:
;;;
;;;   (service reticulum-bridge-service-type
;;;            (reticulum-bridge-configuration
;;;             (control-socket "/var/run/reticulum-bridge.sock")))

(define-module (reticulum-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (rns-bridge)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (reticulum-bridge-configuration
            reticulum-bridge-service-type))

;;; ── Reticulum bridge ──────────────────────────────────────────────────────

(define-record-type* <reticulum-bridge-configuration>
  reticulum-bridge-configuration make-reticulum-bridge-configuration
  reticulum-bridge-configuration?
  (package        reticulum-bridge-configuration-package
                  (default rns-bridge))
  (control-socket reticulum-bridge-configuration-control-socket
                  (default "/var/run/reticulum-bridge.sock"))
  (socket-dir     reticulum-bridge-configuration-socket-dir
                  (default "/var/lib/reticulum-bridge")))

(define (reticulum-bridge-shepherd-service config)
  (let ((package        (reticulum-bridge-configuration-package config))
        (control-socket (reticulum-bridge-configuration-control-socket config))
        (socket-dir     (reticulum-bridge-configuration-socket-dir config)))
    (list
     (shepherd-service
      (provision '(reticulum-bridge))
      (documentation "Rust bridge between Goblins OCapN and Reticulum mesh")
      (requirement '(networking))
      (start #~(lambda args
                 ;; Spawn the bridge as usual, then watch for the control
                 ;; socket to appear and chmod 666 so the (non-root) gateway
                 ;; user can connect. The bridge creates the socket with the
                 ;; default 0755 umask which excludes write-for-others; the
                 ;; playnet gateway then hits EACCES on connect(2).
                 (let ((pid (apply
                             (make-forkexec-constructor
                              (list #$(file-append package "/bin/rns-bridge")
                                    "--control-socket" #$control-socket
                                    "--socket-dir" #$socket-dir)
                              #:environment-variables
                              (list "HOME=/var/lib/reticulum-bridge")
                              #:log-file "/var/log/reticulum-bridge.log")
                             args)))
                   ;; Persistent guard, not a 30-try one-shot: a bridge
                   ;; respawn recreates the socket 0755 and was observed
                   ;; to slip past the one-shot (2026-06-06 19:28 — the
                   ;; playnet gateway then crash-looped on EPERM until a
                   ;; manual chmod). Re-assert 666 every 2s for the
                   ;; lifetime of the service; a stat every 2s is free.
                   ((module-ref (resolve-interface '(ice-9 threads)) 'call-with-new-thread)
                    (lambda ()
                      (let loop ()
                        (catch #t
                          (lambda ()
                            (when (and (file-exists? #$control-socket)
                                       (not (= (logand (stat:perms (stat #$control-socket)) #o666)
                                               #o666)))
                              (chmod #$control-socket #o666)))
                          (lambda _ #f))
                        (sleep 2)
                        (loop))))
                   pid)))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

(define (reticulum-bridge-activation config)
  #~(begin
      (use-modules (guix build utils))
      (mkdir-p #$(reticulum-bridge-configuration-socket-dir config))))

(define reticulum-bridge-service-type
  (service-type
   (name 'reticulum-bridge)
   (extensions
    (list (service-extension shepherd-root-service-type
                             reticulum-bridge-shepherd-service)
          (service-extension activation-service-type
                             reticulum-bridge-activation)))
   (default-value (reticulum-bridge-configuration))
   (description "Bridge between Goblins OCapN and Reticulum mesh network.")))
