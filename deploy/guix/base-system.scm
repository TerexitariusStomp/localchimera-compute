;;; deploy/guix/base-system.scm — base operating system for Hetzner machines
;;;
;;; Inherit from %hetzner-os-x86 (built into Guix) and add:
;;; - openssh with key-based auth, no passwords
;;; - nginx (services can extend it)
;;; - certbot for automatic TLS (extends nginx)
;;; - ntp
;;; - a deploy user with NOPASSWD sudo (required by guix deploy for non-root login)
;;; - Emacs + Geiser for live Goblins REPL hacking

(define-module (base-system)
  #:use-module (gnu)
  #:use-module (gnu machine hetzner)
  #:use-module (gnu services certbot)
  #:use-module (gnu services web)
  #:use-module (gnu services ssh)
  #:use-module (gnu services base)
  #:use-module (gnu services networking)
  #:use-module (gnu services shepherd)     ;; shepherd-root-service-type
  #:use-module (gnu packages admin)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages curl)
  #:use-module (gnu packages ssh)
  #:use-module (gnu packages web)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages guile-xyz)    ;; for guile-goblins
  #:use-module (gnu packages emacs)        ;; emacs-no-x
  #:use-module (gnu packages emacs-xyz)    ;; geiser, smartparens, rainbow-delimiters
  #:export (%base-hetzner-system
            make-hetzner-system))

;; TODO: replace with your actual SSH public key
(define %admin-ssh-public-key
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@host")

;; Minimal Emacs config for Geiser + Goblins hacking.
;; Deployed to /home/deploy/.emacs.d/init.el via activation service.
(define %emacs-init-el
  (plain-file "init.el"
    "(require 'geiser-guile)
(show-paren-mode 1)
(require 'smartparens-config)
(smartparens-global-mode 1)
(require 'rainbow-delimiters)
(add-hook 'scheme-mode-hook #'rainbow-delimiters-mode)

;; Geiser default implementation
(setq geiser-default-implementation 'guile)

;; IMPORTANT: run (use-modules (goblins)) first in the REPL before
;; doing any vat work, to avoid the port-redirection issue described
;; in the Goblins README.
(message \"Remember: (use-modules (goblins)) before spawning vats!\")"))

;; Development REPL service — starts Guile listening on a Unix socket.
;; Connect with: M-x geiser-connect-local RET guile RET /var/run/xorg-dev.sock RET
;; Manual start only (security): herd start xorg-dev-repl
(define %xorg-dev-repl-service
  (shepherd-service
   (provision '(xorg-dev-repl))
   (documentation "Guile REPL for live xorg hacking via Geiser")
   (requirement '(networking))
   (start #~(make-forkexec-constructor
             (list #$(file-append guile-3.0 "/bin/guile")
                   "--listen=/var/run/xorg-dev.sock")
             #:log-file "/var/log/xorg-dev-repl.log"))
   (stop #~(make-kill-destructor))
   (respawn? #f)
   (auto-start? #f)))

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
       guile-goblins
       ;; Emacs + Geiser for live Goblins hacking
       emacs-no-x              ;; terminal Emacs (no X11 needed on server)
       emacs-geiser            ;; Geiser for Guile REPL integration
       emacs-geiser-guile      ;; Guile backend for Geiser
       emacs-smartparens       ;; structural editing
       emacs-rainbow-delimiters) ;; colored parens
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
       (service ntp-service-type)

       ;; Dev REPL — manual start only (herd start xorg-dev-repl)
       (simple-service 'xorg-dev-repl
                       shepherd-root-service-type
                       (list %xorg-dev-repl-service))

       ;; Deploy Emacs config for the deploy user
       (simple-service 'deploy-emacs-config
                       activation-service-type
                       #~(begin
                           (let* ((dir "/home/deploy/.emacs.d")
                                  (target (string-append dir "/init.el")))
                             (unless (file-exists? dir)
                               (mkdir dir))
                             (when (file-exists? target)
                               (delete-file target))
                             (copy-file #$%emacs-init-el target)
                             (let ((pw (getpwnam "deploy")))
                               (chown dir (passwd:uid pw) (passwd:gid pw))
                               (chown target (passwd:uid pw) (passwd:gid pw)))))))

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
