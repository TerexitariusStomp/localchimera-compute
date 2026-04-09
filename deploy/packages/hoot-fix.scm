;;; hoot-fix.scm — Patches for guile-hoot 0.8.0
;;;
;;; Two upstream bugs we work around:
;;;
;;; 1. backend.scm's compile-test lacks the `mutable-bytevector?` case,
;;;    crashing when compiling Goblins/srfi-9/fibers to WASM. The
;;;    $mutable-bytevector type exists in stdlib.scm — only the
;;;    backend predicate dispatch is missing.
;;;
;;; 2. lib/ice-9/exceptions.scm re-exports `make-quit-exception` and
;;;    `quit-exception?`, but `(hoot exceptions)` (the upstream this
;;;    pulls from) does not actually define them. Compile-time skips
;;;    the check; the runtime module loader (the -g1/-g2 path used by
;;;    live-hacking) hits the missing binding the moment any module
;;;    `#:use-module`s `(ice-9 exceptions)`. Goblins triggers this
;;;    immediately via `goblins/core-types.scm:23`. We comment out the
;;;    two broken re-exports the same way `&quit-exception` is already
;;;    commented out in the same file. The bindings weren't usable
;;;    anyway — removing the lie just lets the runtime loader proceed.

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
                    "          (#('bytevector? #f (a))")))))
            (add-after 'unpack 'fix-ice-9-exceptions-quit-exception
              (lambda _
                ;; Comment out the two re-exports of bindings that
                ;; (hoot exceptions) doesn't actually define. Mirrors
                ;; how `&quit-exception` is already commented out in
                ;; the same file. Without this, any wasm built with
                ;; -g1/-g2 (runtime module system) crashes the first
                ;; time something imports (ice-9 exceptions) — which
                ;; happens immediately via goblins/core-types.scm.
                ;; substitute* matches each pattern against the WHOLE
                ;; file as one string, and Guile regex `^`/`$` are
                ;; string anchors not line anchors. Anchor on \n
                ;; instead so we hit just the bare re-export lines.
                (substitute* "lib/ice-9/exceptions.scm"
                  (("               make-quit-exception\n")
                   "               ;; make-quit-exception\n")
                  (("               quit-exception\\?\n")
                   "               ;; quit-exception?\n"))))))))))
