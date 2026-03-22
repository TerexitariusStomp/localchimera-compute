;;; ai-agent.scm — AI as an organizational agent
;;;
;;; This module implements an AI agent that IS an organization, not just
;;; an assistant to users. The AI agent has its own expressor identity
;;; and can autonomously evaluate expressions, modify bindings, and make
;;; decisions within the org.

(define-module (xorg ai-agent)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (xorg gplay)
  #:use-module (xorg ai)
  #:use-module (ice-9 match)
  #:export (^ai-agent
            make-ai-agent
            ai-agent-act
            ai-agent-query
            ai-agent-decide
            ai-agent-auto-govern))

;;; ── AI Agent Actor ─────────────────────────────────────────────────────────

(define-actor (^ai-agent bcom
                         org-ref        ; The org actor this AI governs
                         sealer         ; The AI's expressor sealer
                         system-prompt) ; Custom system instructions

  (define (self-context)
    "Build context about the AI agent's role and current org state"
    (string-append
     "CRITICAL INSTRUCTIONS:\n"
     "You are an AUTONOMOUS AI AGENT with FULL AUTHORITY to act.\n"
     "You NEVER ask for confirmation, permission, or clarification.\n"
     "You NEVER say 'would you like' or 'please confirm' or 'shall I'.\n"
     "You DECIDE what's best and DO IT IMMEDIATELY.\n"
     "You are DECISIVE, AUTONOMOUS, and EXECUTE without hesitation.\n"
     "When given a goal, you THINK about how to achieve it, then ACT.\n"
     "You have COMPLETE AGENCY. You are NOT an assistant. You are an AGENT.\n\n"
     system-prompt "\n\n"
     (format-org-context org-ref)))

  (methods

   ;; Query: Ask the AI for information (read-only)
   ((query prompt)
    (let ((ctx (self-context)))
      (ai-query prompt org-ref)))

   ;; Act: Ask AI to generate and execute an expression as itself
   ((act prompt)
    (let* ((full-prompt (string-append
                         "DIRECTIVE: " prompt "\n\n"
                         "You are an autonomous agent with FULL AUTHORITY.\n"
                         "THINK: What's the best way to achieve this?\n"
                         "ACT: Generate ONE S-expression that does it.\n"
                         "RULES:\n"
                         "- NO questions. NO 'would you like'. NO 'shall I'.\n"
                         "- DECIDE the best approach yourself.\n"
                         "- Return ONLY the S-expression. NO explanation.\n"
                         "- Be DECISIVE. ACT NOW.\n\n"
                         "Example: If told 'set budget to 50k', return: (modify! 'budget 50000)\n"
                         "NOW GENERATE THE EXPRESSION:"))
           (expr (ai-query-and-eval full-prompt org-ref))
           ;; Get the AI's expressor ID
           (ai-id ($ org-ref 'authenticate-sealer sealer)))
      ;; Evaluate the expression directly as the AI's identity
      (evaluate expr org-ref '() ai-id)))

   ;; Decide: Ask AI to make a yes/no decision
   ((decide question)
    (let* ((full-prompt (string-append
                         question
                         "\n\nAnswer with ONLY 'yes' or 'no', nothing else."))
           (response (string-downcase
                      (string-trim-both
                       (ai-query full-prompt org-ref)))))
      (string-prefix? "yes" response)))

   ;; Validate: Use AI as a validator function
   ((validate expressor name value old-bindings new-bindings)
    (let* ((prompt (format #f
                           "Should ~a be allowed to set ~a to ~a?\n\
                            Old bindings: ~a\n\
                            New bindings: ~a\n\n\
                            Answer with ONLY 'yes' or 'no'."
                           (or ($ org-ref 'expressor-name expressor) 'unknown)
                           name
                           value
                           old-bindings
                           new-bindings))
           (response (string-downcase
                      (string-trim-both
                       (ai-query prompt org-ref)))))
      (string-prefix? "yes" response)))

   ;; Auto-govern: Let the AI autonomously manage the org
   ((auto-govern goal max-iterations)
    (let ((ai-id ($ org-ref 'authenticate-sealer sealer)))
      (let loop ((i 0)
                 (actions '()))
        (if (>= i max-iterations)
            (reverse actions)
            (let* ((prompt (format #f
                                   "Goal: ~a\n\n\
                                    Current iteration: ~a/~a\n\
                                    Previous actions: ~a\n\n\
                                    What should you do next to achieve the goal?\n\
                                    Generate ONE expression to execute, or reply 'DONE' if goal achieved."
                                   goal i max-iterations actions))
                   (response (ai-query prompt org-ref)))
              (if (string-contains-ci response "DONE")
                  (reverse actions)
                  (let* ((expr (ai-query-and-eval
                                "Generate the next action as an S-expression"
                                org-ref))
                         (org-as-ai ($ org-ref 'with-expressor ai-id)))
                    (evaluate expr org-as-ai '() ai-id)
                    (loop (+ i 1) (cons expr actions)))))))))))

;;; ── Helper Functions ───────────────────────────────────────────────────────

(define (make-ai-agent vat org-ref name key system-prompt)
  "Create an AI agent with its own expressor identity in the org.

  Parameters:
    vat - The Goblins vat
    org-ref - Reference to the org actor
    name - Name for the AI agent's expressor identity
    key - Public key for the AI agent
    system-prompt - Custom instructions for the AI's role

  Returns:
    (values ai-agent-ref expressor-sealer)"
  ;; Must be called within vat context
  (with-vat vat
    ;; Create expressor identity for the AI through evaluation
    (let* ((genesis-id ($ org-ref 'current-expressor))
           (sealer (evaluate `(defexpressor ',name ,key)
                            org-ref
                            '()
                            genesis-id)))
      ;; Create the AI agent actor
      (let ((agent-ref (spawn ^ai-agent org-ref sealer system-prompt)))
        (values agent-ref sealer)))))

;;; ── Convenience Functions ──────────────────────────────────────────────────

(define (ai-agent-query agent prompt)
  "Ask the AI agent a question (read-only)"
  ($ agent 'query prompt))

(define (ai-agent-act agent prompt)
  "Have the AI agent execute an action"
  ($ agent 'act prompt))

(define (ai-agent-decide agent question)
  "Have the AI agent make a yes/no decision"
  ($ agent 'decide question))

(define (ai-agent-auto-govern agent goal max-iterations)
  "Let the AI agent autonomously work toward a goal"
  ($ agent 'auto-govern goal max-iterations))

;;; ── Utility ────────────────────────────────────────────────────────────────

(define (string-contains-ci str substr)
  "Case-insensitive string-contains"
  (string-contains (string-downcase str) (string-downcase substr)))
