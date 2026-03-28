;;; module/xorg/ai.scm — AI integration for xorg via capabilities
;;;
;;; One ^ai-capability per org. AI access is governed by capability
;;; possession, not by expressor identity. No per-expressor config lookup.

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
  "Build a string describing the current org state."
  (let* ((bindings ($ ref 'bindings))
         (history  ($ ref 'history))
         (exp-name (or ($ ref 'expressor-name ($ ref 'current-expressor)) '?))
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

;;; ── HTTP client (capability-based) ─────────────────────────────────────────

(define (openrouter-chat http-client model system-prompt user-prompt)
  "POST a chat completion request to OpenRouter via an http-client capability.
   All arguments are explicit — no global fallbacks."
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
         (stripped (cond
                   ((string-prefix? "```scheme" trimmed)
                    (substring trimmed 9))
                   ((string-prefix? "```scm" trimmed)
                    (substring trimmed 6))
                   ((string-prefix? "```" trimmed)
                    (substring trimmed 3))
                   (else trimmed)))
         (stripped (if (string-suffix? "```" stripped)
                      (substring stripped 0 (- (string-length stripped) 3))
                      stripped)))
    (string-trim-both stripped)))

;;; ── ^ai-capability ─────────────────────────────────────────────────────────

(define (^ai-capability bcom http-client default-model)
  "A capability actor for AI queries. One per org.
   http-client: an ^http-client capability actor
   default-model: string like \"google/gemini-flash-2.0\""
  (methods
   [(query system-prompt user-prompt)
    (openrouter-chat http-client default-model system-prompt user-prompt)]
   [(query-with-model model system-prompt user-prompt)
    (openrouter-chat http-client model system-prompt user-prompt)]
   [(model) default-model]))

(define (make-ai-capability vat http-client default-model)
  "Spawn an ^ai-capability in VAT."
  (with-vat vat (spawn ^ai-capability http-client default-model)))

;;; ── Capability-backed handlers ─────────────────────────────────────────────
;;; AI access is governed by capability, not by who is asking.
;;; The _expressor-id parameter is passed by gplay.scm but ignored.

(define *current-ai-capability* #f)

(define (ai-query-via-capability prompt ref _expressor-id)
  "Query AI with org context. Expressor identity ignored — cap governs access."
  (unless *current-ai-capability*
    (error "No AI capability installed. Use install-ai-capability! first."))
  ($ *current-ai-capability* 'query (format-org-context ref) prompt))

(define (ai-query-and-eval-via-capability prompt ref _expressor-id)
  "Query AI for an S-expression. Strips fences, parses result.
   No per-expressor config — one capability, one model, one prompt format."
  (unless *current-ai-capability*
    (error "No AI capability installed. Use install-ai-capability! first."))
  (let* ((system-prompt
          (string-append
           (format-org-context ref)
           "\n\nIMPORTANT: You must respond with ONLY a single valid Scheme "
           "S-expression, nothing else. No explanation, no markdown, no prose. "
           "Just the raw expression.\n\n"
           "Use (modify! 'name value) to create or update bindings. "
           "Use string literals for text values (\"hello\"), not quoted symbols. "
           "Example: (modify! 'greeting \"hello world\")\n"
           "Example: (modify! 'budget 50000)\n"
           "For multiple changes: (begin (modify! 'a 1) (modify! 'b 2))"))
         (response ($ *current-ai-capability* 'query system-prompt prompt))
         (cleaned  (strip-code-fences response)))
    (call-with-input-string cleaned read)))

(define (install-ai-capability! ai-cap)
  "Install an ^ai-capability as the backing for (ai ...) and (ai-eval ...).
   One capability per org. Access governed by capability possession."
  (set! *current-ai-capability* ai-cap)
  (set-ai-handler! ai-query-via-capability)
  (set-ai-eval-handler! ai-query-and-eval-via-capability))

;;; ── Default handler registration ───────────────────────────────────────────

(set-ai-handler! ai-query-via-capability)
(set-ai-eval-handler! ai-query-and-eval-via-capability)
