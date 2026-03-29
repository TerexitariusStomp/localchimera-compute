;;; module/playnet/gateway/services.scm — Transcription and Express actors
;;;
;;; Thin Goblins actor wrappers around the ^key-pool.
;;; These encapsulate the OpenRouter API logic from relay.scm so the
;;; lobby never exposes the raw key-pool to clients.

(define-module (playnet gateway services)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (json)
  #:export (^transcription-service
            ^express-service))

(define (^transcription-service _bcom pool-vat key-pool)
  ;; pool-vat: the vat containing the key-pool actor
  ;; key-pool: ^key-pool actor ref (or #f if disabled)
  (methods
   ((transcribe audio-b64)
    (unless key-pool
      (error "transcription not available — no API keys configured"))
    (let* ((body (scm->json-string
                  `((model . "google/gemini-2.0-flash-001")
                    (messages
                     . #(((role . "user")
                          (content
                           . #(((type . "text")
                                (text . "Transcribe this audio exactly, word for word. Return only the transcript text, nothing else."))
                               ((type . "image_url")
                                (image_url
                                 . ((url . ,(string-append
                                             "data:audio/webm;base64,"
                                             audio-b64)))))))))))))
           (response-str (with-vat pool-vat
                           ($ key-pool 'request "/chat/completions" body)))
           (json (json-string->scm response-str))
           (choices (assoc-ref json "choices")))
      (if (and choices (> (vector-length choices) 0))
          (or (assoc-ref (assoc-ref (vector-ref choices 0) "message")
                         "content")
              "")
          (error "transcription returned no choices"))))))

(define (^express-service _bcom pool-vat key-pool)
  (methods
   ((express nl-text)
    (unless key-pool
      (error "express not available — no API keys configured"))
    (let* ((body (scm->json-string
                  `((model . "google/gemini-2.0-flash-001")
                    (messages
                     . #(((role . "system")
                          (content . "You are inside playnet, a Scheme-based programmable organization. Convert the user's natural language into a single valid Scheme S-expression. Respond with ONLY the raw S-expression, no markdown, no explanation, no code fences. Use (modify! 'name value) for bindings, (define name value) for definitions, (lambda (args) body) for functions."))
                         ((role . "user")
                          (content . ,nl-text)))))))
           (response-str (with-vat pool-vat
                           ($ key-pool 'request "/chat/completions" body)))
           (json (json-string->scm response-str))
           (choices (assoc-ref json "choices")))
      (if (and choices (> (vector-length choices) 0))
          (or (assoc-ref (assoc-ref (vector-ref choices 0) "message")
                         "content")
              "")
          (error "express returned no choices"))))))
