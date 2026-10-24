;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/manifests/dev-test-manifest.scm — fast dev test loop env
;;;
;;; Brings up vanilla Guile + Goblins + the Scheme libraries needed to run
;;; every suite under tests/ that needs no daemon, and the *mock-only*
;;; tests under tests/keri/ (i.e. test-keri-*.scm — NOT integration/).
;;;
;;; ── Why not deploy/channels.scm? ────────────────────────────────────────────
;;;
;;; channels.scm pins the `localchimera` channel to a Radicle seed
;;; (currently iris.radicle.xyz, formerly seed.radicle.garden). Both seeds
;;; respond fine to bare `git ls-remote`, but `guix time-machine`'s libgit2
;;; client times out trying to handshake with Radicle's git HTTP bridge. So
;;; every Make target wired through `$(TIME_MACHINE)` hangs. We don't need
;;; the localchimera channel to RUN tests — only `guix pull` / `guix deploy`
;;; need it for reproducibility — so this manifest is consumed via plain
;;; `guix shell -L deploy/guix -m ...` that bypasses time-machine entirely.
;;; Local modules in deploy/guix/ are resolved via -L, not channel pinning.
;;;
;;; Trade-off: NOT bit-for-bit reproducible across hosts (uses whatever
;;; Guix revision the caller has). For production deployment we still go
;;; through `guix time-machine -C deploy/channels.scm`. For the inner dev
;;; test loop, that's the right trade — fast feedback over reproducibility.
;;;
;;; The reproducibility canary is `make test-all-pinned` — the day Radicle's
;;; git HTTP bridge becomes libgit2-friendly again, that target lights up.
;;;
;;; ── Usage ───────────────────────────────────────────────────────────────────
;;;
;;;   guix shell -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- \
;;;     guile --no-auto-compile -L module tests/some-test.scm
;;;
;;; Invoked automatically by Makefile targets via $(GUILE_TEST_DEV).

(use-modules (guix profiles)
             (gnu packages)
             (blake3))                        ; -L deploy/guix provides this

(packages->manifest
 (append
  (map specification->package
       '("guile-next"
         "guile-goblins"
         "guile-gcrypt"
         "guile-json"
         "guile-zlib"                      ; the basemap's PMTiles reader (gzipped directories)
         "guile-sqlite3"                   ; corpus-guile-native phase 2+: read the corpus's .db directly
         "guile-fibers"
         "libsodium"                       ; for Ed25519 seed → keypair FFI
         ;; The planner's §2b hot loop is C, and `libplanner_kernel.so` is a
         ;; build artifact rather than a tracked file — so a fresh checkout has
         ;; the source and not the object. Every `native-c` solve then fails at
         ;; load, which is what CI reported on its first real run (102 suites
         ;; red in ~0 s each, one missing .so). The compiler lives HERE, in the
         ;; same manifest the suite runs under, so the kernel is built by the
         ;; same environment that loads it.
         "gcc-toolchain"
         "make"
         ;; Two more the suite reaches for and this manifest never named, so on a
         ;; developer's machine they came from the HOST and on CI they were
         ;; simply absent: `osqp` (planner.scm's third backend dlopens libosqp —
         ;; three suites select it explicitly and error out where it is missing)
         ;; and GNU `units`, which utils/units.scm shells out to. units.scm
         ;; degrades to #f without it, so its absence is silent rather than
         ;; loud — the worse of the two failures.
         ;;
         ;; `guix shell` without --pure inherits PATH, which is what let all
         ;; three hide: the environment that ran the tests here was never the
         ;; environment the manifest describes.
         "osqp"
         "units"
         "coreutils"
         ;; tools/test/run-scm-tests.sh discovers the suite with `find` and fans out
         ;; with `xargs`; neither is in coreutils. Without them the runner found
         ;; nothing, ran nothing, and printed `0 passed, 0 failed` — exit 0.
         "findutils"
         "grep"
         "sed"
         "bash"
         ;; (localchimera fleet child) generates each child box's SSH key by running
         ;; `ssh-keygen`; tests/fleet/test-child-unlock.scm and test-keeper.scm
         ;; reach it. Same story as the tools above: present from the host on a
         ;; developer's machine, absent under --pure and in native CI, where
         ;; both went red with "fleet child: ssh-keygen failed".
         "openssh"))
  ;; Local C library packaged in deploy/guix/blake3.scm — provides
  ;; libblake3.so for module/localchimera/keri/blake3.scm to dlopen.
  ;; KERIA SAIDs (CESR code "E") are blake3-256 digests.
  (list blake3)))
