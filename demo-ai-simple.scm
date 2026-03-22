#!/usr/bin/env guile
!#

;;; demo-ai-simple.scm — Simple working demo of AI agent

(add-to-load-path "module")

(use-modules (xorg ai)
             (xorg ai-agent)
             (xorg org)
             (xorg gplay)
             (goblins)
             (ice-9 rdelim))

;; Load .env
(when (file-exists? ".env")
  (call-with-input-file ".env"
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
            (loop)))))))

(set-ai-api-key! (getenv "OPENROUTER_API_KEY"))

(display "\n═══════════════════════════════════════════════════════════\n")
(display "           AI Agent Demo - Simple Usage\n")
(display "═══════════════════════════════════════════════════════════\n\n")

(display "Step 1: Create org\n")
(define my-org (make-org "ai-demo"))
(display "  ✓ Created org: ai-demo\n\n")

(display "Step 2: Create AI agent using convenience function\n")
(define-values (agent sealer)
  (make-org-ai-agent my-org
                     'ai-assistant
                     "ai-pub-key"
                     "You are a helpful AI assistant for this org."))
(display "  ✓ Created AI agent: ai-assistant\n\n")

(display "Step 3: View org history\n")
(display "  Note: AI agent is now an expressor!\n")
(with-vat (org-vat my-org)
  (let ((history ($ (org-ref my-org) 'history)))
    (for-each
     (lambda (entry)
       (format #t "    v~a [~a]: ~a\n"
               (car entry)
               (or ($ (org-ref my-org) 'expressor-name (cadr entry)) '?)
               (caddr entry)))
     (reverse history))))

(display "\n═══════════════════════════════════════════════════════════\n\n")
(display "✓ AI agent successfully created!\n\n")
(display "To use it interactively, start the REPL:\n\n")
(display "  make repl\n")
(display "  scheme@(guile-user)> (use-modules (xorg ai) (xorg ai-agent))\n")
(display "  scheme@(guile-user)> (define my-org (make-org \"test\"))\n")
(display "  scheme@(guile-user)> (define-values (agent seal)\n")
(display "                         (make-org-ai-agent my-org 'ai \"key\" \"Help users.\"))\n")
(display "  scheme@(guile-user)> (with-vat (org-vat my-org)\n")
(display "                         (ai-agent-query agent \"Hello!\"))\n\n")
(display "Note: AI agent 'ai-assistant' is now an expressor in the org.\n")
(display "      It can act, decide, validate, and auto-govern!\n\n")
