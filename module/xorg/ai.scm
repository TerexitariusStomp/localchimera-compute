;;; module/xorg/ai.scm — AI integration for xorg via capabilities
;;;
;;; Provides ^ai-capability: a Goblins actor wrapping AI query access.
;;; The org holds this capability; expressors use it through org bindings.
;;;
;;; openrouter-chat now takes an http-client capability as first argument
;;; instead of reading global mutable state.
;;;
;;; Pure utility functions (format-org-context, format-org-state,
;;; strip-code-fences) remain unchanged — they format strings, no IO.
;;;
;;; Backward compatibility: on module load, set-ai-handler! is called
;;; with closures that delegate to the capability when one is installed
;;; via install-ai-capability!, or error if none is set.

(define-module (xorg ai)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (xorg gplay)
  #:use-module (json)
  #:export (^ai-capability
            make-ai-capability
            format-org-context
            format-org-state
            strip-code-fences
            openrouter-chat
            install-ai-capability!))

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

(define (format-org-state ref)
  "Build a string describing the current org state: expressor, bindings, history, forms.
Does NOT include a preamble — callers prepend their own identity/role instructions."
  (let* ((bindings ($ ref 'bindings))
         (history  ($ ref 'history))
         (exp-name (or ($ ref 'expressor-name ($ ref 'current-expressor)) '?))
         ;; Current branch history, last 10 entries
         (branch   (ancestor-chain history ($ ref 'head-version)))
         (recent   (if (> (length branch) 10)
                       (list-tail branch (- (length branch) 10))
                       branch)))
    (string-append
     "Current expressor (identity): " (symbol->string exp-name) "\n\n"
     "Current bindings:\n"
     (string-join (map (lambda (b) (format-binding b ref)) bindings) "\n")
     "\n\nRecent history:\n"
     (string-join (map (lambda (e) (format-history-entry e ref)) recent) "\n")
     "\n\nAvailable special forms: (modify! 'name value), (enact! validator-expr), "
     "(rollback! version), (defexpressor name key), (as expressor-id expr), "
     "(ai prompt), (ai-eval prompt), "
     "(show-history), (show-expressors), (lambda (args ...) body), "
     "(if test then else), (quote expr).\n")))

(define (format-org-context ref)
  "Build a system prompt string describing the current org actor state."
  (string-append
   "You are an AI assistant integrated into xorg, an experimental "
   "organizational system built as a Scheme-based REPL.\n\n"
   (format-org-state ref)))

;;; ── Per-expressor config lookup ──────────────────────────────────────────

(define (expressor-config-key ref expressor-id key-suffix)
  "Build a namespaced config symbol: expressor-name:key-suffix.
Returns #f if expressor has no name."
  (let ((name ($ ref 'expressor-name expressor-id)))
    (and name
         (string->symbol
          (string-append (symbol->string name) ":" (symbol->string key-suffix))))))

(define (lookup-expressor-config ref expressor-id key-suffix)
  "Look up a per-expressor config binding. Returns #f if not found."
  (let ((config-key (expressor-config-key ref expressor-id key-suffix)))
    (and config-key
         (catch #t
           (lambda () ($ ref 'lookup config-key))
           (lambda _ #f)))))

;;; ── HTTP client (capability-based) ─────────────────────────────────────────

(define (openrouter-chat http-client model system-prompt user-prompt)
  "POST a chat completion request to OpenRouter via an http-client capability.
   http-client: an ^http-client capability actor reference
   model: string like \"google/gemini-flash-2.0\"
   system-prompt: string
   user-prompt: string
   Returns the assistant message content string."
  (let* ((body (scm->json-string
                `((model . ,model)
                  (messages . #(((role . "system")
                                 (content . ,system-prompt))
                                ((role . "user")
                                 (content . ,user-prompt)))))))
         (response-str ($ http-client 'post "/chat/completions" body))
         (json     (json-string->scm response-str))
         (choices  (assoc-ref json "choices")))
    (unless (and choices (> (vector-length choices) 0))
      (error "OpenRouter returned no choices:" response-str))
    (assoc-ref (assoc-ref (vector-ref choices 0) "message") "content")))

;;; ── strip-code-fences ──────────────────────────────────────────────────────

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

;;; ── ^ai-capability ─────────────────────────────────────────────────────────

(define (^ai-capability bcom http-client default-model)
  "A capability actor for AI queries. The org holds this; expressors use it.
   http-client: an ^http-client capability actor
   default-model: string like \"google/gemini-flash-2.0\""
  (methods
   [(query system-prompt user-prompt)
    (openrouter-chat http-client default-model system-prompt user-prompt)]
   [(query-with-model model system-prompt user-prompt)
    (openrouter-chat http-client model system-prompt user-prompt)]
   [(model) default-model]))

(define (make-ai-capability vat http-client default-model)
  "Convenience: spawn an ^ai-capability in VAT."
  (with-vat vat (spawn ^ai-capability http-client default-model)))

;;; ── Capability-backed query functions ──────────────────────────────────────
;;;
;;; These closures are installed as the gplay.scm AI handlers via
;;; set-ai-handler! / set-ai-eval-handler!. They delegate to the
;;; currently installed ^ai-capability.

(define *current-ai-capability* #f)

(define (install-ai-capability! ai-cap)
  "Install an ^ai-capability actor as the backing for (ai ...) and (ai-eval ...)
   in gplay.scm. Call this after spawning the capability."
  (set! *current-ai-capability* ai-cap)
  ;; Wire into gplay.scm's handler globals
  (set-ai-handler! ai-query-via-capability)
  (set-ai-eval-handler! ai-query-and-eval-via-capability))

(define (ai-query-via-capability prompt ref expressor-id)
  "Send PROMPT to AI with org context, using the installed ^ai-capability."
  (unless *current-ai-capability*
    (error "No AI capability installed. Use install-ai-capability! first."))
  (let* ((custom-prompt (lookup-expressor-config ref expressor-id 'prompt))
         (custom-model  (lookup-expressor-config ref expressor-id 'model))
         (system-prompt (if custom-prompt
                            (string-append custom-prompt "\n\n" (format-org-state ref))
                            (format-org-context ref))))
    (if custom-model
        ($ *current-ai-capability* 'query-with-model
           custom-model system-prompt prompt)
        ($ *current-ai-capability* 'query system-prompt prompt))))

(define (ai-query-and-eval-via-capability prompt ref expressor-id)
  "Send PROMPT to AI, instructing it to return a single S-expression.
   Strips markdown fences, parses with read, returns the parsed expression."
  (unless *current-ai-capability*
    (error "No AI capability installed. Use install-ai-capability! first."))
  (let* ((custom-prompt (lookup-expressor-config ref expressor-id 'prompt))
         (custom-model  (lookup-expressor-config ref expressor-id 'model))
         (system-prompt
          (string-append
           (if custom-prompt
               (string-append custom-prompt "\n\n" (format-org-state ref))
               (format-org-context ref))
           "\n\nIMPORTANT: You must respond with ONLY a single valid Scheme "
           "S-expression, nothing else. No explanation, no markdown, no prose. "
           "Just the raw expression.\n\n"
           "Use (modify! 'name value) to create or update bindings. "
           "Use string literals for text values (\"hello\"), not quoted symbols. "
           "Example: (modify! 'greeting \"hello world\")\n"
           "Example: (modify! 'budget 50000)\n"
           "For multiple changes: (begin (modify! 'a 1) (modify! 'b 2))"))
         (response (if custom-model
                       ($ *current-ai-capability* 'query-with-model
                          custom-model system-prompt prompt)
                       ($ *current-ai-capability* 'query system-prompt prompt)))
         (cleaned  (strip-code-fences response)))
    (call-with-input-string cleaned read)))

;;; ── Handler registration ───────────────────────────────────────────────────
;;; Install capability-backed handlers. These will error with a clear message
;;; if (ai ...) is used before install-ai-capability! is called.

(set-ai-handler! ai-query-via-capability)
(set-ai-eval-handler! ai-query-and-eval-via-capability)
