;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/playnet-iso.scm — bootable Guix System ISO for the confidential-VPS provider.
;;;
;;; Two modes, chosen at build time by PLAYNET_ISO_MODE:
;;;
;;;   auto    (default) fully autonomous install on first boot. The ISO
;;;           configures networking, partitions /dev/sda, sets up a
;;;           disk-backed cow-store overlay, runs `guix system init`
;;;           against a baked-in on-disk OS config, and reboots — with no
;;;           operator at the console.
;;;   remote  an installer environment for the fleet keeper
;;;           (deploy/scripts/bootstrap-child.sh). The ISO configures
;;;           networking and opens sshd to the parent's provisioning key
;;;           (PLAYNET_FLEET_PUBKEY, a .pub file); the parent partitions,
;;;           encrypts and installs over SSH. It carries the stock
;;;           cow-store service, cryptsetup, and /etc/playnet-installer,
;;;           the file the installer requires before it touches a disk.
;;;
;;; Per-VM static-IP, gateway, and DNS are picked up from build-time
;;; env vars (PLAYNET_HOST_IP, PLAYNET_HOST_GATEWAY, PLAYNET_HOST_DNS)
;;; so one source file serves many provider hosts without per-host rebuilds.
;;;
;;;   PLAYNET_HOST_IP=… make iso
;;;   PLAYNET_ISO_MODE=remote PLAYNET_FLEET_PUBKEY=fleet.pub \
;;;     PLAYNET_HOST_IP=… make iso

(use-modules (gnu)
             (gnu packages ssh)
             (gnu packages bash)
             (gnu packages tor)
             (gnu packages disk)              ; parted
             (gnu packages linux)             ; e2fsprogs, dosfstools
             (gnu packages base)              ; coreutils, util-linux
             (gnu services ssh)
             (gnu services networking)
             (gnu services shepherd)
             (guix gexp)
             (ice-9 rdelim)
             (srfi srfi-13)
             (playnet-keys))

(define %playnet-iso-ssh-key %operator-ssh-public-key)

(define %iso-mode
  (let ((m (or (getenv "PLAYNET_ISO_MODE") "auto")))
    (unless (member m '("auto" "remote"))
      (error "PLAYNET_ISO_MODE is auto or remote, not" m))
    (string->symbol m)))
(define %remote? (eq? %iso-mode 'remote))

;; The parent's provisioning public key: the one key, besides the
;; operator's, that opens root's sshd on a remote-mode ISO.
(define %fleet-ssh-key
  (and %remote?
       (let ((file (getenv "PLAYNET_FLEET_PUBKEY")))
         (unless (and file (file-exists? file))
           (error "PLAYNET_FLEET_PUBKEY names the parent's .pub file in remote mode"))
         (let ((line (string-trim-both (call-with-input-file file read-line))))
           (unless (string-prefix? "ssh-" line)
             (error "PLAYNET_FLEET_PUBKEY holds no OpenSSH public key" file))
           line))))

(define %iso-root-keys
  (if %remote?
      (string-append %playnet-iso-ssh-key "\n" %fleet-ssh-key "\n")
      %playnet-iso-ssh-key))

;; No hardcoded default — operators MUST pass PLAYNET_HOST_IP at build
;; time. Hardcoding a real host IP here pushes the origin into the
;; public Radicle repo, defeating the whole CDN-fronts-the-origin
;; design (an attacker with the RID could grep + reach the box directly,
;; which iptables drops but which still reveals the origin location).
(define %static-ip
  (or (getenv "PLAYNET_HOST_IP")
      (error "PLAYNET_HOST_IP env var is required for the ISO build")))
(define %static-gateway (or (getenv "PLAYNET_HOST_GATEWAY") "172.16.0.1"))
(define %static-dns-1   "1.1.1.1")
(define %static-dns-2   "9.9.9.9")

;; The on-disk OS that the auto-installer writes to /dev/sda. Baked
;; into the ISO at build time so the installer doesn't need to fetch
;; or generate it at boot. Self-contained: imports only stock modules,
;; inlines the operator pubkey.
(define %post-install-config
  (mixed-text-file "playnet-post-install.scm"
"(use-modules (gnu)
             (gnu packages ssh)
             (gnu packages bash)
             (gnu packages tor)
             (gnu services ssh))

(define %ops-key
  \"" %playnet-iso-ssh-key "\")

(operating-system
  (host-name \"playnet-205\")
  (timezone \"Etc/UTC\")
  (bootloader (bootloader-configuration
               (bootloader grub-efi-bootloader)
               (targets (list \"/boot/efi\"))
               (terminal-outputs '(console))))
  (initrd-modules (append (list \"virtio_scsi\" \"virtio_blk\" \"nvme\" \"ahci\")
                          %base-initrd-modules))
  (file-systems
   (append
    (list (file-system (mount-point \"/\")
                       (device (file-system-label \"playnet-root\"))
                       (type \"ext4\"))
          (file-system (mount-point \"/boot/efi\")
                       (device (file-system-label \"EFI\"))
                       (type \"vfat\")))
    %base-file-systems))
  (users (append
           (list (user-account (name \"deploy\")  (group \"users\") (supplementary-groups '(\"wheel\"))
                               (home-directory \"/home/deploy\")  (shell (file-append bash \"/bin/bash\")))
                 (user-account (name \"playnet\") (group \"users\") (supplementary-groups '(\"wheel\"))
                               (home-directory \"/home/playnet\") (shell (file-append bash \"/bin/bash\"))))
           %base-user-accounts))
  (packages (append (map specification->package
                          '(\"openssh\" \"tor\" \"torsocks\" \"guix\" \"nss-certs\"))
                    %base-packages))
  (services
   (append
    (list
     ;; Static networking matching the provider's floating-IP linknet model.
     (service static-networking-service-type
              (list (static-networking
                     (addresses (list (network-address (device \"eth0\")
                                                       (value \"" %static-ip "/32\"))))
                     (routes
                      (list (network-route (destination \"" %static-gateway "\")
                                           (device \"eth0\"))
                            (network-route (destination \"default\")
                                           (gateway \"" %static-gateway "\")
                                           (device \"eth0\"))))
                     (name-servers '(\"" %static-dns-1 "\" \"" %static-dns-2 "\")))))
     (service openssh-service-type
              (openssh-configuration
               (openssh openssh-sans-x)
               (permit-root-login 'prohibit-password)
               (password-authentication? #f)
               (authorized-keys
                `((\"deploy\" ,(plain-file \"deploy-key\" %ops-key))
                  (\"root\"   ,(plain-file \"root-key\"   %ops-key)))))))
    %base-services)))
"))

;; Helpers of the boot-time scripts below.
(define %script-helpers
  #~(begin
      (define (sh . args)
        (let ((status (apply system* args)))
          (unless (zero? status)
            (error "command failed:" args 'status status))))
      (define (sh-ok? . args) (zero? (apply system* args)))
      (define (logf fmt . xs)
        (apply format (current-output-port) (string-append fmt "\n") xs))))

;; The static address, its gateway route and the resolvers. One script for
;; both modes: the provider's linknet gives a /32 whose gateway is reachable
;; on the link only, and dhcpcd's fallback address is overwritten here.
(define %static-net-script
  (program-file "playnet-static-net.sh"
   #~(begin
       #$%script-helpers
       (define iproute #$(file-append iproute "/sbin/ip"))
       (logf "=== networking setup ===")
       (sh-ok? iproute "addr" "flush" "dev" "eth0")
       (sh iproute "link" "set" "eth0" "up")
       (sh iproute "addr" "add" (string-append #$%static-ip "/32") "dev" "eth0")
       (sh iproute "route" "add" #$%static-gateway "dev" "eth0")
       (sh iproute "route" "add" "default" "via" #$%static-gateway
           "dev" "eth0" "src" #$%static-ip)
       ;; Replace the read-only resolv.conf symlink
       (sh-ok? "/run/current-system/profile/bin/rm" "-f" "/etc/resolv.conf")
       (call-with-output-file "/etc/resolv.conf"
         (lambda (p)
           (format p "nameserver ~a\nnameserver ~a\n"
                   #$%static-dns-1 #$%static-dns-2)))
       (logf "=== networking up ==="))))

(define playnet-static-net-service-type
  (service-type
   (name 'playnet-static-net)
   (extensions
    (list (service-extension shepherd-root-service-type
                             (lambda (_)
                               (list (shepherd-service
                                      (provision '(playnet-static-net))
                                      (requirement '(user-processes networking))
                                      (auto-start? #t)
                                      (one-shot? #t)
                                      (documentation
                                       "Give the host its static address, route and resolvers.")
                                      (start
                                       #~(make-forkexec-constructor
                                          (list #$%static-net-script)
                                          #:log-file "/var/log/playnet-static-net.log"))
                                      (stop #~(make-kill-destructor))
                                      (respawn? #f)))))))
   (description "Static address, gateway route and resolvers for the ISO.")
   (default-value #f)))

;; The auto-install script. Runs on first boot.
;; - Runs after playnet-static-net, which gives the host its address.
;; - Partitions /dev/sda, mkfs, mounts.
;; - Sets up cow-store overlay (writes go to disk, not tmpfs).
;; - Runs `guix system init --no-grafts` against the baked-in config.
;; - Logs every step to /var/log/playnet-auto-install.log so an operator
;;   can SSH in afterwards and see exactly what happened.
;; - Reboots on success. Stops on failure so we can SSH in to debug.
(define %auto-install-script
  (program-file "playnet-auto-install.sh"
   #~(begin
       (use-modules (ice-9 popen) (ice-9 rdelim) (ice-9 textual-ports))
       #$%script-helpers

       (define iproute   #$(file-append iproute "/sbin/ip"))
       (define parted    #$(file-append parted "/sbin/parted"))
       (define mkfsvfat  #$(file-append dosfstools "/sbin/mkfs.vfat"))
       (define mkfsext4  #$(file-append e2fsprogs "/sbin/mkfs.ext4"))
       (define mount-bin "/run/current-system/profile/bin/mount")
       (define umount-bin "/run/current-system/profile/bin/umount")
       (define guix-bin  "/run/current-system/profile/bin/guix")
       (define reboot-bin "/run/current-system/profile/sbin/reboot")
       (define sync-bin  "/run/current-system/profile/bin/sync")
       (define mkdir-bin "/run/current-system/profile/bin/mkdir")

       (logf "=== wait for /dev/sda ===")
       (let loop ((tries 30))
         (cond ((zero? tries) (error "timed out waiting for /dev/sda"))
               ((file-exists? "/dev/sda") (logf "ok"))
               (else (sleep 1) (loop (- tries 1)))))

       (logf "=== partition /dev/sda ===")
       (sh parted "/dev/sda" "--script" "--"
           "mklabel" "gpt"
           "mkpart" "EFI"  "fat32" "1MiB" "513MiB"
           "set" "1" "esp" "on"
           "mkpart" "root" "ext4"  "513MiB" "100%")
       (sleep 2)
       (sh-ok? "/run/current-system/profile/sbin/partprobe" "/dev/sda")
       (sleep 2)
       (sh mkfsvfat "-F32" "-n" "EFI" "/dev/sda1")
       (sh mkfsext4 "-F" "-L" "playnet-root" "/dev/sda2")

       (logf "=== mount target ===")
       (sh mount-bin "/dev/sda2" "/mnt")
       (sh mkdir-bin "-p" "/mnt/boot/efi")
       (sh mount-bin "/dev/sda1" "/mnt/boot/efi")

       (logf "=== cow-store: redirect /gnu/store writes to /mnt ===")
       (sh mkdir-bin "-p" "/mnt/.cow-upper" "/mnt/.cow-work" "/mnt/tmp" "/.rw-store")
       (sh mount-bin "--bind" "/mnt/tmp" "/tmp")
       (sh mount-bin "-t" "overlay" "none" "/.rw-store"
           "-o" "lowerdir=/gnu/store,upperdir=/mnt/.cow-upper,workdir=/mnt/.cow-work")
       (sh mount-bin "--move" "/.rw-store" "/gnu/store")

       (logf "=== install-time swap on disk ===")
       (sh "/run/current-system/profile/bin/fallocate" "-l" "4G" "/mnt/.swap")
       (sh "/run/current-system/profile/bin/chmod" "600" "/mnt/.swap")
       (sh "/run/current-system/profile/sbin/mkswap" "/mnt/.swap")
       (sh "/run/current-system/profile/sbin/swapon" "/mnt/.swap")

       (logf "=== guix system init --no-grafts (this is the slow part) ===")
       (sh guix-bin "system" "init" "--no-grafts"
           #$%post-install-config "/mnt")

       (logf "=== installed; writing success marker, syncing, rebooting ===")
       (call-with-output-file "/mnt/.PLAYNET_INSTALL_SUCCESS"
         (lambda (p) (display "ok\n" p)))
       (sh-ok? "/run/current-system/profile/sbin/swapoff" "/mnt/.swap")
       (sh-ok? "/run/current-system/profile/bin/rm" "-f" "/mnt/.swap")
       (sh sync-bin)
       (sleep 3)
       (sh-ok? umount-bin "/mnt/boot/efi")
       (sh-ok? umount-bin "/mnt")
       (sh sync-bin)
       (sleep 5)
       (logf "=== rebooting in 5s — disk install complete ===")
       (sleep 5)
       (sh reboot-bin))))

(define playnet-auto-install-service-type
  (service-type
   (name 'playnet-auto-install)
   (extensions
    (list (service-extension shepherd-root-service-type
                             (lambda (_)
                               (list (shepherd-service
                                      (provision '(playnet-auto-install))
                                      (requirement '(user-processes networking playnet-static-net))
                                      (auto-start? #t)
                                      (one-shot? #t)
                                      (documentation
                                       "Auto-install Guix System onto /dev/sda and reboot.")
                                      (start
                                       #~(make-forkexec-constructor
                                          (list #$%auto-install-script)
                                          #:log-file "/var/log/playnet-auto-install.log"))
                                      (stop #~(make-kill-destructor))
                                      (respawn? #f)))))))
   (description "Run playnet-install /dev/sda at boot then reboot.")
   (default-value #f)))

(operating-system
  (host-name "playnet")
  (timezone "Etc/UTC")
  (bootloader (bootloader-configuration
               (bootloader grub-efi-bootloader)
               (targets (list "/boot/efi"))
               (terminal-outputs '(console))))
  (initrd-modules (append
                    (list "virtio_scsi" "virtio_blk" "nvme" "ahci")
                    %base-initrd-modules))
  (file-systems (cons (file-system
                        (mount-point "/")
                        (device "playnet-root")
                        (type "ext4"))
                      %base-file-systems))

  (users (append
           (list (user-account (name "deploy")  (group "users") (supplementary-groups '("wheel"))
                               (home-directory "/home/deploy")  (shell (file-append bash "/bin/bash")))
                 (user-account (name "playnet") (group "users") (supplementary-groups '("wheel"))
                               (home-directory "/home/playnet") (shell (file-append bash "/bin/bash"))))
           %base-user-accounts))

  ;; Live ISO has parted/dosfstools so the auto-installer can partition;
  ;; a remote-mode ISO adds cryptsetup for the encrypted root the parent
  ;; sets up over SSH (util-linux, e2fsprogs and guix come with the base).
  (packages (append (map specification->package
                          (append '("openssh" "tor" "torsocks" "guix" "nss-certs"
                                    "parted" "dosfstools")
                                  (if %remote? '("cryptsetup") '())))
                    %base-packages))

  (services
   (append
    (list
     ;; Keep dhcpcd as the 'networking' provider so ssh-daemon's
     ;; shepherd dependency is satisfied. playnet-static-net gives the
     ;; host its address; dhcpcd's APIPA fallback is harmless and gets
     ;; overwritten by `ip addr flush`.
     (service dhcpcd-service-type)
     (service playnet-static-net-service-type)
     (service openssh-service-type
              (openssh-configuration
               (openssh openssh-sans-x)
               (permit-root-login 'prohibit-password)
               (password-authentication? #f)
               (authorized-keys
                `(("deploy" ,(plain-file "deploy-key" %playnet-iso-ssh-key))
                  ("root"   ,(plain-file "root-key"   %iso-root-keys))))))
     (service tor-service-type
              (tor-configuration
               (hidden-services
                (list (tor-onion-service-configuration
                       (name "playnet-iso")
                       (mapping '((22 "127.0.0.1:22"))))))))
     ;; The file bootstrap-child.sh requires before it touches a disk:
     ;; this image is an installer environment.
     (simple-service 'playnet-installer-marker etc-service-type
                     `(("playnet-installer" ,(plain-file "playnet-installer" "installer\n")))))
    (if %remote?
        ;; `herd start cow-store /mnt` sends the installer's store writes
        ;; to the target disk, as on the stock installation image.
        ;; (gnu system install) defines the service type without exporting it.
        (list (service (@@ (gnu system install) cow-store-service-type) 'mooooo))
        ;; The autonomous installer.
        (list (service playnet-auto-install-service-type)))
    %base-services)))
