;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; server/fleet-keeper.scm — the fleet keeper's process
;;;
;;; Every LOCALCHIMERA_KEEPER_INTERVAL seconds (default 120) it reads this box's
;;; desired-fleet.scm and hosts.scm and runs one (localchimera fleet keeper)
;;; tick: install the hosts that ask for it, send passphrases to hosts
;;; waiting in their initrd, promote a host whose system has come up.
;;;
;;; It runs as the account that holds the provisioning key, and on a
;;; Tor-only box under torsocks (LOCALCHIMERA_KEEPER_SSH_PREFIX=torsocks), so
;;; every SSH connection it opens rides Tor.
;;;
;;; Run as a Shepherd service (deploy/guix/fleet-keeper-service.scm) or:
;;;   guile --no-auto-compile -L module -s server/fleet-keeper.scm [--once]

(use-modules (localchimera fleet child)
             (localchimera fleet keeper)
             (localchimera fleet records)
             (ice-9 format)
             (srfi srfi-1)
             (srfi srfi-13))

(define %data-dir (or (getenv "LOCALCHIMERA_DATA_DIR") "/var/lib/localchimera"))
(define %deploy-dir
  (or (getenv "LOCALCHIMERA_DEPLOY_DIR") "/home/localchimera/localchimera-repo/deploy"))
(define %identity
  (or (getenv "LOCALCHIMERA_FLEET_SSH_KEY")
      (string-append (passwd:dir (getpwuid (getuid))) "/.ssh/id_ed25519")))
(define %interval
  (or (and=> (getenv "LOCALCHIMERA_KEEPER_INTERVAL") string->number) 120))
(define %ssh-prefix
  (let ((p (getenv "LOCALCHIMERA_KEEPER_SSH_PREFIX")))
    (if (and p (not (string-null? p))) (string-tokenize p) '())))

;; Shepherd stamps each line of the service's log file.
(define (log! fmt . args)
  (apply format #t fmt args)
  (force-output))

(define run-ssh (ssh-runner #:prefix %ssh-prefix))

(define (unlock! name address)
  (try-unlock! %data-dir name address %identity #:run run-ssh))

(define %installer
  (or (getenv "LOCALCHIMERA_KEEPER_INSTALLER")
      (string-append %deploy-dir "/scripts/bootstrap-child.sh")))

(define (installer-ready?)
  (access? %installer X_OK))

(define (install! m dir)
  "Run the installer against the recorded host. It reads the host's secrets
from DIR, and exits 0 once the target has rebooted toward its initrd."
  (let ((code (apply system*
                     (append
                      (list %installer
                            (materialized-host-name m)
                            (materialized-host-ipv4 m)
                            dir
                            %identity
                            (or (materialized-host-ssh-host-key m) ""))))))
    (unless (zero? (status:exit-val code))
      (error "bootstrap-child.sh exited" (status:exit-val code)))
    #t))

(define %hosts-file (string-append %deploy-dir "/hosts.scm"))

(define (promote! m)
  (promote-host! %hosts-file
                 (lambda (h) (equal? (materialized-host-name h)
                                     (materialized-host-name m)))))

(define (tick!)
  (catch #t
    (lambda ()
      (keeper-tick! %data-dir
                    (load-fleet-file (string-append %deploy-dir "/desired-fleet.scm"))
                    (load-fleet-file %hosts-file)
                    #:install! install!
                    #:unlock! unlock!
                    #:promote! promote!
                    #:installer-ready? installer-ready?
                    #:log! log!))
    (lambda (key . args)
      (log! "  [keeper] tick raised ~a ~s~%" key args))))

(log! "  [keeper] up: every ~as, data ~a, fleet files in ~a, installer ~a~a~%"
      %interval %data-dir %deploy-dir
      (if (installer-ready?) %installer "absent")
      (if (null? %ssh-prefix) "" (format #f ", ssh via ~a" %ssh-prefix)))

(if (member "--once" (command-line))
    (tick!)
    (let loop ()
      (tick!)
      (sleep %interval)
      (loop)))
