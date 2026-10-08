;;; deploy/machines.scm — <machine> wrapper for `guix deploy`
;;;
;;; The operating-system is defined in deploy/os.scm — the source of
;;; truth. This file only wraps it in a <machine> record (the value
;;; `guix deploy` expects) plus the fleet-host bookkeeping.
;;;
;;; Usage:
;;;   PLAYNET_PROVIDER=deploy/providers/provider-1.scm \
;;;     guix time-machine -C deploy/channels.scm -- \
;;;     deploy -L deploy/guix deploy/machines.scm
;;;
;;; Server-side counterpart (much smaller closure delta):
;;;   PLAYNET_PROVIDER=deploy/providers/provider-1.scm \
;;;     sudo -E guix system reconfigure -L deploy/guix deploy/os.scm

(define %machines-this-dir
  (dirname (or (current-filename)
               (canonicalize-path "deploy/machines.scm"))))

;; Pull in the operating-system definition plus every helper it
;; declares (provider-ref, %guix-x86, %dynamic-users, …) into our
;; top-level scope. primitive-load evaluates its file in the *current*
;; module's environment, so every (define …) in os.scm becomes a
;; binding here — including the `(use-modules …)` imports at the top.
(primitive-load (string-append %machines-this-dir "/os.scm"))

;; ── Fleet hosts ─────────────────────────────────────────────────────────
;; Load materialized hosts from deploy/hosts.scm (gitignored, written by
;; the ^fleet-reconciler). Only hosts whose bootstrap-state is
;; 'bootstrapped get wired into the deploy target — hosts in 'pending
;; (freshly provisioned Debian VM, awaiting manual Guix conversion) are
;; skipped silently. See deploy/hosts.scm.example for the format.
;;
;; After running the Guix bootstrap on a new VM, edit its entry in
;; hosts.scm to change (bootstrap-state pending) to
;; (bootstrap-state bootstrapped), then `guix deploy` will pick it up.

(use-modules (playnet fleet records)
             (srfi srfi-1))

(define %fleet-hosts
  (let ((hosts-file (string-append %machines-this-dir "/hosts.scm")))
    (if (file-exists? hosts-file)
        (primitive-load hosts-file)
        '())))

(define %fleet-machines
  (filter-map
   (lambda (m)
     (and (eq? (materialized-host-bootstrap-state m) 'bootstrapped)
          (materialized-host-ipv4 m)
          (machine
           (operating-system %guix-x86)    ; fleet hosts share the same OS
           (environment managed-host-environment-type)
           (configuration
            (machine-ssh-configuration
             (host-name (materialized-host-ipv4 m))
             (system "x86_64-linux")
             (identity (or (getenv "DEPLOY_SSH_IDENTITY")
                           "/home/user/.ssh/id_ed25519"))
             (host-key (or (materialized-host-ssh-host-key m) "")))))))
   %fleet-hosts))

;; `guix deploy` reads the LAST top-level expression as the list of
;; <machine> records. The primary machine (this provider's host) goes
;; first; fleet machines follow.
(append
 (list (machine
        (operating-system %guix-x86)
        (environment managed-host-environment-type)
        (configuration (machine-ssh-configuration
                        (host-name (provider-ref 'host-ip))
                        (system (provider-ref 'system))
                        (identity (or (getenv "DEPLOY_SSH_IDENTITY")
                                      "/home/user/.ssh/id_ed25519"))
                        (host-key (provider-ref 'ssh-host-key))))))
 %fleet-machines)
