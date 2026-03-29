#!/usr/bin/env guile
!#

;;; demo-ai-simple.scm — Simple working demo of AI expressor

(add-to-load-path "module")

(use-modules (playnet ai)
             (playnet org)
             (playnet gplay)
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
(display "           AI Expressor Demo - Simple Usage\n")
(display "═══════════════════════════════════════════════════════════\n\n")

(display "Step 1: Create org\n")
(define my-org (make-org "ai-demo"))
(display "  ✓ Created org: ai-demo\n\n")

(display "Step 2: Create AI expressor\n")
(define ai-sealer
  (make-org-ai-agent my-org
                     'ai-assistant
                     "ai-pub-key"
                     "You are a helpful AI assistant for this org."))
(display "  ✓ Created AI expressor: ai-assistant\n\n")

(display "Step 3: View org history\n")
(display "  Note: Config bindings are visible in history!\n")
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
(display "✓ AI expressor created!\n\n")
(display "To use it interactively:\n\n")
(display "  make repl\n")
(display "  scheme@(guile-user)> (use-modules (playnet ai) (playnet org))\n")
(display "  scheme@(guile-user)> (define my-org (make-org \"test\"))\n")
(display "  scheme@(guile-user)> (define ai-seal\n")
(display "                         (make-org-ai-agent my-org 'ai \"key\" \"Help users.\"))\n")
(display "  scheme@(guile-user)> (enter! my-org)\n")
(display "  play[genesis]> (as ai-seal (ai \"Hello!\"))\n")
(display "  play[genesis]> (as ai-seal (ai-eval \"Create a greeting\"))\n")
(display "  play[genesis]> (modify! 'ai:prompt \"Be very concise.\")  ;; matches expressor name 'ai\n\n")
