;;; module/playnet/ai/tee-attestation.scm — root a nano-gpt TEE response toward
;;; the hardware vendor, one honest layer past the response signature.
;;;
;;; tee-crypto.scm proves "the response was signed by KEY K." This module answers
;;; the next two questions:
;;;   (a) is K genuinely bound to a real enclave? — the attestation QUOTE
;;;       (Intel TDX DCAP `intel_quote` / NVIDIA CC `nvidia_payload`) must
;;;       cryptographically commit K in its report_data AND chain to the vendor
;;;       root CA with an acceptable measurement + TCB.
;;;   (b) is it the SAME enclave as before? — continuity / pinning, which catches
;;;       a provider silently swapping the enclave or key between calls.
;;;
;;; WHAT IS HERE (real, testable, no vendor format needed):
;;;   • normalize-attestation — extract kind + signer + payload from the JSON.
;;;   • verify-attestation    — the rooting ORCHESTRATION: presence → vendor quote
;;;       (injected) → report_data binds the signing key → measurement allowlist.
;;;   • pins-*                — enclave-identity pinning (TOFU + change detection),
;;;       persisted on disk in the same s-expr pack idiom as the legal registry.
;;;
;;; WHAT IS AN INJECTED SEAM (fail-closed default `%quote-unverified`):
;;;   • verify-quote : raw-payload -> ((measurement . HEX) (report-data . HEX)) | #f
;;;     The Intel-DCAP / NVIDIA-NRAS parser + ECDSA-P256 + PCK/device cert chain to
;;;     the vendor root + TCB check. It is DELIBERATELY not implemented against a
;;;     guessed binary layout: it needs the vendor root certs + TCB collateral and
;;;     a REAL sample payload (a live nano-gpt TEE call) to build and test
;;;     correctly. Everything above it is exercised here by injecting a stub quote.

(define-module (playnet ai tee-attestation)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (normalize-attestation
            attestation-present?
            %quote-unverified
            report-data-binds?
            verify-attestation
            empty-pins pins-check pins-add
            save-enclave-pins load-enclave-pins))

;;; ─── normalize the attestation JSON (already parsed to a string-keyed alist) ─
(define (norm-hex s)
  (and (string? s)
       (string-downcase (if (and (>= (string-length s) 2) (string=? (substring s 0 2) "0x"))
                            (substring s 2) s))))

(define (normalize-attestation att)
  (let ((iq (assoc-ref att "intel_quote"))
        (nv (assoc-ref att "nvidia_payload"))
        (addr (assoc-ref att "signing_address"))
        (nonce (assoc-ref att "nonce")))
    (let ((payload (or (and (string? iq) (> (string-length iq) 0) iq)
                       (and (string? nv) (> (string-length nv) 0) nv))))
      `((kind . ,(cond ((and (string? iq) (> (string-length iq) 0)) 'intel-tdx)
                       ((and (string? nv) (> (string-length nv) 0)) 'nvidia-cc)
                       (else 'none)))
        (signing-address . ,addr)
        (nonce   . ,nonce)
        (payload . ,payload)
        (present? . ,(and payload (string? addr) (> (string-length addr) 0) #t))))))

(define (attestation-present? rec) (assq-ref rec 'present?))

;;; ─── the vendor-quote seam (fail-closed default) ───────────────────────────
;; A verifier: raw-payload -> ((measurement . HEX) (report-data . HEX)) | #f.
;; #f means "did not verify" (bad signature / broken chain / bad TCB). The real
;; Intel-DCAP / NVIDIA-NRAS verifier drops in here; the default refuses.
(define (%quote-unverified payload) #f)

;; report_data must commit the signing key. The exact commitment convention is
;; enclave-specific and MUST be confirmed against a real quote; the default is a
;; lenient containment check (the 20-byte address appears in the 64-byte
;; report_data), overridable via #:binds? for a strict hash-equality rule.
(define (report-data-binds? report-data address)
  (let ((rd (norm-hex report-data)) (a (norm-hex address)))
    (and rd a (string-contains rd a) #t)))

;;; ─── the rooting orchestration (pure; vendor crypto injected) ──────────────
(define* (verify-attestation att
                             #:key (verify-quote %quote-unverified)
                                   (trusted-measurements '())   ; '() = accept + report (TOFU)
                                   (binds? report-data-binds?)
                                   (require-binding? #t))
  "Root an attestation toward the vendor. Returns a verdict alist:
   ((ok . BOOL) (reason . STR|#f) (kind . SYM) (measurement . HEX|#f)
    (signing-address . STR|#f))."
  (let* ((rec  (normalize-attestation att))
         (kind (assq-ref rec 'kind))
         (addr (assq-ref rec 'signing-address))
         (payload (assq-ref rec 'payload)))
    (define (fail r) `((ok . #f) (reason . ,r) (kind . ,kind)
                       (measurement . #f) (signing-address . ,addr)))
    (cond
     ((not (attestation-present? rec))
      (fail "attestation missing payload or signing_address"))
     (else
      (let ((vq (verify-quote payload)))
        (cond
         ((not vq)
          (fail (if (eq? verify-quote %quote-unverified)
                    "vendor-quote-verifier-not-wired"
                    "vendor quote did not verify (signature / cert chain / TCB)")))
         (else
          (let ((meas (assq-ref vq 'measurement))
                (rd   (assq-ref vq 'report-data)))
            (cond
             ((and require-binding? (not (binds? rd addr)))
              (fail "attestation report_data does not commit the signing key"))
             ((and (pair? trusted-measurements)
                   (not (member (norm-hex meas) (map norm-hex trusted-measurements))))
              (fail "enclave measurement is not in the trusted set"))
             (else `((ok . #t) (reason . #f) (kind . ,kind)
                     (measurement . ,meas) (signing-address . ,addr))))))))))))

;;; ─── enclave-identity pinning (continuity / TOFU) ──────────────────────────
;; pins : alist of  model -> ((address . A) (measurement . M|#f))
(define empty-pins '())

(define (pins-check pins model address measurement)
  "→ 'ok | 'unpinned | 'address-changed | 'measurement-changed"
  (let ((p (assoc-ref pins model)))
    (cond ((not p) 'unpinned)
          ((not (equal? (norm-hex (assoc-ref p 'address)) (norm-hex address)))
           'address-changed)
          ((and measurement (assoc-ref p 'measurement)
                (not (equal? (norm-hex (assoc-ref p 'measurement)) (norm-hex measurement))))
           'measurement-changed)
          (else 'ok))))

(define (pins-add pins model address measurement)   ; functional upsert
  (cons (cons model `((address . ,address) (measurement . ,measurement)))
        (filter (lambda (e) (not (equal? (car e) model))) pins)))

(define (save-enclave-pins path pins)
  (call-with-output-file path
    (lambda (port) (write pins port) (newline port))))

(define (load-enclave-pins path)
  (if (file-exists? path)
      (call-with-input-file path read)
      empty-pins))
