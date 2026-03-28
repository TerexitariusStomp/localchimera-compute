;;; deploy/guix/python-rns.scm — Guix package definition for Reticulum (rns)
;;;
;;; Makes Reticulum fully declarative — add to machines.scm packages
;;; and it survives every guix deploy. No pip, no manual steps.
;;;
;;; Usage in machines.scm:
;;;   (use-modules (python-rns))
;;;   ...
;;;   (packages (list ... python-rns ...))
;;;
;;; Or standalone:
;;;   guix package -L deploy/guix -i python-rns

(define-module (python-rns)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix build-system pyproject)
  #:use-module ((guix licenses) #:prefix license:)
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
             "https://files.pythonhosted.org/packages/"
             "ff/d6/4cce15da08cbdf63a9178d854154c48ad6032cf246a2c46a869e7507d26c/"
             "rns-" version "-py3-none-any.whl"))
       (sha256
        (base32 "0ixpkk27jfhlpkw9z0ac60x0bxyvjckq61l20pfq25adssmpb8dj"))))
    (build-system pyproject-build-system)
    (propagated-inputs
     (list python-cryptography python-pyserial))
    (arguments
     ;; No tests in the wheel; skip check phase
     (list #:tests? #f))
    (home-page "https://reticulum.network/")
    (synopsis "Cryptography-based networking for LoRa, packet radio, and mesh")
    (description
     "Reticulum is a networking stack for building local and wide-area
networks using any available transport.  It provides encrypted, self-
configuring mesh networking over LoRa radio, serial links, TCP, UDP,
I2P, and packet radio.  No source addresses, zero-trust encryption
by default, works at 5 bits/second.  Used as an OCapN netlayer for
Spritely Goblins actors.")
    (license license:expat)))
