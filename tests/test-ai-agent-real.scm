#!/usr/bin/env guile
!#

;;; test-ai-agent-real.scm — Test AI expressor functionality
;;;
;;; An AI agent is just an expressor with config bindings.
;;; This creates one and verifies it can act within an org.

(define %project-root (string-append (dirname (current-filename)) "/.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (xorg ai)
             (xorg org)
             (xorg gplay)
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

(display "\n╔═══════════════════════════════════════════════════════════════╗\n")
(display "║        AI Expressor Test - Organizations as Intelligence      ║\n")
(display "╚═══════════════════════════════════════════════════════════════╝\n\n")

(load-env (string-append %project-root "/.env"))
(set-ai-api-key! (getenv "OPENROUTER_API_KEY"))

(display "1. Creating organization...\n")
(define my-org (make-org "ai-governed"))
(display "   ✓ Org created: ai-governed\n\n")

(display "2. Creating AI expressor with config bindings...\n")
(define ai-sealer
  (make-ai-agent
   (org-vat my-org)
   (org-ref my-org)
   'ai-governor
   "ai-pub-key"
   "You are an AI governor for this organization. You make wise decisions."))

(display "   ✓ AI expressor 'ai-governor' created\n")
(with-vat (org-vat my-org)
  (display "   ✓ ai-governor:prompt = ")
  (display ($ (org-ref my-org) 'lookup 'ai-governor:prompt))
  (newline)
  (newline))

(display "3. Testing AI query via (as sealer (ai ...))...\n")
(catch #t
  (lambda ()
    (with-vat (org-vat my-org)
      (let ((response (evaluate `(as ,ai-sealer (ai "What bindings exist in this org?"))
                                (org-ref my-org) '()
                                ($ (org-ref my-org) 'current-expressor))))
        (display "   AI Response: ")
        (display response)
        (newline)
        (newline))))
  (lambda (key . args)
    (display "   ✗ Error: ")
    (display key)
    (display ": ")
    (display args)
    (newline)
    (newline)))

(display "4. Testing AI action via (as sealer (ai-eval ...))...\n")
(display "   Asking AI to create a welcome message...\n")
(catch #t
  (lambda ()
    (with-vat (org-vat my-org)
      (evaluate `(as ,ai-sealer
                     (ai-eval "Create a binding called 'welcome' with a friendly greeting"))
                (org-ref my-org) '()
                ($ (org-ref my-org) 'current-expressor))
      (display "   ✓ AI executed action\n\n")))
  (lambda (key . args)
    (display "   ✗ Error: ")
    (display key)
    (display ": ")
    (display args)
    (newline)
    (newline)))

(display "5. Checking org history...\n")
(with-vat (org-vat my-org)
  (let ((history ($ (org-ref my-org) 'history)))
    (display "   Recent history entries:\n")
    (for-each
     (lambda (entry)
       (let ((version (car entry))
             (exp-id (cadr entry))
             (expr (caddr entry)))
         (format #t "     v~a [~a]: ~a\n"
                 version
                 (or ($ (org-ref my-org) 'expressor-name exp-id) '?)
                 expr)))
     (reverse (if (> (length history) 7)
                  (list-tail history (- (length history) 7))
                  history)))))

(display "\n════════════════════════════════════════════════════════════════\n\n")
(display "Key points:\n")
(display "  - AI is just an expressor with config bindings\n")
(display "  - Config (ai-governor:prompt) is visible in the org\n")
(display "  - (as sealer (ai ...)) queries as the AI identity\n")
(display "  - (as sealer (ai-eval ...)) generates and executes code\n")
(display "  - History shows both config setup and AI actions\n")
(display "  - Any expressor can (modify! 'ai-governor:prompt ...) to change the AI\n\n")
