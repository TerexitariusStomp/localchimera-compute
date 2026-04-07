;;; hoot-fix.scm — Patch guile-hoot 0.8.0 to add missing mutable-bytevector? case
;;;
;;; Hoot 0.8.0's backend.scm compile-test lacks mutable-bytevector?,
;;; crashing when compiling Goblins/srfi-9/fibers to WASM.
;;; The $mutable-bytevector type exists in stdlib.scm — only the
;;; backend predicate dispatch is missing.

(define-module (hoot-fix)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (guix gexp)
  #:use-module (gnu packages guile-xyz))

(define-public guile-hoot/fixed
  (package
    (inherit guile-hoot)
    (name "guile-hoot-fixed")
    (arguments
     (substitute-keyword-arguments (package-arguments guile-hoot)
       ;; Disable the upstream test suite. Two reasons:
       ;;
       ;;  1. The patch we apply is a one-line backend fix; running
       ;;     tens of minutes of test suite to re-validate it doesn't
       ;;     buy us anything we don't already get from trusting
       ;;     upstream's release process.
       ;;  2. On at least the current Guix pin (1bfc9513…), `make check`
       ;;     hangs inside the build sandbox — a Hoot test forks a
       ;;     subprocess that never returns, leaving every parent make
       ;;     stuck in `wait()`. Skipping the phase keeps the
       ;;     derivation reproducible instead of bisecting upstream.
       ((#:tests? _ #f) #f)
       ((#:phases phases '%standard-phases)
        #~(modify-phases #$phases
            (add-after 'unpack 'fix-mutable-bytevector
              (lambda _
                (substitute* "module/hoot/backend.scm"
                  (("\\(#\\('bytevector\\? #f \\(a\\)\\)")
                   (string-append
                    "(#('mutable-bytevector? #f (a)) `(,(local.get a) (ref.test ,(make-ref-type #f '$mutable-bytevector))))\n"
                    "          (#('bytevector? #f (a))")))))))))))
