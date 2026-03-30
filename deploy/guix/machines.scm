;;; deploy/guix/machines.scm — guix deploy target machines
;;;
;;; Usage (from project root):
;;;   guix deploy deploy/guix/machines.scm
;;;
;;; The server was bootstrapped with bootstrap-hetzner.sh (EFI/x86_64).
;;; Now managed via managed-host-environment-type per Guix manual §11.17.
;;;
;;; Users:
;;;   deploy     — system administration, guix deploy
;;;   playnet    — live hacking: Emacs/Geiser, dev REPL
;;;   playnet       — system account for production playnet Shepherd services
;;;   sapient-os — sapient-os agent user

(use-modules (gnu machine)
             (gnu machine ssh)
             (gnu packages admin)
             (gnu packages bash)
             (gnu packages emacs)
             (gnu packages emacs-xyz)
             (gnu packages guile)
             (gnu packages guile-xyz)
             (gnu packages messaging)
             (gnu packages version-control)
             (gnu packages ssh)
             (python-rns)
             (reticulum-service)
             (gnu services base)
             (gnu services networking)
             (gnu services shepherd)
             (gnu services ssh)
             (gnu services web)
             (gnu system linux-initrd)
             (gnu)
             (guix gexp)
             (playnet-gateway-service))

(define %this-dir
  (dirname (or (current-filename)
               (canonicalize-path "deploy/guix/machines.scm"))))

;; Load the playnet package from guix.scm (provides bin/meta-org-relay)
(define %playnet-package
  (load (string-append %this-dir "/../../guix.scm")))

(define %admin-ssh-public-key
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICTLO20IW4Ej9qhXYGnfy0yc8RlvMLEkR+MG39nyK5mq nozomi-laptop")

(define %ci-ssh-public-key
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN3Bhkk/WiuQY0O7sk8Ek/sVqOfkP7NXy3gJEstXWm+x github-actions-deploy")

;; Dynamic users: list of (username . ssh-pubkey) pairs.
;; Managed by provision-user.scm — do not edit users.scm by hand.

(define %dynamic-users
  (primitive-load
   (string-append %this-dir "/users.scm")))

(define %dynamic-user-names (map car %dynamic-users))

;; Helper script for synchronous REPL eval from the command line.
(define %repl-eval-script
  (local-file "../scripts/repl-eval"))

;; Emacs init.el for the playnet user — deployed via activation service.
(define %emacs-init-el
  (plain-file "init.el"
    ";;; playnet Emacs daemon configuration
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
(setq geiser-guile-load-path '(\"/home/playnet/playnet-repo/module\"))

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
(setq playnet-project-root \"/home/playnet/playnet-repo\")

;; Helper: read REPL output after sending
(defun playnet-repl-output ()
  \"Return recent output from the Geiser REPL buffer.\"
  (when-let ((buf (get-buffer \"*Geiser Guile REPL*\")))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-max))
        (forward-line -20)
        (buffer-substring-no-properties (point) (point-max))))))

(message \"playnet Emacs daemon ready\")"))

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

    ;; Static accounts:
    ;;   deploy     — system administration, guix deploy (wheel + NOPASSWD sudo)
    ;;   playnet    — live hacking: Emacs/Geiser, dev REPL
    ;;   playnet       — system account for production playnet Shepherd services
    ;; Dynamic accounts (from users.scm, managed by provision-user.scm):
    ;;   sapient-os — sapient-os agent user (own key)
    ;;   …          — any future provisioned users
    (users (append
            (list
             (user-account
              (name "deploy")
              (group "users")
              (supplementary-groups '("wheel"))
              (home-directory "/home/deploy")
              (shell (file-append bash "/bin/bash")))
             (user-account
              (name "playnet")
              (group "users")
              (home-directory "/home/playnet")
              (shell (file-append bash "/bin/bash")))
             (user-account
              (name "playnet")
              (group "users")
              (system? #t)
              (home-directory "/var/lib/playnet")
              (shell (file-append bash "/bin/bash"))))
            ;; All users from users.scm (sapient-os + any provisioned accounts)
            (map (lambda (entry)
                   (user-account
                    (name (car entry))
                    (group "users")
                    (home-directory (string-append "/home/" (car entry)))
                    (shell (file-append bash "/bin/bash"))))
                 %dynamic-users)
            %base-user-accounts))

    (sudoers-file
     (plain-file "sudoers"
       (string-append
        "root ALL=(ALL) ALL\n"
        "%wheel ALL=(ALL) ALL\n"
        "deploy ALL=(ALL) NOPASSWD: ALL\n"
        ;; Allow the relay (playnet user) to spawn login shells as provisioned users
        "playnet ALL=(ALL) NOPASSWD: /usr/bin/env su - *\n")))

    (packages
     (append
      (list guile-goblins
            guile-fibers
            emacs-no-x
            emacs-geiser
            emacs-geiser-guile
            emacs-smartparens
            emacs-rainbow-delimiters
            emacs-claude-code-ide
            htop
            git
            mosquitto
            guile-mqtt
            guile-json-4
            python-rns)
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
                   ("root"   ,(plain-file "ci-root-key" %ci-ssh-public-key))
                   ("deploy" ,(plain-file "deploy-key" %admin-ssh-public-key))
                   ("deploy" ,(plain-file "ci-deploy-key" %ci-ssh-public-key))
                   ("playnet",(plain-file "playnet-key" %admin-ssh-public-key))
                   ;; Dynamic users — each gets their own registered public key
                   ,@(map (lambda (entry)
                            (list (car entry)
                                  (plain-file (string-append (car entry) "-key")
                                              (cdr entry))))
                          %dynamic-users)))))

      ;; OCapN gateway — capability-secure communication over WebSocket + Reticulum
      (service playnet-gateway-service-type
               (playnet-gateway-configuration
                (package %playnet-package)
                (port 9090)
                (environment
                 `(("API_KEYS" . ,(or (getenv "API_KEYS")
                                      (getenv "OPENROUTER_KEYS") ""))))))

      ;; Dev REPL — Guile on a Unix socket, runs as playnet user.
      ;; Connect with: M-x geiser-connect-local RET guile RET /var/run/playnet/repl.sock
      ;; Manual start only: herd start playnet-repl
      (simple-service 'playnet-repl
                      shepherd-root-service-type
                      (list (shepherd-service
                             (provision '(playnet-repl))
                             (documentation "Guile REPL for live hacking via Geiser")
                             (requirement '(networking user-processes))
                             (start #~(make-forkexec-constructor
                                       (list #$(file-append guile-3.0 "/bin/guile")
                                             "-L" "/home/playnet/playnet-repo/module"
                                             "-c"
                                             "(use-modules (system repl server)) (run-server (make-unix-domain-server-socket #:path \"/var/run/playnet/repl.sock\"))")
                                       #:user "playnet"
                                       #:group "users"
                                       #:log-file "/var/log/playnet-repl.log"
                                       #:environment-variables
                                       (list (string-append "GUILE_LOAD_PATH="
                                              "/run/current-system/profile/share/guile/site/3.0:"
                                              "/home/playnet/playnet-repo/module")
                                             (string-append "GUILE_LOAD_COMPILED_PATH="
                                              "/run/current-system/profile/lib/guile/3.0/site-ccache")
                                             "HOME=/home/playnet")))
                             (stop #~(lambda (pid)
                                      ((make-kill-destructor) pid)
                                      (when (file-exists? "/var/run/playnet/repl.sock")
                                        (delete-file "/var/run/playnet/repl.sock"))
                                      #f))
                             (respawn? #f)
                             (auto-start? #f))))

      ;; Mosquitto MQTT broker — localhost only, for VF bridge.
      ;; Sensors and bridge actors connect locally; no external exposure.
      (simple-service 'mosquitto
                      shepherd-root-service-type
                      (list (shepherd-service
                             (provision '(mosquitto))
                             (documentation "MQTT broker for VF event bridge")
                             (requirement '(networking))
                             (start #~(make-forkexec-constructor
                                       (list #$(file-append mosquitto "/sbin/mosquitto")
                                             "-c" #$(plain-file "mosquitto.conf"
                                                     "listener 1883 127.0.0.1\nallow_anonymous true\nlog_dest stderr\n"))
                                       #:log-file "/var/log/mosquitto.log"))
                             (stop #~(make-kill-destructor))
                             (respawn? #t))))

      ;; Dev bridge — MQTT subscriber that launches Claude Code on deficit signals.
      ;; The VF planner emits development deficit signals; this bridge acts on them.
      ;; Manual start only: herd start dev-bridge
      (simple-service 'dev-bridge
                      shepherd-root-service-type
                      (list (shepherd-service
                             (provision '(dev-bridge))
                             (documentation "MQTT → Claude Code development bridge")
                             (requirement '(networking mosquitto))
                             (start #~(make-forkexec-constructor
                                       (list #$(file-append guile-3.0 "/bin/guile")
                                             "--no-auto-compile"
                                             "-L" "/home/playnet/playnet-repo/module"
                                             "-s" "/home/playnet/playnet-repo/server/dev-bridge.scm")
                                       #:user "playnet"
                                       #:group "users"
                                       #:log-file "/var/log/dev-bridge.log"
                                       #:environment-variables
                                       (list (string-append "GUILE_LOAD_PATH="
                                              "/run/current-system/profile/share/guile/site/3.0:"
                                              "/home/playnet/playnet-repo/module")
                                             "HOME=/home/playnet"
                                             "DEV_CHECKOUT_DIR=/home/playnet/dev-checkout"
                                             (string-append "PATH="
                                              "/run/current-system/profile/bin:"
                                              "/home/playnet/.local/bin:"
                                              "/run/current-system/profile/sbin"))))
                             (stop #~(make-kill-destructor))
                             (respawn? #t)
                             (auto-start? #f))))

      ;; Reticulum mesh networking — rnsd daemon + OCapN bridge.
      ;; Enables Goblins actors over LoRa, serial, TCP, I2P, packet radio.
      (service rnsd-service-type)
      (service reticulum-bridge-service-type)

      ;; Activation: set up playnet user environment.
      ;; Uses mkdir-p because on first deploy, user-homes may not have
      ;; created the home directory yet when activation runs.
      (simple-service 'playnet-setup
                      activation-service-type
                      #~(begin
                          (use-modules (guix build utils))
                          (let ((pw (getpwnam "playnet")))
                            ;; Home directory (mkdir-p may create it before user-homes)
                            (mkdir-p "/home/playnet")
                            (chown "/home/playnet" (passwd:uid pw) (passwd:gid pw))
                            ;; Socket directory for REPL (playnet-writable, on tmpfs)
                            (let ((run-dir "/var/run/playnet"))
                              (mkdir-p run-dir)
                              (chown run-dir (passwd:uid pw) (passwd:gid pw)))
                            ;; Emacs config
                            (let* ((emacs-dir "/home/playnet/.emacs.d")
                                   (init-target (string-append emacs-dir "/init.el")))
                              (mkdir-p emacs-dir)
                              (when (file-exists? init-target)
                                (delete-file init-target))
                              (copy-file #$%emacs-init-el init-target)
                              (chown init-target (passwd:uid pw) (passwd:gid pw))
                              (chown emacs-dir (passwd:uid pw) (passwd:gid pw)))
                            ;; Helper scripts
                            (let* ((bin-dir "/home/playnet/bin")
                                   (repl-eval (string-append bin-dir "/repl-eval")))
                              (mkdir-p bin-dir)
                              (when (file-exists? repl-eval)
                                (delete-file repl-eval))
                              (copy-file #$%repl-eval-script repl-eval)
                              (chmod repl-eval #o755)
                              (chown repl-eval (passwd:uid pw) (passwd:gid pw))
                              (chown bin-dir (passwd:uid pw) (passwd:gid pw)))
                            ;; Symlink to packaged code (immutable, from Guix store)
                            (let ((repo-dir "/home/playnet/playnet-repo")
                                  (pkg-dir (string-append #$%playnet-package "/share/playnet")))
                              (when (and (file-exists? repo-dir)
                                         (not (symbolic-link? repo-dir)))
                                ;; Existing mutable clone — remove it
                                (system* "rm" "-rf" repo-dir))
                              (unless (file-exists? repo-dir)
                                (symlink pkg-dir repo-dir)))
                            ;; Writable dev checkout for self-improvement agent
                            ;; (mutable clone, separate from immutable Guix store symlink)
                            (let ((dev-dir "/home/playnet/dev-checkout"))
                              (unless (file-exists? dev-dir)
                                (system* "git" "clone"
                                         "https://github.com/interplaynetary/xorg.git"
                                         dev-dir)
                                (chown dev-dir (passwd:uid pw) (passwd:gid pw)))))))

      ;; Activation: set up dynamic user home directories.
      ;; For each user in users.scm: ensure home exists, correct ownership,
      ;; and symlink to packaged code.
      (simple-service 'dynamic-user-setup
                      activation-service-type
                      #~(begin
                          (use-modules (guix build utils))
                          (for-each
                           (lambda (username)
                             (let* ((home     (string-append "/home/" username))
                                    (repo-dir (string-append home "/playnet-repo"))
                                    (bin-dir  (string-append home "/bin"))
                                    (pkg-dir  (string-append #$%playnet-package "/share/playnet"))
                                    (pw       (false-if-exception (getpwnam username))))
                               (when pw
                                 ;; Home dir
                                 (mkdir-p home)
                                 (chown home (passwd:uid pw) (passwd:gid pw))
                                 ;; ~/bin
                                 (mkdir-p bin-dir)
                                 (chown bin-dir (passwd:uid pw) (passwd:gid pw))
                                 ;; Symlink to packaged code
                                 (unless (file-exists? repo-dir)
                                   (symlink pkg-dir repo-dir)))))
                           '#$%dynamic-user-names)))

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
                       (identity (or (getenv "DEPLOY_SSH_IDENTITY")
                          "/home/nozomi/.ssh/id_ed25519"))
                       (host-key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE7y+yzSS5w+oDfeG8pKgpbcB+Xd2W+WxV1/kAn6Fnlk")))))
