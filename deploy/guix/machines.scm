;;; deploy/guix/machines.scm — guix deploy target machines
;;;
;;; Usage:
;;;   GUIX_HETZNER_API_TOKEN=<token> guix deploy -L deploy/guix deploy/guix/machines.scm
;;;
;;; On first deploy, Guix will:
;;;   1. Create the SSH key on Hetzner API
;;;   2. Create the server (cx22 in nbg1)
;;;   3. Boot into rescue mode, format ext4, install minimal Guix
;;;   4. Reboot and apply the full operating-system config
;;;
;;; On subsequent deploys, it reconfigures the running system.

;; Load path set via -L flag: guix deploy -L deploy/guix ...

(use-modules (gnu machine)
             (gnu machine hetzner)
             (base-system))

(define %ssh-key "~/.ssh/id_ed25519")

(list
 ;; Generic base server — no application services yet.
 ;; Clone this and add (make-hetzner-system #:extra-services ...) for each machine.
 (machine
  (operating-system
   (make-hetzner-system
    #:hostname "guix-1"
    ;; Uncomment when you have a domain pointing at this server:
    ;; #:certbot-email "ops@example.com"
    ;; #:certbot-domains '("guix-1.example.com")
    ))
  (environment hetzner-environment-type)
  (configuration
   (hetzner-configuration
    (server-type "cpx11")    ;; 2 vCPU, 2GB RAM, 40GB disk — cheapest x86
    (location "nbg1")        ;; Nuremberg
    (ssh-key %ssh-key)
    (labels '(("managed-by" . "guix")))))))
