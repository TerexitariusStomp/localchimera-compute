;;; test-witnessed-work-event.scm — the trust floor's first slice.
;;;
;;; The recipe metabolism reads work events as evidence, and evidence that is
;;; one scope's word is the known single-issuer integrity hole (patchwork §4a
;;; / trust-substrate). This pins the slice that closes it at the credential
;;; layer: attest-contribution! #:witnesses puts a k-of-n multisig block on the
;;; work-event ACDC itself — verified by cred-multisig-valid?, refusing a
;;; forged or duplicated signer — while the witness-less path stays exactly the
;;; single-signer behaviour it always was.

;; the host crypto backend: loading (playnet keri signify) installs it
(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules ((playnet keri signify) #:select ()))
(use-modules (playnet test harness))
(use-modules (playnet vf schemas) (srfi srfi-1))
(use-modules (playnet observation credentials) (playnet personhood witnessed-work) (playnet personhood attestation-ceremony) (playnet credentials work) (playnet keri acdc) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri first-person predicates))
(use-modules ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-aid keri-identity-keypair sign-said)))
(use-modules (goblins) (rnrs bytevectors))
(use-modules (srfi srfi-1))

(define (fresh n) (make-keri-identity (make-bytevector 32 n)))
(define (signer id) (cons (keri-identity-aid id) (keri-identity-keypair id)))

(define (work-ev eid pid hours)
  (make-economic-event #:id eid #:action 'work #:output-of pid #:resource-conforms-to "skill-bake"
                       #:provider "EAda" #:effort-quantity (make-measure hours %effort-unit)
                       #:has-point-in-time "2026-03-01T08:00:00Z"))

(define vat (spawn-vat))

(display "\n── a work event, witnessed k-of-n ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (w1 (fresh 71)) (w2 (fresh 72)) (w3 (fresh 73))
         (aids (map keri-identity-aid (list w1 w2 w3))))
    (attest-contribution! store "EScope" (work-ev "e1" "p1" 6.0)
                          #:witnesses (list (signer w1) (signer w2)))
    (let ((we (find (lambda (c) (equal? "e1" (cred-claim c 'event-id)))
                    (non-revoked-by-schema store *schema-playnet-work-event*))))
      (check-pred "the work-event ACDC exists"            (and we #t))
      (check-pred "it carries a multisig block, not one scope's word"
                  (pair? (cred-signature we)))
      (check-pred "two live witnesses meet threshold 2"
                  (cred-multisig-valid? we aids 2))
      (check-pred "…but never threshold 3"
                  (not (cred-multisig-valid? we aids 3)))
      (check-pred "a single-sig verifier declines the block (no crash)"
                  (not (cred-signature-valid? we))))))

(display "\n── without witnesses: the path it always was ──\n")

(with-vat vat
  (let ((store (spawn-acdc-store)))
    (attest-contribution! store "EScope" (work-ev "e2" "p2" 4.0))
    (check-pred "the single-issuer work event still issues"
                (and (find (lambda (c) (equal? "e2" (cred-claim c 'event-id)))
                           (non-revoked-by-schema store *schema-playnet-work-event*))
                     #t))))

(display "\n── the ceremony: keys never leave the witnesses, quorum or nothing ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         ;; three witnesses; one refuses anything over 8 claimed hours
         (honest (lambda (cred) #t))
         (strict (lambda (cred) (let ((h (cred-claim cred 'hours))) (and h (<= h 8.0)))))
         (w1 (spawn ^work-witness (fresh 81) honest))
         (w2 (spawn ^work-witness (fresh 82) honest))
         (w3 (spawn ^work-witness (fresh 83) strict))
         (aids (map (lambda (w) ($ w 'aid)) (list w1 w2 w3))))
    (check-pred "quorum follows command: idle work needs one witness, heavy three"
                (and (= 1 (witness-quorum 0.0)) (= 2 (witness-quorum 0.4))
                     (= 3 (witness-quorum 0.9))))
    ;; 6 h: all three sign, quorum 3 met, issued and valid
    (let ((we (gather-witnessed-attestation! store "EScope" (work-ev "e5" "p5" 6.0)
                                             (list w1 w2 w3) #:quorum 3)))
      (check-pred "quorum met: issued, and the gathered block verifies"
                  (and we (cred-multisig-valid? we aids 3))))
    ;; 12 h: the strict witness refuses, only 2 sign, quorum 3 NOT met
    (let ((we (gather-witnessed-attestation! store "EScope" (work-ev "e6" "p6" 12.0)
                                             (list w1 w2 w3) #:quorum 3)))
      (check-pred "below quorum NOTHING issues — an unwitnessed claim is no evidence"
                  (and (not we)
                       (not (find (lambda (c) (equal? "e6" (cred-claim c 'event-id)))
                                  (non-revoked-by-schema store *schema-playnet-work-event*))))))
    ;; …but the same event at quorum 2 issues on the two honest signatures
    (let ((we (gather-witnessed-attestation! store "EScope" (work-ev "e7" "p7" 12.0)
                                             (list w1 w2 w3) #:quorum 2)))
      (check-pred "the refusal is one witness's, not a veto: quorum 2 still issues"
                  (and we (cred-multisig-valid? we aids 2))))))

(display "\n── the async form: the same ritual, signatures across turns ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (w1 (spawn ^work-witness (fresh 91) (lambda (c) #t)))
         (w2 (spawn ^work-witness (fresh 92) (lambda (c) #t)))
         (aids (map (lambda (w) ($ w 'aid)) (list w1 w2))))
    (call-with-values
        (lambda () (spawn-witnessed-work-ceremony store "EScope" (work-ev "e8" "p8" 5.0)
                                                  #:quorum 2))
      (lambda (ceremony base)
        (check-pred "the ceremony opens collecting"
                    (eq? 'collecting ($ ceremony 'status)))
        ;; one signature arrives…
        (let ((a1 ($ w1 'witness base)))
          ($ ceremony 'attest (car a1) (cdr a1)))
        (check-pred "…and finalize refuses below quorum"
                    (catch #t (lambda () ($ ceremony 'finalize) #f)
                           (lambda args #t)))
        ;; …the second lands a turn later, as a remote one would
        (let ((a2 ($ w2 'witness base)))
          ($ ceremony 'attest (car a2) (cdr a2)))
        (let ((we ($ ceremony 'finalize)))
          (check-pred "at quorum the block verifies — the same evidence, gathered async"
                      (and we (cred-multisig-valid? we aids 2)
                           (eq? 'finalized ($ ceremony 'status)))))))))

(display "\n── the landing: a remote reply finds its ceremony by the SAID it signed ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (w1 (spawn ^work-witness (fresh 95) (lambda (c) #t)))
         (w2 (spawn ^work-witness (fresh 96) (lambda (c) #t)))
         (aids (map (lambda (w) ($ w 'aid)) (list w1 w2))))
    (call-with-values
        (lambda () (spawn-witnessed-work-ceremony store "EScope" (work-ev "e9" "p9" 5.0)
                                                  #:quorum 2))
      (lambda (ceremony base)
        (let ((said (cred-said base)))
          (check-pred "the ceremony is addressable by its statement SAID"
                      (eq? ceremony (attestation-ceremony-for said)))
          ;; two replies arrive over "the wire" — nothing but said/aid/sig
          (let ((a1 ($ w1 'witness base)) (a2 ($ w2 'witness base)))
            (check-pred "the first landing attests"
                        (eq? 'attested (land-witness-attestation! said (car a1) (cdr a1))))
            (check-pred "the second meets quorum: finalized, on the spot"
                        (eq? 'finalized (land-witness-attestation! said (car a2) (cdr a2))))
            (check-pred "…and the registry entry retires with it"
                        (not (attestation-ceremony-for said)))
            (check-pred "the issued block verifies"
                        (let ((we (find (lambda (c) (equal? "e9" (cred-claim c 'event-id)))
                                        (non-revoked-by-schema store *schema-playnet-work-event*))))
                          (and we (cred-multisig-valid? we aids 2))))))))
    (check-pred "a stale or misdirected reply lands nowhere, silently"
                (not (land-witness-attestation! "EnoSuchSaid" "EGhost" "0Bnope")))))

(display "\n── the UPGRADE: witnessing strengthens the standing credential in place ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (w1 (spawn ^work-witness (fresh 97) (lambda (c) #t)))
         (ev (work-ev "e10" "p10" 3.0)))
    ;; the on-event hook already issued the single-signer provenance copy
    (attest-contribution! store "EScope" ev)
    (let ((before (find (lambda (c) (equal? "e10" (cred-claim c 'event-id)))
                        (non-revoked-by-schema store *schema-playnet-work-event*))))
      (check-pred "the provenance copy stands first" (and before #t))
      ;; the on-demand drive: open, land one signature, quorum 1 finalizes
      (let ((said (open-work-witnessing! store "EScope" ev (list ($ w1 'aid) "EAda"))))
        (check-pred "open returns the statement said — the provenance copy's own"
                    (equal? said (cred-said before)))
        (check-pred "re-opening while collecting hands back the SAME statement"
                    (equal? said (open-work-witnessing! store "EScope" ev (list ($ w1 'aid)))))
        (check-pred "the inbox offers it to a peer, never to the worker"
                    (and (find (lambda (r) (equal? (assq-ref r 'said) said))
                               (witness-work-inbox ($ w1 'aid)))
                         (not (find (lambda (r) (equal? (assq-ref r 'said) said))
                                    (witness-work-inbox "EAda")))))
        (let ((a1 ($ w1 'witness (find (lambda (c) (equal? "e10" (cred-claim c 'event-id)))
                                       (list before)))))
          (check-pred "one landing meets the quorum floor"
                      (eq? 'finalized (land-witness-attestation! said (car a1) (cdr a1)))))
        (let ((after (find (lambda (c) (equal? "e10" (cred-claim c 'event-id)))
                           (non-revoked-by-schema store *schema-playnet-work-event*))))
          (check-pred "the SAME said now carries the multisig block"
                      (and after (equal? (cred-said after) said)
                           (pair? (cred-signature after))
                           (cred-multisig-valid? after (list ($ w1 'aid)) 1)))
          (check-pred "…and the swept inbox no longer offers it"
                      (not (find (lambda (r) (equal? (assq-ref r 'said) said))
                                 (witness-work-inbox ($ w1 'aid))))))))))

(display "\n── a peer gateway's request: remembered, offered, answered, forgotten ──\n")
;; The /multisig/exn transport carries only (said · context) out and
;; (said · aid · sig) back; everything between is this registry — so the
;; federation half is testable exactly here, with no KERIA in the room.

(with-vat vat
  (let ((ctx '((worker . "EWorkerFar") (skill . "skill-weave") (hours . "2")
               (unit . "hours") (scope . "EScopeFar") (origin . "EGateFar"))))
    (remember-remote-witness-request! "EStmtRemote" ctx)
    (check-pred "the remote request reaches a peer's inbox"
                (find (lambda (r) (equal? (assq-ref r 'said) "EStmtRemote"))
                      (witness-work-inbox "EPeer")))
    (check-pred "…but never the worker's own"
                (not (find (lambda (r) (equal? (assq-ref r 'said) "EStmtRemote"))
                           (witness-work-inbox "EWorkerFar"))))
    (check-pred "its origin rides along, for the reply"
                (equal? "EGateFar"
                        (assq-ref (remote-witness-request "EStmtRemote") 'origin)))
    (forget-remote-witness-request! "EStmtRemote")
    (check-pred "answered → forgotten"
                (not (remote-witness-request "EStmtRemote")))))

(display "\n── the composed DOOR: exactly what the planner service consumes ──\n")
;; make-federated-witness-door with no KERIA connected degrades to the
;; local-only behaviour — which makes the whole door walkable here: open,
;; inbox, sign with a witness's own key, attest, finalized.

(use-modules ((playnet personhood witness-relay) #:select (make-federated-witness-door)))
;; the door PUBLISHES its ask as a state file — point the state root at a
;; scratch dir so the suite writes nowhere real
(setenv "PLAYNET_STATE_DIR" (string-append (or (getenv "TMPDIR") "/tmp")
                                           "/witness-door-test-" (number->string (getpid))))

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (w1 (fresh 98))
         (door (make-federated-witness-door #:store-of (lambda (_) store)))
         (ev (work-ev "e11" "p11" 2.0)))
    (let* ((open   (assq-ref door 'open))
           (inbox  (assq-ref door 'inbox))
           (attest (assq-ref door 'attest))
           (said (open "EScope" ev (list (keri-identity-aid w1) "EAda"))))
      (check-pred "door: open returns the statement said" (string? said))
      (check-pred "door: the inbox offers it to the peer"
                  (find (lambda (r) (equal? (assq-ref r 'said) said))
                        (inbox (keri-identity-aid w1))))
      (check-pred "door: a co-signature finalizes at the floor"
                  (eq? 'finalized
                       (attest said (keri-identity-aid w1)
                               (sign-said said (keri-identity-keypair w1)))))
      (check-pred "door: the witnessed credential stands in the store"
                  (let ((we (find (lambda (c) (equal? "e11" (cred-claim c 'event-id)))
                                  (non-revoked-by-schema store *schema-playnet-work-event*))))
                    (and we (pair? (cred-signature we))))))))

(display "\n── a BROWSER citizen co-signs: E-prefix AID, key resolved via the KEL dir ──\n")
;; A browser-born witness is an E-prefix (ICP digest) — no key in the prefix.
;; The gateway binds current-aid-key-resolver to the oobi-host durable dir
;; (oobi-current-key-from-dir): a pure file read the planner-vat attest can
;; make. This pins that whole chain with a fabricated dir entry.

(use-modules ((playnet identity oobi-host)
              #:select (oobi-entry-path oobi-current-key-from-dir))
             ((playnet personhood attestation-ceremony)
              #:select (current-aid-key-resolver)))

(with-vat vat
  (let* ((store   (spawn-acdc-store))
         (wid     (fresh 99))                          ; the browser key, server-side twin
         (key     (keri-identity-aid wid))             ; D-prefix qb64 = the raw pubkey
         (e-aid   "EBrowserCitizen00000000000000000000000000000")
         (dir     (string-append (or (getenv "TMPDIR") "/tmp")
                                 "/oobi-host-test-" (number->string (getpid))))
         (path    (oobi-entry-path dir e-aid))
         (ev      (work-ev "e12" "p12" 3.0)))
    ;; the entry the signup path writes: icp with k[0] = the signing key
    (system* "mkdir" "-p" (dirname path))
    (call-with-output-file path
      (lambda (p) (write `((aid . ,e-aid) (icp . (("k" . #(,key))))) p)))
    (check-pred "the dir resolver reads the key back"
                (equal? key (oobi-current-key-from-dir dir e-aid)))
    (current-aid-key-resolver (lambda (aid) (oobi-current-key-from-dir dir aid)))
    (attest-contribution! store "EScope" ev)
    (let ((said (open-work-witnessing! store "EScope" ev (list e-aid "EAda"))))
      (check-pred "the ceremony opens with the E-AID among its peers" (string? said))
      (check-pred "the E-AID's co-signature verifies through the resolver and finalizes"
                  (eq? 'finalized
                       (land-witness-attestation! said e-aid
                         (sign-said said (keri-identity-keypair wid)))))
      (let ((we (find (lambda (c) (equal? "e12" (cred-claim c 'event-id)))
                      (non-revoked-by-schema store *schema-playnet-work-event*))))
        (check-pred "the multisig block names the E-AID"
                    (and we (assoc e-aid (cred-signature we)) #t))))
    ;; unresolvable E-AID → the pre-existing refusal, not a silent pass
    (attest-contribution! store "EScope" (work-ev "e13" "p13" 1.0))
    (let ((said2 (open-work-witnessing! store "EScope" (work-ev "e13" "p13" 1.0)
                                        (list "EUnknownWitness0000000000000000000000000000" "EAda"))))
      (check-pred "an E-AID the KEL dir does not know still cannot attest"
                  (catch #t
                    (lambda () (land-witness-attestation! said2
                                 "EUnknownWitness0000000000000000000000000000"
                                 (sign-said said2 (keri-identity-keypair wid)))
                               #f)
                    (lambda _ #t))))
    (current-aid-key-resolver #f)))

(test-summary!)
