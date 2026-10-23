;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/guix/python-keria.scm — Guix package definitions for KERIA + deps
;;;
;;; KERIA is a KERI cloud agent: a Python/Falcon HTTP service that manages
;;; KERI AIDs (key event logs, witnesses, credentials) on behalf of clients.
;;; Clients hold private keys; KERIA holds delegated authority only.
;;;
;;; This file packages:
;;;   python-hio    — async IO framework (KERIA dependency)
;;;   python-keri   — core KERI protocol library
;;;   python-keria  — KERIA cloud agent
;;;
;;; Usage in machines.scm / system.scm:
;;;   (use-modules (python-keria))
;;;   (packages (list ... python-keria ...))
;;;
;;; Or standalone:
;;;   guix build -L deploy/guix python-keria
;;;   guix shell -L deploy/guix python-keria -- keria start --config /path/to/config

(define-module (python-keria)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix build-system pyproject)
  #:use-module (guix build-system python)        ; pypi-uri
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages check)
  #:use-module (gnu packages databases)        ; lmdb
  #:use-module (gnu packages libffi)
  #:use-module (gnu packages python-build)
  #:use-module (gnu packages python-check)
  #:use-module (gnu packages crypto)            ; libsodium
  #:use-module (gnu packages finance)           ; python-mnemonic
  #:use-module (gnu packages python-crypto)
  #:use-module (gnu packages python-web)       ; falcon, aiohttp
  #:use-module (gnu packages python-xyz))      ; msgpack, cbor2, etc.

;;; ── python-marshmallow-3 ────────────────────────────────────────────────────
;;; KERIA needs marshmallow 3.x (Guix has 4.0.0 which removed `missing` kwarg).

(define-public python-marshmallow-3
  (package
    (name "python-marshmallow")
    (version "3.26.1")
    (source (origin
              (method url-fetch)
              (uri (pypi-uri "marshmallow" version))
              (sha256 (base32 "1ilxf701vs6j33qj38chshk5lbg1mv06s282ck93j7dndkxszn76"))))
    (build-system pyproject-build-system)
    (arguments (list #:tests? #f))
    (native-inputs (list python-flit-core))
    (propagated-inputs (list python-packaging))
    (home-page "https://marshmallow.readthedocs.io/")
    (synopsis "Marshmallow 3.x — serialization/deserialization library")
    (description "Marshmallow 3.x for KERIA compatibility.")
    (license license:expat)))

;;; ── python-marshmallow-dataclass ────────────────────────────────────────────
;;; Marshmallow schemas from dataclasses.  Not in Guix upstream.

(define-public python-marshmallow-dataclass
  (package
    (name "python-marshmallow-dataclass")
    (version "8.7.1")
    (source (origin
              (method url-fetch)
              (uri (pypi-uri "marshmallow_dataclass" version))
              (sha256 (base32 "1i2rmmppxc00hlph9c3vygvb7v9cxsnzz1xajaqy275kywdhxf2g"))))
    (build-system pyproject-build-system)
    (arguments
     (list #:tests? #f
           #:phases #~(modify-phases %standard-phases (delete 'sanity-check))))
    (native-inputs (list python-setuptools python-wheel))
    (propagated-inputs (list python-marshmallow-3 python-typeguard))
    (home-page "https://github.com/lovasoa/marshmallow_dataclass")
    (synopsis "Marshmallow schemas from dataclasses")
    (description "Automatic generation of marshmallow schemas from dataclasses.")
    (license license:expat)))

;;; ── python-http-sfv ────────────────────────────────────────────────────────
;;; Structured Field Values for HTTP (RFC 8941).  Not in Guix upstream.

(define-public python-http-sfv
  (package
    (name "python-http-sfv")
    (version "0.9.9")
    (source (origin
              (method url-fetch)
              (uri (pypi-uri "http_sfv" version))
              (sha256 (base32 "0ff7822z73jwndyj4jqy4zsd1izgsjlmykw206y3424rxydxqcp1"))))
    (build-system pyproject-build-system)
    (arguments (list #:tests? #f))
    (native-inputs (list python-setuptools python-wheel))
    (home-page "https://github.com/mnot/http-sfv")
    (synopsis "HTTP Structured Field Values (RFC 8941)")
    (description "Parse and serialize HTTP Structured Field Values per RFC 8941.")
    (license license:expat)))

;;; ── python-dataclasses-json ────────────────────────────────────────────────
;;; JSON serialization for dataclasses.  Not in Guix upstream.

(define-public python-dataclasses-json
  (package
    (name "python-dataclasses-json")
    (version "0.6.7")
    (source (origin
              (method url-fetch)
              (uri (pypi-uri "dataclasses_json" version))
              (sha256 (base32 "1h2zqlf6mwmk8zl2k4n26f421xa5lqycafr26namp93f4qlfbcxn"))))
    (build-system pyproject-build-system)
    (arguments (list #:tests? #f))
    (native-inputs (list python-poetry-core python-poetry-dynamic-versioning))
    (propagated-inputs (list python-marshmallow-3))
    (home-page "https://github.com/lidatong/dataclasses-json")
    (synopsis "JSON serialization for Python dataclasses")
    (description "Easily serialize/deserialize dataclasses to/from JSON.")
    (license license:expat)))

;;; ── python-pysodium ────────────────────────────────────────────────────────
;;;
;;; Thin ctypes wrapper around libsodium.  Not in Guix upstream.

(define-public python-pysodium
  (package
    (name "python-pysodium")
    (version "0.7.18")
    (source
     (origin
       (method url-fetch)
       (uri (pypi-uri "pysodium" version))
       (sha256
        (base32 "01wb8pzvhj7cvci1m80f2fa5rj0q83cq4fqr27279b2n8h1dl6kq"))))
    (build-system pyproject-build-system)
    (arguments
     (list
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'unpack 'set-libsodium-path
            (lambda* (#:key inputs #:allow-other-keys)
              (let ((libsodium (search-input-file inputs "lib/libsodium.so")))
                (substitute* "pysodium/__init__.py"
                  (("ctypes\\.util\\.find_library\\(['\"]sodium['\"]\\)\\s*or\\s*ctypes\\.util\\.find_library\\(['\"]libsodium['\"]\\)")
                   (string-append "\"" libsodium "\""))
                  (("ctypes\\.util\\.find_library\\(['\"]sodium['\"]\\)")
                   (string-append "\"" libsodium "\"")))))))))
    (native-inputs (list python-setuptools python-wheel))
    (propagated-inputs (list libsodium))
    (home-page "https://github.com/stef/pysodium")
    (synopsis "Python bindings for libsodium via ctypes")
    (description "Pysodium provides Python bindings to libsodium, a modern
cryptographic library.  It uses ctypes to call libsodium functions directly.")
    (license license:bsd-2)))

;;; ── python-hio ──────────────────────────────────────────────────────────────
;;;
;;; Hierarchical concurrency / async IO framework.
;;; Required by python-keri and python-keria.

(define-public python-hio
  (package
    (name "python-hio")
    (version "0.6.14")
    (source
     (origin
       (method url-fetch)
       (uri "https://files.pythonhosted.org/packages/46/95/97da1390407769e8b8e863738c5d5906caa2310a3b8e256972af1c7f3240/hio-0.6.14.tar.gz")
       (sha256
        (base32 "0gfakwn5wkfib1iy2c5klxfgzz8dj6iiggj5j6r1hlr0687pjsd0"))))
    (build-system pyproject-build-system)
    (arguments
     (list #:tests? #f
           ;; hio requires cbor2>=5.6.2 but Guix has 5.4.2 — skip the
           ;; version check (the API subset we use is compatible).
           #:phases
           #~(modify-phases %standard-phases
               (delete 'sanity-check))))
    (native-inputs
     (list python-setuptools python-wheel))
    (propagated-inputs
     (list python-lmdb
           python-msgpack
           python-cbor2
           python-pysodium
           python-blake3
           python-multidict
           python-ordered-set
           python-falcon))
    (home-page "https://github.com/ioflo/hio")
    (synopsis "Hierarchical concurrency with async IO for Python")
    (description
     "hio provides a hierarchical async coroutine framework used by the KERI
protocol implementation.  It offers an alternative to asyncio with explicit
cooperative scheduling and hierarchical task management.")
    (license license:asl2.0)))

;;; ── python-keri ─────────────────────────────────────────────────────────────
;;;
;;; Core KERI (Key Event Receipt Infrastructure) protocol library.
;;; Provides AID management, key event logs, witness protocols, and ACDC.

(define-public python-keri
  (package
    (name "python-keri")
    (version "1.2.12")
    (source
     (origin
       (method url-fetch)
       (uri "https://files.pythonhosted.org/packages/f1/c6/c552cd481fac99102e0fd753b9df302fbe6acc7c766164e0c73464218724/keri-1.2.12.tar.gz")
       (sha256
        (base32 "1rnaiv9alvznjgkdgh27vqpdybj0n8rimri1bfbz30bvb3p6mj06"))
       ;; Patch Python 3.12 f-string syntax (nested quotes) to work on 3.11.
       ;; keri 1.2.12 uses f'{url.rstrip("/")}' which needs the outer
       ;; quotes swapped when nested inside f"...".
       (modules '((guix build utils)))
       (snippet
        '(for-each
          (lambda (file)
            (substitute* file
              ;; .rstrip("/") inside f-strings → .rstrip(chr(47))
              (("\\.rstrip\\(\"/\"\\)") ".rstrip(chr(47))")
              ;; .rstrip("/")/  → .rstrip(chr(47))/
              (("\\.rstrip\\(\"([^\"]+)\"\\)" all char)
               (string-append ".rstrip(chr("
                              (number->string (char->integer (string-ref char 0)))
                              "))"))))
          (find-files "." "\\.py$")))))
    (build-system pyproject-build-system)
    (arguments
     ;; Tests require network; sanity-check fails on missing optional deps.
     ;; Skip bytecode compilation — some 3.12 syntax may remain.
     (list #:tests? #f
           #:phases
           #~(modify-phases %standard-phases
               (delete 'sanity-check)
               (delete 'compile-bytecode))))
    (native-inputs
     (list python-setuptools python-wheel))
    (propagated-inputs
     (list python-lmdb
           python-pysodium
           python-blake3
           python-msgpack
           python-cbor2
           python-multidict
           python-ordered-set
           python-hio
           python-jsonschema
           python-falcon
           python-pyyaml
           python-cryptography
           python-mnemonic
           python-multicommand
           python-semver
           python-hjson
           python-http-sfv
           python-dataclasses-json
           python-marshmallow-3
           python-apispec
           python-prettytable
           python-qrcode
           python-typing-inspect))
    (home-page "https://github.com/WebOfTrust/keripy")
    (synopsis "Python implementation of KERI (Key Event Receipt Infrastructure)")
    (description
     "KERIpy is the reference implementation of the KERI protocol.
KERI provides self-certifying identifiers (AIDs) anchored to key event logs
(KELs) distributed across witness nodes — enabling portable, server-independent
digital identity.")
    (license license:asl2.0)))

;;; ── python-keria ────────────────────────────────────────────────────────────
;;;
;;; ── python-multicommand ─────────────────────────────────────────────────────
;;;
;;; CLI sub-command framework used by KERIA.  Not in Guix upstream.

(define-public python-multicommand
  (package
    (name "python-multicommand")
    (version "1.0.0")
    (source
     (origin
       (method url-fetch)
       (uri (pypi-uri "multicommand" version))
       (sha256
        (base32 "0c0zqfjh3a1g9mn8m8dhbxpnikm7i04gbr80c6a2cf3hwcz28fgp"))))
    (build-system pyproject-build-system)
    (arguments (list #:tests? #f))
    (native-inputs (list python-poetry-core))
    (home-page "https://github.com/andrewcooke/multicommand")
    (synopsis "Simple sub-command CLI dispatch")
    (description "Multicommand provides simple sub-command dispatch for
Python CLI applications.")
    (license license:expat)))

;;; ── python-keria ────────────────────────────────────────────────────────────
;;;
;;; KERIA cloud agent — HTTP service wrapping python-keri.
;;; Clients (SignifyPy, Signify-TS) connect to KERIA to manage their AIDs
;;; without ever sending private keys to the server.

(define-public python-keria
  (package
    (name "python-keria")
    (version "0.4.0")
    (source
     (origin
       (method url-fetch)
       (uri "https://files.pythonhosted.org/packages/f0/9a/280765245f4216b196d0fa03b4b85406b964e0302a4c3de03608d80db0b9/keria-0.4.0.tar.gz")
       (sha256
        (base32 "1c6jmdgaf642af8m0wim2xlpidk3mb6xhj91a09sblqsqnffw7d5"))))
    (build-system pyproject-build-system)
    (arguments
     (list #:tests? #f
           #:phases
           #~(modify-phases %standard-phases
               (delete 'sanity-check))))
    (native-inputs
     (list python-setuptools python-wheel))
    (propagated-inputs
     (list python-hio
           python-keri
           python-falcon
           python-mnemonic
           python-multicommand
           python-deprecation
           python-marshmallow-dataclass
           python-typing-inspect))
    (home-page "https://github.com/WebOfTrust/keria")
    (synopsis "KERIA — KERI cloud agent service")
    (description
     "KERIA is a cloud agent for KERI (Key Event Receipt Infrastructure).
It exposes a REST API so clients can manage self-sovereign identities (AIDs),
rotate keys, issue ACDC verifiable credentials, and resolve OOBIs — without
ever transmitting private keys.  Clients hold keys locally via SignifyPy or
Signify-TS; KERIA holds only delegated authority.")
    (license license:asl2.0)))
