;;; deploy/guix/machines.scm — guix deploy target machines
;;;
;;; Usage (from project root):
;;;   guix deploy deploy/guix/machines.scm
;;;
;;; The server was bootstrapped with bootstrap-hetzner.sh (EFI/x86_64).
;;; Now managed via managed-host-environment-type per Guix manual §11.17.
;;;
;;; Users:
;;;   deploy — runs Emacs/Geiser, guix deploy, dev REPL (interactive use)
;;;   xorg   — runs xorg Shepherd services (host org, etc.)

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

(define %admin-ssh-public-key
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICTLO20IW4Ej9qhXYGnfy0yc8RlvMLEkR+MG39nyK5mq nozomi-laptop")

;; Emacs init.el for the deploy user — deployed via activation service.
(define %emacs-init-el
  (plain-file "init.el"
    ";;; xorg Emacs daemon configuration
;;; Runs headless — Claude Code accesses via emacsclient

(require 'geiser)
(require 'geiser-guile)
(require 'geiser-eval)
(require 'geiser-connection)
(require 'geiser-doc)
(require 'geiser-xref)
(require 'geiser-edit)
(require 'geiser-completion)
(require 'smartparens-config)
(require 'rainbow-delimiters)

;; Geiser config
(setq geiser-guile-binary \"guile\")
(setq geiser-active-implementations '(guile))
(setq geiser-guile-load-path '(\"/home/deploy/xorg-repo/module\"))

;; Smartparens globally
(smartparens-global-mode 1)
(show-paren-mode 1)

;; Rainbow delimiters for Scheme
(add-hook 'scheme-mode-hook #'rainbow-delimiters-mode)

;; TCP server for remote emacsclient access
(require 'server)
(setq server-use-tcp t)
(setq server-host \"127.0.0.1\")
(setq server-port 9999)

;; Project root
(setq xorg-project-root \"/home/deploy/xorg-repo\")

;; Helper: read REPL output after sending
(defun xorg-repl-output ()
  \"Return recent output from the Geiser REPL buffer.\"
  (when-let ((buf (get-buffer \"*Geiser Guile REPL*\")))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-max))
        (forward-line -20)
        (buffer-substring-no-properties (point) (point-max))))))

(message \"xorg Emacs daemon ready\")"))

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

    ;; deploy: interactive use (Emacs, Geiser, guix deploy)
    ;; xorg:   system account for xorg Shepherd services
    (users (cons*
            (user-account
             (name "deploy")
             (group "users")
             (supplementary-groups '("wheel"))
             (home-directory "/home/deploy")
             (shell (file-append bash "/bin/bash")))
            (user-account
             (name "xorg")
             (group "users")
             (system? #t)
             (home-directory "/var/lib/xorg")
             (shell (file-append bash "/bin/bash")))
            %base-user-accounts))

    (sudoers-file
     (plain-file "sudoers"
       "root ALL=(ALL) ALL\n%wheel ALL=(ALL) ALL\ndeploy ALL=(ALL) NOPASSWD: ALL\n"))

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
                (permit-root-login 'prohibit-password)
                (password-authentication? #f)
                (authorized-keys
                 `(("root"   ,(plain-file "root-key"   %admin-ssh-public-key))
                   ("deploy" ,(plain-file "deploy-key"  %admin-ssh-public-key))))))

      ;; Dev REPL — Guile on a Unix socket, runs as deploy user.
      ;; Connect with: M-x geiser-connect-local RET guile RET /var/run/xorg/dev.sock
      ;; Manual start only: herd start xorg-dev-repl
      (simple-service 'xorg-dev-repl
                      shepherd-root-service-type
                      (list (shepherd-service
                             (provision '(xorg-dev-repl))
                             (documentation "Guile REPL for live xorg hacking via Geiser")
                             (requirement '(networking user-processes))
                             (start #~(make-forkexec-constructor
                                       (list #$(file-append guile-3.0 "/bin/guile")
                                             "-L" "/home/deploy/xorg-repo/module"
                                             "-c"
                                             "(use-modules (system repl server)) (run-server (make-unix-domain-server-socket #:path \"/var/run/xorg/dev.sock\"))")
                                       #:user "deploy"
                                       #:group "users"
                                       #:log-file "/var/log/xorg-dev-repl.log"))
                             (stop #~(make-kill-destructor))
                             (respawn? #f)
                             (auto-start? #f))))

      ;; Activation: set up deploy user environment.
      ;; Uses mkdir-p because on first deploy, user-homes may not have
      ;; created /home/deploy yet when activation runs.
      (simple-service 'deploy-setup
                      activation-service-type
                      #~(begin
                          (use-modules (guix build utils))
                          ;; Socket directory for REPL (deploy-writable, on tmpfs)
                          (let ((run-dir "/var/run/xorg"))
                            (mkdir-p run-dir)
                            (let ((pw (getpwnam "deploy")))
                              (chown run-dir (passwd:uid pw) (passwd:gid pw))))
                          ;; Emacs config
                          (let* ((emacs-dir "/home/deploy/.emacs.d")
                                 (init-target (string-append emacs-dir "/init.el")))
                            (mkdir-p emacs-dir)
                            (when (file-exists? init-target)
                              (delete-file init-target))
                            (copy-file #$%emacs-init-el init-target)
                            (let ((pw (getpwnam "deploy")))
                              (chown init-target (passwd:uid pw) (passwd:gid pw))
                              (chown emacs-dir (passwd:uid pw) (passwd:gid pw))))
                          ;; Helper scripts directory
                          (let ((bin-dir "/home/deploy/bin"))
                            (mkdir-p bin-dir)
                            (let ((pw (getpwnam "deploy")))
                              (chown bin-dir (passwd:uid pw) (passwd:gid pw))))))

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
