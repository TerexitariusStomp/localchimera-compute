;;; deploy/guix/backup-service.scm — declarative state backup service.
;;;
;;; Provides:
;;;
;;;   - playnet-backup-service-type — registers an mcron job that runs
;;;     deploy/scripts/backup-state.sh daily at 03:00 UTC, plus a
;;;     one-shot Shepherd service (`herd start playnet-backup`) so an
;;;     operator can trigger an out-of-band snapshot.
;;;
;;; Closes the three persistence gaps in one mechanism:
;;;
;;;     KERIA witness keystores (HIGH) — /var/lib/playnet/keria/{witnesses,ks,config}
;;;     Tor onion private key   (MEDIUM) — /var/lib/tor/hidden-services/playnet/
;;;     SporeStack token        (LOW) — /var/lib/playnet/sporestack-token.txt
;;;
;;; Output goes to /var/lib/playnet/backups/state-<ISO>.tar.age plus a
;;; latest.tar.age symlink. Encryption uses the existing age recipient
;;; at deploy/.age-yubikey-identity.txt — the same key that protects
;;; deploy/secrets.scm.age. Restore via deploy/scripts/backup-restore.sh.
;;;
;;; If the environment variable PLAYNET_BACKUP_RID is set (and a sister
;;; Radicle backups project exists at that RID), each snapshot is also
;;; committed and pushed there — defense in depth against host seizure.
;;;
;;; Usage in machines.scm:
;;;
;;;     (use-modules (backup-service))
;;;     ...
;;;     (services
;;;       (cons*
;;;         (service mcron-service-type)
;;;         (service playnet-backup-service-type)
;;;         ...))
;;;
;;; Both the mcron and the shepherd one-shot run as root because they
;;; need to read /var/lib/tor/ and chown'd KERIA keystore dirs. age
;;; encryption with a public recipient needs no private key on the box.

(define-module (backup-service)
  #:use-module (gnu services)
  #:use-module (gnu services mcron)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (playnet-backup-configuration
            playnet-backup-configuration?
            playnet-backup-service-type))

(define-record-type* <playnet-backup-configuration>
  playnet-backup-configuration make-playnet-backup-configuration
  playnet-backup-configuration?
  ;; Path on the live box where the script lives. The script is rsynced
  ;; into place by deploy/scripts/reconfigure.sh (same as gateway code),
  ;; so the path is stable across deploys.
  (script  playnet-backup-configuration-script
           (default "/home/playnet/playnet-repo/deploy/scripts/backup-state.sh"))
  ;; mcron schedule expression. Default: every day at 03:03 UTC — :03,
  ;; the minute residue the box keeps for its once-a-day jobs (deploy/os.scm,
  ;; the mcron block: two jobs starting in one minute crash mcron 1.2.2).
  ;; Vixie-cron syntax: "minute hour dom mon dow".
  (schedule playnet-backup-configuration-schedule
            (default "3 3 * * *"))
  ;; Optional sister-Radicle RID for offsite push. Empty string disables.
  (backup-rid playnet-backup-configuration-backup-rid
              (default ""))
  ;; How many local snapshots to keep before pruning.
  (keep    playnet-backup-configuration-keep
           (default 30)))

(define (playnet-backup-mcron-jobs config)
  "Return the mcron job list."
  (let* ((script   (playnet-backup-configuration-script config))
         (schedule (playnet-backup-configuration-schedule config))
         (rid      (playnet-backup-configuration-backup-rid config))
         (keep     (playnet-backup-configuration-keep config)))
    (list
     #~(job #$schedule
            (lambda ()
              (setenv "PLAYNET_BACKUP_RID" #$rid)
              (setenv "PLAYNET_BACKUP_KEEP" (number->string #$keep))
              (system* "/bin/sh" #$script))
            "playnet-backup"))))

(define (playnet-backup-shepherd-service config)
  "Return a one-shot Shepherd service so operators can trigger an
out-of-band snapshot via `herd start playnet-backup`."
  (let* ((script (playnet-backup-configuration-script config))
         (rid    (playnet-backup-configuration-backup-rid config))
         (keep   (playnet-backup-configuration-keep config)))
    (list
     (shepherd-service
      (documentation "Playnet at-risk-state backup (one-shot, encrypted to age).")
      (provision '(playnet-backup))
      (requirement '())
      (one-shot? #t)
      (start
       #~(make-forkexec-constructor
          (list "/bin/sh" #$script)
          #:log-file "/var/log/playnet/backup.log"
          #:environment-variables
          (list (string-append "PLAYNET_BACKUP_RID=" #$rid)
                (string-append "PLAYNET_BACKUP_KEEP="
                               (number->string #$keep))
                "HOME=/root")))))))

(define playnet-backup-service-type
  (service-type
   (name 'playnet-backup)
   (description
    "Daily encrypted snapshot of the playnet at-risk state (KERIA witness
keystores, Tor onion key, SporeStack token, Goblins vat snapshots).
Output: /var/lib/playnet/backups/state-<ISO>.tar.age. Restore via
deploy/scripts/backup-restore.sh. Requires (service mcron-service-type)
in the same services list.")
   (extensions
    (list (service-extension mcron-service-type
                             playnet-backup-mcron-jobs)
          (service-extension shepherd-root-service-type
                             playnet-backup-shepherd-service)))
   (default-value (playnet-backup-configuration))))
