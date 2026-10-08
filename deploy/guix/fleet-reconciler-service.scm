;;; deploy/guix/fleet-reconciler-service.scm — Shepherd service wrapper
;;;
;;; Runs server/fleet-bridge.scm as a long-lived Shepherd service on
;;; the playnet host. The bridge subscribes to MQTT infrastructure
;;; deficit signals (spec-infra-*) and pokes the ^fleet-reconciler
;;; living inside the playnet gateway process via the REPL Unix
;;; socket at /var/run/playnet/repl.sock.
;;;
;;; Requirements:
;;;   - mosquitto service running (provides localhost MQTT broker)
;;;   - playnet-gateway service running (spawns the ^fleet-reconciler
;;;     actor on startup and exposes the REPL socket)
;;;   - /home/playnet/bin/repl-eval script installed (activation
;;;     service in machines.scm does this)
;;;
;;; Usage:
;;;   (use-modules (fleet-reconciler-service))
;;;   (service fleet-reconciler-service-type)
;;;
;;; Starts automatically; manual control:
;;;   herd status   fleet-reconciler
;;;   herd stop     fleet-reconciler
;;;   herd restart  fleet-reconciler
;;;   herd log      fleet-reconciler

(define-module (fleet-reconciler-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages guile)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (fleet-reconciler-configuration
            fleet-reconciler-configuration?
            fleet-reconciler-service-type))

(define-record-type* <fleet-reconciler-configuration>
  fleet-reconciler-configuration make-fleet-reconciler-configuration
  fleet-reconciler-configuration?
  (user            fleet-reconciler-configuration-user
                   (default "playnet"))
  (bridge-script   fleet-reconciler-configuration-bridge-script
                   (default "/home/playnet/playnet-repo/server/fleet-bridge.scm"))
  (module-path     fleet-reconciler-configuration-module-path
                   (default "/home/playnet/playnet-repo/module"))
  (repl-eval-path  fleet-reconciler-configuration-repl-eval-path
                   (default "/home/playnet/bin/repl-eval")))

(define (fleet-reconciler-shepherd-service config)
  (let ((user           (fleet-reconciler-configuration-user config))
        (bridge-script  (fleet-reconciler-configuration-bridge-script config))
        (module-path    (fleet-reconciler-configuration-module-path config))
        (repl-eval-path (fleet-reconciler-configuration-repl-eval-path config)))
    (list
     (shepherd-service
      (provision '(fleet-reconciler))
      (documentation
       "MQTT -> fleet reconciler bridge. Listens for spec-infra-* deficit
signals on localhost:1883 and pokes the fleet reconciler in the playnet
gateway via the REPL unix socket.")
      (requirement '(networking mosquitto))
      (start #~(make-forkexec-constructor
                (list #$(file-append guile-3.0 "/bin/guile")
                      "--no-auto-compile"
                      "-L" #$module-path
                      "-s" #$bridge-script)
                #:user #$user
                #:group "users"
                #:log-file "/var/log/playnet/fleet-reconciler.log"
                #:environment-variables
                (list (string-append "GUILE_LOAD_PATH="
                                     "/run/current-system/profile/share/guile/site/3.0:"
                                     #$module-path)
                      (string-append "REPL_EVAL_PATH=" #$repl-eval-path)
                      "HOME=/home/playnet")))
      ;; Auto-start: the reconciler's state file lives in the gateway's
      ;; persistence store, so if the gateway is down we just retry.
      (respawn? #t)
      (auto-start? #t)))))

(define fleet-reconciler-service-type
  (service-type
   (name 'fleet-reconciler)
   (description
    "MQTT subscriber that pokes the ^fleet-reconciler actor in the
playnet gateway vat whenever an infrastructure deficit signal arrives.
Runs as the playnet user alongside the gateway itself.")
   (extensions
    (list (service-extension shepherd-root-service-type
                             fleet-reconciler-shepherd-service)))
   (default-value (fleet-reconciler-configuration))))
