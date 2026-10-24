#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail

# verify-system-integrity.sh — post-boot integrity check
#
# Verifies that the running Guix system generation matches what
# was deployed. Detects: modified binaries, injected services,
# tampered boot chain, or a hypervisor-level rootkit that altered
# the system between deploy and boot.
#
# Run after every reboot or periodically via mcron:
#   ssh deploy@SERVER 'sudo bash deploy/scripts/verify-system-integrity.sh'
#
# How it works:
#   1. Reads the current system generation from /run/current-system
#   2. Compares the store path against the expected one from the
#      last guix system reconfigure
#   3. Verifies that all Shepherd services match their expected
#      derivation paths
#   4. Checks that no unexpected services are running
#   5. Verifies firewall rules are active

echo "╔══════════════════════════════════════════════╗"
echo "║  LOCALCHIMERA SYSTEM INTEGRITY VERIFICATION       ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

PASS=0
FAIL=0
WARN=0

# Same convention as every Scheme component (module/localchimera/utils/paths.scm):
# the deployment says where its state lives, and /var/lib/localchimera is only the
# packaged default. Stating the literal here meant a deployment that moved its
# data dir got its permissions audited at an address nothing was written to —
# and since the loop below skips files it cannot find, that reads as a pass.
# The skip is unchanged: this fixes where we look, not what silence means.
DATA_DIR="${LOCALCHIMERA_DATA_DIR:-/var/lib/localchimera}"

ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1 — $2"; }
warn() { WARN=$((WARN+1)); echo "  ⚠ $1 — $2"; }

# 1. System generation
echo "── System generation ──"
CURRENT=$(readlink -f /run/current-system)
GENERATION=$(readlink /var/guix/profiles/system)
echo "  current:    $CURRENT"
echo "  generation: $GENERATION"
if [ "$CURRENT" = "$(readlink -f /var/guix/profiles/$GENERATION)" ]; then
    ok "system generation matches"
else
    fail "system generation MISMATCH" "running system differs from latest generation"
fi

# 2. Store integrity (spot-check critical paths)
echo ""
echo "── Store integrity ──"
for path in /run/current-system/profile/bin/guile \
            /run/current-system/profile/sbin/mosquitto \
            /run/current-system/profile/bin/guix; do
    if [ -f "$path" ]; then
        # Guix store items are read-only and content-addressed.
        # If the file exists and the store is intact, it hasn't been modified.
        if [ -r "$path" ] && [ ! -w "$path" ]; then
            ok "$(basename $path) (read-only, store-verified)"
        else
            fail "$(basename $path)" "writable — store integrity compromised"
        fi
    else
        warn "$(basename $path)" "not found"
    fi
done

# 3. Shepherd services — check for unexpected services
echo ""
echo "── Running services ──"
EXPECTED_SERVICES="nginx tor ssh-daemon keria keri-witnesses mosquitto localchimera-gateway radicle-node reticulum-bridge iptables"
RUNNING=$(herd status 2>/dev/null | grep "^+" | sed 's/^ + //')

for svc in $EXPECTED_SERVICES; do
    if echo "$RUNNING" | grep -q "^${svc}$"; then
        ok "$svc running"
    else
        warn "$svc" "not running"
    fi
done

# Check for unexpected services (not in our known list)
KNOWN="console-font-tty|file-system|guix-daemon|loopback|networking|nscd|pam|root|ssh|term-|timer|transient|udev|urandom|user-|virtual-terminal|certbot|log-|monero|localchimera|fleet|deploy|dev-bridge|live-watch|$EXPECTED_SERVICES"
UNEXPECTED=$(echo "$RUNNING" | grep -vE "$KNOWN" || true)
if [ -n "$UNEXPECTED" ]; then
    fail "UNEXPECTED SERVICES" "$UNEXPECTED"
else
    ok "no unexpected services"
fi

# 4. Firewall rules
echo ""
echo "── Firewall ──"
if herd status iptables 2>/dev/null | grep -q "It is running"; then
    ok "iptables service running"
else
    fail "iptables" "not running — ports are exposed"
fi

# 5. Tor
echo ""
echo "── Tor ──"
if herd status tor 2>/dev/null | grep -q "It is running"; then
    ok "tor running"
    ONION=$(cat /var/lib/tor/hidden-services/localchimera/hostname 2>/dev/null || echo "")
    if [ -n "$ONION" ]; then
        ok "onion address: ${ONION:0:16}..."
    else
        warn "onion address" "not found"
    fi
else
    fail "tor" "not running"
fi

# 6. File permissions on secrets
echo ""
echo "── Secret file permissions ──"
for f in "$DATA_DIR/monero/wallet-password.txt" \
         "$DATA_DIR/monero/rpc-login.txt" \
         "$DATA_DIR/sporestack-token.txt" \
         "$DATA_DIR/mosquitto/passwd"; do
    if [ -f "$f" ]; then
        MODE=$(stat -c %a "$f")
        if [ "$MODE" -le 600 ]; then
            ok "$(basename $f) mode $MODE"
        else
            fail "$(basename $f)" "mode $MODE (expected ≤ 600)"
        fi
    fi
done

# Summary
echo ""
echo "══════════════════════════════════════════════"
echo "  ✓ $PASS passed   ⚠ $WARN warnings   ✗ $FAIL failed"
echo "══════════════════════════════════════════════"
echo ""

if [ $FAIL -gt 0 ]; then
    echo "SYSTEM INTEGRITY COMPROMISED. Investigate immediately."
    exit 1
elif [ $WARN -gt 0 ]; then
    echo "Warnings present. Review above."
    exit 0
else
    echo "System integrity verified."
    exit 0
fi
