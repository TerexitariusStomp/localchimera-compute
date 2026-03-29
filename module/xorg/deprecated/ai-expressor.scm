;;; module/playnet/ai-expressor.scm — AI as its own expressor with scoped authority
;;;
;;; The AI expressor:
;;; - has its own sealer (not shared with any human expressor)
;;; - has its own keypair (history entries signed with this key)
;;; - has access to: ai, ai-eval, display, write (via org output-cap)
;;; - has access to anything in extra-bindings
;;; - does NOT have access to: governance seals, infra seals, other capabilities
;;;
;;; The AI's authority is exactly what extra-bindings provides.
;;; (ai-eval-as ai-seal prompt) runs the AI's expression under the AI
;;; expressor's authority, not the caller's.

(define-module (playnet ai-expressor)
  #:use-module (goblins)
  #:use-module ((goblins utils crypto) #:select (generate-key-pair key-pair->public-key))
  #:use-module (playnet gplay)
  #:use-module (playnet org)
  #:use-module (playnet ai)
  #:export (make-ai-expressor!
            ai-expressor-seal
            ai-expressor-public-key))

;;; ── AI expressor factory ────────────────────────────────────────────────────

(define* (make-ai-expressor! org
                             #:key
                             (http-client #f)
                             (model #f)
                             (name 'ai-agent)
                             (keypair (generate-key-pair))
                             (extra-bindings '()))
  "Create an AI expressor inside ORG with its own sealer and keypair.

   The AI expressor:
   - has its own sealer (not shared with any human expressor)
   - has its own keypair (history entries signed with this key)
   - does NOT have access to: governance seals, infra seals, other capabilities

   Returns (values ai-seal ai-public-key)

   The ai-seal can be used to act as the AI: (as ai-seal expr)
   The ai-public-key can be used to verify the AI's history entries.

   IMPORTANT: the AI's (ai-eval-as ai-seal prompt) calls evaluate
   expressions as the AI expressor — not the calling expressor.
   The AI's authority is exactly what extra-bindings provides.

   If http-client and model are provided, installs an AI capability
   for the (ai ...) and (ai-eval ...) forms."
  (with-vat (org-vat org)
    (let* ((ref (org-ref org))
           (gen ($ ref 'current-expressor))
           ;; Create the AI expressor with its keypair via defexpressor
           (ai-seal (evaluate `(defexpressor ',name kp)
                              ref
                              `((kp . ,keypair))
                              gen))
           (ai-public-key (key-pair->public-key keypair)))
      ;; Store extra bindings in the org (as the AI expressor)
      (for-each (lambda (pair)
                  (evaluate `(as seal (modify! ',(car pair) val))
                            ref
                            `((seal . ,ai-seal) (val . ,(cdr pair)))
                            gen))
                extra-bindings)
      ;; Install AI capability if http-client and model provided
      (when (and http-client model)
        (let ((ai-cap (make-ai-capability (org-vat org) http-client model)))
          (install-ai-capability! ai-cap)))
      (values ai-seal ai-public-key))))

;;; ── Accessors (for when callers hold the seal/key pair) ─────────────────────
;;; These are identity functions — provided for API clarity when the caller
;;; stores the seal and key in a record or passes them around.

(define (ai-expressor-seal seal)
  "Identity accessor — returns the AI expressor's seal."
  seal)

(define (ai-expressor-public-key pk)
  "Identity accessor — returns the AI expressor's public key."
  pk)
