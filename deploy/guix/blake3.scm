;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/guix/blake3.scm — Guix package for the BLAKE3 C library
;;;
;;; KERI's SAIDs (Self-Addressing Identifiers, CESR code "E") are
;;; Blake3-256 digests. guile-gcrypt doesn't ship Blake3, so we package
;;; the upstream BLAKE3-team C library here and wrap it via Guile FFI
;;; in module/localchimera/keri/blake3.scm.
;;;
;;; Upstream: https://github.com/BLAKE3-team/BLAKE3
;;; Layout:   c/ subdirectory contains the CMake build for the C library.
;;;           CMake produces libblake3.so + headers (blake3.h).
;;;
;;; Bumping: replace VERSION + recompute the sha256 with `guix hash <tarball>`.

(define-module (blake3)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix build-system cmake)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:))

(define-public blake3
  (package
    (name "blake3")
    (version "1.8.4")
    (source (origin
              (method url-fetch)
              (uri (string-append
                    "https://github.com/BLAKE3-team/BLAKE3/archive/refs/tags/"
                    version ".tar.gz"))
              (file-name (string-append name "-" version ".tar.gz"))
              (sha256
               (base32
                "1gn9i8z0iwbpsg7xx5ahyggndfsk1r68vbz379rv4ph2brf5zvmm"))))
    (build-system cmake-build-system)
    (arguments
     (list
      ;; The CMake project lives in the c/ subdirectory; everything else
      ;; in the tarball is the Rust crate, docs, etc.
      #:configure-flags
      #~(list "-DBUILD_SHARED_LIBS=ON"
              "-DCMAKE_BUILD_TYPE=Release")
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'unpack 'chdir-to-c
            (lambda _
              (chdir "c"))))
      ;; Upstream's CMake doesn't ship a comprehensive ctest target.
      ;; Skip tests; correctness is verified by our Scheme test vectors.
      #:tests? #f))
    (home-page "https://github.com/BLAKE3-team/BLAKE3")
    (synopsis "BLAKE3 cryptographic hash function — C reference implementation")
    (description
     "BLAKE3 is a cryptographic hash function that is faster than MD5,
SHA-1, SHA-2, SHA-3, and BLAKE2.  This package builds the upstream
C reference implementation as a shared library (libblake3.so) plus
headers, suitable for FFI binding from other languages.  Used by
localchimera's KERI bridge to compute Self-Addressing Identifier digests.")
    (license license:cc0)))
