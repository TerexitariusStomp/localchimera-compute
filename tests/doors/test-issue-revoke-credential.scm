;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-issue-revoke-credential.scm — the two doors wired to the live governor gate
;;;
;;; issue-credential/revoke-credential on ^lobby-session used to answer only the
;;; removed-gate error: the role-credential ceremony they gated on was deleted
;;; 2026-08-19, never having bootstrapped for anyone. This is the replacement,
;;; wired to the SAME founders.txt-based `governor?` every other admin door in
;;; (playnet boot governance) already gates on — no new authority concept,
;;; the one that runs the system today.
;;;
;;; What this pins:
;;;   • doors/lobby.scm's own check runs first, with no round trip: a credential whose
;;;     `issuer` field does not match the caller's own AID is refused locally,
;;;     even for a governor, and never reaches governance-svc or the store;
;;;   • a non-governor issuing their OWN credential is refused by governance-svc's
;;;     governor gate, with the store left untouched;
;;;   • a governor issuing their own credential succeeds: the reply is the
;;;     credential's SAID, and the store actually holds it;
;;;   • revoke has no issuer check (governance revokes by policy, not authorship)
;;;     but the same governor gate: a non-governor is refused, a governor's
;;;     revoke lands and the store reads the credential back revoked.
;;;
;;; Run: guile -L module -L tests tests/doors/test-issue-revoke-credential.scm

(use-modules (playnet test harness)
             (playnet doors lobby)
             (playnet boot governance) (playnet keri acdc) (playnet keri acdc-store) (playnet keri said-portable)
             (goblins) (goblins vat))

(define vat (spawn-vat))
(define GOV  "EGovernor0000000000000000000000000000000000")
(define BYST "EBystander0000000000000000000000000000000000")

(define store (with-vat vat (spawn-acdc-store)))
(define svc (with-vat vat
              (spawn-governance-service '() #f #:acdc-store store
                                        #:governor? (lambda (a) (equal? a GOV)))))
(define (session aid) (with-vat vat (spawn ^lobby-session aid #f #f svc #f)))
(define gov-session (session GOV))
(define byst-session (session BYST))

;; a delegated door's reply is a promise (doors/lobby.scm's own arm just returns the
;; `<-` it sent) — settle it the way tests/doors/test-device-auth.scm does.
(define (settle p)
  (let ((box #f) (done #f))
    (with-vat vat
      (on p (lambda (v) (set! box v) (set! done #t))
          #:catch (lambda (e) (set! box (list 'error e)) (set! done #t))))
    (let loop ((i 0))
      (unless (or done (> i 200)) (usleep 10000) (loop (+ i 1))))
    box))

;; a credential whose own SAID actually commits to its content, exactly the
;; shape make-*-credential in credentials.scm returns — `revoked? #f`
;; included, the field every real constructor seeds and a caller-built
;; alist (this door's own case) might not.
(define (cred issuer holder)
  (let* ((schema 'test) (claims '((note . "a test credential"))) (edges '())
         (said (compute-said issuer holder schema claims edges)))
    (list (cons 'said said) (cons 'schema schema) (cons 'issuer issuer)
          (cons 'holder holder) (cons 'claims claims) (cons 'edges edges)
          (cons 'revoked? #f))))

(display "\n── the local issuer check runs before any round trip ──\n")
(define mismatched (cred BYST GOV))                    ; issuer names someone else
(define r1 (with-vat vat ($ gov-session 'issue-credential mismatched)))
(check "a governor issuing someone ELSE's credential is refused" (eq? 'error (car r1)))
(check-pred "…for the issuer mismatch, not the governor gate"
            (string-contains (cadr r1) "issuer must match"))
(check "the store never saw it" (with-vat vat ($ store 'get (assq-ref mismatched 'said))) #f)

(display "\n── a non-governor is refused, even for their own credential ──\n")
(define own (cred BYST BYST))
(define r2 (settle (with-vat vat ($ byst-session 'issue-credential own))))
(check "refused" (eq? 'error (car r2)))
(check-pred "…naming governor standing" (string-contains (cadr r2) "governor standing"))
(check "the store still doesn't have it" (with-vat vat ($ store 'get (cred-said own))) #f)

(display "\n── a governor issuing their own credential lands ──\n")
(define mine (cred GOV GOV))
(define r3 (settle (with-vat vat ($ gov-session 'issue-credential mine))))
(check "the reply is the SAID" r3 (cred-said mine))
(define stored (with-vat vat ($ store 'get (cred-said mine))))
(check-pred "the store actually holds it" stored)
(check "…under the same issuer" (assq-ref stored 'issuer) GOV)

(display "\n── revoke: same gate, no issuer check ──\n")
(define r4 (settle (with-vat vat ($ byst-session 'revoke-credential (cred-said mine)))))
(check "a non-governor cannot revoke" (eq? 'error (car r4)))
(check-pred "…naming governor standing" (string-contains (cadr r4) "governor standing"))
(check-pred "…and it is still live" (not (cred-revoked? (with-vat vat ($ store 'get (cred-said mine))))))
(define r5 (settle (with-vat vat ($ gov-session 'revoke-credential (cred-said mine)))))
(check "a governor's revoke succeeds" r5 'ok)
(check-pred "…and the store reads it back revoked"
            (cred-revoked? (with-vat vat ($ store 'get (cred-said mine)))))

(display "\n── a credential minted with no revoked? field is still revocable ──\n")
;; this door accepts a caller-built alist, not only a constructor's — a
;; credential missing the field entirely used to revoke silently into a
;; no-op (cred-with-revoked, credentials.scm), which nothing here would
;; have caught without a real round trip through the store.
(define fieldless
  (let* ((schema 'test) (claims '((note . "no revoked field"))) (edges '())
         (said (compute-said GOV GOV schema claims edges)))
    (list (cons 'said said) (cons 'schema schema) (cons 'issuer GOV)
          (cons 'holder GOV) (cons 'claims claims) (cons 'edges edges))))
(check "issued" (settle (with-vat vat ($ gov-session 'issue-credential fieldless)))
       (cred-said fieldless))
(check-pred "…and starts unrevoked (the field's absence, not a false #f)"
            (not (cred-revoked? (with-vat vat ($ store 'get (cred-said fieldless))))))
(check "revoke succeeds" (settle (with-vat vat ($ gov-session 'revoke-credential (cred-said fieldless)))) 'ok)
(check-pred "…and the field was ADDED, not silently skipped"
            (cred-revoked? (with-vat vat ($ store 'get (cred-said fieldless)))))

(test-summary!)
