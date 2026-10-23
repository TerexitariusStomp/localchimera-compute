#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# restore-guix.sh
# Restores Guix from Persistent storage after a Tails reboot.
# Uses vsudo for a graphical password prompt with 5-min cache.
#
# What it does:
#   1. Authenticates via vsudo (one prompt, cached 5 min)
#   2. Copies Guix store from Persistent -> /gnu/store
#   3. Creates /var/guix with proper structure
#   4. Starts guix-daemon
#   5. Sets up user profile symlinks

set -uo pipefail

PERSISTENT_STORE="/home/amnesia/Persistent/guix-store/gnu/store"
PERSISTENT_VAR="/home/amnesia/Persistent/guix-var"
VSUDO="/home/amnesia/Persistent/scripts/vsudo"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}[guix] Restoring Guix from Persistent...${NC}"

if [ ! -d "$PERSISTENT_STORE" ]; then
    echo -e "${RED}[guix] ERROR: Persistent store not found at $PERSISTENT_STORE${NC}"
    exit 1
fi

# --- Check if already restored this boot ---
STORE_COUNT=$(ls /gnu/store/ 2>/dev/null | wc -l)
if [ "$STORE_COUNT" -gt 2 ] && pgrep -x guix-daemon > /dev/null 2>&1; then
    echo -e "${GREEN}[guix] Already running this boot, skipping.${NC}"
    if [[ ":$PATH:" != *":/var/guix/profiles/per-user/root/current-guix/bin:"* ]]; then
        export PATH="/var/guix/profiles/per-user/root/current-guix/bin:$PATH"
    fi
    exit 0
fi

# --- Authenticate once upfront ---
echo "[guix] Authenticating (one-time password prompt)..."
$VSUDO true || { echo "[guix] Authentication failed, aborting."; exit 1; }

# --- Run all root commands via a single sudo batch ---
$VSUDO bash -c '
set -uo pipefail

PERSISTENT_STORE="'"$PERSISTENT_STORE"'"
PERSISTENT_VAR="'"$PERSISTENT_VAR"'"

# /gnu/store
STORE_COUNT=$(ls /gnu/store/ 2>/dev/null | wc -l)
if [ "$STORE_COUNT" -le 2 ]; then
    mkdir -p /gnu/store
    chmod 1777 /gnu/store
    echo "[guix] Copying store from Persistent (~30 seconds)..."
    cp -a "$PERSISTENT_STORE"/* /gnu/store/ 2>/dev/null
    chown -R root:root /gnu/store
    echo "[guix] /gnu/store restored"
else
    echo "[guix] /gnu/store already populated, skipping"
fi

# /var/guix
mkdir -p /var/guix/profiles/per-user/root
mkdir -p /var/guix/profiles/per-user/amnesia

if [ ! -L /var/guix/profiles/per-user/root/current-guix ]; then
    ln -sf /gnu/store/3mj5fha5whqhr2mx7x4bzkddww7850b2-profile \
        /var/guix/profiles/per-user/root/current-guix
fi

mkdir -p /usr/local/bin
if [ ! -L /usr/local/bin/guix ]; then
    ln -sf /var/guix/profiles/per-user/root/current-guix/bin/guix /usr/local/bin/guix
fi
if [ ! -L /usr/local/bin/guix-daemon ]; then
    ln -sf /var/guix/profiles/per-user/root/current-guix/bin/guix-daemon /usr/local/bin/guix-daemon
fi

if [ -d "$PERSISTENT_VAR" ] && [ "$(ls -A $PERSISTENT_VAR 2>/dev/null)" ]; then
    echo "[guix] Restoring /var/guix state from Persistent..."
    cp -a "$PERSISTENT_VAR"/* /var/guix/ 2>/dev/null || true
fi

echo "[guix] /var/guix set up"
'

# --- guix-daemon ---
if pgrep -x guix-daemon > /dev/null 2>&1; then
    echo -e "${GREEN}[guix] guix-daemon already running${NC}"
else
    echo "[guix] Starting guix-daemon..."
    $VSUDO guix-daemon --build-users-group=guixbuild &
    sleep 2
    if pgrep -x guix-daemon > /dev/null 2>&1; then
        echo -e "${GREEN}[guix] guix-daemon started${NC}"
    else
        echo -e "${YELLOW}[guix] WARNING: guix-daemon may not have started correctly${NC}"
    fi
fi

# --- User profile ---
mkdir -p ~/.config/guix
if [ ! -L ~/.config/guix/current ]; then
    ln -sf /var/guix/profiles/per-user/amnesia/current-guix ~/.config/guix/current 2>/dev/null || true
fi

if [[ ":$PATH:" != *":/var/guix/profiles/per-user/root/current-guix/bin:"* ]]; then
    export PATH="/var/guix/profiles/per-user/root/current-guix/bin:$PATH"
fi

if [ -f ~/.config/guix/current/etc/profile ]; then
    source ~/.config/guix/current/etc/profile 2>/dev/null || true
fi

if command -v guix > /dev/null 2>&1; then
    GUIX_VER=$(guix --version 2>/dev/null | head -1 || echo "unknown")
    echo -e "${GREEN}[guix] Done! $GUIX_VER${NC}"
else
    echo -e "${YELLOW}[guix] guix not in PATH yet. Try: hash -r${NC}"
fi
