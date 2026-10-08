#!/usr/bin/env bash
# publish-iso.sh — build + pin + publish a playnet bootable ISO.
#
# Output: a content-addressed download URL the VPS provider (or any other
# provider requiring an HTTPS URL) can fetch from. The flow is:
#
#   1. Build the ISO via `make iso` (channel-pinned, reproducible).
#   2. Add it to IPFS via local Kubo daemon. Returns a CID.
#   3. (Optional) Pin via a remote pinning service for durability.
#   4. Write the CID + commit SHA + size to deploy/iso-cid.txt.
#   5. Print HTTPS gateway URLs.
#
# Usage:
#   make publish-iso              # full pipeline
#   deploy/scripts/publish-iso.sh # equivalent
#
# Environment:
#   PUBLISH_ISO_PIN_SERVICE   pinata|web3storage|none (default: none)
#   PINATA_JWT                Pinata JWT token (when PUBLISH_ISO_PIN_SERVICE=pinata)
#   WEB3_STORAGE_TOKEN        web3.storage API token (when web3storage)
#   IPFS_API                  ipfs api endpoint (default: local daemon)
#
# Prereqs:
#   - guix (for make iso)
#   - ipfs (Kubo) on PATH, daemon running
#   - git (for commit SHA)
#
# CI: this script is idempotent + reproducible. Safe to run on every push
# to main. The Guix store deduplicates the build; IPFS deduplicates the
# upload (same content = same CID). Writes deploy/iso-cid.txt which CI
# can commit back with `[skip ci]` to avoid retrigger loops.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# Check prereqs early.
command -v guix >/dev/null 2>&1 || {
  echo "publish-iso: guix not found in PATH" >&2
  exit 1
}
command -v ipfs >/dev/null 2>&1 || {
  echo "publish-iso: ipfs (Kubo) not found in PATH" >&2
  echo "  Install via:  guix install go-ipfs   (or download from dist.ipfs.tech)" >&2
  echo "  Then start the daemon:  ipfs daemon &" >&2
  exit 1
}

# Ensure IPFS daemon is reachable.
if ! ipfs id >/dev/null 2>&1; then
  echo "publish-iso: ipfs daemon not running" >&2
  echo "  Start it with:  ipfs daemon &" >&2
  echo "  Then re-run this script." >&2
  exit 1
fi

echo "publish-iso: building ISO via 'make iso' (slow on first run, fast on rebuild)..."
ISO_PATH=$(make -s iso | tail -1)

if [[ ! -f "$ISO_PATH" ]]; then
  echo "publish-iso: make iso did not return a valid path: $ISO_PATH" >&2
  exit 1
fi

ISO_SIZE=$(stat -c%s "$ISO_PATH")
ISO_SHA256=$(sha256sum "$ISO_PATH" | awk '{print $1}')
echo "publish-iso: ISO ready"
echo "  Path:    $ISO_PATH"
echo "  Size:    $ISO_SIZE bytes ($(numfmt --to=iec "$ISO_SIZE"))"
echo "  SHA256:  $ISO_SHA256"
echo

# Add to IPFS. CIDv1 (base32) is gateway-friendlier than CIDv0.
echo "publish-iso: adding to IPFS (pinning locally)..."
CID=$(ipfs add --quieter --cid-version=1 --pin=true "$ISO_PATH")
echo "  CID:     $CID"
echo

# Optional: pin via a remote service for durability beyond the local
# daemon. Without this, the ISO is only served while the local daemon is
# up. Most users wanting "set and forget" want one of these enabled.
case "${PUBLISH_ISO_PIN_SERVICE:-none}" in
  pinata)
    if [[ -z "${PINATA_JWT:-}" ]]; then
      echo "publish-iso: PUBLISH_ISO_PIN_SERVICE=pinata but PINATA_JWT not set" >&2
      exit 1
    fi
    echo "publish-iso: pinning via Pinata..."
    curl -fsSL -X POST "https://api.pinata.cloud/pinning/pinByHash" \
      -H "Authorization: Bearer $PINATA_JWT" \
      -H "Content-Type: application/json" \
      -d "{\"hashToPin\": \"$CID\", \"pinataMetadata\": {\"name\": \"playnet-iso-$(date -u +%Y%m%d-%H%M%S)\"}}" \
      | head -c 200
    echo
    ;;
  web3storage)
    if [[ -z "${WEB3_STORAGE_TOKEN:-}" ]]; then
      echo "publish-iso: PUBLISH_ISO_PIN_SERVICE=web3storage but WEB3_STORAGE_TOKEN not set" >&2
      exit 1
    fi
    echo "publish-iso: uploading to web3.storage..."
    curl -fsSL -X POST "https://api.web3.storage/car" \
      -H "Authorization: Bearer $WEB3_STORAGE_TOKEN" \
      --data-binary "@$ISO_PATH" \
      | head -c 200
    echo
    ;;
  none|"")
    echo "publish-iso: no remote pin service configured (local daemon only)"
    echo "  Set PUBLISH_ISO_PIN_SERVICE=pinata|web3storage for durability"
    echo "  beyond your local IPFS node."
    ;;
  *)
    echo "publish-iso: unknown PUBLISH_ISO_PIN_SERVICE: $PUBLISH_ISO_PIN_SERVICE" >&2
    exit 1
    ;;
esac

# Record CID + metadata so consumers (and CI) have a stable lookup.
COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
BUILT_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > deploy/iso-cid.txt <<EOF
# playnet ISO content identifier — updated by deploy/scripts/publish-iso.sh.
# CI commits this file back on push to main with the new CID + commit SHA.
# Consumers (VPS provider bring-up, fleet provisioning) read this and fetch via
# any IPFS gateway: https://ipfs.io/ipfs/<CID>
cid:       $CID
commit:    $COMMIT
built_at:  $BUILT_AT
size:      $ISO_SIZE
sha256:    $ISO_SHA256
EOF
echo
echo "publish-iso: wrote deploy/iso-cid.txt"
echo

cat <<EOF
publish-iso: gateway URLs (give one of these to the VPS provider / any HTTP fetcher)

  https://ipfs.io/ipfs/$CID
  https://cloudflare-ipfs.com/ipfs/$CID
  https://dweb.link/ipfs/$CID
  https://nftstorage.link/ipfs/$CID
  https://w3s.link/ipfs/$CID

To verify locally:
  curl -sL https://ipfs.io/ipfs/$CID | sha256sum
  # expect: $ISO_SHA256

To unpin (revoke local hosting) once the VPS provider has fetched:
  ipfs pin rm $CID

EOF
