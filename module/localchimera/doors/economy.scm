;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/doors/economy.scm — the economy doors of the governance service: socialization grants, purchase claims, titles, and a commune accepting them
;;;
;;; A fragment of the governance service (localchimera doors governance): a procedure
;;; from the actor's context to the doors it serves, composed into the service by
;;; (localchimera boot governance). `with-governance-ctx` binds the actor's arguments,
;;; cells and shared helpers under their own names, so each clause reads as it did
;;; inside the actor (docs/planning/codebase-layout.md §5).

(define-module (localchimera doors economy)
  #:use-module (srfi srfi-1)
  #:use-module (localchimera economy socialization)
  #:use-module ((localchimera economy debts) #:select (purchase-claim))
  #:use-module (localchimera keri first-person predicates)
  #:use-module (localchimera keri acdc)
  #:use-module ((localchimera personhood enrollment)
                #:select (spawn-enrollment-ceremony enroll-ceremony-for-candidate
                          enroll-asks expire-stale-enrollments! *self-request-evidence*
                          rehydrate-enrollment-ceremonies!))
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (localchimera doors governance)
  #:use-module ((localchimera protocol dispatch) #:select (declared-doors))
  #:export (governance-economy-doors))

(define (governance-economy-doors ctx)
  (with-governance-ctx ctx
    ;; The ONE construction both purchase-claim legs share, so preimage and
    ;; signed rebuild the identical SAID from the same wire args with nothing
    ;; to echo (the socialize-preimage discipline). Wire absents are "" — each
    ;; normalizes to #f/omitted here, once.
    (define (build-purchase-claim identity-key commune-aid spec qty unit due res ref trig)
      (define (ne s) (and (string? s) (not (string-null? s)) s))
      ;; the ref is what keeps two same-shaped purchases two claims — an
      ;; empty one degrades the id to claim:AID:SPEC:open and the second
      ;; claim silently dedupes away. The shop always sends one (receipt,
      ;; or a timestamp fallback); refuse rather than degrade.
      (unless (ne ref)
        (error "purchase-claim: a non-empty ref (receipt or nonce) is required"))
      (purchase-claim identity-key commune-aid
                      (string-append "claim:" identity-key ":" spec ":"
                                     (or (ne due) "open")
                                     (let ((r (ne ref)))
                                       (if r (string-append ":" r) "")))
                      spec qty (ne unit) (ne due)
                      #:resource-inventoried-as (ne res)
                      #:triggered-by (ne trig)))

    (declared-doors governance

      ;; ── Temporary socialization — client-signed custody attestation ─────────
      ;; The owner (caller = IDENTITY-KEY) lends QTY of RESOURCE-SPEC into
      ;; COMMUNE-AID's use-pool until UNTIL. The custody-attestation's ISSUER is
      ;; the owner, so it must carry the OWNER's signature — the browser signs it
      ;; (the key never leaves the client). valid-from is left open, so the
      ;; credential is fully determined by these args and `socialize-preimage` /
      ;; `socialize-signed` rebuild the identical SAID with nothing to echo (the
      ;; twin of stance-preimage / cast-signed above). UNTIL/RT/CF/RES are strings
      ;; ("" = absent); MOVABLE is a boolean. KIND is "use" (lend the service,
      ;; "" reads as use) or "consume" (lend a quantity to SPEND — money, fuel)
      ;; — see socialization.scm grant-kind-claim.
      ;; REF ("" = none): a caller nonce folded into the grant's SAID so
      ;; recall-then-relend with identical terms mints a fresh credential
      ;; instead of colliding with the revoked one (issue-client-signed!
      ;; now refuses that collision loudly rather than lying 'ok).
      ;; ELIGIBLE ("" = anyone): the owner's steward rule — the slot criteria
      ;; JSON the dial already writes, whose filter-rule bounds who may be
      ;; assigned to work drawing on the grant (socialization.scm, the
      ;; steward gate). Echoed verbatim across both legs like every term.
      ((socialize-preimage identity-key commune-aid spec qty until movable rt cf res kind ref #:optional (eligible #f))
       (%preimage (lambda () (socialization-credential identity-key commune-aid spec qty
                               #:until until #:movable? movable #:return-to rt
                               #:condition-floor cf #:resource res #:kind kind #:ref ref
                               #:eligible eligible))))

      ((socialize-signed identity-key commune-aid spec qty until movable rt cf res kind ref signature #:optional (eligible #f))
       (%signed! (lambda () (socialization-credential identity-key commune-aid spec qty
                              #:until until #:movable? movable #:return-to rt
                              #:condition-floor cf #:resource res #:kind kind #:ref ref
                              #:eligible eligible))
                 identity-key signature "socialize"
                 ;; the title gate: a grant naming an exact resource must be the
                 ;; TITLED owner's to make, once any title over it has been spoken
                 ;; (title-permits? — silence keeps the field-only world)
                 #:gate (lambda (_) (title-permits? acdc-store identity-key
                                                    (and (string? res) (not (string-null? res)) res)))
                 #:gate-refusal "a standing title over that resource names another owner"))

      ;; ── Purchase claims — client-signed, the reimbursement trigger ──────────
      ;; The member (caller = IDENTITY-KEY) asserts "I gave the commons QTY of
      ;; SPEC" — the exact twin of socialize-preimage/-signed: the claim's
      ;; ISSUER is the member, so it must carry the MEMBER's signature (the
      ;; browser signs, the key never leaves the client). accept-reimbursement
      ;; (governance/scope.scm, below) mints the commune's debt with
      ;; triggered-by = this claim's SAID, never fabricating the claim itself.
      ;; RES ("" = unnamed) names WHICH resource paid — resourceInventoriedAs,
      ;; the precise funding-source check. REF ("" = none) is the member's own
      ;; receipt/reference, folded into the claim id so two same-shaped
      ;; purchases (same spec, amount and due) are two claims with two SAIDs,
      ;; not one that silently dedupes the second.
      ;; TRIG ("" = none): the purchase EVENT's id (record-purchase returns
      ;; it) — rides the claim as VF Claim.triggeredBy, tying the signed
      ;; word to the recorded raise it speaks about.
      ((purchase-claim-preimage identity-key commune-aid spec qty unit due res ref trig)
       (%preimage (lambda () (build-purchase-claim identity-key commune-aid spec qty unit due res ref trig))
                  #:refusal (lambda (a) (format #f "purchase-claim: ~a" a))))

      ((purchase-claim-signed identity-key commune-aid spec qty unit due res ref trig signature)
       (%signed! (lambda () (build-purchase-claim identity-key commune-aid spec qty unit due res ref trig))
                 identity-key signature "purchase-claim"))

      ;; ── Accepting a grant or a reimbursement — the commune's own word ───────
      ;; Both accept-socialization and accept-reimbursement (governance/scope.scm)
      ;; are gov-cap-gated ^scope methods, scoped to this gateway's single
      ;; HOME-SCOPE commune (there is no commune-aid → ^scope resolver for an
      ;; arbitrary federation member yet — a real, separate gap; COMMUNE-AID
      ;; is still required and checked, so a caller can never silently target
      ;; the wrong commune, only be refused for a right one this service
      ;; cannot reach).
      ;;
      ;; WHICH commune's key acts: scope-for (the scope graph, or home-scope
      ;; when it is that commune; a commune this process cannot reach is
      ;; refused by name, never silently redirected). WHO may ask it to:
      ;; mint-gov-cap's own concern (governance/scope.scm's may-govern?) —
      ;; refuses IDENTITY-KEY outright when this commune has recognised
      ;; anyone and IDENTITY-KEY isn't one of them. The one further guard
      ;; enforced here: a member can never accept their OWN reimbursement
      ;; claim (self-payout refused outright).
      ;; . opts (kw-ref): 'ratification SAID — a `close`-minted
      ;; recomposition-ratification (kind='ballot #:ratify), spliced
      ;; straight through as ^scope's own 'ratification opt
      ;; (require-ratification!). Absent, this commune's may-govern? alone
      ;; decides, exactly as before.
      ((accept-socialization identity-key commune-aid grant-said . opts)
       (let ((sc (scope-for commune-aid))
             (ratification-said (kw-ref opts 'ratification #f)))
         (if (not sc)
             (list 'error "accept-socialization: no scope reachable here for that commune")
             (catch #t
               (lambda ()
                 (list 'ok (apply $ sc 'accept-socialization
                             ($ sc 'mint-gov-cap identity-key) grant-said
                             (if ratification-said (list 'ratification ratification-said) '()))))
               (lambda (key . args) (list 'error (format #f "accept-socialization failed: ~a" args)))))))

      ((accept-reimbursement identity-key commune-aid claim-said . opts)
       (let ((sc (scope-for commune-aid))
             (ratification-said (kw-ref opts 'ratification #f)))
         (if (not sc)
             (list 'error "accept-reimbursement: no scope reachable here for that commune")
             (catch #t
               (lambda ()
                 (let* ((claim (and acdc-store ($ acdc-store 'get claim-said))))
                   (when (and claim (equal? identity-key (cred-issuer claim)))
                     (error "cannot accept your own reimbursement claim" claim-said))
                   (let ((r (apply $ sc 'accept-reimbursement
                              ($ sc 'mint-gov-cap identity-key) claim-said
                              (if ratification-said (list 'ratification ratification-said) '()))))
                     (list 'ok (car r) (cadr r)))))
               (lambda (key . args) (list 'error (format #f "accept-reimbursement failed: ~a" args)))))))

      ;; ── Ownership — client-signed title attestation ─────────────────────────
      ;; The caller asserts title over ONE resource (rid, spec). Issuer = holder
      ;; = the owner, so the browser signs (the key never leaves the client) —
      ;; the exact twin of socialize-preimage / socialize-signed. A title makes
      ;; the self-assertion declare-means records non-repudiable and contestable;
      ;; the socialization gates and the auditor read it (ownership-ok?).
      ;; REF ("" = none): lets a disowned title be re-asserted — identical
      ;; terms otherwise rebuild the revoked SAID and issue-client-signed!
      ;; refuses the collision loudly.
      ((own-means-preimage identity-key resource-id spec qty qty-unit ref)
       (%preimage (lambda () (ownership-credential identity-key resource-id spec #:qty qty #:qty-unit qty-unit #:ref ref))))

      ((own-means-signed identity-key resource-id spec qty qty-unit ref signature)
       (%signed! (lambda () (ownership-credential identity-key resource-id spec #:qty qty #:qty-unit qty-unit #:ref ref))
                 identity-key signature "ownership"))

      ;; the caller's own live titles: (said resource-id spec kind)
      ((my-titles identity-key)
       (if (not acdc-store) (list 'ok '())
           (list 'ok
                 (map (lambda (c)
                        (list (cred-said c) (cred-claim c 'resource-id)
                              (cred-claim c 'resource-spec)
                              (or (cred-claim c 'kind) "declared")))
                      (filter (lambda (c) (equal? identity-key (cred-issuer c)))
                              (%live-ownership-attestations acdc-store))))))

      ;; withdrawing a title — issuer-owned revocation, desocialize's twin
      ;; (both are revoke-own-credential!, stated once in socialization.scm)
      ((disown-means identity-key said)
       (if (not acdc-store) (list 'error "no credential store")
           (catch #t
             (lambda ()
               (list 'ok (withdraw-title! acdc-store identity-key said)))
             (lambda (key . args) (list 'error (format #f "disown failed: ~a" args))))))

      ;; the caller's own live grants, for the ledger:
      ;; (said spec holder until qty kind eligible)
      ((my-grants identity-key)
       (if (not acdc-store) (list 'ok '())
           (list 'ok
                 (map (lambda (c)
                        (list (cred-said c) (cred-claim c 'resource-spec) (cred-holder c)
                              (or (cred-claim c 'valid-until) "") (cred-claim c 'qty)
                              (if (grant-consume? c) "consume" "use")
                              (or (cred-claim c 'eligible) "")))
                      (filter (lambda (c) (equal? identity-key (cred-issuer c)))
                              (%live-custody-attestations acdc-store #f))))))

      ;; owner recalls a grant early — no signature; the store-side revoke is gated
      ;; by the issuer==owner check inside desocialize-private-resource!.
      ((desocialize identity-key said)
       (if (not acdc-store) (list 'error "no credential store")
           (catch #t
             (lambda () (list 'ok (desocialize-private-resource! acdc-store identity-key said)))
             (lambda (key . args) (list 'error (format #f "recall failed: ~a" args)))))))))
