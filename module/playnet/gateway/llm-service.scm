;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/gateway/llm-service.scm — Gateway-exposed LLM actor
;;;
;;; A single ^ai-service capability covers everything the lobby needs
;;; from an LLM: chat completion, NL→Scheme expression, audio
;;; transcription. Each method is a thin shape around (playnet ai llm)'s
;;; do-completion — different message vector, same wire protocol.
;;;
;;; The actor lives in gateway-vat; the key-pool lives in pool-vat.
;;; (with-vat pool-vat …) returns a Goblins promise from inside
;;; gateway-vat, which propagates through the lobby's `<-` chain to
;;; OCapN consumers naturally.

(define-module (playnet gateway llm-service)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (gcrypt base64)
  #:use-module (json)
  #:use-module (playnet ai llm)
  #:export (^ai-service))

;; The model a picture is read by. It is an enclave (`TEE/…`) slug or it is
;; nothing: the account pays for what runs here, and only the enclave models
;; keep the privacy posture (playnet ai llm) states. No model named, or one
;; outside the enclave, leaves the door answering "" — the capture sheet's cue
;; to take the figure from the person (docs/observation/capture.md §9).
(define %vision-model
  (let ((m (getenv "API_VISION_MODEL")))
    (cond ((not (and (string? m) (not (string-null? m)))) #f)
          ((string-prefix? "TEE/" m) m)
          (else
           (format (current-error-port)
                   "[ai-service see] API_VISION_MODEL=~a is outside the enclave — pictures stay unread\n" m)
           #f))))

;; a picture as the message part an OpenAI-compatible endpoint reads
(define (image-part image-b64 mime)
  `((type . "image_url")
    (image_url . ((url . ,(string-append "data:" mime ";base64," image-b64))))))

(define %transcription-model
  ;; OpenAI-compatible Whisper model id. Both OpenAI and nano-gpt
  ;; accept "whisper-1"; override via env if needed.
  (or (getenv "API_TRANSCRIPTION_MODEL") "whisper-1"))

;; Completions go through (playnet ai llm)'s verified-completion, under the
;; policy AI_TEE_VERIFY_POLICY names. 'off (the default) reduces straight to
;; do-completion* — zero extra network calls. 'observe verifies the enclave's
;; attestation and signature (two extra requests per completion) and logs a
;; failure; 'enforce raises on one. The policy applies to TEE/… models;
;; verified-completion passes every other model through whatever it says.
(define %tee-verify-policy
  (let ((v (or (getenv "AI_TEE_VERIFY_POLICY") "off")))
    (cond ((string=? v "enforce") 'enforce)
          ((string=? v "observe") 'observe)
          (else 'off))))

(define (call-completion pool-vat key-pool messages-vec model)
  (with-vat pool-vat
    (call-with-values
      (lambda () (verified-completion key-pool messages-vec model #:policy %tee-verify-policy))
      (lambda (content verdict)
        (when (and verdict (not (assoc-ref verdict 'ok)))
          (format (current-error-port)
                  "[ai-service tee] verification FAILED (policy=~a): ~a\n"
                  %tee-verify-policy (assoc-ref verdict 'reason)))
        content))))

(define (call-completion/logged op pool-vat key-pool messages-vec model)
  "Like call-completion, but reports any failure to stderr with OP
   tag so we can see which surface (transcribe/express/complete) failed
   and what the upstream said. Re-raises so callers still see broken
   promises on the wire."
  (catch #t
    (lambda ()
      (call-completion pool-vat key-pool messages-vec model))
    (lambda (key . args)
      (format (current-error-port)
              "[ai-service ~a] FAIL key=~s args=~s\n" op key args)
      (apply throw key args))))

(define %express-system-prompt
  "You are inside playnet, a Scheme-based programmable organization. \
Convert the user's natural language into a single valid Scheme \
S-expression. Respond with ONLY the raw S-expression, no markdown, \
no explanation, no code fences. Use (modify! 'name value) for \
bindings, (define name value) for definitions, (lambda (args) body) \
for functions.")

(define (do-transcription pool-vat key-pool audio-b64)
  "POST audio (base64-encoded WAV) to /audio/transcriptions as multipart
   form data. Works with any OpenAI-compatible Whisper endpoint
   (OpenAI, nano-gpt, generic). Returns the transcript string, or
   raises if the upstream call fails."
  (let* ((audio-bytes (base64-decode audio-b64))
         (parts (list (list "file" audio-bytes "audio.wav" "audio/wav")
                      (list "model" %transcription-model)
                      (list "response_format" "json")))
         (response-str
          (with-vat pool-vat
            ($ key-pool 'request-multipart "/audio/transcriptions" parts)))
         (json (catch #t
                 (lambda () (json-string->scm response-str))
                 (lambda _ #f))))
    (cond
     ((and json (assoc-ref json "text"))
      (or (assoc-ref json "text") ""))
     (else
      (format (current-error-port)
              "[ai-service transcribe] unexpected response: ~s\n"
              response-str)
      ""))))

(define (^ai-service _bcom pool-vat key-pool)
  ;; When no keys are configured, return "" rather than raising — the
  ;; client treats empty as "fall back to local Whisper" and we avoid
  ;; the opaque "Unknown error occurred with remote object" that
  ;; non-string Scheme exceptions become on the OCapN wire.
  (define (no-keys? op)
    (cond
     (key-pool #f)
     (else
      (format (current-error-port)
              "[ai-service ~a] no API keys configured — returning empty\n" op)
      #t)))

  ;; The model a caller may name: the house default, or another enclave
  ;; (`TEE/…`) slug. Anything else is answered by the default — the account
  ;; pays for what runs here, and only the enclave models keep the privacy
  ;; posture (playnet ai llm) states.
  (define (model-allowed model)
    (if (and (string? model)
             (or (string=? model %default-completion-model)
                 (string-prefix? "TEE/" model)))
        model
        #f))

  (methods

   ;; Generic chat completion — the primitive.
   ((complete system-prompt user-prompt model)
    (if (no-keys? 'complete) ""
        (call-completion/logged
         'complete pool-vat key-pool
         (vector
          `((role . "system") (content . ,system-prompt))
          `((role . "user")   (content . ,user-prompt)))
         (model-allowed model))))

   ;; Natural-language → Scheme: sugar over 'complete.
   ((express nl-text)
    (if (no-keys? 'express) ""
        (call-completion/logged
         'express pool-vat key-pool
         (vector
          `((role . "system") (content . ,%express-system-prompt))
          `((role . "user")   (content . ,nl-text)))
         #f)))

   ;; A picture, read: SYSTEM-PROMPT says what to look for and in what shape
   ;; to answer, USER-PROMPT what the asker already knows of the scene, and
   ;; IMAGES-B64 is one picture or several of the same thing (a list of
   ;; base64 JPEGs). The picture is sent on and held nowhere here. "" when no
   ;; key or no enclave vision model is configured, and on any failure.
   ((see system-prompt user-prompt images-b64)
    (cond
     ((no-keys? 'see) "")
     ((not %vision-model)
      (format (current-error-port)
              "[ai-service see] no enclave vision model configured (API_VISION_MODEL) — returning empty\n")
      "")
     (else
      (catch #t
        (lambda ()
          (call-completion
           pool-vat key-pool
           (vector
            `((role . "system") (content . ,system-prompt))
            `((role . "user")
              (content . ,(list->vector
                           (cons `((type . "text") (text . ,user-prompt))
                                 (map (lambda (b64) (image-part b64 "image/jpeg"))
                                      (if (string? images-b64) (list images-b64) images-b64)))))))
           %vision-model))
        (lambda (key . args)
          (format (current-error-port)
                  "[ai-service see] FAIL key=~s args=~s\n" key args)
          "")))))

   ;; whether a picture can be read here at all
   ((sees?) (and key-pool %vision-model #t))

   ;; Audio transcription via OpenAI-compatible /audio/transcriptions.
   ;; AUDIO-B64 is base64-encoded WAV (the browser converts webm→wav
   ;; before sending). Posted as multipart/form-data with field "file".
   ;; Returns the transcript string, or "" on any failure (the browser
   ;; falls back to local Whisper).
   ((transcribe audio-b64)
    (cond
     ((no-keys? 'transcribe) "")
     (else
      (format (current-error-port)
              "[ai-service transcribe] called, audio b64 chars ~a, model ~a\n"
              (string-length audio-b64) %transcription-model)
      (catch #t
        (lambda () (do-transcription pool-vat key-pool audio-b64))
        (lambda (key . args)
          (format (current-error-port)
                  "[ai-service transcribe] FAIL key=~s args=~s\n" key args)
          "")))))))
