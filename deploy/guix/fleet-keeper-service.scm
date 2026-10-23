;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/guix/fleet-keeper-service.scm — Shepherd service for the fleet keeper
;;;
;;; Runs server/fleet-keeper.scm: the process that carries a host the
;;; reconciler has recorded to a running, encrypted Guix System, and sends
;;; each fleet host its disk passphrase whenever it waits in its initrd
;;; ((playnet fleet keeper), (playnet fleet child)).
;;;
;;; It runs as the account that holds the provisioning key. Its PATH carries
;;; ssh, ssh-keygen, scp and torsocks; with `tor? #t` every SSH connection
;;; rides Tor, which is the only egress a Tor-only box has.
;;;
;;; Usage:
;;;   (use-modules (fleet-keeper-service))
;;;   (service fleet-keeper-service-type)
;;;
;;;   herd status fleet-keeper
;;;   tail -f /var/log/playnet/fleet-keeper.log

(define-module (fleet-keeper-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages ssh)
  #:use-module (gnu packages tor)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (fleet-keeper-configuration
            fleet-keeper-configuration?
            fleet-keeper-service-type))

(define-record-type* <fleet-keeper-configuration>
  fleet-keeper-configuration make-fleet-keeper-configuration
  fleet-keeper-configuration?
  (user        fleet-keeper-configuration-user
               (default "playnet"))
  (script      fleet-keeper-configuration-script
               (default "/home/playnet/playnet-repo/server/fleet-keeper.scm"))
  (module-path fleet-keeper-configuration-module-path
               (default "/home/playnet/playnet-repo/module"))
  (deploy-dir  fleet-keeper-configuration-deploy-dir
               (default "/home/playnet/playnet-repo/deploy"))
  (data-dir    fleet-keeper-configuration-data-dir
               (default "/var/lib/playnet"))
  ;; Seconds between ticks. Each tick is one SSH attempt per fleet host.
  (interval    fleet-keeper-configuration-interval
               (default 120))
  (tor?        fleet-keeper-configuration-tor?
               (default #t)))

(define (fleet-keeper-shepherd-service config)
  (let ((user        (fleet-keeper-configuration-user config))
        (script      (fleet-keeper-configuration-script config))
        (module-path (fleet-keeper-configuration-module-path config))
        (deploy-dir  (fleet-keeper-configuration-deploy-dir config))
        (data-dir    (fleet-keeper-configuration-data-dir config))
        (interval    (fleet-keeper-configuration-interval config))
        (tor?        (fleet-keeper-configuration-tor? config)))
    (list
     (shepherd-service
      (provision '(fleet-keeper))
      (documentation
       "Installs fleet hosts marked for automatic bootstrap and sends each
fleet host its disk passphrase when it waits in its initrd.")
      (requirement (if tor? '(networking tor) '(networking)))
      (start #~(make-forkexec-constructor
                (list #$(file-append guile-3.0 "/bin/guile")
                      "--no-auto-compile"
                      "-L" #$module-path
                      "-s" #$script)
                #:user #$user
                #:group "users"
                #:log-file "/var/log/playnet/fleet-keeper.log"
                #:environment-variables
                (list (string-append "GUILE_LOAD_PATH="
                                     "/run/current-system/profile/share/guile/site/3.0:"
                                     #$module-path)
                      (string-append
                       "PATH="
                       #$(file-append openssh-sans-x "/bin") ":"
                       #$(file-append torsocks "/bin") ":"
                       #$(file-append guile-3.0 "/bin") ":"
                       #$(file-append coreutils "/bin") ":"
                       #$(file-append bash-minimal "/bin") ":"
                       "/run/current-system/profile/bin")
                      (string-append "PLAYNET_DATA_DIR=" #$data-dir)
                      (string-append "PLAYNET_DEPLOY_DIR=" #$deploy-dir)
                      (string-append "PLAYNET_KEEPER_INTERVAL="
                                     #$(number->string interval))
                      (string-append "PLAYNET_KEEPER_SSH_PREFIX="
                                     #$(if tor? "torsocks" ""))
                      ;; ssh reads the account's home from passwd; the
                      ;; scripts the keeper runs read HOME.
                      "HOME=/home/playnet")))
      (stop #~(make-kill-destructor))
      (respawn? #t)
      (auto-start? #t)))))

(define fleet-keeper-service-type
  (service-type
   (name 'fleet-keeper)
   (description
    "Carries a recorded fleet host to a running encrypted system and keeps
it unlocked across reboots.")
   (extensions
    (list (service-extension shepherd-root-service-type
                             fleet-keeper-shepherd-service)))
   (default-value (fleet-keeper-configuration))))
