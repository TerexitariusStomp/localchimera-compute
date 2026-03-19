;;; play-repl.scm — quick single-org REPL for (xorg play)
;;; Run with:  guile play-repl.scm
;;;        or: guile xorg-repl.scm   (for the full two-tier REPL)

(add-to-load-path "module")
(use-modules (xorg org)
             (xorg ai))

(define my-org
  (make-org "play"
            (append `((set-api-key!  . ,set-ai-api-key!)
                      (set-ai-model! . ,set-ai-model!))
                    default-base-bindings)))
(enter! my-org)
