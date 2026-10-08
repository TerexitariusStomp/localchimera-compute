;;; module/playnet/ai/bridge.scm — Server-side AI bridge for gplay
;;;
;;; Wires the gplay (ai …) and (ai-eval …) special forms to a real LLM.
;;; The key-pool lives in the user's vat (whichever vat the gplay
;;; evaluator is running in), so every $ call is synchronous — no
;;; cross-vat promise dance.
;;;
;;; Configuration:
;;;   API_KEYS or OPENROUTER_KEYS — comma-separated keys (env, optional)
;;;   API_PROVIDER                — "openrouter" (default) | "openai" | "generic"
;;;   API_BASE_URL                — required when API_PROVIDER=generic
;;;   AI_MODEL                    — model id, e.g. "google/gemini-2.0-flash-001"
;;;
;;; At REPL: (set-api-key! "sk-or-…") and (set-ai-model! "openai/gpt-4o").

(define-module (playnet ai bridge)
  #:use-module (goblins)
  #:use-module (playnet org gplay)
  #:use-module (playnet ai key-pool)
  #:use-module (playnet ai llm)
  #:use-module (playnet ai prompt)
  #:use-module (srfi srfi-13)
  #:export (set-ai-api-key!
            set-ai-model!
            current-ai-api-key
            current-ai-model))

;;; ── State ──────────────────────────────────────────────────────────────────

(define *key-pool* #f)
;; Env keys are stashed at module load; the pool is spawned on first use
;; in the caller's current vat, so loading this module doesn't keep a
;; Goblins thread alive forever.
(define *pending-keys*
  (let ((s (or (getenv "API_KEYS") (getenv "OPENROUTER_KEYS") "")))
    (if (string=? s "") #f s)))
;; One source of truth for the default slug: fall through to llm.scm's
;; %default-completion-model (nano-gpt-valid) rather than carry a second copy.
(define *ai-model*
  (or (getenv "AI_MODEL") %default-completion-model))

;;; ── Provider selection ─────────────────────────────────────────────────────

(define (env-provider)
  (let ((name (or (getenv "API_PROVIDER") "nano-gpt")))
    (cond ((string=? name "nano-gpt")   (nano-gpt-provider))
          ((string=? name "openrouter") (openrouter-provider))
          ((string=? name "openai")     (openai-provider))
          ((string=? name "generic")
           (generic-provider
            (or (getenv "API_BASE_URL")
                (error "API_BASE_URL required when API_PROVIDER=generic"))))
          (else (nano-gpt-provider)))))

;;; ── Public surface ─────────────────────────────────────────────────────────

(define (current-ai-model) *ai-model*)
(define (set-ai-model! m) (set! *ai-model* m))

(define (current-ai-api-key)
  ;; Don't reveal key material; just report configured-or-not.
  (and (or *key-pool* *pending-keys*) 'configured))

(define (ensure-pool!)
  "Spawn the key-pool in the current vat on first use. Caller must be
   inside a (with-vat ...) block. Idempotent."
  (when (and *pending-keys* (not *key-pool*))
    (set! *key-pool* (spawn-key-pool *pending-keys* #:provider (env-provider)))
    (set! *pending-keys* #f)))

(define (set-ai-api-key! key)
  (cond
   ((not *key-pool*)
    (set! *pending-keys* key)
    (ensure-pool!))
   (else
    ($ *key-pool* 'add-key key)))
  'ok)

;;; ── Per-expressor config + org-context formatting ──────────────────────────

(define (expressor-config org expressor-id key-suffix)
  "Look up a per-expressor binding (e.g. ai-gov:prompt). Returns #f if absent."
  (let ((exp-name ($ org 'expressor-name expressor-id)))
    (and exp-name
         (let* ((config-key
                 (string->symbol
                  (string-append (symbol->string exp-name)
                                 ":" (symbol->string key-suffix))))
                (entry (assq config-key ($ org 'bindings))))
           (and entry (cdr entry))))))

(define (format-binding pair)
  (let ((name (car pair)) (val (cdr pair)))
    (string-append "  " (symbol->string name) " = "
                   (if (procedure? val)
                       (string-append "<procedure " (symbol->string name) ">")
                       (call-with-output-string
                        (lambda (p) (write val p)))))))

(define (format-org-state org)
  (let* ((bindings ($ org 'bindings))
         (history  ($ org 'history))
         (exp-name (or ($ org 'expressor-name ($ org 'current-expressor)) '?))
         (recent   (let ((h (reverse history)))
                     (if (> (length h) 10)
                         (list-tail h (- (length h) 10))
                         h))))
    (string-append
     "Current expressor (identity): " (symbol->string exp-name) "\n\n"
     "Bindings:\n"
     (string-join (map format-binding bindings) "\n")
     "\n\nRecent history:\n"
     (string-join
      (map (lambda (e)
             (string-append
              "  v" (number->string (car e))
              " [" (symbol->string
                    (or ($ org 'expressor-name (cadr e)) '?))
              "]: "
              (call-with-output-string
               (lambda (p) (write (caddr e) p)))))
           recent)
      "\n"))))

(define (system-prompt org expressor-id)
  (let ((custom (expressor-config org expressor-id 'prompt)))
    (if custom
        (string-append custom "\n\n" (format-org-state org))
        (string-append %ai-system-preamble (format-org-state org)))))

(define (eval-system-prompt org expressor-id)
  (string-append (system-prompt org expressor-id) %ai-eval-suffix))

(define (effective-model org expressor-id)
  (or (expressor-config org expressor-id 'model) *ai-model*))

;;; ── Code-fence stripping (for ai-eval) ─────────────────────────────────────

(define (strip-code-fences str)
  (let* ((s (string-trim-both str))
         (s (cond ((string-prefix? "```scheme" s) (substring s 9))
                  ((string-prefix? "```scm" s)    (substring s 6))
                  ((string-prefix? "```" s)       (substring s 3))
                  (else s)))
         (s (if (string-suffix? "```" s)
                (substring s 0 (- (string-length s) 3))
                s)))
    (string-trim-both s)))

;;; ── gplay handlers ─────────────────────────────────────────────────────────

(define (require-pool!)
  (ensure-pool!)
  (unless *key-pool*
    (error "AI not available - set API_KEYS in the environment, or call (set-api-key! \"sk-...\")")))

(define (complete-with system-prompt user-prompt org expressor-id)
  (require-pool!)
  (do-completion *key-pool*
                 (vector
                  `((role . "system") (content . ,system-prompt))
                  `((role . "user")   (content . ,user-prompt)))
                 (effective-model org expressor-id)))

(define (ai-query prompt org expressor-id)
  (complete-with (system-prompt org expressor-id) prompt org expressor-id))

(define (ai-query-and-eval prompt org expressor-id)
  (let ((response (complete-with (eval-system-prompt org expressor-id)
                                 prompt org expressor-id)))
    (call-with-input-string (strip-code-fences response) read)))

(set-ai-handler! ai-query)
(set-ai-eval-handler! ai-query-and-eval)
