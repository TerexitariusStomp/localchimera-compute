;;; deploy/guix/python-rns.scm — Guix package definition for Reticulum (rns)
;;;
;;; Fully declarative — add to machines.scm packages and Reticulum
;;; survives every guix deploy. No pip, no manual steps.
;;;
;;; Usage in machines.scm:
;;;   (use-modules (python-rns))
;;;   (packages (list ... python-rns ...))
;;;
;;; Or standalone:
;;;   guix build -L deploy/guix python-rns
;;;   guix package -L deploy/guix -i python-rns

(define-module (python-rns)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix git-download)
  #:use-module (guix build-system pyproject)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages python-build)
  #:use-module (gnu packages python-crypto)
  #:use-module (gnu packages python-xyz))

(define-public python-rns
  (package
    (name "python-rns")
    (version "1.1.4")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/markqvist/Reticulum/archive/refs/tags/"
             version ".tar.gz"))
       (sha256
        (base32 "07v0ihinzwq6l7ch1qn1jx6gdkchhj1wrh3mcdnq91awsdq0z285"))))
    (build-system pyproject-build-system)
    (native-inputs
     (list python-setuptools python-wheel))
    (propagated-inputs
     (list python-cryptography python-pyserial))
    (arguments
     (list #:tests? #f
           #:phases
           #~(modify-phases %standard-phases
               ;; Reticulum tries to create ~/.reticulum on import
               (delete 'sanity-check))))
    (home-page "https://reticulum.network/")
    (synopsis "Cryptography-based networking for LoRa, packet radio, and mesh")
    (description
     "Reticulum is a networking stack for building local and wide-area
networks using any available transport.  It provides encrypted, self-
configuring mesh networking over LoRa radio, serial links, TCP, UDP,
I2P, and packet radio.  Used as an OCapN netlayer for Spritely Goblins.")
    (license license:expat)))
