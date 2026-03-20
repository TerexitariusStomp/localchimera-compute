;;; play-repl.scm — quick single-org REPL for (metaorg play)
;;; Run with:  guile play-repl.scm
;;;        or: guile meta-org-repl.scm   (for the full two-tier REPL)

(add-to-load-path "module")
(use-modules (metaorg play)
             (metaorg org)
             (metaorg ai))

(define my-org
  (make-org "play"
            (append `((set-api-key!  . ,set-ai-api-key!)
                      (set-ai-model! . ,set-ai-model!))
                    default-base-bindings)))
(enter! my-org)
