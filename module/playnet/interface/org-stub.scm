;;; module/playnet/interface/org-stub.scm — minimal ^org placeholder
;;;
;;; The /eval and /define commands in command-dispatch want an actor with
;;; 'evaluate and 'modify! methods. There is no real ^org actor in the
;;; codebase yet — surfaces that don't need code-execution semantics use
;;; this stub so dispatch doesn't crash. The dispatch wraps handler calls
;;; in catch #t, so the errors thrown here surface to the user as a clean
;;; "command unavailable" response.

(define-module (playnet interface org-stub)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (^org-stub))

(define (^org-stub _bcom)
  (methods
    ((evaluate _expr)
     (error "/eval is disabled on this surface (no ^org wired)"))
    ((modify! _name _value . _audit)
     (error "/define is disabled on this surface (no ^org wired)"))))
