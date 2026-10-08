#!/bin/bash
# radicle-ci-hook.sh — Radicle-native CI/CD for playnet
#
# Follows the Guix Cookbook §7.5 pattern: watches Radicle node events,
# triggers guix pull + system reconfigure for infra changes, or
# rsync + herd restart for application code changes.
#
# Runs as the radicle-ci Shepherd service (see machines.scm).
# This is the primary CI/CD path — GitHub Actions is transitional.
#
# Usage:
#   RAD_HOME=/var/lib/playnet/radicle \
#   PLAYNET_RID=rad:z27dFkN28LQAsSsG3DVHcfBqYAArQ \
#     radicle-ci-hook.sh

set -euo pipefail

: "${RAD_HOME:=/var/lib/playnet/radicle/.radicle}"
: "${PLAYNET_RID:?Set PLAYNET_RID to the Radicle project ID (rad:z...)}"
: "${REPO_DIR:=/var/lib/playnet/radicle/checkout}"
: "${DEPLOY_DIR:=/home/playnet/playnet-repo}"
: "${LOG_PREFIX:=[radicle-ci]}"
: "${ARTIFACTS_DIR:=/var/lib/playnet/artifacts}"
: "${ARTIFACTS_KEEP:=5}"
# Store hygiene at deploy time. Every deploy builds two docker packs — the
# playnet package, 18 grafted dependencies, two 260 MB tarballs — into
# /gnu/store, and every one of them is garbage the moment the tarball is
# copied out. The box's weekly `guix gc` is a scheduled job; 2026-09-23 the
# scheduler itself was crashing (mcron 1.2.2 with two jobs in one minute) and
# the root disk reached 99% between one Sunday and the next Tuesday, at
# which point the gateway's boot died on a log write and served a dead
# address for hours. So the deploy reclaims its own leavings: the pack's
# store path goes as soon as it is copied, and a `guix gc -F` after the
# heavy paths keeps STORE_FREE_TARGET_GB free — a no-op when nothing is
# dead. The docker packs are the one optional step, and they are skipped
# outright below STORE_FREE_MIN_GB rather than tip the disk over.
: "${STORE_FREE_TARGET_GB:=20}"
: "${STORE_FREE_MIN_GB:=12}"

export HOME="/var/lib/playnet/radicle"
export RAD_HOME="$RAD_HOME"

# Guix keeps the SETUID sudo under /run/privileged/bin (formerly
# /run/setuid-programs); the copy in the profile / PATH is NOT setuid and dies
# with "sudo: … must be owned by uid 0 and have the setuid bit set". The
# shepherd exec inherits a PATH with the profile first, so a bare `sudo`
# resolved to the non-setuid copy and EVERY auto gateway-restart failed —
# `restart_services` fell to its pending-restart queue and the box quietly
# served stale code until an operator restarted by hand. Prepend the
# privileged dir so `sudo` (restart, dev-bridge, and the reconfigure path)
# resolves to the setuid binary. Root-caused 2026-07-28.
for _sudir in /run/privileged/bin /run/setuid-programs; do
    [ -u "$_sudir/sudo" ] && { PATH="$_sudir:$PATH"; break; }
done
export PATH

log() { echo "$LOG_PREFIX $(date -Iseconds) $*"; }

# --- Self-update (exec-self) -------------------------------------------------
# A deployed hook change only rsyncs the FILE; the running service keeps
# executing its in-memory version and cannot sudo-restart itself — so it once
# ran 8-day-stale deploy logic silently. Fix WITHOUT a reconfigure: record the
# hash of the script we booted, and after any deploy whose rsync overwrote it
# with a different version, signal the MAIN process (`$$` is the main PID even
# inside subshells) to re-exec the new code in place. `exec` preserves the PID
# and skips the EXIT trap; the fresh process's reap_others() reaps the old
# backstop/event subshells — exactly what a `herd restart` would do.
SELF="$0"
RUNNING_HOOK_SHA="$(sha1sum "$SELF" 2>/dev/null | cut -d' ' -f1 || true)"
reexec_self() {
    log "hook: deployed script differs from the running one — re-exec'ing in place"
    exec bash "$SELF"
}
maybe_reexec_self() {
    # Called only after a COMPLETED deploy (never mid-deploy), so the gateway
    # restart etc. have already run before we replace ourselves.
    local now
    now="$(sha1sum "$SELF" 2>/dev/null | cut -d' ' -f1 || true)"
    [ -n "$now" ] && [ "$now" != "$RUNNING_HOOK_SHA" ] || return 0
    log "hook: change detected (${RUNNING_HOOK_SHA:0:8} -> ${now:0:8}) — scheduling self-reload"
    kill -USR1 "$$" 2>/dev/null || true
}

# --- Operations ---

sync_application_code() {
    # Runs BEFORE the rsync (like build_browser_wasm/build_planner_kernel in
    # their own branches) so a freshly-built PDF/EPUB rides this same sync —
    # content-stamped internally, so this is a fast no-op on every deploy
    # that doesn't touch docs/playnet.typ.
    build_docs_epub

    log "Syncing application code to $DEPLOY_DIR"
    # We already run as the `playnet` user (per shepherd-radicle-ci.scm
    # #:user "playnet") and DEPLOY_DIR is owned by playnet, so no sudo
    # needed for the rsync or chown. sudo on Guix isn't setuid by
    # default and was failing the whole sync.
    #
    # `P` (protect) filter rules tell --delete to leave alone files
    # in DEPLOY_DIR that are gitignored (and therefore absent from
    # REPO_DIR). Without these, every sync wipes the operator-installed
    # deploy/providers/provider-1.scm, deploy/.age-key.txt, etc., and the
    # next `guix system reconfigure` fails until they're re-scp'd.
    # Pattern set mirrors .gitignore's `^deploy/` block.
    # --exclude (not 'P' protect) for the operator-installed files: it
    # both shields any DEPLOY_DIR copy from --delete AND skips them on
    # the SEND side. The checkout may carry a root-owned 0600
    # deploy/providers/provider-1.scm (real-IP config used for on-box
    # reconfigures); with only a P rule, rsync still tries to open it →
    # "Permission denied" → exit 23 → under set -e the whole sync
    # aborts before the sw.js stamp. Excluding also guarantees the
    # secret file can never be copied into the served tree.
    rsync -a --delete \
        --exclude='deploy/providers/*.scm' \
        --exclude='deploy/hosts.scm' \
        --exclude='deploy/desired-fleet.scm' \
        --exclude='deploy/.age-key.txt' \
        --exclude='deploy/iso-cid.txt' \
        --filter='P browser/rns_wasm.js' \
        --filter='P browser/rns_wasm_bg.wasm' \
        --filter='P browser/.rns-wasm-stamp' \
        --filter='P .rns-wasm-tools' \
        --filter='P browser/repl.wasm' \
        --filter='P browser/day-boot.wasm' \
        --filter='P browser/radicle/***' \
        --filter='P rns-wasm/***' \
        --filter='P server/rns-bridge/***' \
        --filter='P rns-wasm/target' \
        --filter='P rns-wasm/pkg' \
        --include='module/***' \
        --include='server/***' \
        --include='planner/***' \
        --exclude='browser/sw.js' \
        --include='browser/***' \
        --include='rns-wasm/***' \
        --include='hoot/***' \
        --include='tests/***' \
        --include='docs/***' \
        --include='deploy/***' \
        --include='tools/***' \
        --include='Makefile' \
        --include='README.md' \
        --include='LICENSE.md' \
        --include='.guix-channel' \
        --include='guix.scm' \
        --exclude='*' \
        "$REPO_DIR/" "$DEPLOY_DIR/" || {
        # Partial-transfer codes are non-fatal: 23 = some files could
        # not be read (e.g. an unreadable operator file that slipped
        # past the excludes), 24 = files vanished mid-transfer. Under
        # set -e anything else would silently abort the deploy before
        # the stamp/marker below, leaving the backstop retry-looping.
        local _rc=$?
        if [ "$_rc" -eq 23 ] || [ "$_rc" -eq 24 ]; then
            log "rsync partial transfer (code $_rc) — continuing"
        else
            log "rsync FAILED (code $_rc) — aborting sync"
            return "$_rc"
        fi
    }

    # Place the pinned satellite trees (deploy/satellites.scm): the served
    # /radicle/ site, the rns-wasm crate (built below by build-rns-wasm.sh
    # from its placed tree) and the rns-bridge crate (its Guix package
    # fetches the same pin from the node's storage at reconfigure). Each
    # tree comes from the box's own Radicle
    # storage (the node seeds every satellite RID; os.scm derives the seed
    # list from %playnet-satellite-rids-bare), exported at the pinned
    # commit and hash-verified before it replaces the old copy. A
    # rsync P-filter above keeps --delete off browser/radicle, so a deploy
    # whose seed is not synced yet leaves the last placed tree serving.
    # MUST precede build-rns-wasm.sh (it builds the placed crate) and the
    # sw.js stamp (a new explorer changes the fingerprint).
    # Same guile invocation shape as run_planner_seeder: shepherd's exec
    # env carries no GUILE_LOAD_PATH.
    # Placed into BOTH trees: DEPLOY_DIR is what nginx serves and what
    # build-rns-wasm.sh builds; REPO_DIR (the checkout) is what `guix
    # system reconfigure` evaluates, and deploy/guix/satellite-source.scm
    # takes rns-bridge's source from the placed tree there (the daemon's
    # builder cannot fetch a pin itself). Both paths are gitignored.
    if [ -x "$REPO_DIR/deploy/scripts/satellite-pins.scm" ]; then
        for _root in "$REPO_DIR" "$DEPLOY_DIR"; do
            (cd "$REPO_DIR" && GUILE_AUTO_COMPILE=0 RAD_HOME="$RAD_HOME" \
                guile -L "$REPO_DIR/module" \
                      -L /run/current-system/profile/share/guile/site/3.0 \
                      -C /run/current-system/profile/lib/guile/3.0/site-ccache \
                      "$REPO_DIR/deploy/scripts/satellite-pins.scm" place "$_root") \
                2>&1 | while IFS= read -r line; do log "satellites[$(basename "$_root")]: $line"; done \
                || log "satellite placement into $_root incomplete (non-fatal) — last placed trees keep serving"
        done
    fi

    # Self-heal the vendored radicle-planning-boards app (browser/boards/):
    # its hardcoded localhost API fallback, load-order-sensitive runtime
    # config, and CSP/SRI content hashes all break the moment anyone drops
    # in a freshly-fetched copy, and have needed hand-reapplying seven times
    # (see deploy/scripts/patch-boards-app.scm's header). Runs against
    # DEPLOY_DIR (the served copy), not REPO_DIR (the checkout/canonical
    # git history stays the raw upstream drop). Idempotent and a fast no-op
    # once already patched, so unconditional on every deploy is fine — and
    # MUST precede the sw.js bhash fingerprint below, or a boards fix ships
    # without the cache-bust that makes returning visitors pick it up.
    if [ -x "$REPO_DIR/deploy/scripts/patch-boards-app.scm" ]; then
        GUILE_AUTO_COMPILE=0 guile -L "$REPO_DIR/module" \
            "$REPO_DIR/deploy/scripts/patch-boards-app.scm" \
            "$DEPLOY_DIR/browser/boards" \
            2>&1 | while IFS= read -r line; do log "$line"; done \
            || log "patch-boards-app failed (non-fatal) — boards app may be stale/broken"
    fi

    # Build the Reticulum wasm artifacts (gitignored build products —
    # the rsync above never delivers them; without this the mesh
    # browser leg is inert). MUST precede the sw.js stamp below so
    # fresh artifacts change the fingerprint and tabs reinstall.
    # Skips politely (unchanged sources / no guix) and never
    # fails the deploy.
    if [ -x "$DEPLOY_DIR/deploy/scripts/build-rns-wasm.sh" ]; then
        "$DEPLOY_DIR/deploy/scripts/build-rns-wasm.sh" "$DEPLOY_DIR" \
            || log "rns-wasm build failed (non-fatal) — mesh browser leg stays stale"
    fi

    # Stamp the deployed sw.js (tools/sw-stamp.sh says what the stamp is and
    # how it is written). Two properties this deploy relies on: the stamp is
    # a fingerprint of the dial's served bytes, so a deploy that changes none
    # of them leaves sw.js byte-identical and no browser reinstalls; and
    # sw.js is --exclude'd from the rsync above and written here by rename
    # from the SOURCE sw.js, so the deployed file flips old-stamp -> new-stamp
    # in one step.
    local bhash
    if [ -f "$REPO_DIR/browser/sw.js" ] \
       && bhash=$(bash "$REPO_DIR/tools/sw-stamp.sh" "$DEPLOY_DIR/browser" \
                       "$REPO_DIR/browser/sw.js" 2>/dev/null) \
       && [ -n "$bhash" ]; then
        log "Stamped sw.js CACHE = playnet-${bhash} (browser-asset fingerprint)"
    else
        log "WARNING: sw.js stamp failed; the deployed sw.js keeps its previous stamp"
    fi

    # Record the deployed commit in a separate marker for the local-push
    # backstop. The sw.js CACHE used to double as this marker; now that
    # it's a content hash rather than a git SHA, the backstop needs its
    # own record of which commit is live to detect on-box pushes.
    # Dotfile at DEPLOY_DIR top level → matched by the rsync's final
    # --exclude='*', so --delete leaves it alone.
    (cd "$REPO_DIR" && git rev-parse --short HEAD 2>/dev/null) \
        > "$DEPLOY_DIR/.deployed-sha.tmp" \
      && mv -f "$DEPLOY_DIR/.deployed-sha.tmp" "$DEPLOY_DIR/.deployed-sha"
    # And which hook did it: a deploy that lands a new hook runs under the
    # OLD one (this process re-execs only after), so the fresh process reads
    # this marker at boot and redoes the sync once under the new code.
    printf '%s\n' "$RUNNING_HOOK_SHA" > "$DEPLOY_DIR/.deployed-hook-sha.tmp" \
      && mv -f "$DEPLOY_DIR/.deployed-hook-sha.tmp" "$DEPLOY_DIR/.deployed-hook-sha"

    log "Sync complete"
}

build_browser_wasm() {
    # Compile browser/repl.wasm + browser/day-boot.wasm from their .scm
    # sources. The Makefile targets handle the time-machine + guix shell +
    # guild compile-wasm dance. Tor-routed (every guix outbound goes
    # through torsocks per the project posture).
    #
    # The .wasm artifacts are gitignored build products (like rns-wasm) —
    # the box is where they are built, and the rsync's P-filters keep the
    # last-built copies in DEPLOY_DIR when a build fails, so the site
    # degrades to stale rather than missing.
    local TOR=""
    if command -v torsocks >/dev/null 2>&1; then
        TOR="torsocks"
    else
        log "ERROR: torsocks missing — refusing to fetch over clearnet"
        return 1
    fi

    log "Rebuilding browser/repl.wasm + browser/day-boot.wasm (torsocks-wrapped guix shell + guild compile-wasm)"
    (
        cd "$REPO_DIR"
        # Pin the toolchain's closure as a GC root first (Makefile: hoot-warm),
        # so the deploy-time `guix gc` below never collects the patched Hoot
        # and the next build never spends ten minutes compiling it again.
        $TOR make hoot-warm >/dev/null 2>&1 || log "  (hoot-warm failed — the toolchain is unrooted until the next build)"
        $TOR make browser/repl.wasm browser/day-boot.wasm
    ) 2>&1 | tee >(while IFS= read -r line; do log "wasm: $line"; done >&2) | tail -3 || {
        log "WARNING: wasm rebuild failed — syncing the committed .wasm as-is"
        return 0
    }
    log "wasm rebuild OK"
}

build_planner_kernel() {
    # Rebuild the planner's compiled hot-loop kernel (native-c backend) from
    # module/playnet/planner/solve/kernel/kernel.c. The .so is gitignored and built
    # locally — a push that changes kernel.c changes nothing on the box until
    # something rebuilds it, which is exactly the gap that let the held-
    # feasibility fix (kernel.c: pk_frac_to_boundary) sit unbuilt after landing
    # in the checkout. Mirrors build_browser_wasm's shape and BEFORE-sync
    # placement, but needs neither guix time-machine nor torsocks: gcc-toolchain
    # is a system package (deploy/os.scm) once reconfigured, so `make` here is
    # a plain local compile with no network fetch.
    if ! command -v gcc >/dev/null 2>&1 && ! command -v cc >/dev/null 2>&1; then
        log "planner kernel: no C compiler on this host (deploy/os.scm needs gcc-toolchain + a reconfigure) — skipping, native-c backend stays unavailable"
        return 0
    fi
    log "Rebuilding libplanner_kernel.so (module/playnet/planner/solve/kernel)"
    (
        cd "$REPO_DIR/module/playnet/planner/solve/kernel"
        # Explicit CC: verified live that an inherited `CC=cc` (present in this
        # host's ambient root/sudo environment, cause unconfirmed) resolves to a
        # `cc` the invoking user cannot execute — "Permission denied", not
        # "not found" — while `CC=gcc` (what gcc-toolchain actually provides,
        # confirmed via `which gcc`) built clean. The Makefile's own `CC ?= gcc`
        # default is silently skipped whenever CC already has ANY value in the
        # environment, so this cannot be left to inherit.
        CC=gcc make
    ) 2>&1 | tee >(while IFS= read -r line; do log "kernel: $line"; done >&2) | tail -3 || {
        log "WARNING: planner kernel rebuild failed — syncing any existing .so as-is"
        return 0
    }
    log "planner kernel rebuild OK"
}

build_docs_epub() {
    # Compile docs/playnet.typ → docs/playnet.pdf + docs/playnet.epub — the
    # scroll's "the latest spec" links (browser/app.html). Both are
    # gitignored build products (like the wasm artifacts); the rsync never
    # delivers them on its own. Content-stamped inside the script, so a
    # deploy that doesn't touch docs/playnet.typ is a no-op here. Non-fatal:
    # a stale or missing PDF/EPUB must never take down the gateway restart.
    if [ -x "$REPO_DIR/deploy/scripts/build-docs-epub.sh" ]; then
        "$REPO_DIR/deploy/scripts/build-docs-epub.sh" "$REPO_DIR" \
            || log "build-docs-epub failed (non-fatal) — spec download links may be stale/missing"
    fi
}

purge_cdn_cache() {
    # After deploying new browser assets (wasm, JS, CSS, etc.), the CDN's
    # edges drop their now-stale copies. Without this, users keep getting
    # served the old wasm/JS for the edge's cache lifetime (which can be
    # days) — and our auto-stamp on sw.js (commit SHA in CACHE) is defeated
    # because they never even reach the new sw.js to re-install.
    #
    # Which CDN, which zone and which key are this box's own facts
    # (/etc/playnet/cdn.conf, written at reconfigure from the provider
    # config); deploy/scripts/cdn.scm reads them. A box with no CDN, or no
    # key, has nothing to purge and the tool says so. Non-fatal either way.
    local TOR=""
    command -v torsocks >/dev/null 2>&1 && TOR="torsocks"
    log "Purging the CDN..."
    # Same guile invocation shape as run_planner_seeder: shepherd's exec
    # env carries no GUILE_LOAD_PATH, and no CA bundle either.
    local OUT
    OUT=$(cd "$REPO_DIR" && \
        SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
        SSL_CERT_DIR=/etc/ssl/certs \
        GUILE_AUTO_COMPILE=0 \
        GUILE_LOAD_PATH=/run/current-system/profile/share/guile/site/3.0 \
        GUILE_LOAD_COMPILED_PATH=/run/current-system/profile/lib/guile/3.0/site-ccache \
        timeout 120 $TOR guile -L "$REPO_DIR/module" deploy/scripts/cdn.scm purge 2>&1) \
        || log "CDN purge did not complete (non-fatal)"
    [ -n "$OUT" ] && log "$OUT"
}

restart_services() {
    # The sudoers rule (os.scm) grants the playnet user NOPASSWD on exactly
    # `herd restart <these services>` at this absolute path — use it verbatim
    # so sudo's command match can't miss on secure_path resolution.
    log "Restarting services"
    local HERD=/run/current-system/profile/bin/herd

    # playnet-gateway is the production service — its restart MUST land. If it
    # can't, DON'T fail silently (a stale gateway keeps serving old code, which
    # is invisible): capture the error, warn loudly, and drop a marker an
    # operator/monitor can grep. Mirrors the pending-reconfigure pattern.
    if err=$(sudo -n "$HERD" restart playnet-gateway 2>&1); then
        log "  restarted playnet-gateway"
    else
        log "  WARNING: playnet-gateway restart FAILED — it is running STALE code: $err"
        mkdir -p /var/lib/playnet/pending-restart
        echo "$(date -Iseconds) playnet-gateway" >> /var/lib/playnet/pending-restart/queue
    fi

    # playnet-static serves the browser tree and owns HTTP routing
    # (server/serve-static.scm: MIME types, SPA fallback, the /tiles and
    # /route proxies). It reads that module once at exec, so the rsync
    # above changes the file on disk and nothing else — the live server
    # keeps answering from the route table it booted with, and a route
    # added since falls through to the SPA fallback. Same must-land
    # treatment as the gateway: a stale static server is just as
    # invisible, and shows up as HTML where an asset should be.
    if err=$(sudo -n "$HERD" restart playnet-static 2>&1); then
        log "  restarted playnet-static"
    else
        log "  WARNING: playnet-static restart FAILED — it is running STALE code: $err"
        mkdir -p /var/lib/playnet/pending-restart
        echo "$(date -Iseconds) playnet-static" >> /var/lib/playnet/pending-restart/queue
    fi

    # dev-bridge is dev-only and may be absent on prod — best-effort, quiet.
    sudo -n "$HERD" restart dev-bridge >/dev/null 2>&1 \
        && log "  restarted dev-bridge" || true
}

reload_repl() {
    if [ -S /var/run/playnet/repl.sock ]; then
        log "Reloading REPL modules"
        # We already run as playnet — call the binary directly.
        /home/playnet/bin/repl-eval \
            '(for-each (lambda (m) (reload-module (resolve-module m))) (list (quote (playnet core)) (quote (playnet lang knowledge))))' \
            2>/dev/null || log "REPL reload skipped (not running)"
    fi
}

run_preflight() {
    log "Running preflight-check.scm"
    # Already running as playnet user; no sudo needed.
    # preflight-check.scm uses (json) which lives in the system profile at
    # /run/current-system/profile/share/guile/site/3.0 — bare `guile`
    # doesn't include that on its load path by default (only via
    # GUILE_LOAD_PATH, which shepherd doesn't set for this exec), so
    # extend -L explicitly. Also covers (web client), (rnrs bytevectors)
    # etc. that the system profile carries.
    # cd into the checkout: preflight-check.scm shells out to
    # `git status` / `git log rad/main..HEAD`, which need a repo cwd —
    # the shepherd exec starts us at /, so without the cd every run
    # logs two "fatal: not a git repository" lines and the git checks
    # silently pass on empty output.
    (cd "$REPO_DIR" && guile -L "$REPO_DIR/module" \
          -L /run/current-system/profile/share/guile/site/3.0 \
          -C /run/current-system/profile/lib/guile/3.0/site-ccache \
          "$REPO_DIR/deploy/scripts/preflight-check.scm") 2>&1 \
        | while IFS= read -r line; do log "preflight: $line"; done
    local rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        log "preflight-check FAILED (exit $rc) — aborting"
        return 1
    fi
    return 0
}

root_free_gb() {
    # Whole gigabytes free on the root filesystem (where /gnu/store lives).
    df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9'
}

reclaim_store() {
    # Collect dead store paths until STORE_FREE_TARGET_GB is free. Needs no
    # network and no sudo (the daemon does the work). Cheap when idle.
    local before after
    before=$(root_free_gb)
    if guix gc -F "${STORE_FREE_TARGET_GB}G" >/dev/null 2>&1; then
        after=$(root_free_gb)
        log "store reclaim: ${before:-?}G → ${after:-?}G free (target ${STORE_FREE_TARGET_GB}G)"
    else
        log "store reclaim: guix gc failed (non-fatal) — ${before:-?}G free"
    fi
}

_pack_one() {
    # Internal: build one docker pack, copy to $ARTIFACTS_DIR/$2,
    # update the matching symlink. Args: $1=manifest path, $2=basename
    # (e.g. playnet-<sha>.tar.gz), $3=symlink name (e.g. latest.tar.gz).
    local manifest="$1" basename="$2" link="$3" out="$ARTIFACTS_DIR/$2"
    local TOR=""
    command -v torsocks >/dev/null 2>&1 && TOR="torsocks"

    local extra_args=""
    case "$basename" in
        *peer*)
            # Peer image needs init.sh as the docker entrypoint.
            extra_args="--entry-point=/share/playnet/deploy/peer/init.sh"
            ;;
    esac

    log "guix pack: $manifest → $basename"
    local pack_path
    pack_path=$($TOR guix pack --format=docker \
        -S /bin=bin -S /lib=lib -S /share=share \
        $extra_args \
        -L "$REPO_DIR/deploy/guix" \
        -m "$manifest" 2>&1 \
        | tee >(while IFS= read -r line; do log "pack: $line"; done >&2) \
        | tail -1) || {
        log "WARNING: pack of $manifest failed, skipping"
        return 0
    }

    if [ ! -f "$pack_path" ]; then
        log "WARNING: pack output is not a file: $pack_path"
        return 0
    fi

    cp "$pack_path" "$out"
    ln -sfn "$basename" "$ARTIFACTS_DIR/$link"
    log "Image written: $out"
    # The copy in $ARTIFACTS_DIR is the artifact; the store path is a
    # 260 MB leaf nothing references. Let it go now rather than at the next
    # gc (a root-owned deletion the daemon performs; non-fatal if refused).
    guix gc --delete "$pack_path" >/dev/null 2>&1 \
        || log "  (pack path kept in the store until the next gc)"
}

build_docker_image() {
    # Build two flavors per push:
    #   - sealed:  playnet + bash + coreutils + rns-bridge. Immutable
    #              snapshot; right for distribution to anyone.
    #   - peer:    sealed + radicle + tor + shepherd + git + init.sh.
    #              Self-updating: follows main, atomic generation
    #              switching, crash-loop rollback. Right for
    #              co-maintainers running a playnet node.
    # The two share most of their closure so the marginal cost of the
    # second pack is mostly just the radicle/tor/shepherd binaries.

    local short_sha
    short_sha=$(cd "$REPO_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")

    # /var/lib/playnet is owned by the playnet user (this hook's uid), so we
    # create the artifacts subdir WITHOUT sudo. The previous `sudo mkdir`
    # silently failed — the sudoers rule grants only `herd restart …`, not
    # mkdir — so `cp` below hit a missing dir and, under `set -euo pipefail`,
    # aborted the whole deploy (skipping the gateway restart). Plain mkdir,
    # owned by the parent's uid, just works.
    mkdir -p "$ARTIFACTS_DIR"

    # The packs are distribution images, not the deploy: with the disk low
    # they are the one step worth skipping. Reclaim first, then decide.
    local free
    free=$(root_free_gb)
    if [ "${free:-0}" -lt "$STORE_FREE_MIN_GB" ]; then
        reclaim_store
        free=$(root_free_gb)
    fi
    if [ "${free:-0}" -lt "$STORE_FREE_MIN_GB" ]; then
        log "SKIPPING docker packs: ${free:-?}G free on / (< ${STORE_FREE_MIN_GB}G)"
        return 0
    fi

    log "Building docker images for ${short_sha} via guix pack"
    _pack_one "$REPO_DIR/.guix/docker-manifest.scm" \
              "playnet-${short_sha}.tar.gz" "latest.tar.gz"
    _pack_one "$REPO_DIR/.guix/docker-manifest-peer.scm" \
              "playnet-peer-${short_sha}.tar.gz" "latest-peer.tar.gz"

    # Prune: keep $ARTIFACTS_KEEP most recent of each kind.
    for prefix in playnet- playnet-peer-; do
        ls -1t "$ARTIFACTS_DIR/${prefix}"*.tar.gz 2>/dev/null \
            | tail -n +"$((ARTIFACTS_KEEP + 1))" \
            | xargs -r rm -f
    done
}

full_reconfigure() {
    log "Full system reconfigure (Cookbook §7.5 pattern)"

    # Tor-route every guix outbound. The server has tor installed; if
    # torsocks is somehow missing, fail rather than silently leaking.
    local TOR=""
    if command -v torsocks >/dev/null 2>&1; then
        TOR="torsocks"
    else
        log "ERROR: torsocks missing — refusing to fetch over clearnet"
        return 1
    fi

    # Small jitter so the reconfigure doesn't happen exactly at the
    # ref-update timestamp (timing-correlation prevention for Radicle
    # peers + Guix substitute servers observing fetches).
    local JITTER=$((RANDOM % 60))
    log "Jitter: sleeping ${JITTER}s before fetch"
    sleep "$JITTER"

    log "Pulling channels via $TOR..."
    sudo $TOR guix pull -C "$REPO_DIR/deploy/channels.scm" --verbosity=1 || {
        log "WARNING: guix pull failed, continuing with current Guix"
    }

    log "Building packages via manifest (via $TOR)..."
    $TOR guix build -m "$REPO_DIR/.guix/manifest.scm" 2>&1 | tail -5 || {
        log "WARNING: manifest build failed, continuing with reconfigure"
    }

    sudo $TOR /root/.config/guix/current/bin/guix system reconfigure \
        "$REPO_DIR/deploy/machines.scm" \
        --allow-downgrades \
        --verbosity=2
    log "Reconfigure complete"
}

# --- Determine what changed and act accordingly ---

handle_update() {
    local changed_files="$1"

    # Preflight gate: refuse to apply anything if the tree is unsafe.
    # Returning 0 (not failure) keeps the watch loop alive; the next push
    # that fixes the issue will get gated through.
    if ! run_preflight; then
        return 0
    fi

    # Infrastructure changed → sync code + drop a marker, but do NOT
    # auto-reconfigure. full_reconfigure needs `sudo guix system
    # reconfigure`; we run as the playnet user and Guix's sudo isn't
    # setuid (security-by-design — adding setuid would defeat the
    # immutable-system property). Previous behavior: sudo fails →
    # set -e fires → the entire watch loop exits 1 → no further pushes
    # auto-deploy until an operator manually `herd start radicle-ci`.
    # That silently broke auto-deploy for ~19h after one deploy/guix
    # commit. Now we log + drop a marker file the operator can grep.
    if echo "$changed_files" | grep -qE '^deploy/(guix|packages|scripts)/|^guix\.scm$|^\.guix/'; then
        # The build products this commit's sources feed, BEFORE the sync
        # copies them — the same two the application branches below run,
        # for the same reason. Found live 2026-09-23: a commit carrying
        # hoot/, server/ and deploy/ together took this branch, synced the
        # new page and gateway, and left the wasm the page's vat runs from
        # at the previous build — new JS asking for a handler the bundle
        # did not have. Both stay non-fatal, as below.
        if echo "$changed_files" | grep -qE '^(module|server|planner|hoot|browser)/'; then
            build_browser_wasm || log "  build_browser_wasm failed (non-fatal — syncing existing wasm)"
        fi
        if echo "$changed_files" | grep -qE '^module/'; then
            build_planner_kernel || log "  build_planner_kernel failed (non-fatal — native-c backend may be stale/unavailable)"
        fi
        sync_application_code
        log "INFRA CHANGE detected — requires manual 'guix system reconfigure' (sudo unavailable in shepherd context)"
        log "  changed files: $changed_files"
        mkdir -p /var/lib/playnet/pending-reconfigure
        echo "$(date -Iseconds) $changed_files" \
            >> /var/lib/playnet/pending-reconfigure/queue
        # One commit can carry both infra and application code — this branch
        # matches on the infra paths and returns, so without these the
        # application half syncs to disk and stops there. The gateway and the
        # static server each read their code once at exec, so they would go on
        # answering from the version they booted with: the same stale-code
        # failure the marker above exists to make visible, arriving by a
        # quieter route. The reconfigure stays manual; the restart does not
        # depend on it.
        if echo "$changed_files" | grep -qE '^(module|server|planner)/'; then
            restart_services
            reload_repl
        fi
        # Likewise the edge: browser assets that changed in the same commit
        # stay cached at the CDN until something purges them.
        if echo "$changed_files" | grep -qE '^(browser|module|server|planner)/'; then
            purge_cdn_cache
        fi
        build_docker_image || log "  build_docker_image failed (non-fatal — distribution image only)"
        reclaim_store
        return
    fi

    # Application code changed → hot reload.
    # Module changes can affect the browser too (the wasm bundles modules
    # under hoot/repl.scm's import graph), so rebuild the wasm here as
    # well — cheap if substitutes are cached, and prevents drift between
    # the running gateway and what the browser sees.
    if echo "$changed_files" | grep -qE '^(module|server|planner)/'; then
        # Heavy/optional steps (wasm, kernel, docker pack) are guarded `|| log`
        # so a failure in one can NEVER abort the deploy before the gateway
        # restart under `set -euo pipefail` — that regression once left the
        # gateway on 14-day-old code. wasm and the planner kernel both stay
        # BEFORE sync so the freshly-built artifact is what gets copied, but
        # both are non-fatal so a bad build still deploys the server. sync +
        # restart are the critical path: unguarded, so a genuine failure there
        # retries on the next trigger.
        build_browser_wasm || log "  build_browser_wasm failed (non-fatal — syncing existing wasm)"
        build_planner_kernel || log "  build_planner_kernel failed (non-fatal — native-c backend may be stale/unavailable)"
        sync_application_code
        restart_services
        reload_repl
        build_docker_image || log "  build_docker_image failed (non-fatal — distribution image only)"
        purge_cdn_cache
        reclaim_store
        return
    fi

    # Browser/hoot edit → rebuild wasm + sync. No service restart needed
    # (nginx serves the .wasm directly off disk), no docker rebuild
    # (browser ships separately from the image runtimes). hoot/ is in
    # this branch because the wasm artifacts are built FROM it — they are
    # gitignored build products, so a hoot/-only push carries no binary
    # and the box build is the only thing that refreshes the served wasm.
    if echo "$changed_files" | grep -qE '^(browser|hoot)/'; then
        build_browser_wasm || log "  build_browser_wasm failed (non-fatal — syncing existing wasm)"
        sync_application_code
        purge_cdn_cache
        reclaim_store
        return
    fi

    # Anything else (docs, tests): just sync.
    sync_application_code
}

# --- Main loop: maintain checkout and watch for updates ---

# Ensure checkout exists
if [ ! -d "$REPO_DIR/.git" ]; then
    log "Creating initial checkout from Radicle"
    # Clone from the local Radicle storage
    # Strip rad: prefix for filesystem path
    rid_bare="${PLAYNET_RID#rad:}"
    # rad 1.7+ syntax: `rad clone <RID> [PATH]` (positional, --path removed).
    rad_clone_err=$(rad clone "$PLAYNET_RID" "$REPO_DIR" 2>&1) || {
        log "rad clone failed: $rad_clone_err"
        log "Falling back to git clone from local storage"
        # RAD_HOME is the rad data dir itself (e.g. /var/lib/playnet/radicle/.radicle).
        # Storage lives at $RAD_HOME/storage/<rid>, NOT $RAD_HOME/.radicle/storage/<rid>.
        git clone "$RAD_HOME/storage/$rid_bare" "$REPO_DIR"
    }
    sync_application_code
    log "Initial checkout ready"
fi

# Periodic-fetch backstop. The event-driven main loop assumes
# canonicalRefUpdated reliably fires whenever our remote has new
# content — but rad's gossip topology is non-deterministic: a push from
# one node only reaches ~3 random seeds, and those seeds may not be in
# this node's peer set, so the event never arrives. Adding `rad sync
# --fetch` on a fixed cadence catches every miss eventually; a
# successful fetch that pulls new objects then fires canonicalRefUpdated
# locally, which the main loop catches and deploys normally. Failures
# are non-fatal (the loop retries).
PERIODIC_FETCH_SEC="${PERIODIC_FETCH_SEC:-300}"
# A single deploy must never hold the lock forever. A wasm rebuild + two
# docker packs is legitimately slow, but UNBOUNDED is how a wedged
# guix/rad call — or, for an orphaned generation, a `log` write blocked
# on a stdout pipe shepherd stopped draining — froze the pipeline for 12
# minutes still holding .deploy.lock. The watchdog kills the deploy tree
# past this bound so the next trigger proceeds.
DEPLOY_TIMEOUT_SEC="${DEPLOY_TIMEOUT_SEC:-3600}"
LOCK_FILE="/var/lib/playnet/radicle/.deploy.lock"

# --- Pre-merge patch CI (opt-in) --------------------------------------------
# Builds contributor PATCHES before a delegate merges them, and posts the
# result as a patch comment on the board (see CONTRIBUTING.md #3). This is the
# "trust with a safety net" half: a delegate merges knowing it builds.
#
# Deliberately isolated from the deploy path — a SEPARATE checkout, a SEPARATE
# lock, its own watchdog — so a bad patch can never touch production or wedge
# the deploy pipeline. Polls (like the backstop) because rad patch events are
# as gossip-unreliable as canonical ones. Non-fatal throughout.
#
# OPT-IN: stays dormant unless PATCH_CI_ENABLE=1, so shipping this hook change
# cannot alter box behaviour until an operator flips it on after a smoke test.
PATCH_CI_ENABLE="${PATCH_CI_ENABLE:-0}"
PATCH_CI_POLL_SEC="${PATCH_CI_POLL_SEC:-300}"
PATCH_CI_TIMEOUT_SEC="${PATCH_CI_TIMEOUT_SEC:-1800}"
PATCH_CI_CMD="${PATCH_CI_CMD:-make test}"
PATCH_CI_DIR="${PATCH_CI_DIR:-/var/lib/playnet/radicle/patch-ci-checkout}"
PATCH_CI_STATE="${PATCH_CI_STATE:-/var/lib/playnet/radicle/patch-ci-state}"
PATCH_CI_LOCK="/var/lib/playnet/radicle/.patch-ci.lock"
# Enable flag file — lets an operator turn patch CI on/off with a `touch`
# WITHOUT a `guix system reconfigure` (sudo is unavailable in the shepherd
# context; a full reconfigure to flip one env var would be absurd). Enabled if
# PATCH_CI_ENABLE=1 OR this file exists.
PATCH_CI_FLAG="${PATCH_CI_FLAG:-/var/lib/playnet/patch-ci-enabled}"
patch_ci_enabled() { [ "$PATCH_CI_ENABLE" = "1" ] || [ -f "$PATCH_CI_FLAG" ]; }

# Kill a pid and its ENTIRE descendant tree, children first. pgrep walks
# the live process table, so unlike a cmdline match on "radicle-ci-hook.sh"
# (which catches only the bash subshells) this also reaps the non-bash
# deploy children — rsync / make / guix / torsocks — which are exactly
# what got orphaned and sat holding the lock.
kill_tree() {
    local pid="$1" sig="${2:-TERM}" child
    [ -n "$pid" ] || return 0
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        kill_tree "$child" "$sig"
    done
    kill "-$sig" "$pid" 2>/dev/null || true
}

# Reap orphan instances from previous service generations. Shepherd's
# make-kill-destructor signals only the MAIN bash pid, and the old trap
# killed only the backstop pid — so every `herd restart` could leave a
# backstop loop AND its in-flight deploy subshell (plus rsync/make
# children) re-parented to init, running stale code or wedged on the lock.
# Kill each other instance's WHOLE TREE: TERM, brief grace, then KILL.
reap_others() {
    local pid
    for pid in $(pgrep -f "radicle-ci-hook.sh" 2>/dev/null); do
        if [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ]; then continue; fi
        kill_tree "$pid" TERM
    done
    sleep 1
    for pid in $(pgrep -f "radicle-ci-hook.sh" 2>/dev/null); do
        if [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ]; then continue; fi
        kill_tree "$pid" KILL
    done
}
reap_others

# Run one deploy under a watchdog so it can never wedge the pipeline:
# handle_update runs as a background child; if it outlives
# DEPLOY_TIMEOUT_SEC the watchdog SIGTERMs its whole tree and we return,
# releasing the flock for the next trigger.
guarded_deploy() {
    local cf="$1" rc=0 hu wd
    handle_update "$cf" &
    hu=$!
    ( sleep "$DEPLOY_TIMEOUT_SEC"
      log "Deploy exceeded ${DEPLOY_TIMEOUT_SEC}s — killing tree $hu"
      kill_tree "$hu" TERM ) &
    wd=$!
    wait "$hu" || rc=$?
    kill_tree "$wd" KILL 2>/dev/null || true   # cancel the watchdog
    return "$rc"
}

# Take .deploy.lock non-blocking and deploy the given changed-file list.
# The backstop and the event path share this one lock, so two deploys can
# never interleave on the checkout; if one is already running we skip.
locked_deploy() {
    (
        flock -n 9 || { log "Deploy already in progress — skipping"; exit 0; }
        guarded_deploy "$1" || log "Deploy returned non-zero (will retry next trigger)"
        # Deploy done: if it rsynced a new version of this very script, reload.
        maybe_reexec_self
    ) 9>"$LOCK_FILE" || log "Deploy attempt failed (will retry)"
}

# --- Patch CI: build one patch head in the ISOLATED checkout ----------------
PATCH_CI_LAST_TAIL=""
PATCH_CI_RAN=""

# Run the repo's .radicle/native.yaml (the Radicle-native CI contract): the
# `shell` block, under `set -xeuo pipefail`, exactly as radicle-native-ci runs
# it. This file IS the one the broker's native adapter consumes, so the repo's
# CI definition does not change when the runner is swapped.
#
# It parsed `run:` lines before, which is the shell-hook shape and NOT the
# adapter's: RunSpec is `deny_unknown_fields` over a single `shell` key, so the
# old file failed to deserialize and the adapter ran nothing on every commit
# while reporting failure. Two readers, one file, two schemas — asserted in a
# comment, never checked. Reading the same key is what makes the claim true.
patch_ci_run_native() {
    local script rc=0
    # the `shell: |` block: everything indented under it, dedented
    script="$(awk '/^shell:[[:space:]]*\|/{f=1;next} f{ if ($0 ~ /^[^[:space:]]/) exit; sub(/^  /,""); print }' \
                .radicle/native.yaml)"
    if [ -z "${script//[[:space:]]/}" ]; then
        echo ">>> native.yaml has no shell: block"; return 201
    fi
    echo ">>> running .radicle/native.yaml shell block:"
    echo "$script" | sed 's/^/    /'
    timeout "$PATCH_CI_TIMEOUT_SEC" bash -c "set -xeuo pipefail
$script"; rc=$?
    if [ "$rc" != 0 ]; then echo ">>> native CI FAILED (rc=$rc)"; return "$rc"; fi
    echo ">>> native CI passed"
    return 0
}

patch_ci_build_one() {
    local head="$1" rid_bare STORE logf rc
    rid_bare="${PLAYNET_RID#rad:}"
    STORE="$RAD_HOME/storage/$rid_bare"
    # Lazy-create the isolated checkout (a plain clone of local storage — it
    # NEVER touches $REPO_DIR / the deploy path).
    if [ ! -d "$PATCH_CI_DIR/.git" ]; then
        git clone -q "$STORE" "$PATCH_CI_DIR" 2>/dev/null \
            || { PATCH_CI_LAST_TAIL="isolated-checkout clone failed"; return 90; }
    fi
    # Pull ALL storage refs so the patch head object is present, then hard-clean
    # and detach onto it (so a prior build can't bleed into this one).
    git -C "$PATCH_CI_DIR" fetch -q "$STORE" '+refs/*:refs/storage/*' 2>/dev/null || true
    git -C "$PATCH_CI_DIR" reset -q --hard 2>/dev/null || true
    git -C "$PATCH_CI_DIR" clean -qxfd 2>/dev/null || true
    if ! git -C "$PATCH_CI_DIR" checkout -q --detach "$head" 2>/dev/null; then
        PATCH_CI_LAST_TAIL="patch head $head not found in local storage"
        return 91
    fi
    logf=$(mktemp /tmp/patch-ci-XXXXXX.log)
    if [ -f "$PATCH_CI_DIR/.radicle/native.yaml" ]; then
        # Radicle-native CI contract — run the repo's declared steps.
        PATCH_CI_RAN='.radicle/native.yaml'
        ( cd "$PATCH_CI_DIR" && patch_ci_run_native ) >"$logf" 2>&1
    else
        # Fallback for a patch whose tree has no native.yaml yet.
        PATCH_CI_RAN="$PATCH_CI_CMD"
        ( cd "$PATCH_CI_DIR" && timeout "$PATCH_CI_TIMEOUT_SEC" bash -lc "$PATCH_CI_CMD" ) >"$logf" 2>&1
    fi
    rc=$?
    PATCH_CI_LAST_TAIL=$(tail -25 "$logf")
    rm -f "$logf"
    return "$rc"
}

# One pass: build every OPEN patch whose head we haven't built yet, comment it.
patch_ci_once() {
    patch_ci_enabled || return 0
    command -v rad >/dev/null 2>&1 || return 0
    local rid_bare STORE pids pid show status head marker prev msg rc
    rid_bare="${PLAYNET_RID#rad:}"
    STORE="$RAD_HOME/storage/$rid_bare"
    [ -d "$STORE" ] || return 0
    mkdir -p "$PATCH_CI_STATE"

    # Enumerate patch COB ids straight from storage refs — robust and
    # independent of `rad patch list` table formatting; dedup across namespaces.
    pids=$(git -C "$STORE" for-each-ref --format='%(refname)' \
             'refs/namespaces/*/refs/cobs/xyz.radicle.patch/*' 2>/dev/null \
           | sed 's#.*/##' | sort -u)
    [ -n "$pids" ] || return 0

    for pid in $pids; do
        show=$(cd "$REPO_DIR" && timeout 60 rad patch show "$pid" --repo "$PLAYNET_RID" 2>/dev/null) || continue
        status=$(echo "$show" | grep -i status | head -1 | grep -oiE 'open|merged|archived|draft' | head -1)
        [ "$status" = "open" ] || continue
        head=$(echo "$show" | grep -i head | grep -oiE '[0-9a-f]{40}' | head -1)
        [ -n "$head" ] || continue

        marker="$PATCH_CI_STATE/$pid"
        prev=$(cat "$marker" 2>/dev/null || true)
        [ "$prev" = "$head" ] && continue   # already built this exact revision

        log "patch-ci: building patch $pid @ $head"
        if patch_ci_build_one "$head"; then
            msg="✅ CI passed — \`$PATCH_CI_RAN\` succeeded at \`$head\`."
            rc=0
        else
            rc=$?
            msg=$(printf '❌ CI failed (rc=%s) — `%s` at `%s`.\n\nLast lines:\n```\n%s\n```' \
                    "$rc" "$PATCH_CI_RAN" "$head" "$PATCH_CI_LAST_TAIL")
        fi
        (cd "$REPO_DIR" && timeout 60 rad patch comment "$pid" --repo "$PLAYNET_RID" -m "$msg" >/dev/null 2>&1) \
            || log "patch-ci: could not post comment on $pid (build rc=$rc)"

        # Native patch LABEL as the machine-readable CI signal — this is what
        # merge-patch.sh gates on. Labels are first-class Radicle patch state,
        # so the delegate (and the board) see ci-pass/ci-fail at a glance.
        local good bad
        if [ "$rc" = 0 ]; then good="ci-pass"; bad="ci-fail"; else good="ci-fail"; bad="ci-pass"; fi
        (cd "$REPO_DIR" && timeout 30 rad patch label "$pid" "$good" --repo "$PLAYNET_RID" >/dev/null 2>&1) \
            || log "patch-ci: could not set label $good on $pid"
        (cd "$REPO_DIR" && timeout 30 rad patch label "$pid" --delete "$bad" --repo "$PLAYNET_RID" >/dev/null 2>&1) || true

        echo "$head" > "$marker"   # record even on failure so we don't re-spam
        log "patch-ci: patch $pid @ $head done (rc=$rc, label=$good)"
    done
}

# Poll loop — mirrors backstop_loop (rad patch events are as gossip-unreliable
# as canonical ones). Own lock so passes never overlap; per-op timeouts above
# bound each build/rad call, so no deploy-path watchdog is needed here.
patch_ci_loop() {
    if ! patch_ci_enabled; then
        log "patch-ci: disabled (enable with: touch $PATCH_CI_FLAG   — or PATCH_CI_ENABLE=1)"
        # Re-check periodically so `touch`-ing the flag turns CI on WITHOUT a
        # service restart (no reconfigure needed on the tor-only box).
        while ! patch_ci_enabled; do sleep "$PATCH_CI_POLL_SEC"; done
        log "patch-ci: flag appeared — enabling"
    fi
    log "patch-ci: enabled — every ${PATCH_CI_POLL_SEC}s, native.yaml or '$PATCH_CI_CMD', checkout: $PATCH_CI_DIR"
    while true; do
        sleep "$PATCH_CI_POLL_SEC"
        ( flock -n 8 || exit 0
          patch_ci_once || true
        ) 8>"$PATCH_CI_LOCK" || true
    done
}

# --- Canonical auto-co-sign (operator delegate → board) ---------------------
# When the operator delegate (ops) advances its signed main beyond
# canonical — e.g. after a plain `git push rad main` from home, whose ref
# reaches this node over the onion — co-sign it as THIS node (the box delegate)
# so canonical advances and the board updates. This makes `git push rad main`
# ALONE enough to update the board; `make ship` is no longer required (it stays
# as a synchronous fallback). FF-ONLY: never auto-sign a rewind or a divergent
# history — that needs a real quorum decision, not a rubber stamp. Opt out with
# CANONICAL_COSIGN=0.
#
# TRUST NOTE: this makes the box co-sign whatever the operator delegate
# publishes — effectively threshold-1 for the operator. Fine while the box is
# just the operator's own server. When HUMAN delegates join, raise the identity
# threshold so operator+box alone are NOT a quorum (else human review is
# bypassed); this only ever co-signs the ONE operator delegate below.
CANONICAL_COSIGN="${CANONICAL_COSIGN:-1}"
OPERATOR_DELEGATE="${OPERATOR_DELEGATE:-z6MkhFnFe4dPHjHfZb4YAoYGf48AiaLAZHDj53yZBzfCJKVf}"

canonical_cosign() {
    [ "$CANONICAL_COSIGN" = "1" ] || return 0
    local rid_bare STORE omar canon
    rid_bare="${PLAYNET_RID#rad:}"
    STORE="$RAD_HOME/storage/$rid_bare"
    [ -d "$STORE" ] || return 0
    omar=$(git -C "$STORE" rev-parse --verify "refs/namespaces/$OPERATOR_DELEGATE/refs/heads/main" 2>/dev/null) || return 0
    canon=$(git -C "$STORE" rev-parse --verify "refs/heads/main" 2>/dev/null) || return 0
    [ "$omar" != "$canon" ] || return 0
    if ! git -C "$STORE" merge-base --is-ancestor "$canon" "$omar" 2>/dev/null; then
        log "cosign: operator main ${omar:0:8} is not a fast-forward of canonical ${canon:0:8} — skipping (manual quorum needed)"
        return 0
    fi
    log "cosign: operator delegate advanced to ${omar:0:8} (ff) — co-signing as this node"
    ( cd "$REPO_DIR" || exit 1
      git fetch -q "$STORE" "refs/namespaces/$OPERATOR_DELEGATE/refs/heads/main" 2>/dev/null || true
      if ! git merge --ff-only "$omar" >/dev/null 2>&1; then
          # A prior fetch may have landed the commit WITHOUT its full tree
          # (interrupted mid-transfer) — every future ff then dies with
          # "unable to read tree", and normal negotiation won't repair it (we
          # "have" the commit, so nothing re-sends). That silently wedged the
          # whole pipeline for days. Force a full object backfill and retry
          # once before giving up.
          log "cosign: ff to ${omar:0:8} failed ($(git merge --ff-only "$omar" 2>&1 | head -1)) — refetching objects"
          git fetch --refetch -q "$STORE" "refs/namespaces/$OPERATOR_DELEGATE/refs/heads/main" 2>/dev/null || true
      fi
      if git merge --ff-only "$omar" >/dev/null 2>&1; then
          env RAD_PASSPHRASE="$(cat /run/secrets/rad-passphrase 2>/dev/null)" \
              git push rad main >/dev/null 2>&1 \
              || log "cosign: rad push failed (passphrase/permissions?)"
          # Radicle's canonical computation is over-conservative while orphaned
          # delegates linger on divergent history (an old "clearnet-face" fork):
          # after the push it re-pins refs/heads/main to an OLD commit instead of
          # the operator head — even though threshold=1 makes the operator
          # delegate authoritative for canonical. Force canonical to the operator
          # head (the ff-only guards above already proved it's a clean descendant)
          # so the board/explorer + peers track current work. No-op once canon
          # already equals it. REMOVE once the orphan delegates are dropped (rev
          # e7ed3e3 — needs their own signatures; see project_deploy_pipeline).
          now=$(git -C "$STORE" rev-parse --verify refs/heads/main 2>/dev/null || echo "")
          if [ "$now" != "$omar" ] && git -C "$STORE" merge-base --is-ancestor "$now" "$omar" 2>/dev/null; then
              git -C "$STORE" update-ref refs/heads/main "$omar" \
                  && log "cosign: forced canonical to operator head ${omar:0:8} (Radicle re-pinned to ${now:0:8}; threshold=1 → operator authoritative)"
          else
              log "cosign: canonical advanced to $(git -C "$STORE" rev-parse --short refs/heads/main 2>/dev/null) — board updated"
          fi
      else
          log "cosign: checkout STILL could not ff to ${omar:0:8} after refetch — skipping (manual repair needed)"
      fi )
}

backstop_loop() {
    while true; do
        sleep "$PERIODIC_FETCH_SEC"
        # cd to the checkout: rad sync requires being inside a rad repo.
        # Failures (network, no new content, etc.) are silent on purpose
        # — they just mean "nothing pulled this cycle, try next."
        (cd "$REPO_DIR" && rad sync --fetch 2>/dev/null) || true

        # Auto-co-sign: if the operator delegate advanced canonical-worthy, sign
        # it as this node so canonical + the board advance with no manual promote.
        # Runs before the local-push check below (which then deploys the new tip).
        canonical_cosign

        # Canonical backstop: event_watch_loop's `canonicalRefUpdated` subscription
        # is a live stream, not a backlog — a canonical advance landing in the gap
        # between "stream ended" and "reconnected" (its own BACKOFF loop, below) is
        # gone the moment it passes: the next event tells the stream about the NEXT
        # advance, never the one it missed. Caught live 2026-09-14: canonical in the
        # bare STORE had moved on, the checkout hadn't, and neither of the other two
        # checks here noticed — canonical_cosign only acts when THIS node's own
        # signature is the thing missing (omar != canon) and is a no-op once they
        # already agree, and the deployed-sha check below only compares the checkout
        # to what is DEPLOYED, never to canonical. So: read canonical straight from
        # the bare storage (the same place canonical_cosign reads $canon from) and
        # fast-forward the checkout onto it whenever it is behind. FF-ONLY, the same
        # discipline as canonical_cosign — a diverged canonical needs a human, a
        # behind one just needs this. Runs every tick either way; cheap when clean.
        local _rid_bare _store _canon _chead
        _rid_bare="${PLAYNET_RID#rad:}"
        _store="$RAD_HOME/storage/$_rid_bare"
        _canon=$(git -C "$_store" rev-parse --verify refs/heads/main 2>/dev/null) || _canon=""
        _chead=$(cd "$REPO_DIR" && git rev-parse --verify HEAD 2>/dev/null) || _chead=""
        if [ -n "$_canon" ] && [ -n "$_chead" ] && [ "$_canon" != "$_chead" ] \
           && git -C "$_store" merge-base --is-ancestor "$_chead" "$_canon" 2>/dev/null; then
            log "Canonical backstop: checkout ${_chead:0:8} is behind canonical ${_canon:0:8} (ff) — catching up"
            if (cd "$REPO_DIR" && git fetch rad 2>/dev/null && git reset --hard "$_canon" >/dev/null 2>&1); then
                log "Canonical backstop: checkout now at ${_canon:0:8}"
            else
                log "Canonical backstop: could not fast-forward to ${_canon:0:8} — will retry next tick"
            fi
        fi

        # Local-push backstop: an on-box `git push rad main` advances the
        # checkout HEAD but fires NO canonicalRefUpdated event (that only
        # fires on FETCHED updates), and the event handler's prev==new check
        # would skip it anyway. So compare the checkout HEAD to what is
        # actually deployed (the .deployed-sha marker written by
        # sync_application_code) and deploy any drift. Converges: every
        # handle_update path rewrites the marker, so after a deploy
        # head==deployed and it won't repeat. locked_deploy's flock keeps a
        # long deploy (wasm rebuild) from overlapping the next 300s tick.
        # `|| true` is required: before the first post-upgrade deploy the
        # marker file doesn't exist, cat exits 1, and under set -e a bare
        # failed assignment would kill this whole background loop.
        local _deployed _head _cf
        _deployed=$(cat "$DEPLOY_DIR/.deployed-sha" 2>/dev/null || true)
        _head=$(cd "$REPO_DIR" && git rev-parse --short HEAD 2>/dev/null) || true
        if [ -n "$_head" ] && [ "$_head" != "$_deployed" ]; then
            _cf=$(cd "$REPO_DIR" && { [ -n "$_deployed" ] && git diff --name-only "$_deployed" "$_head" 2>/dev/null; } || true)
            log "Local-push backstop: checkout $_head != deployed ${_deployed:-none} - deploying"
            locked_deploy "$_cf"
        fi
    done
}

event_watch_loop() {
    # Reconnect loop — the rad node events stream can end unexpectedly.
    # Retry with backoff, capped at 60 seconds.
    local BACKOFF=1
    while true; do
        log "Watching for ref updates on $PLAYNET_RID"

        rad node events 2>/dev/null | while IFS= read -r event; do
            BACKOFF=1  # reset backoff on successful read
            # Trigger on canonicalRefUpdated — fires exactly once per real
            # main-update, only after sigref validation succeeds. The actual
            # event names are camelCase JSON ("canonicalRefUpdated",
            # "refsFetched", "peerConnected"); older docs / earlier rad
            # versions used "refs-changed" which never appears in the stream.
            if echo "$event" | grep -q "$PLAYNET_RID" && echo "$event" | grep -q '"type":"canonicalRefUpdated"'; then
                log "Ref update detected: $event"

                cd "$REPO_DIR"
                git fetch rad 2>/dev/null || git fetch origin 2>/dev/null || true
                prev_head=$(git rev-parse HEAD)
                git reset --hard FETCH_HEAD 2>/dev/null || true
                new_head=$(git rev-parse HEAD)

                if [ "$prev_head" != "$new_head" ]; then
                    changed_files=$(git diff --name-only "$prev_head" "$new_head" 2>/dev/null || echo "")
                    log "Changed files: $changed_files"
                    locked_deploy "$changed_files"
                else
                    log "No new commits, skipping"
                fi
            fi
        done

        log "Event stream ended, reconnecting in ${BACKOFF}s..."
        sleep "$BACKOFF"
        BACKOFF=$((BACKOFF * 2))
        [ "$BACKOFF" -gt 60 ] && BACKOFF=60
    done
}

# Clean up our ENTIRE process tree on exit or signal. Both loops run in
# the BACKGROUND and the script blocks in `wait`, which a signal
# interrupts promptly — a foreground `rad node events` pipeline would
# instead defer the trap until it returned (i.e. never), so the old
# structure could not clean up at all on `herd stop`/`herd restart`.
# cleanup kills every child tree (TERM, brief grace, then KILL) so no
# backstop or half-run deploy is ever orphaned to run stale code or hold
# the lock. `pgrep -P $$` re-reads the live tree each pass.
cleanup() {
    trap - EXIT TERM INT HUP
    local child
    for child in $(pgrep -P $$ 2>/dev/null); do kill_tree "$child" TERM; done
    sleep 1
    for child in $(pgrep -P $$ 2>/dev/null); do kill_tree "$child" KILL; done
}
trap cleanup EXIT
trap 'exit 143' TERM INT HUP
# Self-update: a finished deploy that landed a new hook signals us here.
trap reexec_self USR1

# A deploy that carried a new version of this script ran under the version
# before it (re-exec follows the deploy). If the last sync was done by a
# different hook than the one now running, redo the sync once under this
# code: rsync is a no-op, only the steps the new hook adds do work. Removes
# the "ship a hook change one deploy ahead" rule (learned 2026-09-12 when a
# tree removal deployed under a hook without its protect rule).
_last_hook="$(cat "$DEPLOY_DIR/.deployed-hook-sha" 2>/dev/null || true)"
if [ "$_last_hook" != "$RUNNING_HOOK_SHA" ]; then
    # (an absent marker counts as "another hook": the first boot of the
    # version that writes it re-syncs once too — a no-op except the
    # placement steps, which is the point)
    log "hook: last sync ran under ${_last_hook:-unknown}, this is ${RUNNING_HOOK_SHA:0:8} — re-syncing once under the new code"
    (
        flock -n 9 || { log "hook: deploy in progress — skipping the re-sync"; exit 0; }
        sync_application_code || log "hook: re-sync returned non-zero"
    ) 9>"$LOCK_FILE" || true
fi

backstop_loop &
BACKSTOP_PID=$!
log "Periodic-fetch backstop running (every ${PERIODIC_FETCH_SEC}s, pid $BACKSTOP_PID)"

event_watch_loop &
EVENTS_PID=$!
log "Event watcher running (pid $EVENTS_PID)"

# Pre-merge patch CI (opt-in; dormant unless PATCH_CI_ENABLE=1). Isolated
# checkout + own lock — cannot touch the deploy path. cleanup()'s pgrep -P $$
# reaps it on exit like the other loops.
patch_ci_loop &
PATCH_CI_PID=$!
log "Patch-CI loop started (pid $PATCH_CI_PID, enabled=$PATCH_CI_ENABLE)"

# Block until both loops exit — which only happens on signal; the traps
# above do the cleanup. wait is interruptible, so SIGTERM acts at once.
wait
