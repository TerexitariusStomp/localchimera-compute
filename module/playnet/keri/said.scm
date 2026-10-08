;;; said.scm — SAID derivation on a native Guile: said-portable + libblake3
;;;
;;; (playnet keri said-portable) is the derivation itself and compiles under
;;; Hoot/WASM, so it takes its blake3-256 by injection. This module is the
;;; native half: loading it installs the FFI blake3 from (playnet keri blake3).
;;; The install is lazy — the closure resolves the FFI module on the FIRST
;;; compute-said, so loading a credential module never dlopens libblake3.
;;; (The browser build installs its own backend in hoot/day-boot.scm.)

(define-module (playnet keri said)
  #:use-module (playnet keri said-portable)
  #:re-export (canonical-string said-sort-pairs compute-said install-said-blake3!))

;; A page's build carries this module too (the credential modules import it): there
;; the page installs its own backend, and nothing is installed here.
(cond-expand
 (guile
  (install-said-blake3!
   (let ((fn #f))
     (lambda (bv)
       (unless fn
         (set! fn (module-ref (resolve-interface '(playnet keri blake3))
                              'blake3-256)))
       (fn bv)))))
 (else))
