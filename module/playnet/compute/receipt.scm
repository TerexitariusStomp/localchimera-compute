;;; compute/receipt.scm — a receipt is an event whose digest a hive can replay.
;;;
;;; WHAT THE FILE HOLDS. The SignedReceipt as a wire record, the canonical
;;; digest both signatures cover, and the fold into <economic-event>. The
;;; digest is byte-identical to poi-compute's `receiptCanonical` in
;;; packages/hive-bridge/src/receipt-translate.ts — same domain separator,
;;; same field order, same JSON.stringify bytes — so a receipt signed by a
;;; hive node and one assembled here hash to the same commitment. The golden
;;; vectors in tests/compute/test-receipt.scm are produced by the TypeScript
;;; and held here; if either side changes canonicalization, one suite turns
;;; red and the format fork is visible before it ships.
;;;
;;; Canonical form is `sha256(DOMAIN || json)` where DOMAIN is
;;; "naoms-compute-receipt/v1" + NUL — a separator byte, so no key order or
;;; separator-joining ambiguity can creep in. The `result` plaintext is NOT
;;; in the digest: the commitment is to `outputHash`, which is what lets a
;;; receipt survive the seven-day forgetting window still verifiable.
;;;
;;; `usage` and `repro` are null when absent (the literal emits them, JS
;;; undefineds are dropped only INSIDE sub-objects — the asymmetry is load-
;;; bearing and the vectors pin it). A preempted outcome is a receipt with
;;; state "preempted": recorded, unpaid, not a miss (naoms-compute.md §10).

(define-module (playnet compute receipt)
  #:use-module (playnet vf schemas)
  #:use-module (playnet compute specs)
  #:use-module (gcrypt hash)
  #:use-module (gcrypt base16)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 format)
  #:export (<usage-meter> make-usage-meter usage-meter? usage-meter-unit usage-meter-amount
            <repro-spec> make-repro-spec repro-spec? repro-spec-mode
            repro-spec-seed repro-spec-decoding repro-spec-engine-version
            <receipt> make-receipt receipt?
            receipt-bridge-job-id receipt-lender-did receipt-input-hash receipt-output-hash
            receipt-engine receipt-usage receipt-repro receipt-executed-at
            receipt-lender-sig receipt-borrower-sig receipt-digest-field
            receipt-canonical receipt-digest receipt-digest-ok?
            receipt->event))


;;; ── the wire records ────────────────────────────────────────────────────

(define-record-type <usage-meter>
  (%make-usage-meter unit amount)
  usage-meter?
  (unit    usage-meter-unit)     ; "tokens" | "seconds"
  (amount  usage-meter-amount))  ; number

(define* (make-usage-meter #:key unit amount)
  (unless (member unit '("tokens" "seconds"))
    (error "usage-meter: unit must be tokens or seconds" unit))
  (%make-usage-meter unit amount))

(define-record-type <repro-spec>
  (%make-repro-spec mode seed decoding engine-version)
  repro-spec?
  (mode           repro-spec-mode)            ; 'exact | 'deterministic | 'none
  (seed           repro-spec-seed)            ; number | #f
  (decoding       repro-spec-decoding)        ; string | #f
  (engine-version repro-spec-engine-version)) ; string | #f

(define* (make-repro-spec #:key mode (seed #f) (decoding #f) (engine-version #f))
  (unless (repro-mode? mode)
    (error "repro-spec: not a repro mode" mode))
  (%make-repro-spec mode seed decoding engine-version))

(define-record-type <receipt>
  (%make-receipt bridge-job-id lender-did input-hash output-hash
                 engine usage repro executed-at
                 lender-sig borrower-sig digest-field)
  receipt?
  (bridge-job-id  receipt-bridge-job-id)
  (lender-did     receipt-lender-did)
  (input-hash     receipt-input-hash)
  (output-hash    receipt-output-hash)
  (engine         receipt-engine)          ; string | #f
  (usage          receipt-usage)           ; <usage-meter> | #f
  (repro          receipt-repro)           ; <repro-spec> | #f
  (executed-at    receipt-executed-at)     ; integer, epoch ms
  (lender-sig     receipt-lender-sig)      ; string | #f until signed
  (borrower-sig   receipt-borrower-sig)    ; string | #f until countersigned
  (digest-field   receipt-digest-field))   ; string | #f — claimed digest

(define* (make-receipt #:key bridge-job-id lender-did input-hash output-hash
                       (engine #f) (usage #f) (repro #f) executed-at
                       (lender-sig #f) (borrower-sig #f) (digest-field #f))
  (%make-receipt bridge-job-id lender-did input-hash output-hash
                 engine usage repro executed-at
                 lender-sig borrower-sig digest-field))


;;; ── the canonical JSON, byte-exact to JSON.stringify ────────────────────
;;;
;;; Rules that matter: compact separators; strings escape `"`, `\`, and C0
;;; controls (\b \f \n \r \t short forms, the rest \u00xx lowercase);
;;; non-ASCII passes through as UTF-8 (TextEncoder does the same on the JS
;;; side); numbers print as JSON.stringify prints them — integers plain.
;;; Fractional inexact numbers print via number->string, which agrees with
;;; JS's shortest-round-trip for ordinary decimals; metering that needs
;;; arbitrary precision should stay exact-integers (the vectors do).

(define (json-escape s)
  (call-with-output-string
    (lambda (out)
      (string-for-each
        (lambda (c)
          (let ((n (char->integer c)))
            (cond ((char=? c #\")   (display "\\\"" out))
                  ((char=? c #\\)   (display "\\\\" out))
                  ((char=? c #\backspace) (display "\\b" out))
                  ((char=? c #\page)      (display "\\f" out))
                  ((char=? c #\newline)   (display "\\n" out))
                  ((char=? c #\return)    (display "\\r" out))
                  ((char=? c #\tab)       (display "\\t" out))
                  ((< n #x20) (format out "\\u~4,'0x" n))
                  (else (write-char c out)))))
        s))))

(define (json-number n)
  (cond ((integer? n) (number->string (inexact->exact n)))
        (else (number->string (exact->inexact n)))))

(define (json-value v)
  (cond ((eq? v 'null)   "null")
        ((string? v)     (string-append "\"" (json-escape v) "\""))
        ((number? v)     (json-number v))
        ((list? v)       (json-object v))   ; an alist is a nested object
        (else (error "json-value: unsupported" v))))

(define (json-object pairs)
  ;; pairs: ((key . value) ...) in emission order — order IS the format.
  (string-append "{"
    (string-join (map (lambda (p)
                        (string-append "\"" (car p) "\":" (json-value (cdr p))))
                      pairs)
                 ",")
    "}"))

(define (usage->pairs u)
  `(("unit"   . ,(usage-meter-unit u))
    ("amount" . ,(usage-meter-amount u))))

(define (repro->pairs r)
  ;; Optional fields emit ONLY when present — JSON.stringify drops undefined.
  (filter-map
    (lambda (p) (and (cdr p) p))
    `(("mode"          . ,(symbol->string (repro-spec-mode r)))
      ("seed"          . ,(repro-spec-seed r))
      ("decoding"      . ,(repro-spec-decoding r))
      ("engineVersion" . ,(repro-spec-engine-version r)))))

(define (receipt-canonical r)
  ;; Field order is the wire format. `result` is intentionally absent —
  ;; the commitment is to outputHash, so the digest is identical after
  ;; forgetting.
  (json-object
    `(("bridgeJobId" . ,(receipt-bridge-job-id r))
      ("lenderDid"   . ,(receipt-lender-did r))
      ("inputHash"   . ,(receipt-input-hash r))
      ("outputHash"  . ,(receipt-output-hash r))
      ("engine"      . ,(or (receipt-engine r) 'null))
      ("usage"       . ,(if (receipt-usage r)
                            (usage->pairs (receipt-usage r))
                            'null))
      ("repro"       . ,(if (receipt-repro r)
                            (repro->pairs (receipt-repro r))
                            'null))
      ("executedAt"  . ,(receipt-executed-at r)))))

(define *receipt-domain* (string-append "naoms-compute-receipt/v1" (string #\nul)))

(define (receipt-digest r)
  (string-downcase
    (bytevector->base16-string
      (sha256 (string->utf8 (string-append *receipt-domain*
                                           (receipt-canonical r)))))))

(define (receipt-digest-ok? r)
  "The digest a receipt CLAIMS is the digest its body produces."
  (equal? (receipt-digest-field r) (receipt-digest r)))


;;; ── the fold into an event ──────────────────────────────────────────────
;;;
;;; A receipt is a `use` event: borrowed capacity — the machine stays the
;;; lender's, only its time crosses. provider is the lender's DID; receiver
;;; is the scope the job ran for. `usage` meters the resource-quantity in
;;; its own unit (tokens or seconds); effort-quantity stays unstated until
;;; a receipt learns to carry both. `state` is the SubmitOutcome —
;;; "accepted" or "preempted" — so a fold can pay the first and only record
;;; the second.

(define* (receipt->event r #:key scope-id spec-id commitment-id intent-id
                         (state "accepted"))
  (make-economic-event
    #:id (receipt-digest r)
    #:action 'use
    #:provider (receipt-lender-did r)
    #:receiver scope-id
    #:resource-conforms-to spec-id
    #:resource-quantity (and (receipt-usage r)
                             (make-measure (usage-meter-amount (receipt-usage r))
                                           (usage-meter-unit (receipt-usage r))))
    #:has-point-in-time
      (strftime "%Y-%m-%dT%H:%M:%SZ"
                (gmtime (quotient (receipt-executed-at r) 1000)))
    #:fulfills commitment-id
    #:satisfies intent-id
    #:in-scope-of (if scope-id (list scope-id) '())
    #:state state
    #:note "naoms-compute-receipt/v1"))
