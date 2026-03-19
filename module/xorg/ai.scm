(define-module (xorg ai)
  #:use-module (xorg play)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 match)
  #:use-module (ice-9 rdelim)
  #:use-module (json)
  #:export (current-ai-api-key
            current-ai-model
            set-ai-api-key!
            set-ai-model!
            ai-query
            ai-query-and-eval))

;;; ── API key & model management ─────────────────────────────────────────────

(define current-ai-api-key (make-parameter (or (getenv "OPENROUTER_API_KEY") #f)))
(define current-ai-model   (make-parameter "openai/gpt-4o-mini"))

(define (set-ai-api-key! key)
  (current-ai-api-key key))

(define (set-ai-model! model)
  (current-ai-model model))

;;; ── Context formatter ──────────────────────────────────────────────────────

(define (format-binding pair)
  "Format a single (name . value) binding for the system prompt."
  (let ((name (car pair))
        (val  (cdr pair)))
    (string-append
     "  " (symbol->string name) " = "
     (cond
      ((procedure? val) (string-append "<procedure " (symbol->string name) ">"))
      ((expressor? val) (string-append "<expressor "
                                       (symbol->string (or (expressor-name val) '?))
                                       ">"))
      (else (call-with-output-string (lambda (p) (write val p))))))))

(define (format-history-entry entry)
  "Format a single history entry for the system prompt."
  (string-append
   "  v" (number->string (history-version entry))
   " [" (symbol->string (or (expressor-name (history-expressor entry)) '?))
   "]: " (call-with-output-string (lambda (p) (write (history-expr entry) p)))))

(define (format-env-context env)
  "Build a system prompt string describing the current environment state."
  (let* ((bindings (env-bindings env))
         (history  (env-history env))
         (exp-id   (env-expressor env))
         (exp-name (or (expressor-name exp-id) '?))
         ;; Take last 10 history entries (most recent)
         (recent   (let ((h (reverse history)))
                     (if (> (length h) 10)
                         (list-tail h (- (length h) 10))
                         h))))
    (string-append
     "You are an AI assistant integrated into xorg, an experimental "
     "organizational system built as a Scheme-based REPL.\n\n"
     "Current expressor (identity): " (symbol->string exp-name) "\n\n"
     "Current bindings:\n"
     (string-join (map format-binding bindings) "\n")
     "\n\nRecent history:\n"
     (string-join (map format-history-entry recent) "\n")
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
                       #:decode-body? #f))
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

(define (ai-query prompt env)
  "Send PROMPT to OpenRouter with environment context. Returns a string."
  (let ((system-prompt (format-env-context env)))
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

(define (ai-query-and-eval prompt env)
  "Send PROMPT to OpenRouter, instructing the AI to return a single S-expression.
Strips markdown fences, parses with read, and returns the parsed expression."
  (let* ((system-prompt
          (string-append
           (format-env-context env)
           "\n\nIMPORTANT: You must respond with ONLY a single valid Scheme "
           "S-expression, nothing else. No explanation, no markdown, no prose. "
           "Just the raw expression. For example: (modify! 'greeting \"hello\")"))
         (response (openrouter-chat system-prompt prompt))
         (cleaned  (strip-code-fences response)))
    (call-with-input-string cleaned read)))

;;; ── Handler registration ───────────────────────────────────────────────────
;;; Set the play.scm parameters so (ai ...) and (ai-eval ...) work in evaluate.

(set-ai-handler! ai-query)
(set-ai-eval-handler! ai-query-and-eval)
