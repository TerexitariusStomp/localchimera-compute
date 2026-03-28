#!/usr/bin/env guile
!#

;;; demo-ai-agent.scm — AI as organizational expressor
;;;
;;; An AI agent is just an expressor with config bindings.
;;; No special actor, no external control loop —
;;; expressions all the way down.

(add-to-load-path "module")

(use-modules (xorg ai)
             (xorg org)
             (goblins)
             (ice-9 rdelim))

;;; Load .env
(define (load-env filepath)
  (when (file-exists? filepath)
    (call-with-input-file filepath
      (lambda (port)
        (let loop ()
          (let ((line (read-line port)))
            (unless (eof-object? line)
              (let ((trimmed (string-trim-both line)))
                (unless (or (string-null? trimmed) (string-prefix? "#" trimmed))
                  (let ((parts (string-split trimmed #\=)))
                    (when (= (length parts) 2)
                      (setenv (string-trim-both (car parts))
                              (string-trim-both (cadr parts)))))))
              (loop))))))))

(display "
╔════════════════════════════════════════════════════════════════╗
║          AI Expressor: The Organization IS Intelligence        ║
╚════════════════════════════════════════════════════════════════╝

An AI agent in xorg is just an expressor with config bindings.
Its system prompt lives in the org as a regular binding —
inspectable, governable, and modifiable by any authorized expressor.

There is no separate actor, no external control loop, no hardcoded
personality. The module provides mechanism, not direction.

")

(load-env ".env")
(set-ai-api-key! (getenv "OPENROUTER_API_KEY"))

(display "════════════════════════════════════════════════════════════════\n\n")

(display "Setup:\n\n")

(display "  ;; Create an AI expressor — returns the sealer (capability)\n")
(display "  (define ai-sealer\n")
(display "    (make-ai-agent vat org 'ai-gov \"key\"\n")
(display "      \"You govern this org wisely.\"))\n\n")

(display "  ;; Config is now visible in the org:\n")
(display "  ai-gov:prompt  ;=> \"You govern this org wisely.\"\n\n")

(display "════════════════════════════════════════════════════════════════\n\n")

(display "Usage — just (as sealer ...) + existing REPL forms:\n\n")

(display "  ;; Query: AI reads org state\n")
(display "  (as ai-sealer (ai \"What's the budget?\"))\n\n")

(display "  ;; Act: AI generates and executes an expression\n")
(display "  (as ai-sealer (ai-eval \"Create a proposal for funding\"))\n\n")

(display "  ;; Change the AI's behavior — subject to the validator\n")
(display "  (modify! 'ai-gov:prompt \"Be cautious and deliberate.\")\n\n")

(display "  ;; AI as validator — metacircular, no actor needed\n")
(display "  (enact! (lambda (e n v pre post)\n")
(display "            (string-prefix? \"yes\"\n")
(display "              (ai (string-append \"Should \" (symbol->string n)\n")
(display "                                 \" be changed? yes/no\")))))\n\n")

(display "════════════════════════════════════════════════════════════════\n\n")

(display "Example use cases:\n\n")

(display "  1. Autonomous DAO Governor\n")
(display "     (make-ai-agent vat org 'dao-gov \"key\"\n")
(display "       \"Approve proposals aligned with the mission.\")\n\n")

(display "  2. Resource Allocator\n")
(display "     (make-ai-agent vat org 'allocator \"key\"\n")
(display "       \"Distribute funds based on priority.\")\n\n")

(display "  3. Self-Evolving Org\n")
(display "     (make-ai-agent vat org 'evolver \"key\"\n")
(display "       \"Propose new validators and structures.\")\n\n")

(display "════════════════════════════════════════════════════════════════\n\n")

(display "Why this design:\n\n")
(display "  - Config is a binding → inspectable, governable, forkable\n")
(display "  - No hardcoded personality → direction is up to the expressors\n")
(display "  - No special actor → (as sealer (ai-eval ...)) is all you need\n")
(display "  - History shows everything → config changes, AI actions, all of it\n")
(display "  - AI sees its own prompt → self-reflective by construction\n\n")
