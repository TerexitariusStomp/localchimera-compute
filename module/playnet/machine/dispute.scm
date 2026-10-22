;;; module/playnet/machine/dispute.scm — the dispute lifecycle (spec §5).
;;;
;;; A receipt is a claim about work; a dispute is what happens when a party
;;; says the claim is false. Two kinds, per the spec's bridge model:
;;;
;;;   'non-delivery  — the claim's deadline passed with no countersigned
;;;                    receipt, or the delivered result never landed. No
;;;                    receipt by the deadline means no payment; the
;;;                    dispute is the record of that fact.
;;;   'wrong-result  — the receipt exists but the result is wrong. PoI
;;;                    replay is authoritative: the challenge carries the
;;;                    receipt digest, reproduced:false, the attestation
;;;                    hash, and the counter-hash the replay produced.
;;;
;;; Review is three sortition-selected hive members — the hive does NOT
;;; re-run the prover; it weighs the evidence the prover (or its absence)
;;; produced. Timelines: 72 hours to raise, four days for review, seven
;;; days to closure. The disputed receipt is retained in full until
;;; closure — hash commitments survive forgetting, plaintext does not.
;;;
;;; WHAT IS HERE:
;;;   • <dispute> — id, claim, challenger, kind, challenge, raised-at,
;;;     state, reviewers, verdicts, outcome.
;;;   • select-reviewers — deterministic sortition: members sorted by
;;;     sha256(dispute-id ∥ member), first three, claim parties excluded.
;;;     Anyone can re-run the sort and check the same three names — a
;;;     selection nobody can argue with and nobody had to trust.
;;;   • dispute-outcome — two of three verdicts decide; 'lapsed when the
;;;     closure deadline passes on an undecided review.
;;;   • the timeline constants.
;;;
;;; The store (^dispute-store, registry.scm) is a shelf beside the
;;; registry — the doors hold the policy.

(define-module (playnet machine dispute)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:use-module (gcrypt hash)
  #:use-module (gcrypt base16)
  #:use-module (rnrs bytevectors)
  #:use-module (playnet machine replay)
  #:export (<dispute> make-dispute dispute?
            dispute-id dispute-claim-id dispute-challenger dispute-kind
            dispute-challenge dispute-raised-at dispute-state
            dispute-reviewers dispute-verdicts dispute-outcome
            select-reviewers dispute-vote dispute-close dispute-open->review
            *challenge-window* *review-window* *closure-window*
            dispute-digest))


;;; ── the timelines (spec §5) ──────────────────────────────────────────────
;;; Seconds: 72h to raise, 4 days of member review, 7 days to closure.

(define *challenge-window* (* 72 3600))
(define *review-window*    (* 4 24 3600))
(define *closure-window*   (* 7 24 3600))


;;; ── the record ───────────────────────────────────────────────────────────

(define-record-type <dispute>
  (%make-dispute id claim-id challenger kind challenge raised-at
                 state reviewers verdicts outcome)
  dispute?
  (id         dispute-id)          ; string — "dispute-<n>-<rand>"
  (claim-id   dispute-claim-id)    ; string — the claim under dispute
  (challenger dispute-challenger)  ; string — who raised it
  (kind       dispute-kind)        ; 'non-delivery | 'wrong-result
  (challenge  dispute-challenge)   ; <challenge> | #f (non-delivery carries none)
  (raised-at  dispute-raised-at)   ; epoch seconds
  (state      dispute-state)       ; 'open | 'in-review | 'closed
  (reviewers  dispute-reviewers)   ; 3 member AIDs, sortition-selected
  (verdicts   dispute-verdicts)    ; alist aid → 'upheld | 'dismissed
  (outcome    dispute-outcome))    ; #f | 'upheld | 'dismissed | 'lapsed

(define* (make-dispute #:key id claim-id challenger kind challenge raised-at
                       (reviewers '()))
  (unless (memq kind '(non-delivery wrong-result))
    (error "dispute: kind is non-delivery or wrong-result" kind))
  (%make-dispute id claim-id challenger kind challenge raised-at
                 'open reviewers '() #f))

(define (dispute-digest d)
  "The evidence commitment: sha256 over the dispute's fields — the digest a
   hive's records carry once the plaintext receipt is forgotten."
  (bytevector->base16-string
   (sha256 (string->utf8
            (format #f "playnet-dispute/v1\0~a\0~a\0~a\0~a\0~a\0"
                    (dispute-id d) (dispute-claim-id d)
                    (dispute-challenger d) (dispute-kind d)
                    (dispute-raised-at d))))))


;;; ── sortition ────────────────────────────────────────────────────────────
;;; Deterministic, reproducible: score each member sha256(seed ∥ member),
;;; sort ascending, take three. The hive does not run the prover — this is
;;; all it does: three names nobody picked.

(define (select-reviewers members seed exclude)
  "From MEMBERS (AID strings), deterministically pick 3 excluding EXCLUDE
   (a list of AIDs — the claim's parties and the challenger)."
  (let* ((pool (filter (lambda (m) (not (member m exclude))) members))
         (scored
          (map (lambda (m)
                 (cons (bytevector->base16-string
                        (sha256 (string->utf8 (string-append seed "\0" m))))
                       m))
               pool))
         (sorted (sort scored (lambda (a b) (string<? (car a) (car b))))))
    (map cdr (list-head sorted (min 3 (length sorted))))))


;;; ── the vote and the close ───────────────────────────────────────────────

(define (dispute-vote d aid verdict)
  "A selected reviewer speaks 'upheld or 'dismissed. Re-voting replaces."
  (unless (memq verdict '(upheld dismissed))
    (error "dispute-vote: verdict is upheld or dismissed" verdict))
  (unless (member aid (dispute-reviewers d))
    (error "dispute-vote: not a selected reviewer" aid))
  (unless (eq? (dispute-state d) 'in-review)
    (error "dispute-vote: not in review"))
  (let* ((verdicts (cons (cons aid verdict)
                         (alist-delete aid (dispute-verdicts d) equal?)))
         (upheld (length (filter (lambda (p) (eq? (cdr p) 'upheld)) verdicts)))
         (dismissed (- (length verdicts) upheld))
         (decided (cond ((>= upheld 2) 'upheld)
                        ((>= dismissed 2) 'dismissed)
                        (else #f))))
    (%make-dispute (dispute-id d) (dispute-claim-id d) (dispute-challenger d)
                   (dispute-kind d) (dispute-challenge d) (dispute-raised-at d)
                   (if decided 'closed 'in-review)
                   (dispute-reviewers d) verdicts (or decided #f))))

(define* (dispute-open->review d members #:key (exclude '()))
  "An open dispute enters review: three sortition-selected members."
  (%make-dispute (dispute-id d) (dispute-claim-id d) (dispute-challenger d)
                 (dispute-kind d) (dispute-challenge d) (dispute-raised-at d)
                 'in-review
                 (select-reviewers members (dispute-id d) exclude)
                 '() #f))

(define* (dispute-close d #:key (now #f) (current-time (lambda () 0)))
  "Deadline bookkeeping: a review past the closure window lapses."
  (let ((now (or now (current-time))))
    (if (and (not (eq? (dispute-state d) 'closed))
             (> (- now (dispute-raised-at d)) *closure-window*))
        (%make-dispute (dispute-id d) (dispute-claim-id d) (dispute-challenger d)
                       (dispute-kind d) (dispute-challenge d)
                       (dispute-raised-at d) 'closed
                       (dispute-reviewers d) (dispute-verdicts d) 'lapsed)
        d)))
