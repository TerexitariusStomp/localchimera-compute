;;; test-personhood-flow.scm — being recognised, through the governance service.
;;;
;;; A candidate asks for themself; the ask is a durable ceremony with the
;;; ecosystem's quorum clamped to who could sign; recognised people sign it
;;; from the witness rail; at quorum the personhood issues and the ask reads
;;; back finalized. The founder's unilateral grant is the genesis act only.
;;; A restart brings every open ask back with the vouches it had.
;;;
;;; Run:  guile --no-auto-compile -L module -L tests tests/governance/test-personhood-flow.scm

(setenv "PLAYNET_STATE_DIR"
        (string-append (or (getenv "TMPDIR") "/tmp") "/pn-personhood-flow-" (number->string (getpid))))

(use-modules (playnet test harness)
             (playnet scope root) (srfi srfi-1) (playnet doors service)
             (playnet personhood attestation-ceremony) (playnet personhood enrollment) (playnet boot scope) (playnet boot governance) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri first-person credentials) (playnet keri first-person predicates)
             ((playnet personhood attestation-ceremony) #:select (*attestation-ceremonies* land-witness-attestation!))
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid sign-said))
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(define ECO "EHearth")
(define (ids n) (map (lambda (_) (make-keri-identity)) (iota n)))
(define (aid id) (keri-identity-aid id))
(define (sign id said) (sign-said said (keri-identity-keypair id)))

(define vat (spawn-vat))
(with-vat vat
  (let* ((store (spawn-acdc-store))
         (root  (spawn-scope-root "Hearth"))
         (scope (spawn-scope "Hearth" #:kind 'commune #:scope-root-ref root
                             #:scope-aid ECO #:acdc-store store))
         (svc   (spawn-governance-service (list root) ($ root 'ballot-store)
                                          #:acdc-store store #:home-scope scope
                                          #:governor? (lambda (a) (equal? a "EFounder"))))
         (founder "EFounder")
         (ana (car (ids 1))) (cy (car (ids 1))) (bo (car (ids 1))) (dee (car (ids 1))))

    (display "\n── genesis: the founder's act, once ──\n")
    (check "nobody recognised: a stranger's ask has no one to sign it — still opens at k=1"
           (car ($ svc 'fp-request-enroll (aid bo) ECO)) 'ok)
    (check "the founder recognises themself while no one is recognised"
           (car ($ svc 'fp-grant founder ECO founder)) 'ok)
    (check "once bootstrapped, the unilateral grant is refused"
           (car ($ svc 'fp-grant founder ECO (aid dee))) 'error)
    (check "a recognised person cannot ask again"
           (car ($ svc 'fp-request-enroll founder ECO)) 'error)

    (display "\n── the ask: durable, clamped, readable ──\n")
    (let ((my (cdr ($ svc 'fp-my-ceremony (aid bo) ECO))))
      (check "Bo's ask is collecting" (assq-ref my 'state) 'collecting)
      (check "with one witness asked — the population clamps the policy's two"
             (assq-ref my 'quorum) 1))
    (check "asking again finds the standing ask, not a rival"
           (and (eq? 'ok (car ($ svc 'fp-request-enroll (aid bo) ECO)))
                (length (cdr ($ svc 'fp-pending founder ECO))))
           1)
    ;; the founder signs Bo in from the rail: the same landing the door uses
    (let* ((c (enroll-ceremony-for-candidate ECO (aid bo)))
           (said ($ c 'statement-said)))
      (check "a stranger cannot sign — no personhood"
             (catch #t (lambda () ($ c 'attest (aid dee) (sign dee said)) 'signed)
               (lambda _ 'refused))
             'refused)
      (check "the founder's signature is refused too — the founder's AID has no key here"
             (catch #t (lambda () ($ c 'attest founder "bogus") 'signed) (lambda _ 'refused))
             'refused))

    (display "\n── two witnesses, k = 2 ──\n")
    ;; Ana and Cy are recognised (the founder's ecosystem issues them directly
    ;; here — what a ceremony would have done); now the population is 3
    (for-each (lambda (id) ($ store 'issue (make-personhood-credential ECO (aid id) 100)))
              (list ana cy))
    (check "Dee asks" (car ($ svc 'fp-request-enroll (aid dee) ECO)) 'ok)
    (let* ((my (cdr ($ svc 'fp-my-ceremony (aid dee) ECO)))
           (c (enroll-ceremony-for-candidate ECO (aid dee)))
           (said ($ c 'statement-said)))
      (check "Dee's ask wants two" (assq-ref my 'quorum) 2)
      (check "Ana signs — one of two" (land-witness-attestation! said (aid ana) (sign ana said)) 'attested)
      (check "the ask reads one of two"
             (assq-ref (cdr ($ svc 'fp-my-ceremony (aid dee) ECO)) 'count) 1)
      (check "Ana cannot sign twice"
             (catch #t (lambda () (land-witness-attestation! said (aid ana) (sign ana said)) 'signed)
               (lambda _ 'refused))
             'refused)
      (check "the record on disk carries the one vouch"
             (length (assq-ref (enrollment-record said) 'attestations)) 1)

      (display "\n── a restart: the ask comes back with its vouch ──\n")
      ;; forget the live ceremony, as a process exit would
      (hash-remove! *attestation-ceremonies* said)
      (check "gone from the registry" (enroll-ceremony-for-candidate ECO (aid dee)) #f)
      (let ((back (cdr ($ svc 'fp-rehydrate!))))
        (check "the record restores it" (and (member said back) #t) #t))
      (let ((c2 (enroll-ceremony-for-candidate ECO (aid dee))))
        (check "collecting again, Ana's vouch still counted" ($ c2 'attestation-count) 1)
        (check "Cy signs — quorum, the credential issues"
               (land-witness-attestation! said (aid cy) (sign cy said)) 'finalized))
      (check "Dee is recognised" (holds-any-live-phc? store (aid dee)) #t)
      (check "Dee's credential carries both witnesses"
             (length (filter (lambda (e) (string-prefix? "witness-" (symbol->string (car e))))
                             (cred-edges (any-live-phc-for store (aid dee)))))
             2)
      (check "the ask reads finalized" (assq-ref (cdr ($ svc 'fp-my-ceremony (aid dee) ECO)) 'state) 'finalized)
      (check "no ask stands" (length (cdr ($ svc 'fp-pending founder ECO))) 1))  ; Bo's still collecting

    (display "\n── introducing someone: a recognised sponsor ──\n")
    (let ((eve (car (ids 1))))
      (check "Ana introduces Eve" (car ($ svc 'fp-open-ceremony (aid ana) ECO (aid eve))) 'ok)
      (check "a stranger cannot introduce"
             (car ($ svc 'fp-open-ceremony (aid eve) ECO (aid bo))) 'error)
      (check "Eve's ask names Ana as sponsor"
             (assq-ref (find (lambda (r) (equal? (aid eve) (assq-ref r 'candidate)))
                             (cdr ($ svc 'fp-pending founder ECO)))
                       'sponsor)
             (aid ana)))

    (display "\n── a second ecosystem sharing this SAME store: its own genesis, untouched ──\n")
    ;; ECO (Hearth) is fully bootstrapped above. ecosystem-personhood-
    ;; bootstrapped? (first-person.scm) is scoped to the ecosystem AID, not
    ;; the store — a brand-new ecosystem sharing this store must still reach
    ;; its own genesis grant. The bug this guards: fp-grant used to read
    ;; personhood-bootstrapped? (store-wide), which would have refused
    ;; every OTHER ecosystem's genesis the moment ANY ecosystem anywhere in
    ;; the store recognised its first person. Needs a genuinely resolvable
    ;; second scope, not a bare AID string — ecosystem-for deliberately
    ;; falls back to home-scope for an UNRESOLVABLE scope-id (a dial still
    ;; carrying a placeholder label), so the fixture must wire scope-of the
    ;; same way test-scope-of-and-vouch.scm's "Away" does.
    (let* ((new-root (spawn-scope-root "NewCommune"))
           (new-scope (spawn-scope "NewCommune" #:kind 'commune #:scope-root-ref new-root
                                   #:scope-aid "ENewCommune" #:acdc-store store))
           (svc2 (spawn-governance-service (list root) ($ root 'ballot-store)
                                           #:acdc-store store #:home-scope scope
                                           #:scope-of (lambda (a) (and (equal? a "ENewCommune") new-scope))
                                           #:governor? (lambda (a) (equal? a "EFounder")))))
      (check "a brand-new ecosystem, sharing Hearth's store, still reaches genesis"
             (car ($ svc2 'fp-grant founder "ENewCommune" founder)) 'ok)
      (check "and its own genesis window closes after, same as any ecosystem's"
             (car ($ svc2 'fp-grant founder "ENewCommune" (aid dee))) 'error))))

(test-summary!)
