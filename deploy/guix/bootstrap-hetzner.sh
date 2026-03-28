#!/usr/bin/env bash
set -euo pipefail

# bootstrap-hetzner.sh — Bootstrap Guix System on Hetzner (EFI/x86_64)
#
# Does what (gnu machine hetzner) does, but uses ftp.gnu.org
# (ftpmirror.gnu.org is returning 502).
#
# After success, switch machines.scm to managed-host-environment-type.
#
# Usage: ./deploy/guix/bootstrap-hetzner.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECRETS="$SCRIPT_DIR/secrets.scm"

if [ -z "${GUIX_HETZNER_API_TOKEN:-}" ] && [ -f "$SECRETS" ]; then
    GUIX_HETZNER_API_TOKEN=$(guile -c "(primitive-load \"$SECRETS\") (display (getenv \"GUIX_HETZNER_API_TOKEN\"))")
fi
: "${GUIX_HETZNER_API_TOKEN:?Set GUIX_HETZNER_API_TOKEN}"

API="https://api.hetzner.cloud/v1"
AUTH="Authorization: Bearer $GUIX_HETZNER_API_TOKEN"
SSH_KEY="/home/nozomi/.ssh/id_ed25519"
SSH_PUB="$(cat "${SSH_KEY}.pub")"
SERVER_TYPE="cpx22"
LOCATION="nbg1"

hetzner() { curl -s -H "$AUTH" -H "Content-Type: application/json" "$@"; }
ssh_cmd() { ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$SSH_KEY" root@"$SERVER_IP" "$@"; }

# --- Step 1: SSH key ---
echo "=== 1. SSH key ==="
SSH_KEY_ID=$(hetzner "$API/ssh_keys" | python3 -c "
import sys, json
for k in json.load(sys.stdin)['ssh_keys']:
    print(k['id']); break
" 2>/dev/null || true)
if [ -z "$SSH_KEY_ID" ]; then
    SSH_KEY_ID=$(hetzner -X POST "$API/ssh_keys" \
        -d "{\"name\":\"guix-deploy\",\"public_key\":\"$SSH_PUB\"}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['ssh_key']['id'])")
fi
echo "Key: $SSH_KEY_ID"

# --- Step 2: Create server ---
echo "=== 2. Create server ==="
SERVER_RESP=$(hetzner -X POST "$API/servers" \
    -d "{\"name\":\"guix-x86\",\"server_type\":\"$SERVER_TYPE\",\"location\":\"$LOCATION\",\"image\":\"debian-12\",\"ssh_keys\":[$SSH_KEY_ID]}")
SERVER_ID=$(echo "$SERVER_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['server']['id'])")
echo "Server: $SERVER_ID"

echo "Waiting for server..."
while true; do
    STATUS=$(hetzner "$API/servers/$SERVER_ID" | python3 -c "import sys,json; print(json.load(sys.stdin)['server']['status'])")
    [ "$STATUS" = "running" ] && break
    sleep 3
done
SERVER_IP=$(hetzner "$API/servers/$SERVER_ID" | python3 -c "import sys,json; print(json.load(sys.stdin)['server']['public_net']['ipv4']['ip'])")
echo "IP: $SERVER_IP"

# --- Step 3: Enable rescue + reset ---
echo "=== 3. Rescue mode ==="
ACTION_ID=$(hetzner -X POST "$API/servers/$SERVER_ID/actions/enable_rescue" \
    -d "{\"type\":\"linux64\",\"ssh_keys\":[$SSH_KEY_ID]}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['action']['id'])")
for i in $(seq 1 30); do
    S=$(hetzner "$API/actions/$ACTION_ID" | python3 -c "import sys,json; print(json.load(sys.stdin)['action']['status'])")
    [ "$S" = "success" ] && break; sleep 2
done

hetzner -X POST "$API/servers/$SERVER_ID/actions/reset" -d '{}' > /dev/null
echo "Resetting into rescue..."
sleep 20
ssh-keygen -R "$SERVER_IP" 2>/dev/null || true
for i in $(seq 1 30); do
    ssh_cmd true 2>/dev/null && break; sleep 5
done
echo "SSH connected"

# --- Step 4: Install on rescue system ---
echo "=== 4. Installing Guix ==="
ssh_cmd bash <<'REMOTE_INSTALL'
set -e

# Install required packages
apt-get update -qq
apt-get install -y cloud-initramfs-growroot uidmap 2>&1 | tail -3

# Partition: grow to full disk, then format
umount /dev/sda1 2>/dev/null || true
umount /dev/sda15 2>/dev/null || true
growpart /dev/sda 1 || true
mkfs.ext4 -L root -F /dev/sda1

# Mount
mount /dev/sda1 /mnt
mkdir -p /mnt/boot/efi
mount /dev/sda15 /mnt/boot/efi
mkdir -p /mnt/boot/grub

# SSH keys for new system
mkdir -p /mnt/root/.ssh
chmod 700 /mnt/root/.ssh
cp /root/.ssh/authorized_keys /mnt/root/.ssh/authorized_keys
chmod 600 /mnt/root/.ssh/authorized_keys

# Bind mount store
mkdir -p /mnt/tmp/gnu/store /gnu/store
mount --bind /mnt/tmp/gnu/store /gnu/store

# Install Guix with working mirror
mkdir -p /etc/guix
wget -qO /tmp/guix-install.sh https://guix.gnu.org/guix-install.sh
sed -i 's|https://ftpmirror.gnu.org/gnu/guix/|https://ftp.gnu.org/gnu/guix/|g' /tmp/guix-install.sh
chmod +x /tmp/guix-install.sh
set +e
yes '' | /tmp/guix-install.sh 2>&1 | tail -10
set -e

# guix-install.sh may have overridden our bind mount via systemd.
# Re-establish it so /gnu/store points to disk, not RAM.
umount /gnu/store 2>/dev/null || true
mount --bind /mnt/tmp/gnu/store /gnu/store
echo "Bind mount re-established: $(ls /gnu/store | wc -l) items"

# Find guix binary
pkill guix-daemon 2>/dev/null || true; sleep 1
GUIX=$(ls /gnu/store/*-guix-*/bin/guix 2>/dev/null | head -1)
GUIX_DAEMON=$(ls /gnu/store/*-guix-*/bin/guix-daemon 2>/dev/null | head -1)
GUIX_SHARE=$(dirname $(dirname "$GUIX"))/share/guix

echo "Guix: $GUIX"
echo "Daemon: $GUIX_DAEMON"
$GUIX --version

# Start daemon
$GUIX_DAEMON --build-users-group=guix-daemon --disable-chroot &
sleep 3

# Authorize substitutes
$GUIX archive --authorize < "$GUIX_SHARE/bordeaux.guix.gnu.org.pub"

# Write EFI OS config
cat > /tmp/hetzner-os.scm << 'EOF'
(use-modules (gnu) (guix utils))
(use-package-modules ssh)
(use-service-modules base networking ssh)
(use-system-modules linux-initrd)
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
  (services
   (cons* (service dhcpcd-service-type)
          (service openssh-service-type
                   (openssh-configuration
                    (openssh openssh-sans-x)
                    (permit-root-login 'prohibit-password)))
          %base-services)))
EOF

echo "=== guix system init (EFI) ==="
$GUIX system init --verbosity=2 --fallback /tmp/hetzner-os.scm /mnt
echo "=== BOOTLOADER INSTALLED ==="

# Sync store items to real location
echo "Syncing store..."
cd /mnt/tmp/gnu/store
for item in *; do
    [ ! -e "/mnt/gnu/store/$item" ] && cp -al "$item" "/mnt/gnu/store/$item" 2>/dev/null || true
done
echo "Store: $(ls /mnt/gnu/store | wc -l) items"
echo "=== DONE ==="
REMOTE_INSTALL

# --- Step 5: Boot into Guix ---
echo "=== 5. Booting Guix System ==="
hetzner -X POST "$API/servers/$SERVER_ID/actions/disable_rescue" -d '{}' > /dev/null
sleep 2
hetzner -X POST "$API/servers/$SERVER_ID/actions/poweroff" -d '{}' > /dev/null
sleep 10
hetzner -X POST "$API/servers/$SERVER_ID/actions/poweron" -d '{}' > /dev/null

sleep 30
ssh-keygen -R "$SERVER_IP" 2>/dev/null || true
for i in $(seq 1 30); do
    echo "Boot check $i..."
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
           -i "$SSH_KEY" root@"$SERVER_IP" 'uname -a' 2>/dev/null; then
        echo ""
        echo "============================================="
        echo "  GUIX SYSTEM IS RUNNING!"
        echo "  Server: $SERVER_IP"
        echo "  ID: $SERVER_ID"
        echo "============================================="
        exit 0
    fi
    sleep 5
done

echo "Timeout. Check console: https://console.hetzner.cloud"
echo "Server: $SERVER_IP (ID: $SERVER_ID)"
