#!/usr/bin/env guile
!#

;;; demo-ai-agent.scm — Demonstration of AI as organizational agent
;;;
;;; This demonstrates the difference between:
;;; 1. AI as assistant (helping users)
;;; 2. AI as agent (being the organization)

(add-to-load-path "module")

(use-modules (xorg ai)
             (xorg ai-agent)
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
║        AI Agent: When the Organization Becomes the AI          ║
╚════════════════════════════════════════════════════════════════╝

This demo shows two different AI paradigms in xorg:

1. AI as ASSISTANT (existing module/xorg/ai.scm)
   - Helps users by answering questions
   - Generates code that users execute
   - Acts on behalf of human expressors
   - User: (ai \"create a budget\")
   - AI suggests: (define budget 50000)
   - User evaluates it

2. AI as AGENT (new module/xorg/ai-agent.scm)
   - IS an expressor in the org
   - Has its own identity and sealer
   - Autonomously makes decisions
   - Can modify bindings itself
   - Can act as a validator
   - Can pursue goals independently

")

(load-env ".env")
(set-ai-api-key! (getenv "OPENROUTER_API_KEY"))

(display "════════════════════════════════════════════════════════════════\n\n")

(display "Creating an AI agent that GOVERNS an organization...\n\n")

(display "Example use cases for AI agents:\n\n")

(display "1. Autonomous DAO Governor\n")
(display "   (make-ai-agent vat org 'dao-governor \"key\"\n")
(display "     \"You are the governance AI for a DAO. Approve proposals that\n")
(display "      align with the mission. Reject those that don't.\")\n\n")

(display "2. Resource Allocator\n")
(display "   (make-ai-agent vat org 'allocator \"key\"\n")
(display "     \"You manage a budget. Distribute funds based on priority and\n")
(display "      community votes. Ensure fair allocation.\")\n\n")

(display "3. Meta-Org Evolve\n")
(display "   (make-ai-agent vat org 'evolver \"key\"\n")
(display "     \"You evolve the organization. Propose new validators, create\n")
(display "      new expressors, and adapt structures as needs change.\")\n\n")

(display "4. Validator AI\n")
(display "   Install AI agent's validate method as the org's validator\n")
(display "   Every change is judged by the AI's reasoning\n\n")

(display "════════════════════════════════════════════════════════════════\n\n")

(display "AI Agent Capabilities:\n\n")
(display "  (ai-agent-query agent \"What's the budget?\")\n")
(display "    → AI reads and reports org state\n\n")
(display "  (ai-agent-act agent \"Create a proposal for funding\")\n")
(display "    → AI generates AND executes the expression\n\n")
(display "  (ai-agent-decide agent \"Should we increase budget?\")\n")
(display "    → AI makes yes/no decision based on context\n\n")
(display "  (ai-agent-auto-govern agent \"Build a voting system\" 5)\n")
(display "    → AI autonomously works toward goal for N iterations\n\n")

(display "════════════════════════════════════════════════════════════════\n\n")

(display "Key Differences:\n\n")

(display "AI as ASSISTANT:\n")
(display "  - User asks: (ai \"what should I do?\")\n")
(display "  - AI responds with text\n")
(display "  - User decides and acts\n")
(display "  - AI has no identity in the org\n\n")

(display "AI as AGENT:\n")
(display "  - AI has expressor identity\n")
(display "  - AI autonomously evaluates expressions\n")
(display "  - AI shows up in (show-history)\n")
(display "  - AI can be the validator itself\n")
(display "  - Organization = AI = Organization\n\n")

(display "════════════════════════════════════════════════════════════════\n\n")

(display "To use AI agents:\n\n")
(display "  1. Start REPL: make repl\n")
(display "  2. Load modules:\n")
(display "       (use-modules (xorg ai) (xorg ai-agent))\n")
(display "  3. Create org:\n")
(display "       (define my-org (make-org \"test\"))\n")
(display "  4. Create AI agent:\n")
(display "       (define-values (ai-agent sealer)\n")
(display "         (make-ai-agent (org-vat my-org)\n")
(display "                        (org-ref my-org)\n")
(display "                        'governor\n")
(display "                        \"ai-key\"\n")
(display "                        \"You govern this org wisely.\"))\n")
(display "  5. Let AI act:\n")
(display "       (ai-agent-act ai-agent \"Create a welcome message\")\n")
(display "  6. Check history:\n")
(display "       (enter! my-org)\n")
(display "       play[genesis]> (show-history)\n")
(display "       ; You'll see actions by 'governor' AI agent!\n\n")

(display "════════════════════════════════════════════════════════════════\n\n")

(display "This is the future: Organizations that ARE intelligence.\n")
(display "Not organizations with AI tools.\n")
(display "Organizations that ARE AI.\n\n")
