;;; deploy/manifests/keri-lib-manifest.scm — everything the KERI + OpenVTC
;;; library needs, and nothing else.
;;;
;;; The library is module/playnet/keri (the First Person profile under keri/first-person/)
;;; (docs/planning/identity/keri-openvtc-library-split.md). This manifest is its whole
;;; dependency set, every package from Guix itself, so the standalone
;;; `playnet-keri` repository — which carries this file at this same path —
;;; runs its suites in a pure shell on any machine with Guix:
;;;
;;;   guix shell --pure -m deploy/manifests/keri-lib-manifest.scm -- \
;;;     guile --no-auto-compile -L module tests/keri/test-blake3.scm
;;;
;;; `make test-keri-lib` runs every shipped suite that way.

(use-modules (guix profiles)
             (gnu packages))

(packages->manifest
 (map specification->package
      '("guile"
         "guile-goblins"                  ; the credential store is an actor
         "guile-fibers"
         "guile-gcrypt"
         "guile-json"
         "guile-gnutls"                   ; (web client) over HTTPS toward KERIA
         "libsodium"                      ; Ed25519 seed → keypair, X25519
         "coreutils" "bash" "grep" "sed" "findutils"
         "libblake3"                      ; Blake3-256 for SAIDs
         "git")))                         ; tools/openvtc-parity-check.sh
