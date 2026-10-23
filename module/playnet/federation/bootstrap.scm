;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; federation/bootstrap.scm — governance bootstrap ceremony
;;;
;;; State-machine actor that walks through the founding ceremony:
;;;   1. Register founding members (personal AIDs)
;;;   2. Create governance group AID (multi-sig)
;;;   3. Create TEL registry for credentials
;;;   4. Issue founding member + governor credentials
;;;   5. Split bran into Shamir shares
;;;   6. Distribute shares to founders
;;;
;;; In test mode (no live KERIA), steps 2-4 use synthetic values. The
;;; ceremony is the same; the difference is whether the underlying KERI
;;; calls go to a real KERIA or are simulated.
;;;

(define-module (playnet federation bootstrap)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (playnet credentials keys)
  #:use-module (playnet credentials membership)
  #:use-module (playnet keri first-person credentials)
  #:use-module (playnet crypto shamir)
  #:use-module (rnrs bytevectors)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (^bootstrap-ceremony spawn-bootstrap-ceremony bootstrap-ceremony!))

;; =========================================================================
;; ^bootstrap-ceremony — state machine
;; =========================================================================

(define-actor (^bootstrap-ceremony bcom
                                   state        ;; symbol: see below
                                   founders     ;; list of (name aid-prefix oobi-url)
                                   governance-aid  ;; string or #f
                                   registry-id     ;; string or #f
                                   credentials     ;; list of issued credential SAIDs
                                   shares          ;; list of (index threshold . bv) or #f
                                   acdc-store      ;; ^acdc-store ref
                                   keri-backend)   ;; alist of procs or #f (test mode)

  ;; States: awaiting-founders → creating-governance → creating-registry
  ;;       → issuing-credentials → splitting-bran → distributing-shares
  ;;       → complete
  ;;
  ;; keri-backend: when #f, uses synthetic AIDs/registry (test mode).
  ;; When an alist, expects:
  ;;   (create-group . (lambda (member-names threshold) → aid-string))
  ;;   (create-registry . (lambda (aid-name reg-name) → registry-id))
  ;;   (resolve-oobi . (lambda (url) → #t))
  ;;
  ;; NOTE on SHARES: despite holding raw Shamir share bytevectors, this is
  ;; NOT the only copy — split-bran (below) issues each share as a
  ;; bran-share-credential into ACDC-STORE with the identical share-data
  ;; bytes (see share->alist) *before* it lands here. As long as
  ;; ACDC-STORE is durable, the secret material already survives a
  ;; restart via the credential layer; SHARES here is just in-progress
  ;; bookkeeping of which shares are still pending pickup via 'get-share,
  ;; not the actor's sole copy — unlike ^bran-custodian's shares, which
  ;; really were the only copy and got the encrypted-durable-dir
  ;; treatment for exactly that reason.
  ;;
  ;; Deliberately no #:portrait/#:restore here. KERI-BACKEND mixes two
  ;; shapes under one alist — some keys are procedures
  ;; (create-group/create-registry/resolve-oobi, called), one is a raw
  ;; value (signing-keypair, used directly, never called) — so the usual
  ;; "stub every key with an erroring procedure" rewire pattern doesn't
  ;; fit cleanly, and defaulting keri-backend to #f on restore would
  ;; silently flip every method over to synthetic/test-mode credential
  ;; generation in what could be a live founding ceremony — a much worse
  ;; failure than the current "no native persistence" gap. This is a
  ;; short-lived, one-operator-session state machine; getting restore
  ;; semantics subtly wrong here is worse than leaving it unaddressed.

  (methods

    ((status) state)
    ((founders) founders)
    ((governance-aid) governance-aid)
    ((registry-id) registry-id)
    ((credentials-issued) credentials)
    ((shares-remaining)
     (if shares (length shares) 0))

    ;; --- Phase 1: Register founders ---

    ((add-founder name aid-prefix oobi-url)
     (unless (eq? state 'awaiting-founders)
       (error "add-founder: ceremony not in awaiting-founders state" state))
     (bcom (^bootstrap-ceremony bcom 'awaiting-founders
                                (cons (list name aid-prefix oobi-url) founders)
                                governance-aid registry-id credentials
                                shares acdc-store keri-backend)))

    ;; --- Phase 2: Create governance group AID ---

    ((create-governance group-name signing-threshold)
     (unless (eq? state 'awaiting-founders)
       (error "create-governance: wrong state" state))
     (when (null? founders)
       (error "create-governance: no founders registered"))
     (when (< (length founders) signing-threshold)
       (error "create-governance: fewer founders than threshold"
              (length founders) signing-threshold))
     (let ((gov-aid (if keri-backend
                       ((assq-ref keri-backend 'create-group)
                        (map car founders) signing-threshold)
                       (string-append "E_gov_" group-name "_"
                                      (number->string (length founders))))))
       (bcom (^bootstrap-ceremony bcom 'creating-registry
                                  founders gov-aid registry-id credentials
                                  shares acdc-store keri-backend)
             gov-aid)))

    ;; --- Phase 3: Create TEL registry ---

    ((create-registry registry-name)
     (unless (eq? state 'creating-registry)
       (error "create-registry: wrong state" state))
     (let ((rid (if keri-backend
                    ((assq-ref keri-backend 'create-registry)
                     governance-aid registry-name)
                    (string-append "reg_" registry-name "_"
                                   (number->string (length founders))))))
       (bcom (^bootstrap-ceremony bcom 'issuing-credentials
                                  founders governance-aid rid credentials
                                  shares acdc-store keri-backend)
             rid)))

    ;; --- Phase 4: Issue founding credentials ---

    ((issue-founding-credentials)
     (unless (eq? state 'issuing-credentials)
       (error "issue-founding-credentials: wrong state" state))
     ;; Each founder receives a membership credential *and* a
     ;; Personhood Credential (PHC). The governance-aid is the ecosystem
     ;; AID for First-Person verification: everyone founded together is
     ;; mutually in the same ecosystem, which is the precondition the
     ;; trust-triangle verifier checks later (FPP I1).
     ;;
     ;; GENESIS ROOT: the founding commune is self-rooted — it IS the
     ;; origin of its personhood graph, so it blesses ITSELF as an
     ;; authorized PHC issuer (root == ecosystem == governance-aid). Every
     ;; founder PHC carries an `issuer-authz` edge to that self-blessing,
     ;; so the graph is structurally rooted from birth; when a Universal
     ;; Commune later federates these communes it re-anchors them to the
     ;; UC root (the shared trust registry). Trust holds either way: a
     ;; self-rooted issuer satisfies `issuer-chains-to-root?` trivially.
     ;; Group signing key: in real mode the KERI backend supplies the
     ;; governance group's signing capability (a 'signing-keypair entry)
     ;; so genesis credentials carry a verifiable signature by the group
     ;; AID — the precondition for `require-signature? #t` verifiers and
     ;; foreign end-verifiability. #f in synthetic test mode → unsigned.
     (let* ((sign-kp (and keri-backend (assq-ref keri-backend 'signing-keypair)))
            (genesis-aic
             (make-authorized-issuer-credential
               #:root-aid governance-aid
               #:ecosystem-aid governance-aid
               #:blessed-at (instant->unix (clock-now))
               #:signing-keypair sign-kp))
            (aic-said ($ acdc-store 'issue genesis-aic))
            (issued
             (fold
              (lambda (founder acc)
                (let* ((name (car founder))
                       (aid  (cadr founder))
                       (now  (instant->unix (clock-now)))
                       (member-cred
                        (make-membership-credential
                          #:issuer-group-aid governance-aid
                          #:holder-aid aid
                          #:commune name
                          #:admitted-at now
                          #:signing-keypair sign-kp))
                       (phc
                        (make-personhood-credential
                          #:ecosystem-aid governance-aid
                          #:holder-aid aid
                          #:enrolled-at now
                          #:enrollment-evidence-digest
                          (string-append "founder:" name)
                          #:issuer-authz-said aic-said
                          #:signing-keypair sign-kp)))
                  (cons ($ acdc-store 'issue member-cred)
                        (cons ($ acdc-store 'issue phc) acc))))
              (list aic-said) founders)))
       (bcom (^bootstrap-ceremony bcom 'splitting-bran
                                  founders governance-aid registry-id
                                  issued shares acdc-store keri-backend)
             issued)))

    ;; --- Phase 5: Split bran ---

    ((split-bran bran-string k n)
     (unless (eq? state 'splitting-bran)
       (error "split-bran: wrong state" state))
     (when (< n (length founders))
       (error "split-bran: n < number of founders" n (length founders)))
     (let* ((bran-bv (string->utf8 bran-string))
            (split-shares (shamir-split bran-bv k n))
            ;; Same group signing key issue-founding-credentials used for
            ;; the AIC/PHC above — a bran-share ACDC carries real key
            ;; material and deserves the same signature, not less.
            (sign-kp (and keri-backend (assq-ref keri-backend 'signing-keypair))))
       ;; Issue bran-share credentials for each founder
       (for-each
         (lambda (founder share)
           (let* ((aid (cadr founder))
                  (sa  (share->alist share))
                  (cred (make-bran-share-credential
                          #:issuer-group-aid governance-aid
                          #:holder-aid aid
                          #:share-index (assoc-ref sa 'share-index)
                          #:threshold (assoc-ref sa 'threshold)
                          #:total-shares n
                          #:share-data-hex (assoc-ref sa 'share-data)
                          #:signing-keypair sign-kp)))
             ($ acdc-store 'issue cred)))
         founders
         (take split-shares (length founders)))
       (bcom (^bootstrap-ceremony bcom 'distributing-shares
                                  founders governance-aid registry-id
                                  credentials split-shares acdc-store
                                  keri-backend)
             (length split-shares))))

    ;; --- Phase 6: Distribute shares ---

    ((get-share member-index)
     (unless (eq? state 'distributing-shares)
       (error "get-share: wrong state" state))
     (let ((share (find (lambda (s) (= (share-index s) member-index))
                        shares)))
       (unless share
         (error "get-share: no share for index" member-index))
       (let ((remaining (remove (lambda (s) (= (share-index s) member-index))
                                shares)))
         (bcom (^bootstrap-ceremony bcom
                                    (if (null? remaining) 'complete
                                        'distributing-shares)
                                    founders governance-aid registry-id
                                    credentials remaining acdc-store
                                    keri-backend)
               share))))

))


(define* (spawn-bootstrap-ceremony acdc-store #:key (keri-backend #f))
  "Spawn a bootstrap ceremony actor in the awaiting-founders state.
   keri-backend: #f for test mode (synthetic AIDs), or an alist with
   'create-group and 'create-registry procedures for live KERIA."
  (spawn ^bootstrap-ceremony
         'awaiting-founders '() #f #f '() #f acdc-store keri-backend))

(define (bootstrap-ceremony! ceremony group-name signing-threshold
                              registry-name bran-string k n)
  "Run the full bootstrap ceremony. CEREMONY must have founders registered.
   Returns a status alist."
  (let ((gov-aid ($ ceremony 'create-governance group-name signing-threshold)))
    ($ ceremony 'create-registry registry-name)
    ($ ceremony 'issue-founding-credentials)
    ($ ceremony 'split-bran bran-string k n)
    `((status         . ,($ ceremony 'status))
      (governance-aid . ,gov-aid)
      (founders       . ,(length ($ ceremony 'founders)))
      (shares         . ,n)
      (threshold      . ,k))))
