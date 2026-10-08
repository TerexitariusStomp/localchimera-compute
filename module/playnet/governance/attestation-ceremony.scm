;;; attestation-ceremony.scm — the k-of-n vouching ritual, once.
;;;
;;; Enrollment (a PHC needs k humans who met the candidate) and witnessed work
;;; events (a claim on the commons needs k parties who saw the work) are ONE
;;; ceremony: a statement-SAID witnesses sign, an eligibility rule for who may,
;;; a threshold, and an issuance when it is met. What differs is injected —
;;; the statement, the rule, and what FINALIZE mints:
;;;
;;;   enrollment   issues a PHC carrying each witness as an NI2I EDGE
;;;                (a walkable vouch chain — audit who vouched for whom)
;;;   work events  attach the attestations as the multisig BLOCK
;;;                (a threshold check — cred-multisig-valid? in one call)
;;;
;;; The collected alist (witness-aid . sig-qb64) is BOTH at once: it is
;;; verbatim the multisig block shape, and the edge-builder maps over it. One
;;; ritual, two encodings of its outcome.
;;;
;;; The actor is also the ASYNC form remote witnessing needs: a signature
;;; arriving over any transport — the /multisig/exn routes and ipex-policy
;;; registry stand in governance/keri/notifications.scm — lands as ($ ceremony 'attest
;;; aid sig), across as many turns as the network takes. `collecting` is the
;;; whole state machine a round-trip requires.
;;;
;;; Included fragment — imports come from (playnet governance). Precedes
;;; enrollment-ceremony.scm, which is this actor with enrollment's three
;;; specifics injected.

(define-module (playnet governance attestation-ceremony)
  #:use-module (playnet keri citizen-sig)
  #:use-module (playnet utils boot-cell)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (^attestation-ceremony *attestation-ceremonies*
            register-attestation-ceremony! attestation-ceremony-for
            land-witness-attestation! witness-attest-handler
            current-aid-key-resolver))

;; ── Resolving a witness's SIGNING key ───────────────────────────────────────
;;
;; verify-said-signature decodes the key straight out of a D/B AID prefix.
;; A browser-born citizen is an E-prefix (ICP digest) — its key lives in
;; the KEL the gateway's oobi-host holds, exactly the two-step the lobby's
;; keri-authenticate already does. The ceremony can't reach that actor
;; (attest runs in the planner vat; the oobi-host lives in the gateway's),
;; so the gateway binds this BOOT CELL to a vat-free resolver over the
;; oobi-host's durable dir: (aid → current signing key qb64 | #f).
;; Unbound, or an AID it doesn't know → verification against the AID
;; itself, the pre-existing D/B behaviour.

(define current-aid-key-resolver (make-boot-cell))

(define (witness-signing-key aid)
  (let ((resolve (current-aid-key-resolver)))
    (or (and resolve (resolve aid)) aid)))

(define-actor (^attestation-ceremony bcom
                                     state          ;; 'collecting | 'finalized | 'abandoned
                                     statement-said ;; what witnesses sign
                                     threshold-k
                                     eligible?      ;; witness-aid → bool | error-msg string
                                     issue!         ;; attestations → issued SAID (or cred)
                                     attestations   ;; alist witness-aid → sig-qb64
                                     finalized      ;; issue!'s result, or #f
                                     #:optional (on-change #f)) ;; (state attestations finalized) → any

  ;; ON-CHANGE, when given, hears every transition after it commits — the
  ;; durable record a ceremony keeps of itself lives outside the actor (an
  ;; enrollment writes its file, work ceremonies keep none), so the ritual
  ;; stays one thing and persistence is the caller's injection.
  (define (rebuild new-state new-atts new-final)
    (when on-change
      (catch #t (lambda () (on-change new-state new-atts new-final)) (lambda _ #f)))
    (^attestation-ceremony bcom new-state statement-said threshold-k
                           eligible? issue! new-atts new-final on-change))

  (methods
    ((status) state)
    ((statement-said) statement-said)
    ((attestation-count) (length attestations))
    ((attesting-witnesses) (map car attestations))
    ((attestations) attestations)
    ((finalized-said) finalized)
    ((threshold) threshold-k)
    ((finalized-phc-said) finalized)          ; enrollment's historical name
    ;; may AID sign this ceremony — the rule, asked without signing, so an
    ;; inbox can say why a chip is dark before anyone taps it
    ((eligible? witness-aid) (eligible? witness-aid))

    ((attest witness-aid signature)
     (unless (eq? state 'collecting)
       (error "attest: ceremony not collecting" state))
     (let ((ok (eligible? witness-aid)))
       (unless (eq? ok #t)
         (error (if (string? ok) ok "attest: witness not eligible") witness-aid)))
     (unless (verify-said-signature statement-said signature
                                    (witness-signing-key witness-aid))
       (error "attest: signature does not verify against witness AID" witness-aid))
     (when (assoc witness-aid attestations)
       (error "attest: witness already attested" witness-aid))
     (let ((new-atts (cons (cons witness-aid signature) attestations)))
       (bcom (rebuild 'collecting new-atts finalized)
             (length new-atts))))

    ((finalize)
     (unless (eq? state 'collecting)
       (error "finalize: wrong state" state))
     (when (< (length attestations) threshold-k)
       (error "finalize: not enough attestations"
              (length attestations) threshold-k))
     (let ((result (issue! attestations)))
       (bcom (rebuild 'finalized attestations result) result)))

    ((abandon)
     (bcom (rebuild 'abandoned attestations finalized)))))

;; ── The landing: a remote signature finds its ceremony ──────────────────────
;;
;; A ceremony is addressed by its statement-SAID — the one identifier both
;; sides already hold, since it is what the witness signed. The registry is a
;; roster of LIVE actors (not stored state: an entry exists exactly while a
;; ceremony collects, and finalization removes it), and the landing is the
;; whole inbound protocol: attest, and finalize the moment quorum is met.

(define *attestation-ceremonies* (make-hash-table))   ; statement-said → ceremony ref

(define (register-attestation-ceremony! said ceremony)
  (hash-set! *attestation-ceremonies* said ceremony))
(define (attestation-ceremony-for said)
  (hash-ref *attestation-ceremonies* said #f))

(define (land-witness-attestation! statement-said witness-aid sig)
  "One remote co-signature, landed: find the collecting ceremony by the SAID
   the witness signed, attest, and — the moment the threshold is met —
   finalize and retire the registry entry. Returns 'finalized, 'attested, or
   #f when no ceremony is collecting under that SAID (a stale or misdirected
   reply lands nowhere, silently: refusal is the default). A bad signature or
   ineligible witness raises exactly as a local attest does — the transport
   earns no leniency."
  (let ((ceremony (attestation-ceremony-for statement-said)))
    (and ceremony
         (let ((n ($ ceremony 'attest witness-aid sig)))
           (if (>= n ($ ceremony 'threshold))
               (begin ($ ceremony 'finalize)
                      (hash-remove! *attestation-ceremonies* statement-said)
                      'finalized)
               'attested)))))

;; The /multisig/exn stitch, registered by the caller that runs a KERIA
;; poller (governance/keri/notifications.scm `register-notification-handler!` — multiple
;; handlers per route, so this rides beside the group-inception handling).
;; The payload convention: the exn's embed carries kind "witness-attest" with
;; the statement said, the witness aid, and the 0B sig. EXTRACT is injected
;; ((said note) → (values statement-said witness-aid sig) or #f) because only
;; the poller's owner knows its KERIA client; the landing above is the whole
;; transport-independent protocol.
(define (witness-attest-handler extract)
  (lambda (route said note)
    (call-with-values (lambda () (extract said note))
      (lambda vals
        (when (and (= 3 (length vals)) (car vals))
          (apply land-witness-attestation! vals))))))
