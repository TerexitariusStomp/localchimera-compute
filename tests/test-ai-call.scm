#!/usr/bin/env guile
!#

;;; test-ai-call.scm — Actually call the AI API to verify it works

(define %project-root (string-append (dirname (current-filename)) "/.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (xorg ai)
             (xorg org)
             (goblins)
             (ice-9 rdelim))

;;; Load .env
(define (load-env-file filepath)
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

(display "\n=== Testing AI API Call ===\n\n")

(load-env-file (string-append %project-root "/.env"))
(set-ai-api-key! (getenv "OPENROUTER_API_KEY"))

(display "Creating org with Goblins vat...\n")
(define test-org (make-org "ai-test"))
(display "✓ Org created\n\n")

(display "Making AI query: 'What is 2 + 2?'\n")
(display "This will actually call OpenRouter API...\n\n")

(catch #t
  (lambda ()
    (let ((response (ai-query "What is 2 + 2? Answer in one short sentence."
                              (org-ref test-org))))
      (display "✅ AI Response:\n")
      (display "   ")
      (display response)
      (newline)
      (newline)
      (display "✅ AI integration is WORKING!\n")))
  (lambda (key . args)
    (display "❌ Error calling AI:\n")
    (format #t "   ~a: ~a\n" key args)))

(display "\n")
