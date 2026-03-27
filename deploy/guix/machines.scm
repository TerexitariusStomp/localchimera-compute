;;; deploy/guix/machines.scm — guix deploy target machines
;;;
;;; Usage:
;;;   GUIX_HETZNER_API_TOKEN=<token> \
;;;     guix deploy -L deploy/guix deploy/guix/machines.scm
;;;
;;; Guix provisions the Hetzner server automatically:
;;;   1. Creates SSH key on Hetzner API
;;;   2. Creates the server
;;;   3. Boots rescue mode, formats disk, installs Guix
;;;   4. Reboots into full OS config

;; Load path set via -L flag

(use-modules (gnu machine)
             (gnu machine hetzner)
             (base-system))

(define %ssh-key "/home/nozomi/.ssh/id_ed25519")

(list
 (machine
  (operating-system
   (make-hetzner-system
    #:hostname "guix-1"))
  (environment hetzner-environment-type)
  (configuration
   (hetzner-configuration
    (server-type "cpx22")    ;; 2 vCPU x86, 4GB RAM, 80GB disk — x86 in nbg1
    (location "nbg1")        ;; Nuremberg
    (ssh-key %ssh-key)
    (authorize? #t)
    (delete? #f)             ;; keep server on failure so we can debug
    (labels '(("managed-by" . "guix")))))))
