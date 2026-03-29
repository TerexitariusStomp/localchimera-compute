;;; host-org-entry.scm — entry point for the host org Shepherd service
;;;
;;; Starts a persistent host org with service capabilities.
;;; Called by: guile host-org-entry.scm
;;; Logs to: /var/log/xorg-host.log (via Shepherd)
;;;
;;; On first boot: creates a fresh host org with governance.
;;; On subsequent boots: restores from persistent store.
;;;
;;; Admin: after first deploy, connect via Geiser and grant capabilities:
;;;   (host-grant-service! host "nginx"
;;;                        (make-service-cap (org-vat host) "nginx")
;;;                        infra-seal)
;;;   (host-grant-deploy! host "deploy/guix/machines.scm" infra-seal)

(use-modules (goblins)
             (xorg gplay)
             (xorg host)
             (xorg services))

;; TODO: wire Bloblin persistence when make-governed-org-persistent exists
;; (use-modules (goblins persistence-store bloblin))
;; (define store (make-bloblin-store "/var/lib/xorg/host-org.db"))

;; Create the host org (non-persistent for now)
(define-values (host gov-seal infra-seal member-seal)
  (make-host-org "host"))

(format #t "host-org: started~%")
(format #t "host-org: governance domains ready (gov, infra, member)~%")

;; Wire in service capabilities (only on first boot — subsequent boots restore
;; from store once persistence is wired).
;;
;; Admin: fill these in after first deploy, or connect via Geiser REPL.
;;
;; Example:
;; (host-grant-service! host "nginx"
;;                      (make-service-cap (org-vat host) "nginx")
;;                      infra-seal)
;; (host-grant-deploy! host "deploy/guix/machines.scm" infra-seal)

;; Keep running — Shepherd manages lifecycle
(let loop ()
  (sleep 60)
  (loop))
