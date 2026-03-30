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
       ((#:phases phases '%standard-phases)
        #~(modify-phases #$phases
            (add-after 'unpack 'fix-mutable-bytevector
              (lambda _
                (substitute* "module/hoot/backend.scm"
                  (("\\(#\\('bytevector\\? #f \\(a\\)\\)")
                   (string-append
                    "(#('mutable-bytevector? #f (a)) `(,(local.get a) (ref.test ,(make-ref-type #f '$mutable-bytevector))))\n"
                    "          (#('bytevector? #f (a))")))))))))))
