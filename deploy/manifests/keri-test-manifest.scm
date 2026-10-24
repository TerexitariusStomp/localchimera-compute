;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/manifests/keri-test-manifest.scm — real-KERIA integration test env
;;;
;;; Brings up the Python stack needed to run `keria start` and `kli witness
;;; demo` alongside Guile + Goblins so `tests/keri/integration/` can exercise
;;; the bridge against real KERIA over real HTTP (ports 3901–3903, 5642–5647).
;;;
;;; ── Why not deploy/channels.scm? ────────────────────────────────────────────
;;;
;;; channels.scm pins the `localchimera` channel to a Radicle seed
;;; (iris.radicle.xyz). The seed itself responds fine to bare `git
;;; ls-remote` in <2s, but `guix time-machine`'s libgit2 client times
;;; out trying to handshake with Radicle's git HTTP bridge. Same
;;; symptom on seed.radicle.garden. So every Make target wired through
;;; `$(TIME_MACHINE)` hangs.  We don't need the localchimera channel for
;;; running tests — only `guix pull` / `guix deploy` need it for
;;; reproducibility — so this manifest is consumed via plain
;;; `guix shell -L deploy/guix -m ...` that bypasses time-machine
;;; entirely. Local modules in deploy/guix/ are resolved via -L, not
;;; via channel pinning.
;;;
;;; Trade-off: this environment is NOT bit-for-bit reproducible across
;;; hosts (it uses whatever Guix revision the caller has). For production
;;; deployment we still go through `guix time-machine -C deploy/channels.scm`.
;;; For a developer-local integration test run, that trade-off is fine.
;;;
;;; ── Usage ───────────────────────────────────────────────────────────────────
;;;
;;;   guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
;;;     sh tests/keri/integration/run-integration.sh
;;;
;;; Invoked automatically by `make test-keri-integration`.

(use-modules (guix profiles)
             (gnu packages)
             (python-keria)               ; -L deploy/guix provides this
             (blake3))                    ; ditto — for libblake3.so

(packages->manifest
 (append
  (map specification->package
       '("guile"
         "guile-goblins"
         "guile-gcrypt"
         "guile-json"
         "libsodium"                       ; for Ed25519 seed → keypair FFI
         "libgcrypt"                       ; for localchimera/push/crypto.scm dlopen
         "coreutils"
         "grep"
         "sed"
         "curl"
         "procps"
         "bash"))
  ;; Local packages defined in deploy/guix/{python-keria,blake3}.scm —
  ;; these are NOT upstream Guix packages, they get pulled in via
  ;; -L deploy/guix on the shell command line.
  (list python-keri
        python-keria
        blake3)))
