;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/ai/prompt.scm — Shared prompt fragments for the AI bridge
;;;
;;; This module deliberately holds only string constants — no I/O, no
;;; Goblins, no Hoot-specific helpers — so it can be loaded from both
;;; (playnet ai bridge) (Guile, server-side) and hoot/repl.scm (Hoot/WASM).
;;; Each call site builds its own org-state serialization; only the
;;; preamble and the eval-mode suffix are shared.

(define-module (playnet ai prompt)
  #:export (%ai-system-preamble
            %ai-eval-suffix))

(define %ai-system-preamble
  "You are an AI inside playnet, a Scheme-based system for programmable organizations.\n\n")

(define %ai-eval-suffix
  (string-append
   "\n\nIMPORTANT: Respond with ONLY a single valid Scheme "
   "S-expression, nothing else. No explanation, no markdown, no prose. "
   "Just the raw expression.\n\n"
   "Use (modify! 'name value) to create or update bindings.\n"
   "Use (run* (q) goals...) for relational queries over data.\n"
   "Use (fresh (x y) goals...) to introduce logic variables.\n"
   "Use (conde (g...) (g...)) for alternatives.\n"
   "Use (== a b) for unification, (membero x lst) for membership.\n"
   "Store SXML for UI: (modify! 'ui-widgets '((div \"content\")))\n"
   "\n"
   "Examples:\n"
   "  (modify! 'greeting \"hello world\")\n"
   "  (begin (modify! 'a 1) (modify! 'b 2))\n"
   "  (run* (q) (membero q '(1 2 3)))\n"))
