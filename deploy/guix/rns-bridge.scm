;;; deploy/guix/rns-bridge.scm — Guix package for rns-bridge (Rust Reticulum bridge)
;;;
;;; Single binary that embeds an RNS node and bridges Goblins OCapN to
;;; the Reticulum mesh network.  Replaces the Python reticulum-bridge.py.
;;;
;;; Dependencies are managed via `guix import crate --lockfile` and
;;; stored in rust-crates.scm.  Fully reproducible — no vendoring, no
;;; internet access at build time.
;;;
;;; To update deps after editing Cargo.toml (in the satellite, ../playnet-rns-bridge):
;;;   cd ../playnet-rns-bridge && cargo update && cargo audit && git commit
;;;   guix import -i deploy/guix/rust-crates.scm crate -f ../playnet-rns-bridge/Cargo.lock rns-bridge
;;;   make bump SAT=rns-bridge
;;;   (--insert preserves bzip2-sys snippet and define-cargo-inputs mapping)
;;;
;;; Usage in machines.scm:
;;;   (use-modules (rns-bridge))
;;;   ;; then reference rns-bridge package or reticulum-bridge-service-type

(define-module (rns-bridge)
  #:use-module (guix packages)
  #:use-module (guix build-system cargo)
  #:use-module (guix gexp)
  #:use-module (satellite-source)
  #:use-module ((guix licenses) #:prefix license:))

;; The crate is the rns-bridge satellite (deploy/satellites.scm): its source
;; is the tree `satellite-pins.scm place` put at server/rns-bridge in this
;; checkout, hash-verified there and stamped with the pinned commit;
;; satellite-source refuses any other stamp (see satellite-source.scm for
;; why the daemon cannot fetch the pin itself).
(define-public rns-bridge
  (package
    (name "rns-bridge")
    (version "0.1.0")
    (source (satellite-source "rns-bridge"))
    (build-system cargo-build-system)
    (arguments (list #:install-source? #f))
    (inputs (cargo-inputs 'rns-bridge #:module '(rust-crates)))
    (home-page "https://app.radicle.xyz/nodes/seed.radicle.garden/rad:z27dFkN28LQAsSsG3DVHcfBqYAArQ")
    (synopsis "Rust bridge between Goblins OCapN and Reticulum mesh network")
    (description
     "A single-binary Reticulum bridge that replaces the Python rnsd daemon
and reticulum-bridge.py script.  Embeds an RNS node (via rns-net) and
speaks the same Unix socket protocol as the Python bridge, so the Guile
OCapN netlayer works unchanged.  Built on lelloman/rns-rs.")
    (license license:expat)))
