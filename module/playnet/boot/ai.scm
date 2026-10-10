;;; module/playnet/boot/ai.scm — the key-pool vat: the provider keys, their health, the AI and corpus services.

(define-module (playnet boot ai)
  #:use-module ((playnet ai key-pool) #:select (generic-provider make-key-pool nano-gpt-provider openai-provider
                                                openrouter-provider start-key-pool-monitor))
  #:use-module ((playnet boot site) #:select (log!))
  #:use-module ((playnet gateway llm-service) #:select (^ai-service))
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:export (spawn-key-pool! spawn-ai-services!))

(define (spawn-key-pool!)
  "The provider key pool in its own vat, with its health monitor. (values
pool-vat key-pool); key-pool is #f without API_KEYS, and transcription is off.
Before fibers: the monitor is a thread."
  (let* ((pool-vat (spawn-vat #:name "key-pool"))
         (key-pool
          (let ((keys-env (or (getenv "API_KEYS")
                              (getenv "OPENROUTER_KEYS")
                              ""))
                (provider-name (or (getenv "API_PROVIDER") "nano-gpt")))
            (if (string=? keys-env "")
                (begin
                  (log! "  [gateway] No API_KEYS — transcription disabled~%")
                  #f)
                (let* ((provider (case (string->symbol provider-name)
                                   ((openrouter) (openrouter-provider))
                                   ((openai)     (openai-provider))
                                   ((nano-gpt)   (nano-gpt-provider))
                                   ((generic)    (generic-provider
                                                  (or (getenv "API_BASE_URL")
                                                      (error "API_PROVIDER=generic requires API_BASE_URL"))))
                                   (else (error "unknown API_PROVIDER" provider-name))))
                       (pool (make-key-pool pool-vat keys-env #:provider provider)))
                  (log! "  [gateway] key-pool loaded (~a) — transcription enabled~%"
                        provider-name)
                  pool)))))
    ;; Start key-pool health monitor
    (when key-pool
      (start-key-pool-monitor pool-vat key-pool))
    (values pool-vat key-pool)))

(define (spawn-ai-services! gateway-vat pool-vat key-pool)
  "The AI service over the pool and the corpus search, both in GATEWAY-VAT.
(values ai-service corpus-service); the corpus service is #f on a box without
its libraries."
  (values
   (with-vat gateway-vat
     (spawn ^ai-service pool-vat key-pool))
   ;; Corpus search (docs/planning/faces/corpus-guile-native.md phase 4) needs
   ;; guile-sqlite3 + onnxruntime — NOT yet in every deployment's own
   ;; manifest (a deploy/*.scm decision left to whoever runs this box,
   ;; not made here). Resolved defensively, so a box without them still
   ;; boots the whole gateway; the door in ^lobby already answers
   ;; "not configured" when corpus-svc is #f, the same shape as
   ;; ^ai-service's own no-keys? degrading to "" rather than refusing
   ;; to start.
   (catch #t
     (lambda ()
       (let ((m (resolve-module '(playnet gateway corpus-service) #:ensure #f)))
         (and m (with-vat gateway-vat (spawn (module-ref m '^corpus-service))))))
     (lambda (key . args)
       (log! "  [gateway] corpus search unavailable on this box (needs guile-sqlite3 + onnxruntime): ~a ~a~%" key args)
       #f))))
