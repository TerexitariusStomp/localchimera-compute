;;; module/playnet/ai/llm.scm — Plain LLM completion primitive over a key-pool
;;;
;;; Single concern: given a key-pool actor (assumed reachable
;;; synchronously from the caller's vat), a vector of message alists,
;;; and a model id, perform one chat-completions request and return the
;;; assistant content string. No actors, no Goblins exposure, no gplay
;;; bridging — those live in (playnet gateway services) and (playnet ai bridge)
;;; respectively, both depending on this module.
;;;
;;; The caller is responsible for vat placement: keep the key-pool in
;;; the same vat you call do-completion from, or wrap the call in
;;; (with-vat pool-vat …) when you have a fibers-aware caller that
;;; awaits the resulting promise.

(define-module (playnet ai llm)
  #:use-module (goblins)
  #:use-module (json)
  #:use-module (srfi srfi-13)
  #:use-module (web uri)
  #:use-module (playnet ai tee-crypto)       ; keccak256 + secp256k1 ecrecover (pure Guile)
  #:use-module (playnet ai tee-attestation)  ; vendor-quote rooting + enclave pinning
  #:export (do-completion
            do-completion*
            llm-completer
            verified-completion
            tee-verify
            tee-model?
            %ecdsa-unwired
            %default-completion-model))

;; The house default. `TEE/gpt-oss-120b` runs inside a nano-gpt Trusted Execution
;; Environment (confidential enclave) — our privacy posture: no third-party
;; gateway sees plaintext outside the enclave, no training, attestable (see
;; tee-verify below). It is an MoE, so cheap/fast for its size, and its
;; OpenAI-lineage instruction-following is the most reliable at the structured
;; (S-expression-only) replies the legal extractor asks for.
;; NOTE: `TEE/…` slugs exist ONLY on nano-gpt (our default provider). If you
;; switch API_PROVIDER to openrouter/openai, ALSO override API_DEFAULT_MODEL to a
;; slug that provider carries. This is the ONE place the default slug lives.
(define %default-completion-model
  (or (getenv "API_DEFAULT_MODEL") "TEE/gpt-oss-120b"))

;; The most a completion may answer with. Every reply this codebase asks for
;; is a sentence, an S-expression or a short record; the cap bounds what one
;; call can cost the account, and a runaway prompt stops here.
(define %max-completion-tokens
  (or (and=> (getenv "API_MAX_TOKENS") string->number) 4096))

;; do-completion* — the request, returning BOTH the content and the top-level
;; response "id" (the request id a TEE signature is fetched by). do-completion is
;; the string-only wrapper the vast majority of callers want.
(define (do-completion* key-pool messages-vec model)
  (let* ((body (scm->json-string
                `((model      . ,(or model %default-completion-model))
                  (max_tokens . ,%max-completion-tokens)
                  (messages   . ,messages-vec))))
         (response-str ($ key-pool 'request "/chat/completions" body))
         (json    (json-string->scm response-str))
         (choices (assoc-ref json "choices")))
    (if (and choices (> (vector-length choices) 0))
        (values (or (assoc-ref (assoc-ref (vector-ref choices 0) "message")
                               "content")
                    "")
                (assoc-ref json "id"))
        ;; The error carries the upstream's own explanation — an OpenAI-shaped
        ;; error body, or the whole parsed response when there is none — so a
        ;; caller that catches it (the gateway's call-completion/logged, gplay's
        ;; require-pool! surface) can tell a bad key from a rate limit from a
        ;; malformed request.
        (error "completion returned no choices:" (or (assoc-ref json "error") json)))))

(define (do-completion key-pool messages-vec model)
  (call-with-values (lambda () (do-completion* key-pool messages-vec model))
    (lambda (content id) content)))

;;; ─── TEE (confidential-enclave) response verification ──────────────────────
;;; A nano-gpt `TEE/…` model runs inside a Trusted Execution Environment and
;;; exposes an attestation + a per-response signature
;;; (docs.nano-gpt.com/api-reference/tee-verification). Selecting a TEE slug
;;; ROUTES into the enclave; it does not, by itself, PROVE the answer you got
;;; came from one. `tee-verify` establishes that binding:
;;;
;;;   1. GET /tee/attestation?model=…&nonce=N  → signing_address (Ethereum-style),
;;;      the echoed nonce, and the hardware attestation (nvidia_payload/intel_quote).
;;;   2. the chat completion's top-level "id" is the request id (from do-completion*).
;;;   3. GET /tee/signature/{id}?model=…&signing_algo=ecdsa
;;;         → text (the signed message), signature (hex), signing_address.
;;;   4. checks: text == OUR content · sig.signing_address == attestation.signing_address
;;;      · nonce echoed · attestation non-empty · THEN recover the signer from
;;;      (text, signature) and require it == signing_address.
;;;
;;; The consistency checks (1–4 up to the recovery) run here in Guile: they bind
;;; the signature to our EXACT output and to the attested enclave key, and block
;;; replay. The final CRYPTOGRAPHIC step — Ethereum personal_sign ecrecover
;;; (keccak256 + secp256k1 pubkey recovery) — is implemented in pure Guile in
;;; (playnet ai tee-crypto) `tee-verify-ecdsa`, validated against canonical
;;; vectors (tests/planner/test-tee-crypto.scm), and is the DEFAULT #:verify-ecdsa
;;; here — so client-side enforcement is ON: under policy 'enforce a TEE response
;;; whose signature does not recover to the attested enclave address is REJECTED.
;;; The seam stays injectable: pass #:verify-ecdsa %ecdsa-unwired to fail closed
;;; without crypto, or a browser/noble verifier, or a mock in tests.
(define (tee-model? model) (and (string? model) (string-prefix? "TEE/" model)))

;; opt-out sentinel: no cryptographic recovery (always #f → fail-closed).
(define (%ecdsa-unwired text hex-sig expected-addr) #f)

(define* (tee-verify key-pool model request-id content
                     #:key (verify-ecdsa tee-verify-ecdsa) (nonce #f)
                           (verify-quote %quote-unverified) (trusted-measurements '()))
  "Fetch + check a TEE model's attestation and per-response signature. Returns a
   verdict alist ((ok . BOOL) (reason . STR|#f) (signing-address . STR|#f)).
   VENDOR ROOTING: when #:verify-quote is supplied (not the fail-closed default)
   or #:trusted-measurements is non-empty, the attestation is ALSO rooted toward
   the vendor via (playnet ai tee-attestation) — the quote must verify, its
   report_data must commit the signing key, and the measurement must be trusted."
  (let* ((nonce (or nonce (number->string (random 1000000000000000000))))
         (mq    (uri-encode model))
         (att   (json-string->scm
                 ($ key-pool 'request-get
                    (string-append "/tee/attestation?model=" mq
                                   "&nonce=" (uri-encode nonce)))))
         (att-addr  (assoc-ref att "signing_address"))
         (att-nonce (assoc-ref att "nonce"))
         (has-hw    (or (assoc-ref att "nvidia_payload") (assoc-ref att "intel_quote")))
         (root?     (or (not (eq? verify-quote %quote-unverified))
                        (pair? trusted-measurements))))
    (define (fail reason) `((ok . #f) (reason . ,reason) (signing-address . ,att-addr)))
    ;; #f when rooting passes (or isn't requested); a reason string when it fails.
    (define (root-failure)
      (and root?
           (let ((v (verify-attestation att #:verify-quote verify-quote
                                        #:trusted-measurements trusted-measurements)))
             (and (not (assq-ref v 'ok)) (assq-ref v 'reason)))))
    (cond
     ((not (and (string? att-addr) (> (string-length att-addr) 0)))
      (fail "attestation missing signing_address"))
     ((not has-hw) (fail "attestation missing hardware quote (nvidia_payload/intel_quote)"))
     ((and att-nonce (not (equal? att-nonce nonce)))
      (fail "attestation nonce mismatch (possible replay)"))
     ((not (and (string? request-id) (> (string-length request-id) 0)))
      (fail "completion carried no request id"))
     (else
      (let* ((sig      (json-string->scm
                        ($ key-pool 'request-get
                           (string-append "/tee/signature/" (uri-encode request-id)
                                          "?model=" mq "&signing_algo=ecdsa"))))
             (text     (assoc-ref sig "text"))
             (hex-sig  (assoc-ref sig "signature"))
             (sig-addr (assoc-ref sig "signing_address")))
        (cond
         ((not (and (string? text) (string? hex-sig) (string? sig-addr)))
          (fail "signature response incomplete"))
         ((not (equal? sig-addr att-addr))
          (fail "signer address does not match the attested enclave address"))
         ((not (equal? text content))
          (fail "signed text does not match our completion content"))
         ((not (verify-ecdsa text hex-sig sig-addr))
          (fail (if (eq? verify-ecdsa %ecdsa-unwired)
                    "ecdsa-recovery-not-wired"
                    "ecdsa recovery did not match signing_address")))
         ((root-failure) => fail)             ; vendor rooting, when requested
         (else `((ok . #t) (reason . #f) (signing-address . ,att-addr)))))))))

(define* (verified-completion key-pool messages-vec model
                              #:key (verify-ecdsa tee-verify-ecdsa) (policy 'enforce) (nonce #f)
                                    (verify-quote %quote-unverified) (trusted-measurements '()))
  "do-completion + TEE verification. Returns (values CONTENT VERDICT); VERDICT is
   #f for a non-TEE model or policy 'off. POLICY: 'enforce (a TEE verdict with
   ok=#f RAISES), 'observe (return the verdict, never raise), 'off (skip).
   #:verify-quote / #:trusted-measurements enable vendor rooting (see tee-verify)."
  (call-with-values (lambda () (do-completion* key-pool messages-vec model))
    (lambda (content id)
      (if (or (eq? policy 'off) (not (tee-model? model)))
          (values content #f)
          (let ((verdict (tee-verify key-pool model id content
                                     #:verify-ecdsa verify-ecdsa #:nonce nonce
                                     #:verify-quote verify-quote
                                     #:trusted-measurements trusted-measurements)))
            (when (and (eq? policy 'enforce) (not (assoc-ref verdict 'ok)))
              (error "TEE verification failed:" (assoc-ref verdict 'reason) model))
            (values content verdict))))))

;;; llm-completer — a plain (prompt → text) thunk over a key-pool, the shape a
;;; text-in/text-out caller wants (e.g. the legal-statute extractor's legal/scrape.scm
;;; #:complete seam). It curries a system prompt + model onto do-completion and
;;; keeps that module's vat contract: the KEY-POOL must be reachable synchronously,
;;; so run the thunk inside the pool's vat — (with-vat pool-vat (… (completer p) …)).
;;; Reuses the key-pool's provider selection / rotation / health / private
;;; (nano-gpt) provider, so callers never hand-roll an HTTP or CLI transport.
;;; With #:verify? #t and a TEE model, each completion is TEE-verified before its
;;; text is returned (see verified-completion / tee-verify) — #:policy and
;;; #:verify-ecdsa pass straight through. The verdict is discarded here (the thunk
;;; is text-in/text-out); under the default 'enforce a failed verdict RAISES.
(define* (llm-completer key-pool #:key (system #f) (model #f)
                        (verify? #f) (policy 'enforce) (verify-ecdsa tee-verify-ecdsa))
  (lambda (prompt)
    (let ((messages (if system
                        (vector `((role . "system") (content . ,system))
                                `((role . "user")   (content . ,prompt)))
                        (vector `((role . "user")   (content . ,prompt))))))
      (if verify?
          (call-with-values
            (lambda () (verified-completion key-pool messages model
                         #:policy policy #:verify-ecdsa verify-ecdsa))
            (lambda (content verdict) content))
          (do-completion key-pool messages model)))))
