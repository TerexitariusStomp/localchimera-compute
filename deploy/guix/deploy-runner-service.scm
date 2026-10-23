;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/guix/deploy-runner-service.scm — auto-deploy on fleet changes
;;;
;;; Runs as the `deploy` user (NOT playnet) because guix deploy needs
;;; SSH access to target machines using the deploy key.
;;;
;;; Subscribes to playnet/signals/fleet-changed on the local MQTT
;;; broker. When triggered, runs `guix deploy deploy/machines.scm`.
;;; 10-minute cooldown between deploys.
;;;
;;; Usage:
;;;   (use-modules (deploy-runner-service))
;;;   (service deploy-runner-service-type)

(define-module (deploy-runner-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages guile)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (deploy-runner-configuration
            deploy-runner-configuration?
            deploy-runner-service-type))

(define-record-type* <deploy-runner-configuration>
  deploy-runner-configuration make-deploy-runner-configuration
  deploy-runner-configuration?
  ;; Runs as the deploy user — needs SSH access to target machines.
  (user         deploy-runner-configuration-user
                (default "deploy"))
  (script       deploy-runner-configuration-script
                (default "/home/playnet/playnet-repo/server/deploy-runner.scm"))
  (deploy-dir   deploy-runner-configuration-deploy-dir
                (default "/home/playnet/playnet-repo/deploy"))
  (ssh-identity deploy-runner-configuration-ssh-identity
                (default "/home/deploy/.ssh/id_ed25519")))

(define (deploy-runner-shepherd-service config)
  (let ((user         (deploy-runner-configuration-user config))
        (script       (deploy-runner-configuration-script config))
        (deploy-dir   (deploy-runner-configuration-deploy-dir config))
        (ssh-identity (deploy-runner-configuration-ssh-identity config)))
    (list
     (shepherd-service
      (provision '(deploy-runner))
      (documentation
       "Auto-deploy on fleet changes. Subscribes to MQTT
playnet/signals/fleet-changed and runs guix deploy as the deploy user.")
      (requirement '(networking))  ; no MQTT — uses inotifywait on trigger file
      (start #~(make-forkexec-constructor
                (list #$(file-append guile-3.0 "/bin/guile")
                      "--no-auto-compile"
                      "-s" #$script)
                #:user #$user
                #:group "users"
                #:log-file "/var/log/playnet/deploy-runner.log"
                #:environment-variables
                (list (string-append "GUILE_LOAD_PATH="
                                     "/run/current-system/profile/share/guile/site/3.0")
                      (string-append "PLAYNET_DEPLOY_DIR=" #$deploy-dir)
                      (string-append "DEPLOY_SSH_IDENTITY=" #$ssh-identity)
                      (string-append "HOME=/home/" #$user)
                      (string-append "PATH="
                                     "/run/current-system/profile/bin:"
                                     "/run/current-system/profile/sbin"))))
      (stop #~(make-kill-destructor))
      (respawn? #t)
      ;; Manual start — enable only after verifying fleet provisioning
      ;; works end-to-end. Once enabled, fleet changes trigger automatic
      ;; guix deploy without human intervention.
      (auto-start? #f)))))

(define deploy-runner-service-type
  (service-type
   (name 'deploy-runner)
   (description
    "Auto-deploy service. Subscribes to MQTT fleet-changed signals and
runs guix deploy as the deploy user. Manual start:
  herd start deploy-runner")
   (extensions
    (list (service-extension shepherd-root-service-type
                             deploy-runner-shepherd-service)))
   (default-value (deploy-runner-configuration))))
