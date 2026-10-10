;;; module/playnet/economy/acceptance.scm — the economy methods of a scope: a socialization grant and a reimbursement claim accepted.
;;;
;;; A fragment of the scope actor (playnet scope actor): a procedure from the
;;; actor's context to the doors it serves, composed into every scope by
;;; (playnet boot scope). `with-scope-ctx` binds the actor's fields and helpers
;;; under their own names, so each clause reads as it did inside the actor
;;; (docs/planning/codebase-layout.md §5).

(define-module (playnet economy acceptance)
  #:use-module (srfi srfi-1)
  #:use-module (playnet keri first-person predicates)
  #:use-module (playnet credentials commitments)
  #:use-module (playnet credentials custody)
  #:use-module (playnet keri acdc)
  #:use-module ((playnet economy debts) #:select (debt-commitment))
  #:use-module ((playnet economy socialization) #:select (member-consume-grant-total member-consume-grant-over))
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (playnet scope actor)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (scope-acceptance-doors))

(define (scope-acceptance-doors ctx)
  (with-scope-ctx ctx
    (declared-doors scope

    ((accept-socialization gov-cap grant-said . opts)
     ;; The commune's BILATERAL consent to an owner's temporary-socialization
     ;; grant (a custody attestation an owner issued crediting this commune).
     ;; Only the commune, through its OWN gov-cap, can commit the commune — so
     ;; the consent is minted HERE, gov-cap-gated and scope-SIGNED, not fabricated
     ;; by the owner. Binds the owner's grant (primary) to the commune's return
     ;; COMMITMENT (reciprocal, always `transfer-custody` — the object comes
     ;; back, never a value substitute; see socialization.scm's grant-consume?
     ;; comment for why a private-repayment loan shape was tried and removed)
     ;; in an Agreement. The return commitment is a real outstanding commitment
     ;; against the spec, so it TRAVELS with custody (transfer-custody #:carries)
     ;; to whoever the plan hands the means to next — each holder accountable
     ;; in turn (social-means: a moving assignment). A bare grant with no care
     ;; terms needs none of this — it is a unilateral gift of use into the pool.
     ;;
     ;; opts (kw-ref): 'contribution (money-spec amount unit due) — a share of
     ;; the lent thing's running cost the commune bears: ONE more reciprocal
     ;; clause, a fixed sum of money due on a date, never a price per use
     ;; (docs/legal/structure.md §5; the records read it as `cost-share`,
     ;; and a sum that tracked the use as `metered-use`, a rent).
     ;; opts (kw-ref): 'ratification SAID — a closed, labour-voice-weighted
     ;; `^ballot`'s ratification naming this exact grant (docs/playnet.typ:
     ;; "producers recognise... weighted by labour-voice"), the same
     ;; optional evidence admit-commune/merge-with/split accept. Optional
     ;; unless this scope's own governance-policy has set
     ;; require-ratification, in which case require-ratification! refuses
     ;; the act without one — see voice/quorum.scm.
     (require-gov-cap! gov-sealed? gov-cap "accept-socialization" name)
     (require-store!   acdc-store    "accept-socialization" name)
     (require-ratification! scope-root-ref acdc-store scope-aid
                            (kw-ref opts 'ratification #f)
                            'accept-socialization grant-said)
     (let ((grant (any-cred-by-said acdc-store grant-said)))
       ;; it must be a custody attestation crediting THIS commune — the commune
       ;; accepts a grant made TO it, not any credential and not one addressed elsewhere.
       (unless (and grant
                    (equal? *schema-playnet-custody-attestation* (cred-schema grant))
                    (equal? scope-aid (cred-holder grant)))
         (error "accept-socialization: not a custody grant to this commune" name grant-said))
       (let* ((owner (cred-issuer grant))
              (spec  (cred-claim grant 'resource-spec))
              (until (cred-claim grant 'valid-until))
              (return-c (make-commitment-credential
                         scope-aid owner (string-append "return-" grant-said)
                         'transfer-custody
                         #:resource-conforms-to spec #:due until
                         #:signing-keypair keypair))
              (contribution (kw-ref opts 'contribution #f))
              (share-c (and contribution
                            (let ((money-spec (list-ref contribution 0))
                                  (amount (list-ref contribution 1))
                                  (unit (list-ref contribution 2))
                                  (due (list-ref contribution 3)))
                              (make-commitment-credential
                               scope-aid owner (string-append "share-" grant-said)
                               'transfer
                               #:resource-conforms-to money-spec
                               #:resource-quantity (cons amount unit) #:due due
                               #:signing-keypair keypair))))
              (agreement (make-agreement-credential
                          scope-aid owner (string-append "agr-" grant-said)
                          #:primary-commitment-ids    (list grant-said)
                          #:reciprocal-commitment-ids (append (list (cred-said return-c))
                                                              (if share-c (list (cred-said share-c)) '()))
                          #:accepted-at (iso-utc-now)
                          #:signing-keypair keypair)))
         ;; idempotent: the ids are deterministic from the grant, so re-accepting
         ;; is a no-op rather than a duplicate.
         ($ acdc-store 'issue-idempotent return-c)
         (when share-c ($ acdc-store 'issue-idempotent share-c))
         ($ acdc-store 'issue-idempotent agreement)
         (cred-said agreement))))

    ((accept-reimbursement gov-cap claim-said . opts)
     ;; The reimbursement acceptance, in the VF Claim shape (docs/valueflows
     ;; examples, "Claim for income"): the member's own signed purchase-claim
     ;; (economy/debts.scm purchase-claim, client-signed via the same
     ;; ceremony socialize-preimage/-signed uses) attests a PAST fact — "I
     ;; gave the commons this" — so the commune's reciprocal debt is
     ;; TRIGGERED BY it (the debt carries `triggered-by` = the claim's SAID)
     ;; rather than bound in an Agreement, which VF reserves for connecting
     ;; reciprocal PROMISES (accept-socialization's case: a grant offer and
     ;; a return commitment, both forward-looking). One credential minted,
     ;; the provenance on it. Only the commune, through its OWN gov-cap, may
     ;; commit itself to owing anything back — so the debt is minted HERE,
     ;; gov-cap-gated and scope-signed; the claim already exists,
     ;; member-signed, never fabricated by governance.
     ;;
     ;; FUNDING SOURCE (docs/planning/socialization/reimbursement-funding-source.md):
     ;;   - a claim NAMING the resource that paid (resource-inventoried-as)
     ;;     is checked exactly: a resource under a live consume-grant to
     ;;     this commune is a self-attested spend of already-socialized
     ;;     money — REFUSED outright, a gift owes nothing back; an
     ;;     ungranted named resource positively clears the coarse flag.
     ;;   - a claim naming nothing falls back to the spec-wide flag
     ;;     (member-consume-grant-total), surfaced in the return value for
     ;;     governance to weigh, never auto-deducted — an unrelated purse
     ;;     and a genuinely-fronted purchase look identical from outside.
     ;;
     ;; Deterministic id from claim-said — re-accepting the same claim is a
     ;; no-op, not a duplicate. Returns (list debt-said flagged-amount).
     ;;
     ;; opts (kw-ref): 'ratification SAID — same evidence and same policy
     ;; gate as accept-socialization above.
     (require-gov-cap! gov-sealed? gov-cap "accept-reimbursement" name)
     (require-store!   acdc-store    "accept-reimbursement" name)
     (require-ratification! scope-root-ref acdc-store scope-aid
                            (kw-ref opts 'ratification #f)
                            'accept-reimbursement claim-said)
     (let ((claim (any-cred-by-said acdc-store claim-said)))
       (unless (and claim
                    (equal? *schema-playnet-commitment* (cred-schema claim))
                    (eq? 'transfer (cred-claim claim 'action))
                    (equal? scope-aid (cred-holder claim)))
         (error "accept-reimbursement: not a purchase claim addressed to this commune" name claim-said))
       (let* ((member (cred-issuer claim))
              (spec   (cred-claim claim 'resource-conforms-to))
              (rq     (cred-claim claim 'resource-quantity))
              (qty    (and (pair? rq) (car rq)))
              (unit   (and (pair? rq) (cdr rq)))
              (due    (cred-claim claim 'due))
              (rid    (cred-claim claim 'resource-inventoried-as)))
         (when (and rid (member-consume-grant-over acdc-store member scope-aid rid spec))
           (error "accept-reimbursement: the claim names a resource already consume-granted to this commune — socialized money owes nothing back" claim-said))
         (let ((flagged (if rid 0 (member-consume-grant-total acdc-store member spec)))
               (debt    (debt-commitment scope-aid member (string-append "repay-" claim-said)
                                         spec qty unit due
                                         #:triggered-by claim-said
                                         #:signing-keypair keypair)))
           ($ acdc-store 'issue-idempotent debt)
           (list (cred-said debt) flagged))))))))
