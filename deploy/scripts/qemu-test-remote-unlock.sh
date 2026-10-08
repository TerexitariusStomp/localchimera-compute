#!/usr/bin/env bash
# qemu-test-remote-unlock.sh — prove the initrd SSH unlock door in a local VM.
#
# Usage:
#   deploy/scripts/qemu-test-remote-unlock.sh
#
# Runs unprivileged, end to end:
#   1. makes test keys (parent, operator, initrd host key) and a passphrase;
#   2. fills deploy/fleet-child-os.scm.example for QEMU's user network
#      (10.0.2.15/24, gateway 10.0.2.2) and builds that system on the host;
#   3. builds an installer VM (`guix system vm`, host store shared over 9p)
#      whose one job, as root inside QEMU, is: GPT + LUKS + mkfs on a blank
#      qcow2, then the steps of `guix system init` (populate the root, copy
#      and register the closure, grub-install, grub.cfg);
#   4. boots the disk under UEFI firmware with hostfwd :$SSH_PORT -> :22 and
#      checks: the initrd host key answers, a wrong passphrase exits 1 and
#      the door stays, a foreign key is refused, the right passphrase exits
#      0, the booted sshd answers with its own host key, / is the LUKS
#      mapping, /gnu/store is the plain partition;
#   5. reboots the guest and unlocks it a second time.
#
# Env vars:
#   WORK=DIR        scratch directory (default /tmp/claude-1000/remote-unlock-proof)
#   SSH_PORT=N      forwarded host port (default 2222)
#   KEEP_DISK=1     reuse $WORK/target.qcow2 and skip steps 2–3
#   FIRMWARE=bios   install grub-bootloader and boot with SeaBIOS
#                   (default: uefi)
#
# Exit status 0 means every check passed.  Logs: $WORK/*.log.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${WORK:-/tmp/claude-1000/remote-unlock-proof}"
SSH_PORT="${SSH_PORT:-2222}"
FIRMWARE="${FIRMWARE:-uefi}"
PASSPHRASE='correct horse battery staple'

LUKS_UUID=11111111-2222-4333-8444-555555555555
STORE_UUID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
ESP_ID=1234ABCD

mkdir -p "$WORK"
cd "$WORK"

say()  { printf '\n=== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# QEMU and the firmware come from Guix; they need no profile.
QEMU_DIR=$(guix build qemu | grep -v -- '-doc$\|-static$' | head -1)
QEMU="$QEMU_DIR/bin/qemu-system-x86_64"
QEMU_IMG="$QEMU_DIR/bin/qemu-img"
OVMF="$(guix build ovmf-x86-64 | tail -1)/share/firmware/ovmf_x64.bin"
ACCEL=tcg
[[ -r /dev/kvm && -w /dev/kvm ]] && ACCEL=kvm

# ── 1. keys ────────────────────────────────────────────────────────────
for key in parent_key operator_key initrd_host_key; do
  [[ -f $key ]] || ssh-keygen -q -t ed25519 -N '' -C "$key" -f "$key"
done

# ── 2. the child system, from the one template ─────────────────────────
BOOTLOADER_TARGET=/dev/vda    # a BIOS host's GRUB goes on the disk; UEFI needs none

fill_template() {
  # The host's initrd door key is the one this box's record holds for it.
  local kdir="$WORK/data/fleet-children/fleet-child"
  mkdir -p -m 700 "$kdir"
  cp initrd_host_key "$kdir/initrd-host-key"
  cp initrd_host_key.pub "$kdir/initrd-host-key.pub"
  guile --no-auto-compile -L "$REPO/module" \
    "$REPO/deploy/scripts/render-child-os.scm" fleet-child \
    --data-dir "$WORK/data" --deploy-dir "$REPO/deploy" \
    --identity-pub parent_key.pub --root-key operator_key.pub \
    --address 10.0.2.15 --prefix 24 --gateway 10.0.2.2 \
    --name-server 10.0.2.3 --kernel-arg console=ttyS0,115200 \
    --luks-uuid "$LUKS_UUID" --store-uuid "$STORE_UUID" \
    --esp-uuid "${ESP_ID:0:4}-${ESP_ID:4:4}" \
    $([[ "$FIRMWARE" == bios ]] && echo "--bios $BOOTLOADER_TARGET" || echo --uefi) \
    > child-os.scm
}

# ── 3. the installer VM ────────────────────────────────────────────────
write_installer() {
  cat > installer-os.scm <<'EOF'
;; Installer VM.  As root inside QEMU it partitions the blank target disk,
;; formats LUKS, and performs the steps of `guix system init' from the
;; host's store, which `guix system vm' shares read-only over 9p.
(use-modules (gnu) (gnu system) (gnu bootloader) (gnu bootloader grub)
             (gnu services shepherd)
             (gnu packages linux) (gnu packages disk) (gnu packages cryptsetup)
             (gnu packages bootloaders) (gnu packages guile) (gnu packages gnupg)
             (gnu packages admin)
             (guix gexp) (guix modules)
             ((guix self) #:select (make-config.scm)))

;; (guix …) and (gnu …) modules, leaving out (guix config) and (guix git).
(define (neither-config-nor-git? name)
  (and (guix-module-name? name)
       (not (equal? name '(guix config)))
       (not (equal? name '(guix git)))))

(define here (dirname (current-filename)))
(define child-os (load (string-append here "/child-os.scm")))
(define bootcfg (operating-system-bootcfg child-os))
(define passphrase (getenv "REMOTE_UNLOCK_TEST_PASSPHRASE"))
(define bios? (equal? (getenv "REMOTE_UNLOCK_TEST_FIRMWARE") "bios"))

(define closure-graphs
  (computed-file "child-closures"
                 #~(begin (mkdir #$output)
                          (copy-file "system" (string-append #$output "/system"))
                          (copy-file "bootcfg" (string-append #$output "/bootcfg")))
                 #:options `(#:references-graphs (("system" ,child-os)
                                                  ("bootcfg" ,bootcfg)))))

(define schema
  (local-file (search-path %load-path "guix/store/schema.sql")))

(define install-program
  (program-file
   "install-child"
   (with-extensions (list guile-sqlite3 guile-gcrypt)
     (with-imported-modules `(,@(source-module-closure
                                 '((gnu build install)
                                   (guix build utils)
                                   (guix build store-copy)
                                   (guix store database))
                                 #:select? neither-config-nor-git?)
                              ((guix config) => ,(make-config.scm)))
       #~(begin
           (use-modules (gnu build install) (guix build store-copy)
                        (guix store database)
                        (guix build utils) (ice-9 popen))
           ;; Store file names are UTF-8.
           (setlocale LC_ALL "C.UTF-8")
           (define disk "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_TARGET")
           (define (part n)
             (string-append (canonicalize-path disk) (number->string n)))
           (define graphs (list #$(file-append closure-graphs "/system")
                                #$(file-append closure-graphs "/bootcfg")))
           (define (pipe-to input program . args)
             (let ((port (apply open-pipe* OPEN_WRITE program args)))
               (display input port)
               (unless (zero? (status:exit-val (close-pipe port)))
                 (error "failed" program args))))
           (define (register-closure prefix closure)
             (let ((items (call-with-input-file closure read-reference-graph)))
               (parameterize ((sql-schema #$schema))
                 (with-database (store-database-file #:prefix prefix) db
                   #:wal-mode? #f
                   (register-items db items
                                   #:prefix prefix
                                   #:registration-time %epoch)))))
           (setenv "PATH" (string-join
                           (map (lambda (p) (string-append p "/sbin:" p "/bin"))
                                '(#$util-linux #$e2fsprogs #$dosfstools
                                  #$cryptsetup #$coreutils #$eudev))
                           ":"))
           (let loop ((n 30))
             (unless (or (file-exists? disk) (zero? n)) (sleep 1) (loop (- n 1))))
           ;; 1 BIOS boot, 2 ESP (/boot), 3 plain store, 4 LUKS root.
           (pipe-to (string-append
                     "label: gpt\n"
                     "size=1M, type=21686148-6449-6E6F-744E-656564454649, name=bios\n"
                     "size=300M, type=U, name=esp\n"
                     "size=5G, type=L, name=store\n"
                     "type=L, name=cryptroot\n")
                    "sfdisk" disk)
           (invoke "udevadm" "settle")
           (invoke "mkfs.fat" "-F" "32" "-i" #$(getenv "REMOTE_UNLOCK_TEST_ESP_ID")
                   "-n" "ESP" (part 2))
           (invoke "mkfs.ext4" "-q" "-F" "-L" "store"
                   "-U" #$(getenv "REMOTE_UNLOCK_TEST_STORE_UUID") (part 3))
           ;; 128 MiB of Argon2 memory: the initrd of a small VM opens it
           ;; with room to spare.
           (pipe-to #$passphrase "cryptsetup" "luksFormat" "--batch-mode"
                    "--type" "luks2"
                    "--uuid" #$(getenv "REMOTE_UNLOCK_TEST_LUKS_UUID")
                    "--pbkdf-memory" "131072"
                    "--key-file" "-" (part 4))
           (pipe-to #$passphrase "cryptsetup" "open" "--type" "luks"
                    "--key-file" "-" (part 4) "installroot")
           (invoke "mkfs.ext4" "-q" "-F" "-L" "root" "/dev/mapper/installroot")
           (mkdir-p "/mnt")
           (invoke "mount" "/dev/mapper/installroot" "/mnt")
           (mkdir-p "/mnt/gnu/store")
           (mkdir-p "/mnt/boot")
           (invoke "mount" (part 3) "/mnt/gnu/store")
           (false-if-exception (rmdir "/mnt/gnu/store/lost+found"))
           (invoke "mount" (part 2) "/mnt/boot")
           (display "populating root, copying the closure...\n")
           (populate-root-file-system #$child-os "/mnt")
           (populate-store graphs "/mnt" #:deduplicate? #f)
           (display "registering the closure...\n")
           (for-each (lambda (graph) (register-closure "/mnt" graph)) graphs)
           (display "installing GRUB...\n")
           ;; The arguments the bootloader's own installer passes, plus
           ;; --target: the installer VM boots by BIOS, so grub-install's
           ;; platform guess is named explicitly.
           (setenv "GRUB_ENABLE_CRYPTODISK" "y")
           (if #$bios?
               (invoke #$(file-append grub "/sbin/grub-install")
                       "--boot-directory" "/mnt/boot" "--target=i386-pc"
                       (canonicalize-path disk))
               (invoke #$(file-append grub-efi "/sbin/grub-install")
                       "--bootloader-id=Guix" "--boot-directory" "/mnt/boot"
                       "--efi-directory" "/mnt/boot" "--removable"
                       "--target=x86_64-efi"))
           (install-boot-config #$bootcfg "/boot/grub/grub.cfg" "/mnt")
           (mkdir-p "/mnt/var/guix/gcroots")
           (symlink #$bootcfg "/mnt/var/guix/gcroots/bootcfg")
           (invoke "lsblk" "-f" (canonicalize-path disk))
           (invoke "umount" "/mnt/boot")
           (invoke "umount" "/mnt/gnu/store")
           (invoke "umount" "/mnt")
           (invoke "cryptsetup" "close" "installroot")
           (sync)
           (display "INSTALL-OK\n"))))))

(define wrapper
  (program-file
   "install-and-halt"
   #~(begin
       (let ((console (open-file "/dev/ttyS0" "w0")))
         (dup2 (fileno console) 1)
         (dup2 (fileno console) 2))
       (let ((status (system* #$install-program)))
         (format #t "INSTALL-EXIT ~a~%" status)
         (system* #$(file-append shepherd "/sbin/halt"))))))

(operating-system
  (host-name "installer")
  (timezone "Etc/UTC")
  (kernel-arguments '("console=ttyS0,115200"))
  (bootloader (bootloader-configuration
               (bootloader grub-bootloader) (targets '("/dev/vda"))))
  (file-systems (cons (file-system (mount-point "/") (device "/dev/vda1")
                                   (type "ext4"))
                      %base-file-systems))
  (services
   (cons (simple-service 'install shepherd-root-service-type
                         (list (shepherd-service
                                (provision '(install-child))
                                (requirement '(user-processes udev))
                                (one-shot? #t)
                                (start #~(make-forkexec-constructor
                                          (list #$wrapper))))))
         %base-services)))
EOF
}

if [[ "${KEEP_DISK:-0}" != 1 || ! -f target.qcow2 ]]; then
  say "building the child system from deploy/fleet-child-os.scm.example"
  fill_template
  guix system build -L "$REPO/deploy/guix" child-os.scm > build-child.log 2>&1 \
    || { tail -30 build-child.log; fail "child system build"; }
  tail -1 build-child.log

  say "building the installer VM"
  write_installer
  export REMOTE_UNLOCK_TEST_PASSPHRASE="$PASSPHRASE" \
         REMOTE_UNLOCK_TEST_FIRMWARE="$FIRMWARE" \
         REMOTE_UNLOCK_TEST_LUKS_UUID="$LUKS_UUID" \
         REMOTE_UNLOCK_TEST_STORE_UUID="$STORE_UUID" \
         REMOTE_UNLOCK_TEST_ESP_ID="$ESP_ID"
  guix system vm -L "$REPO/deploy/guix" installer-os.scm > build-installer.log 2>&1 \
    || { tr '\r' '\n' < build-installer.log | tail -30; fail "installer VM build"; }
  RUN_VM=$(tail -1 build-installer.log)

  say "installing onto a blank disk inside the installer VM"
  rm -f target.qcow2
  "$QEMU_IMG" create -q -f qcow2 target.qcow2 10G
  # The target sits on a SCSI bus: the installer's own root keeps /dev/vda.
  timeout 1800 "$RUN_VM" -m 2048 -smp 4 -nographic -no-reboot -nic none \
    -device virtio-scsi-pci,id=scsi0 \
    -drive "file=$WORK/target.qcow2,format=qcow2,if=none,id=tgt" \
    -device scsi-hd,drive=tgt,serial=TARGET > install.log 2>&1 < /dev/null || true
  grep -a -q '^INSTALL-OK' install.log || { tr '\r' '\n' < install.log | tail -40; fail "install"; }
  tr '\r' '\n' < install.log | grep -a -A12 '^NAME .*FSTYPE' | grep -a -v '^$' | head -12
fi

# ── 4. boot and unlock ─────────────────────────────────────────────────
boot_guest() {                       # $1 = serial log name
  local firmware=()
  [[ "$FIRMWARE" == bios ]] || firmware=(-bios "$OVMF")
  "$QEMU" -accel "$ACCEL" -m 2048 -smp 2 "${firmware[@]}" \
    -drive "file=$WORK/target.qcow2,format=qcow2,if=virtio" \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
    -device virtio-net-pci,netdev=n0 \
    -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
    -display none -serial "file:$WORK/$1" -pidfile "$WORK/qemu.pid" \
    -daemonize < /dev/null
}
stop_guest() { [[ -f qemu.pid ]] && kill "$(cat qemu.pid)" 2>/dev/null || true; }
trap stop_guest EXIT

COMMON=(-p "$SSH_PORT" -o IdentitiesOnly=yes -o ConnectTimeout=8 -o BatchMode=yes)
door()   { ssh "${COMMON[@]}" -i parent_key   -o StrictHostKeyChecking=yes \
               -o UserKnownHostsFile="$WORK/kh_initrd" root@127.0.0.1 "$@"; }
system() { ssh "${COMMON[@]}" -i operator_key -o StrictHostKeyChecking=accept-new \
               -o UserKnownHostsFile="$WORK/kh_system" root@127.0.0.1 "$@"; }
fingerprint() { ssh-keyscan -p "$SSH_PORT" -t ed25519 127.0.0.1 2>/dev/null \
                  | ssh-keygen -lf - 2>/dev/null | awk '{print $2}'; }
wait_for() {                         # $1 = expected fingerprint, $2 = seconds
  local i
  for ((i = 0; i < $2; i += 2)); do
    [[ "$(fingerprint)" == "$1" ]] && return 0
    sleep 2
  done
  return 1
}

# The parent knows the initrd door by the key it made itself.
echo "[127.0.0.1]:$SSH_PORT $(cut -d' ' -f1,2 initrd_host_key.pub)" > kh_initrd
rm -f kh_system
INITRD_FP=$(ssh-keygen -lf initrd_host_key.pub | awk '{print $2}')

say "boot 1 ($FIRMWARE firmware, accel=$ACCEL)"
boot_guest boot1.log
wait_for "$INITRD_FP" 180 || fail "initrd door did not answer with the initrd host key"
echo "initrd host key on :$SSH_PORT  $INITRD_FP"

say "wrong passphrase"
set +e
printf '%s\n' 'wrong passphrase' | door unlock; rc=$?
set -e
echo "exit=$rc"
[[ $rc -eq 1 ]] || fail "wrong passphrase: expected exit 1"

say "a key other than the parent's"
set +e
ssh "${COMMON[@]}" -i operator_key -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$WORK/kh_initrd" root@127.0.0.1 unlock < /dev/null; rc=$?
set -e
echo "exit=$rc"
[[ $rc -eq 255 ]] || fail "foreign key: expected refusal"
[[ "$(fingerprint)" == "$INITRD_FP" ]] || fail "door closed after refusals"
echo "door still open"

say "right passphrase"
printf '%s\n' "$PASSPHRASE" | door unlock
echo "exit=$?"

say "booted system"
for i in $(seq 1 60); do
  fp=$(fingerprint || true)
  [[ -n "$fp" && "$fp" != "$INITRD_FP" ]] && break
  sleep 2
done
[[ -n "$fp" && "$fp" != "$INITRD_FP" ]] || fail "booted sshd did not answer"
echo "system host key on :$SSH_PORT  $fp"
system 'findmnt /; findmnt /gnu/store; findmnt /boot; lsblk -o NAME,FSTYPE,MOUNTPOINTS;
        ip -4 -brief addr show eth0; ip route; pgrep -a dropbear || echo "dropbear: gone"'
[[ "$(system findmnt -no SOURCE /)" == /dev/mapper/cryptroot ]] || fail "/ is not the LUKS mapping"
system findmnt -no SOURCE /gnu/store | grep -q '^/dev/vda3$' || fail "/gnu/store is not the plain partition"

# ── 5. once more ───────────────────────────────────────────────────────
say "reboot, unlock again"
system 'touch /root/survives-reboot; reboot' || true
sleep 5
wait_for "$INITRD_FP" 180 || fail "initrd door did not come back after reboot"
printf '%s\n' "$PASSPHRASE" | door unlock
echo "exit=$?"
for i in $(seq 1 60); do
  system true 2>/dev/null && break
  sleep 2
done
system 'ls -l /root/survives-reboot; findmnt -no SOURCE /; findmnt -no SOURCE /gnu/store | head -1; uptime'
system halt || true
sleep 5

say "PASS"
