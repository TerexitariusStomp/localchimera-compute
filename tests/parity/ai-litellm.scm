;;; tests/parity/ai-litellm.scm — key-pool ↔ LiteLLM parity.
;;; The contract: a chat request is the OpenAI wire on
;;; /v1/chat/completions — model + messages, keys never in the body.
;;; Invariant leg pins the wire; live leg reads real choices.

(use-modules (playnet test harness)
             (playnet test parity)
             (playnet delegates)
             (srfi srfi-1))

(define fixture-messages '((("role" . "user") ("content" . "ping"))))

(let ((w (litellm-chat-wire "llama-3.2" fixture-messages)))
  (check "litellm wire is model + messages, no key material"
         (and (equal? (cdr (assoc "model" w)) "llama-3.2")
              (equal? (cdr (assoc "messages" w)) fixture-messages)
              (not (assoc "api_key" w))) #t))

(parity-live-delegate "PLAYNET_LITELLM_URL"
  "litellm answers a chat completion"
  (lambda (t) (make-litellm-delegate t))
  (lambda (d) (d "llama-3.2" fixture-messages))
  (lambda (a) (pair? a)))

(test-summary!)
