;;; playnet-hoot.scm — the Hoot the wasm toolchain runs.
;;;
;;; Hoot 0.9.0 as the pinned Guix commit ships it (deploy/channels.scm), plus
;;; the upstream fixes that landed on Hoot main after the 0.9.0 release
;;; (2026-05-13).  The set is the number->string fixes — Hoot's flonum printing
;;; dropped a digit (252.9998 printed as 252.998; Hoot issue #890), and the
;;; ±2^N case — and the corrected negate error.  Each patch is the upstream
;;; commit as `git format-patch` wrote it, under patches/hoot/; drop one when a
;;; Hoot release carries it.
;;;
;;; The wasm Hoot emits uses the standard WebAssembly exception encoding
;;; (try_table / exnref): Chrome 137, Firefox 131, Safari 18.4.  Node 22 needs
;;; --experimental-wasm-exnref to run it (tools/test/run-wasm.cjs adds it itself).

(define-module (playnet-hoot)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix utils)
  #:use-module (gnu packages guile-xyz))

(define-public guile-hoot/playnet
  (package
    (inherit guile-hoot)
    (name "guile-hoot-playnet")
    ;; The upstream suite runs in full except test/test-eval.scm.  That file
    ;; holds 20 cases, each of which recompiles Hoot's runtime-module
    ;; environment while it expands; one case takes 75-100 s of CPU with no
    ;; output (measured 2026-10-01, Hoot 0.9.0 and main), so the file alone
    ;; needs ~30 minutes and reads as a hang.  It covers Hoot's runtime
    ;; `eval`, which the wasm bundles built here do not use.  The number
    ;; printing tests (test-number-to-string, test-write) that cover the
    ;; patches below run.
    (arguments
     (substitute-keyword-arguments (package-arguments guile-hoot)
       ((#:phases phases)
        #~(modify-phases #$phases
            (replace 'check
              (lambda* (#:key tests? #:allow-other-keys)
                (when tests?
                  (let ((tests (filter
                                (lambda (f) (not (string-suffix? "test-eval.scm" f)))
                                (find-files "test" "^test-.*\\.scm$"))))
                    (invoke "make" "check" "GUILE_AUTO_COMPILE=0"
                            (string-append "TESTS=" (string-join tests " ")))))))))))
    (source
     (origin
       (inherit (package-source guile-hoot))
       (patches
        (list (local-file "patches/hoot/0001-Fix-bytevector-copy-in-flonum-utf8-algorithm.patch")
              (local-file "patches/hoot/0002-Attempt-to-fix-flonum-string-again.patch")
              (local-file "patches/hoot/0003-Fix-number-string-for-2-N-where-52-N-1023.patch")
              (local-file "patches/hoot/0004-Fix-the-negate-error-implementation.patch")))))))
