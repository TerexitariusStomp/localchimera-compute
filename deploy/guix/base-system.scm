;;; deploy/guix/base-system.scm — base operating system for Hetzner machines
;;;
;;; Inherit from %hetzner-os-x86 (built into Guix) and add:
;;; - openssh with key-based auth, no passwords
;;; - nginx (services can extend it)
;;; - certbot for automatic TLS (extends nginx)
;;; - ntp
;;; - a deploy user with NOPASSWD sudo (required by guix deploy for non-root login)

(define-module (base-system)
  #:use-module (gnu)
  #:use-module (gnu machine hetzner)
  #:use-module (gnu services certbot)
  #:use-module (gnu services web)
  #:use-module (gnu services ssh)
  #:use-module (gnu services base)
  #:use-module (gnu services networking)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages curl)
  #:use-module (gnu packages ssh)
  #:use-module (gnu packages web)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages guile-xyz)   ;; for guile-goblins
  #:export (%base-hetzner-system
            make-hetzner-system))

;; TODO: replace with your actual SSH public key
(define %admin-ssh-public-key
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@host")

;; Produces a base operating-system for Hetzner x86_64 servers.
;; Inherit from %hetzner-os-x86 which handles bootloader, file systems,
;; kernel, and initrd for Hetzner's rescue + BIOS environment.
(define %base-hetzner-system
  (operating-system
    (inherit %hetzner-os-x86)

    (timezone "UTC")
    (locale "en_US.utf8")

    ;; A deploy user with NOPASSWD sudo — required so guix deploy can
    ;; reconfigure without root SSH (guix deploy docs section 11.17).
    (users (cons*
            (user-account
             (name "deploy")
             (group "users")
             (supplementary-groups '("wheel"))
             (home-directory "/home/deploy")
             (shell (file-append bash "/bin/bash")))
            ;; Unprivileged user for xorg org processes.
            ;; Each xorg Shepherd service runs as this user.
            (user-account
             (name "xorg")
             (group "users")
             (system? #t)
             (home-directory "/var/lib/xorg")
             (shell (file-append bash "/bin/bash")))
            %base-user-accounts))

    ;; Hardcoded sudoers: %sudoers-specification is not reliably
    ;; accessible as a string, so we write it directly.
    (sudoers-file
     (plain-file "sudoers"
                 "root ALL=(ALL) ALL\n%wheel ALL=(ALL) ALL\ndeploy ALL=(ALL) NOPASSWD: ALL\n"))

    (packages
     (append
      (list
       openssh
       nginx
       curl
       htop
       guile-3.0
       guile-goblins)
      %base-packages))

    (services
     (append
      (list
       ;; SSH — key-only, no passwords, no root login
       (service openssh-service-type
                (openssh-configuration
                 (openssh openssh)
                 (permit-root-login 'prohibit-password)
                 (password-authentication? #f)
                 (authorized-keys
                  `(("root"   ,(plain-file "root-key"   %admin-ssh-public-key))
                    ("deploy" ,(plain-file "deploy-key"  %admin-ssh-public-key))))))

       ;; nginx — starts with empty server blocks.
       ;; Certbot and application services extend it.
       (service nginx-service-type
                (nginx-configuration
                 (server-blocks '())))

       ;; NTP
       (service ntp-service-type))

      %base-services))))

;; Convenience constructor: produce a complete operating-system
;; for a specific hostname, inheriting from %base-hetzner-system
;; and optionally adding extra services and certbot domains.
;;
;; Example:
;;   (make-hetzner-system
;;     #:hostname "relay"
;;     #:certbot-email "ops@example.com"
;;     #:certbot-domains '("relay.example.com")
;;     #:extra-services (list (service my-app-service-type ...)))
(define* (make-hetzner-system
          #:key
          hostname
          (certbot-email #f)
          (certbot-domains '())
          (extra-services '()))
  (operating-system
    (inherit %base-hetzner-system)
    (host-name hostname)
    (services
     (append
      extra-services
      (if (and certbot-email (not (null? certbot-domains)))
          (list
           (service certbot-service-type
                    (certbot-configuration
                     (email certbot-email)
                     (certificates
                      (list
                       (certificate-configuration
                        (domains certbot-domains)))))))
          '())
      (operating-system-user-services %base-hetzner-system)))))
