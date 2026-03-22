(define-module (xorg ai)
  #:use-module (goblins)
  #:use-module (xorg gplay)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 rdelim)
  #:use-module (json)
  #:export (current-ai-api-key
            current-ai-model
            set-ai-api-key!
            set-ai-model!
            load-ai-key-from-env!
            ai-query
            ai-query-and-eval
            format-org-context
            strip-code-fences
            openrouter-chat))

;;; ── API key & model management ─────────────────────────────────────────────

;; Auto-load from .env file if it exists
(define (try-load-env-file)
  (when (file-exists? ".env")
    (catch #t
      (lambda ()
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
      (lambda args #f))))

;; Try to load .env on module initialization
(try-load-env-file)

(define current-ai-api-key (make-parameter (or (getenv "OPENROUTER_API_KEY") #f)))
(define current-ai-model   (make-parameter "openai/gpt-4o-mini"))

(define (set-ai-api-key! key)
  (current-ai-api-key key))

(define (set-ai-model! model)
  (current-ai-model model))

(define (load-ai-key-from-env!)
  "Load API key from OPENROUTER_API_KEY environment variable"
  (let ((key (getenv "OPENROUTER_API_KEY")))
    (if key
        (begin
          (set-ai-api-key! key)
          (display "✓ Loaded API key from OPENROUTER_API_KEY\n"))
        (display "⚠ No OPENROUTER_API_KEY in environment\n"))))

;;; ── Context formatter ──────────────────────────────────────────────────────

(define (format-binding pair ref)
  "Format a single (name . value) binding for the system prompt."
  (let ((name (car pair))
        (val  (cdr pair)))
    (string-append
     "  " (symbol->string name) " = "
     (cond
      ((procedure? val) (string-append "<procedure " (symbol->string name) ">"))
      (($ ref 'expressor? val)
       (string-append "<expressor "
                      (symbol->string (or ($ ref 'expressor-name val) '?))
                      ">"))
      (else (call-with-output-string (lambda (p) (write val p))))))))

(define (format-history-entry entry ref)
  "Format a single history entry for the system prompt."
  (string-append
   "  v" (number->string (car entry))
   " [" (symbol->string (or ($ ref 'expressor-name (cadr entry)) '?))
   "]: " (call-with-output-string (lambda (p) (write (caddr entry) p)))))

(define (format-org-context ref)
  "Build a system prompt string describing the current org actor state."
  (let* ((bindings ($ ref 'bindings))
         (history  ($ ref 'history))
         (exp-name (or ($ ref 'expressor-name ($ ref 'current-expressor)) '?))
         ;; Current branch history, last 10 entries
         (branch   (ancestor-chain history ($ ref 'head-version)))
         (recent   (if (> (length branch) 10)
                       (list-tail branch (- (length branch) 10))
                       branch)))
    (string-append
     "You are an AI assistant integrated into xorg, an experimental "
     "organizational system built as a Scheme-based REPL.\n\n"
     "Current expressor (identity): " (symbol->string exp-name) "\n\n"
     "Current bindings:\n"
     (string-join (map (lambda (b) (format-binding b ref)) bindings) "\n")
     "\n\nRecent history:\n"
     (string-join (map (lambda (e) (format-history-entry e ref)) recent) "\n")
     "\n\nAvailable special forms: (modify! 'name value), (enact! validator-expr), "
     "(rollback! version), (defexpressor name key), (as expressor-id expr), "
     "(show-history), (show-expressors), (lambda (args ...) body), "
     "(if test then else), (quote expr).\n")))

;;; ── HTTP client ────────────────────────────────────────────────────────────

(define (openrouter-chat system-prompt user-prompt)
  "POST a chat completion request to OpenRouter. Returns the assistant message content."
  (let ((api-key (current-ai-api-key)))
    (unless api-key
      (error "No API key set. Use (set-api-key! \"sk-or-...\") or export OPENROUTER_API_KEY."))
    (let* ((body (scm->json-string
                  `((model . ,(current-ai-model))
                    (messages . #(((role . "system")
                                   (content . ,system-prompt))
                                  ((role . "user")
                                   (content . ,user-prompt))))))))
      (call-with-values
          (lambda ()
            (http-post "https://openrouter.ai/api/v1/chat/completions"
                       #:body (string->utf8 body)
                       #:headers
                       `((content-type . (application/json))
                         (authorization . (bearer ,(string->symbol api-key)))
                         (user-agent . "xorg/0.1"))
                       #:streaming? #f
                       #:decode-body? #f
                       #:verify-certificate? #f))
        (lambda (response body-bv)
          (let* ((body-str (if (bytevector? body-bv)
                               (utf8->string body-bv)
                               body-bv))
                 (json     (json-string->scm body-str))
                 (choices  (assoc-ref json "choices")))
            (unless (and choices (> (vector-length choices) 0))
              (error "OpenRouter returned no choices:" body-str))
            (assoc-ref (assoc-ref (vector-ref choices 0) "message") "content")))))))

;;; ── Query functions ────────────────────────────────────────────────────────

(define (ai-query prompt ref)
  "Send PROMPT to OpenRouter with org context. Returns a string."
  (let ((system-prompt (format-org-context ref)))
    (openrouter-chat system-prompt prompt)))

(define (strip-code-fences str)
  "Remove markdown code fences (```scheme ... ``` or ``` ... ```) from STR."
  (let* ((trimmed (string-trim-both str))
         ;; Remove leading ```scheme or ```
         (stripped (cond
                   ((string-prefix? "```scheme" trimmed)
                    (substring trimmed 9))
                   ((string-prefix? "```scm" trimmed)
                    (substring trimmed 6))
                   ((string-prefix? "```" trimmed)
                    (substring trimmed 3))
                   (else trimmed)))
         ;; Remove trailing ```
         (stripped (if (string-suffix? "```" stripped)
                      (substring stripped 0 (- (string-length stripped) 3))
                      stripped)))
    (string-trim-both stripped)))

(define (ai-query-and-eval prompt ref)
  "Send PROMPT to OpenRouter, instructing the AI to return a single S-expression.
Strips markdown fences, parses with read, and returns the parsed expression."
  (let* ((system-prompt
          (string-append
           (format-org-context ref)
           "\n\nIMPORTANT: You must respond with ONLY a single valid Scheme "
           "S-expression, nothing else. No explanation, no markdown, no prose. "
           "Just the raw expression. For example: (modify! 'greeting \"hello\")"))
         (response (openrouter-chat system-prompt prompt))
         (cleaned  (strip-code-fences response)))
    (call-with-input-string cleaned read)))

;;; ── Handler registration ───────────────────────────────────────────────────
;;; Set the gplay.scm handlers so (ai ...) and (ai-eval ...) work in evaluate.

(set-ai-handler! ai-query)
(set-ai-eval-handler! ai-query-and-eval)
