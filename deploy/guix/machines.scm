;;; deploy/guix/machines.scm — guix deploy target machines
;;;
;;; Usage (from project root):
;;;   guix deploy deploy/guix/machines.scm
;;;
;;; The server was bootstrapped with bootstrap-hetzner.sh (EFI/x86_64).
;;; Now managed via managed-host-environment-type per Guix manual §11.17.

(use-modules (gnu machine)
             (gnu machine ssh)
             (gnu packages admin)
             (gnu packages bash)
             (gnu packages emacs)
             (gnu packages emacs-xyz)
             (gnu packages guile)
             (gnu packages guile-xyz)
             (gnu packages version-control)
             (gnu packages ssh)
             (gnu services base)
             (gnu services networking)
             (gnu services shepherd)
             (gnu services ssh)
             (gnu system linux-initrd)
             (gnu)
             (guix gexp))

(define %guix-x86
  (operating-system
    (host-name "guix-x86")
    (timezone "Etc/UTC")
    (bootloader (bootloader-configuration
                 (bootloader grub-efi-bootloader)
                 (targets (list "/boot/efi"))
                 (terminal-outputs '(console))
                 (theme #f)))
    (initrd-modules (append
                     (list "virtio_scsi")
                     %base-initrd-modules))
    (file-systems (cons* (file-system
                           (mount-point "/")
                           (device "/dev/sda1")
                           (type "ext4"))
                         (file-system
                           (mount-point "/boot/efi")
                           (device "/dev/sda15")
                           (type "vfat"))
                         %base-file-systems))

    (packages
     (append
      (list guile-goblins
            emacs-no-x
            emacs-geiser
            emacs-geiser-guile
            emacs-smartparens
            emacs-rainbow-delimiters
            emacs-claude-code-ide
            htop
            git)
      %base-packages))

    (services
     (cons*
      ;; Networking
      (service dhcpcd-service-type)

      ;; SSH — key-only, no passwords
      (service openssh-service-type
               (openssh-configuration
                (openssh openssh-sans-x)
                (permit-root-login 'prohibit-password)))

      ;; Dev REPL — Guile's built-in server on a Unix socket.
      ;; Connect with: M-x geiser-connect-local RET guile RET /var/run/xorg-dev.sock
      ;; Manual start only: herd start xorg-dev-repl
      (simple-service 'xorg-dev-repl
                      shepherd-root-service-type
                      (list (shepherd-service
                             (provision '(xorg-dev-repl))
                             (documentation "Guile REPL for live xorg hacking via Geiser")
                             (requirement '(networking))
                             (start #~(make-forkexec-constructor
                                       (list #$(file-append guile-3.0 "/bin/guile")
                                             "--listen=/var/run/xorg-dev.sock")
                                       #:log-file "/var/log/xorg-dev-repl.log"))
                             (stop #~(make-kill-destructor))
                             (respawn? #f)
                             (auto-start? #f))))

      ;; Use bordeaux as primary substitute server (ci.guix.gnu.org is unreliable)
      (modify-services %base-services
        (guix-service-type config =>
          (guix-configuration
           (inherit config)
           (substitute-urls '("https://bordeaux.guix.gnu.org"))
           (authorized-keys
            (cons (local-file "/etc/guix/signing-key.pub")
                  (guix-configuration-authorized-keys config))))))))))

(list (machine
       (operating-system %guix-x86)
       (environment managed-host-environment-type)
       (configuration (machine-ssh-configuration
                       (host-name "SERVER_IP")
                       (system "x86_64-linux")
                       (identity "/home/nozomi/.ssh/id_ed25519")
                       (host-key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE7y+yzSS5w+oDfeG8pKgpbcB+Xd2W+WxV1/kAn6Fnlk")))))
