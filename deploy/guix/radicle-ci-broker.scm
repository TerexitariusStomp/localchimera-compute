;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/guix/radicle-ci-broker.scm — Guix packages for the Radicle CI broker
;;; and its native CI adapter (full-native, in-repo, reproducible).
;;;
;;; The broker `cib` watches radicle-node events and dispatches CI to an
;;; adapter; the native adapter runs the repo's .radicle/native.yaml steps and
;;; reports results. Both are Rust; deps are vendored through rust-crates.scm
;;; exactly like radicle-http-api and rns-bridge — no build-time network.
;;;
;;; To update deps after a version bump:
;;;   guix import -i deploy/guix/rust-crates.scm crate -f <Cargo.lock> radicle-ci-broker
;;;   guix import -i deploy/guix/rust-crates.scm crate -f <Cargo.lock> radicle-native-ci
;;; and refresh the (crate-source …) hashes below via `guix download`.

(define-module (radicle-ci-broker)
  #:use-module (guix packages)
  #:use-module (guix build-system cargo)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages sqlite)         ;ci-broker.db
  #:use-module (gnu packages tls)            ;openssl
  #:use-module (gnu packages compression)    ;zlib
  #:use-module (gnu packages pkg-config)
  #:use-module (rust-crates)
  #:export (radicle-ci-broker radicle-native-ci))

(define %ci-phases
  ;; build.rs scripts want a writable HOME/TMPDIR in the sandbox; tests want a
  ;; live node / network, so skip them.
  #~(modify-phases %standard-phases
      (add-after 'unpack 'setenv
        (lambda _
          (setenv "HOME" (getcwd))
          (setenv "TMPDIR" "/tmp")))))

;; radicle-ci-broker-only phases: %ci-phases plus two patches for
;; src/cob.rs's announce(), which every real trigger on this box failed with
;; "no refs were announced" (2026-09-16 incident) even though the job COB
;; itself was correctly signed and written each time.
;;
;; The real bug: `node.announce(repo_id, [], TIMEOUT, announcer, …)` passes
;; an EMPTY namespaces list. Traced into heartwood's own source
;; (radicle-protocol/src/service.rs `refs_announcement_for`): the server
;; builds its announced-refs vec *only* from that namespaces iterator — an
;; empty one means an empty vec means an immediate, synchronous
;; "no refs were announced for {rid}" error (radicle-protocol's
;; Command::AnnounceRefs handler), well before TIMEOUT is ever reached (it
;; only guards a later ack-wait loop this call never got to). Confirmed
;; against `rad sync --announce` (radicle-cli/src/node.rs), which passes
;; `[profile.did().into()]` — its own node id — and works. profile.id()
;; already returns &PublicKey (= NodeId, radicle's own type alias), so
;; *profile.id() is directly the right element type.
;;
;; The TIMEOUT bump (5s→30s) is kept too: real, if secondary, headroom for
;; the post-announce ack-wait loop over Tor once refs are actually sent.
(define %ci-broker-phases
  #~(modify-phases #$%ci-phases
      (add-after 'unpack 'patch-announce-timeout
        (lambda _
          (substitute* "src/cob.rs"
            (("const TIMEOUT: Duration = Duration::from_millis\\(5000\\);")
             "const TIMEOUT: Duration = Duration::from_millis(30000);")
            (("node\\.announce\\(repo_id, \\[\\], TIMEOUT, announcer, \\|_, _\\| \\(\\)\\)")
             "node.announce(repo_id, [*profile.id()], TIMEOUT, announcer, |_, _| ())"))))))

(define-public radicle-ci-broker
  (package
    (name "radicle-ci-broker")
    (version "0.29.0")
    (source (crate-source "radicle-ci-broker" "0.29.0"
                          "0f1qf5vripy9m69pvj66np3smxn7486khsn19haxbd6c2n2825yi"))
    (build-system cargo-build-system)
    (arguments
     (list #:install-source? #f
           #:tests? #f
           #:phases %ci-broker-phases))
    (inputs
     (cons* sqlite openssl zlib
            (cargo-inputs 'radicle-ci-broker #:module '(rust-crates))))
    (native-inputs (list pkg-config))
    (home-page "https://radicle-ci.liw.fi/")
    (synopsis "Radicle CI broker (cib) — dispatch CI on node events")
    (description
     "The Radicle CI broker @command{cib} listens to a radicle-node's event
stream and, per its YAML configuration, launches a CI @dfn{adapter} for each
matching change (default branch update, patch created/updated).  It does not
run CI itself; it invokes an adapter (such as @code{radicle-native-ci}) that
performs the run and reports the result.")
    (license (list license:expat license:asl2.0))))

(define-public radicle-native-ci
  (package
    (name "radicle-native-ci")
    (version "0.14.0")
    (source (crate-source "radicle-native-ci" "0.14.0"
                          "1j6qwyriv1fqglg4iv370aykwk9583s3f2bhzyfgkqwa8cfwf7kd"))
    (build-system cargo-build-system)
    (arguments
     (list #:install-source? #f
           #:tests? #f
           #:phases %ci-phases))
    (inputs
     (cons* sqlite openssl zlib
            (cargo-inputs 'radicle-native-ci #:module '(rust-crates))))
    (native-inputs (list pkg-config))
    (home-page "https://radicle-ci.liw.fi/")
    (synopsis "Radicle native CI adapter — runs .radicle/native.yaml steps")
    (description
     "The native CI adapter for the Radicle CI broker.  It reads one JSON event
on stdin, runs the shell steps declared in the repository's
@file{.radicle/native.yaml}, publishes a report, and writes the outcome as JSON
on stdout.  For native CI the adapter is itself the CI engine.")
    (license (list license:expat license:asl2.0))))
