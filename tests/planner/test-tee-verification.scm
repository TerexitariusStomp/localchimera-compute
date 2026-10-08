;;; test-tee-verification.scm — TEE (confidential-enclave) response verification.
;;;
;;; Proves the client-side check that turns "we asked nano-gpt for a TEE/ model"
;;; into "we verified the answer is bound to an attested enclave." Only the HTTP
;;; endpoints are mocked — a fake key-pool answers the chat-completions POST and
;;; the two TEE GETs (/tee/attestation, /tee/signature/{id}) with canned JSON —
;;; so nothing hits the network, yet the whole verification control-flow runs:
;;;   completion(id) → attestation(signing_address,nonce,hw) → signature(text,sig,addr)
;;;   → checks: text==our content · signer==attested addr · nonce echoed · ecrecover.
;;;
;;; The cryptographic ecrecover (keccak256+secp256k1) is INJECTABLE (#:verify-ecdsa);
;;; the default (%ecdsa-unwired) is fail-closed, which we also assert. Everything
;;; runs inside (with-vat vat …) because the mock key-pool is a synchronous
;;; near-call there.
;;;
;;; Run: guile -L module tests/planner/test-tee-verification.scm

(use-modules (playnet test harness)
             (goblins) (goblins vat) (goblins actor-lib methods)
             (playnet ai llm) (json)
             (srfi srfi-1) (srfi srfi-13) (ice-9 format))

;;; ─── a fake key-pool: canned JSON per endpoint, set per-test ───────────────
(define *chat* #f) (define *att* #f) (define *sig* #f)
(define (^mock _bcom)
  (methods
   ((request path body) *chat*)                    ; POST /chat/completions
   ((request-get path)                             ; GET  /tee/...
    (cond ((string-contains path "attestation") *att*)
          ((string-contains path "signature")   *sig*)
          (else "{}")))))

;;; JSON builders matching nano-gpt's documented shapes.
(define* (mk-chat #:key (id "req-1") (content "RESULT"))
  (scm->json-string
   `(("id" . ,id)
     ("choices" . #((("message" . (("content" . ,content)))))))))
(define* (mk-att #:key (addr "0xENCLAVE") (nonce #f) (hw "nvidia-payload-b64"))
  (scm->json-string
   `(,@(if nonce `(("nonce" . ,nonce)) '())
     ("signing_address" . ,addr)
     ,@(if hw `(("nvidia_payload" . ,hw)) '()))))
(define* (mk-sig #:key (text "RESULT") (signature "0xSIGHEX") (addr "0xENCLAVE"))
  (scm->json-string
   `(("text" . ,text) ("signature" . ,signature) ("signing_address" . ,addr))))

(define ACCEPT (lambda (text hex addr) #t))       ; a stand-in real recoverer
(define REJECT (lambda (text hex addr) #f))

(define vat (spawn-vat))
(define* (verify #:key (model "TEE/gpt-oss-120b") (verify-ecdsa %ecdsa-unwired) (nonce "N1"))
  (with-vat vat
    (let ((pool (spawn ^mock)))
      (tee-verify pool model "req-1" "RESULT" #:verify-ecdsa verify-ecdsa #:nonce nonce))))
(define (ok? v)     (assoc-ref v 'ok))
(define (reason v)  (assoc-ref v 'reason))

;;; ─── 1. happy path : consistent + a passing recoverer → verified ──────────
(set! *att* (mk-att #:addr "0xENCLAVE" #:nonce "N1"))
(set! *sig* (mk-sig #:text "RESULT" #:addr "0xENCLAVE"))
(display "\n── a fully consistent, recovered TEE response verifies ──\n")
(let ((v (verify #:verify-ecdsa ACCEPT)))
  (format #t "  verdict: ~s\n" v)
  (check "matching addr + text + nonce + a passing ecrecover → ok" (ok? v) #t)
  (check "…and it reports the attested signer address" (assoc-ref v 'signing-address) "0xENCLAVE"))

;;; ─── 2. the DEFAULT recoverer is fail-closed ──────────────────────────────
(display "\n── the default (unwired) ecrecover fails closed, even when consistent ──\n")
(let ((v (verify)))                                ; verify-ecdsa = %ecdsa-unwired
  (check "consistent but no real recoverer → ok=#f" (ok? v) #f)
  (check "…with an honest reason, not a fake pass" (reason v) "ecdsa-recovery-not-wired"))

;;; ─── 3. signer address ≠ attested enclave address → reject ────────────────
(set! *sig* (mk-sig #:text "RESULT" #:addr "0xIMPOSTOR"))
(display "\n── a signer that isn't the attested enclave is rejected ──\n")
(let ((v (verify #:verify-ecdsa ACCEPT)))
  (check "signer ≠ attested address → ok=#f" (ok? v) #f)
  (check-pred "…reason names the address mismatch"
              (string-contains (reason v) "attested enclave address")))

;;; ─── 4. signed text ≠ our content → reject (response substitution) ────────
(set! *sig* (mk-sig #:text "SOMETHING ELSE" #:addr "0xENCLAVE"))
(display "\n── a signature over different text than we received is rejected ──\n")
(let ((v (verify #:verify-ecdsa ACCEPT)))
  (check "signed text ≠ our content → ok=#f" (ok? v) #f)
  (check-pred "…reason names the text mismatch"
              (string-contains (reason v) "completion content")))

;;; ─── 5. attestation missing the hardware quote → reject ───────────────────
(set! *att* (mk-att #:addr "0xENCLAVE" #:nonce "N1" #:hw #f))
(set! *sig* (mk-sig))
(display "\n── attestation without a hardware quote is rejected ──\n")
(let ((v (verify #:verify-ecdsa ACCEPT)))
  (check "no nvidia_payload/intel_quote → ok=#f" (ok? v) #f)
  (check-pred "…reason names the missing quote" (string-contains (reason v) "hardware quote")))

;;; ─── 6. nonce not echoed → replay suspected → reject ──────────────────────
(set! *att* (mk-att #:addr "0xENCLAVE" #:nonce "STALE"))
(set! *sig* (mk-sig))
(display "\n── an attestation nonce that isn't the one we sent is rejected ──\n")
(let ((v (verify #:verify-ecdsa ACCEPT #:nonce "N-FRESH")))
  (check "echoed nonce ≠ sent nonce → ok=#f" (ok? v) #f)
  (check-pred "…reason names replay" (string-contains (reason v) "replay")))

;;; ─── 7. verified-completion : 'enforce RAISES on a bad verdict ────────────
(set! *chat* (mk-chat #:content "RESULT"))
(set! *att*  (mk-att #:addr "0xENCLAVE"))
(set! *sig*  (mk-sig #:addr "0xIMPOSTOR"))          ; will fail the address check
(display "\n── verified-completion under 'enforce refuses a bad TEE response ──\n")
(define enforce-raised
  (with-vat vat
    (catch #t
      (lambda ()
        (verified-completion (spawn ^mock)
          (vector `((role . "user") (content . "hi"))) "TEE/gpt-oss-120b"
          #:verify-ecdsa ACCEPT #:policy 'enforce)
        #f)
      (lambda _ #t))))
(check "'enforce raises when the enclave binding fails" enforce-raised #t)

;;; ─── 8. 'observe returns the verdict without raising ──────────────────────
(display "\n── 'observe returns content + a failing verdict, no raise ──\n")
(define observe-out
  (with-vat vat
    (call-with-values
      (lambda () (verified-completion (spawn ^mock)
                   (vector `((role . "user") (content . "hi"))) "TEE/gpt-oss-120b"
                   #:verify-ecdsa ACCEPT #:policy 'observe))
      list)))
(check "'observe still returns the content" (first observe-out) "RESULT")
(check "'observe surfaces ok=#f rather than raising" (ok? (second observe-out)) #f)

;;; ─── 9. a NON-TEE model skips verification (no verdict, plain content) ────
(display "\n── a non-TEE model is not verified — verdict #f, content passes through ──\n")
(define plain-out
  (with-vat vat
    (call-with-values
      (lambda () (verified-completion (spawn ^mock)
                   (vector `((role . "user") (content . "hi"))) "openai/gpt-4o-mini"
                   #:policy 'enforce))
      list)))
(check "non-TEE model → content returned" (first plain-out) "RESULT")
(check "non-TEE model → no verdict (#f)" (second plain-out) #f)

;;; ─── 10. happy path through verified-completion end-to-end ────────────────
(set! *sig* (mk-sig #:addr "0xENCLAVE"))            ; now consistent again
(display "\n── verified-completion happy path: content + ok verdict ──\n")
(define good-out
  (with-vat vat
    (call-with-values
      (lambda () (verified-completion (spawn ^mock)
                   (vector `((role . "user") (content . "hi"))) "TEE/gpt-oss-120b"
                   #:verify-ecdsa ACCEPT #:policy 'enforce))
      list)))
(check "a fully-verified TEE completion returns its content" (first good-out) "RESULT")
(check "…and an ok verdict" (ok? (second good-out)) #t)

(display "\n")
(test-summary!)
