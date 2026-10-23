;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/keri/blake3.scm — Blake3-256 via FFI to libblake3.so
;;;
;;; KERI's SAIDs (Self-Addressing Identifiers, CESR code "E") are
;;; Blake3-256 digests. guile-gcrypt doesn't ship Blake3 so we wrap
;;; the upstream BLAKE3 C library, packaged in deploy/guix/blake3.scm.
;;;
;;; The library MUST be on LD_LIBRARY_PATH or the loader's default
;;; search path. The dev/integration manifests
;;; (deploy/manifests/{dev,keri}-test-manifest.scm) include the
;;; `blake3' package; running tests via `make test-keri` /
;;; `make test-keri-integration` arranges this automatically.
;;;
;;; If you `guile' this module from a shell that lacks libblake3.so,
;;; the load-foreign-library call below raises with a clear message —
;;; that's the signal to enter the right `guix shell'.

(define-module (playnet keri blake3)
  #:use-module (system foreign)
  #:use-module (system foreign-library)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 format)
  #:export (blake3-256
            blake3-256-string
            blake3-256-hex
            blake3-version))

;;; ── Library handle ───────────────────────────────────────────────────────────

(define (%search-paths)
  ;; Guix's `guix shell` doesn't set LD_LIBRARY_PATH by default, but it
  ;; does set GUIX_ENVIRONMENT to the active profile. Append that
  ;; profile's lib dir so dlopen finds libblake3.so without forcing the
  ;; user to manage LD_LIBRARY_PATH manually. Also fall back to the
  ;; user profile (~/.guix-profile/lib) for `guix install`-installed libs.
  (filter (lambda (p) (and p (file-exists? p)))
          (list (and=> (getenv "GUIX_ENVIRONMENT")
                       (lambda (env) (string-append env "/lib")))
                (and=> (getenv "HOME")
                       (lambda (h) (string-append h "/.guix-profile/lib"))))))

(define %libblake3
  ;; load-foreign-library searches #:search-path + the loader's defaults.
  ;; Don't pass an absolute store path — it would freeze a /gnu/store
  ;; hash into source, breaking on rebuild.
  (load-foreign-library "libblake3"
                        #:search-path (%search-paths)))

;;; ── struct size ──────────────────────────────────────────────────────────────
;;;
;;; sizeof(blake3_hasher) on x86_64. Computed from blake3.h:
;;;   uint32_t key[8]                  =   32
;;;   blake3_chunk_state chunk         =  112  (cv 32 + counter 8 + buf 64
;;;                                              + 3×u8 + 5 padding)
;;;   uint8_t cv_stack_len             =    1
;;;   uint8_t cv_stack[55 × 32]        = 1760
;;;   trailing alignment padding       =    7
;;;                                     ─────
;;;                                     1912

(define %hasher-size 1912)

;;; ── FFI bindings ─────────────────────────────────────────────────────────────

(define %blake3-version
  (foreign-library-function %libblake3 "blake3_version"
                            #:return-type '*
                            #:arg-types '()))

(define %blake3-init
  (foreign-library-function %libblake3 "blake3_hasher_init"
                            #:return-type void
                            #:arg-types '(*)))

(define %blake3-update
  (foreign-library-function %libblake3 "blake3_hasher_update"
                            #:return-type void
                            #:arg-types (list '* '* size_t)))

(define %blake3-finalize
  (foreign-library-function %libblake3 "blake3_hasher_finalize"
                            #:return-type void
                            #:arg-types (list '* '* size_t)))

;;; ── Public API ───────────────────────────────────────────────────────────────

(define (blake3-version)
  "Return the upstream BLAKE3 library version string."
  (pointer->string (%blake3-version)))

(define (blake3-256 bv)
  "Compute the 32-byte Blake3-256 digest of bytevector BV."
  (unless (bytevector? bv)
    (error "blake3-256: expected bytevector" bv))
  (let* ((hasher    (make-bytevector %hasher-size 0))
         (hasher-p  (bytevector->pointer hasher))
         (input-len (bytevector-length bv))
         (out       (make-bytevector 32 0)))
    (%blake3-init hasher-p)
    (when (> input-len 0)
      (%blake3-update hasher-p (bytevector->pointer bv) input-len))
    (%blake3-finalize hasher-p (bytevector->pointer out) 32)
    out))

(define (blake3-256-string str)
  "Convenience: Blake3-256 of STR's UTF-8 bytes."
  (blake3-256 (string->utf8 str)))

(define (blake3-256-hex bv)
  "Compute Blake3-256 of BV and return the digest as a lowercase hex string."
  (let* ((digest (blake3-256 bv))
         (parts  (map (lambda (i)
                        (format #f "~2,'0x" (bytevector-u8-ref digest i)))
                      (iota 32))))
    (apply string-append parts)))
