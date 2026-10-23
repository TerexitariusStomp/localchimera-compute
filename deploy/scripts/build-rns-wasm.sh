#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# build-rns-wasm.sh — build the browser Reticulum wasm artifacts at deploy.
#
# rns_wasm.js / rns_wasm_bg.wasm are gitignored build products (like a
# target/ dir), so the CI rsync never delivers them — without this step
# production serves NO rns wasm and the whole mesh browser leg
# (persona identities, relay-announce, LXMF mail) is inert.
#
# Toolchain, all from Guix (verified 2026-09-14):
#   - rustc + cargo are Guix's `rust`; the wasm32 standard library is built
#     FROM SOURCE (`rust:rust-src`, cargo -Z build-std) because Guix's rust
#     ships the host target only and upstream's prebuilt rust-std refuses
#     Guix's rustc ("compiled by an incompatible version": the release
#     string differs by "(built from a source tarball)");
#   - cargo is pointed at `rust:rust-src`'s library tree, because rust's
#     own output carries a copy whose Cargo.lock checksums Guix's build
#     zeroed (sha256 of nothing), and build-std refuses it;
#   - the linker is LLD's wasm-ld (`lld`); Guix's rust has no rust-lld;
#   - wasm-bindgen-cli is `cargo install`ed at EXACTLY the version in
#     Cargo.lock (bindgen requires an exact match; Guix's is 0.2.111 and
#     yanked), into a cache dir beside the crate, once per version.
#
# Skips (exit 0, deploy must not break): no guix, or sources unchanged
# since the last successful build (content stamp).
#
# Usage: build-rns-wasm.sh <deploy-dir>
#   builds <deploy-dir>/rns-wasm and installs the two artifacts into
#   <deploy-dir>/browser/. The crate sits at the repo root, outside the
#   served tree; only its two products reach the document root.
#
# ORDERING: must run BEFORE the sw.js CACHE fingerprint stamp — fresh
# artifacts have to change the fingerprint so tabs reinstall.

set -euo pipefail

DEPLOY_DIR="${1:?usage: build-rns-wasm.sh <deploy-dir>}"
CRATE="$DEPLOY_DIR/rns-wasm"
OUT="$DEPLOY_DIR/browser"
LOG_PREFIX="[build-rns-wasm]"
TOOLS="${RNS_WASM_TOOLS:-$DEPLOY_DIR/.rns-wasm-tools}"   # bindgen + cargo homes, kept across deploys

log() { echo "$LOG_PREFIX $(date -Iseconds) $*"; }

[ -d "$CRATE" ] || { log "no crate at $CRATE — skipping"; exit 0; }
command -v guix >/dev/null 2>&1 || { log "no guix — skipping"; exit 0; }

# Tor-only box: egress iptables drops non-Tor traffic, so cargo's network
# calls (crates.io index and crates, the std's own dependencies) ride the
# local SOCKS port. libcurl inside cargo honors the proxy env. No-op when a
# proxy is already configured or no Tor port is listening (dev machines).
if [ -z "${https_proxy:-}" ] && command -v ss >/dev/null 2>&1 \
   && ss -ltn 2>/dev/null | grep -q ':9050 '; then
    export http_proxy=socks5h://127.0.0.1:9050
    export https_proxy=socks5h://127.0.0.1:9050
    log "routing cargo network through Tor (socks5h://127.0.0.1:9050)"
fi

# Content stamp: skip the (minutes-long) build when sources are
# untouched. Hash the crate sources + lock, not the artifacts.
stamp_file="$OUT/.rns-wasm-stamp"
src_hash=$(cd "$CRATE" && cat Cargo.toml Cargo.lock $(find src -type f | sort) | sha256sum | cut -c1-16)
if [ -f "$stamp_file" ] && [ "$(cat "$stamp_file")" = "$src_hash" ] \
   && [ -f "$OUT/rns_wasm.js" ] && [ -f "$OUT/rns_wasm_bg.wasm" ]; then
    log "sources unchanged ($src_hash) — skipping build"
    exit 0
fi

# wasm-bindgen-cli at EXACTLY the lockfile's wasm-bindgen version.
bindgen_version=$(grep -A1 '^name = "wasm-bindgen"$' "$CRATE/Cargo.lock" \
                  | sed -n 's/^version = "\(.*\)"/\1/p')
[ -n "$bindgen_version" ] || { log "cannot read wasm-bindgen version from Cargo.lock"; exit 1; }
mkdir -p "$TOOLS"
BINDGEN="$TOOLS/bindgen-$bindgen_version/bin/wasm-bindgen"

# One guix shell for everything: rust + cargo + the std sources + lld + a C
# compiler (build scripts in wasm-bindgen-cli's dependencies call cc) + a CA
# bundle (cargo's curl has none otherwise). The env inside:
#   RUSTFLAGS --sysroot: the profile is the sysroot, so the std built below
#                        and wasm-ld are found where rustc looks;
#   RUSTC_BOOTSTRAP=1:   -Z build-std on a stable rustc;
#   __CARGO_TESTS_ONLY_SRC_ROOT: the clean library tree (see the header).
log "building rns-wasm ($src_hash, bindgen $bindgen_version) in a guix shell"
guix shell -L "$DEPLOY_DIR/deploy/guix" rust rust:cargo rust:rust-src lld gcc-toolchain nss-certs -- \
  env CRATE="$CRATE" TOOLS="$TOOLS" BINDGEN="$BINDGEN" BV="$bindgen_version" bash -euo pipefail -c '
    export SSL_CERT_DIR=$GUIX_ENVIRONMENT/etc/ssl/certs
    export SSL_CERT_FILE=$GUIX_ENVIRONMENT/etc/ssl/certs/ca-certificates.crt
    export CARGO_HTTP_CAINFO=$SSL_CERT_FILE
    export CARGO_HOME=$TOOLS/cargo-home
    export CC=gcc   # cc-rs looks for cc; the Guix toolchain names it gcc
    if ! [ -x "$BINDGEN" ]; then
        echo "[build-rns-wasm] installing wasm-bindgen-cli $BV (one-time)"
        cargo install wasm-bindgen-cli --version "$BV" --locked --root "$TOOLS/bindgen-$BV"
    fi
    export RUSTFLAGS="--sysroot=$GUIX_ENVIRONMENT -C linker=wasm-ld"
    export RUSTC_BOOTSTRAP=1
    export __CARGO_TESTS_ONLY_SRC_ROOT=$GUIX_ENVIRONMENT/lib/rustlib/src/rust/library
    cd "$CRATE"
    cargo build --release --target wasm32-unknown-unknown -Z build-std=std,panic_abort
    "$BINDGEN" --target web --no-typescript --out-dir "$CRATE/pkg" \
        "$CRATE/target/wasm32-unknown-unknown/release/rns_wasm.wasm"
  '
install -m 644 "$CRATE/pkg/rns_wasm.js"      "$OUT/rns_wasm.js"
install -m 644 "$CRATE/pkg/rns_wasm_bg.wasm" "$OUT/rns_wasm_bg.wasm"
echo "$src_hash" > "$stamp_file"
log "installed rns_wasm.js + rns_wasm_bg.wasm into $OUT"
