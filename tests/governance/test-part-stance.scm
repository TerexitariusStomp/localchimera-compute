;;; test-part-stance.scm — a HAND of signed stances on parts of a plan.
;;;
;;; docs/planning/voice/voice-over-the-plan.md "The warp, and the conversation":
;;; a stance is signed as an expression-stance credential with domain
;;; plan-part, its targets the parts in VF terms (parts.scm), its values SIGNED
;;; in [−1, 1]. What this suite pins:
;;;   • the client-signed round trip (part-stance-preimage → sign → cast-part-signed),
;;;     the twin of test-client-signing's stance round trip;
;;;   • the hand parses and round-trips through the SAID (string->part);
;;;   • a negative portion is accepted HERE and refused by validate-distribution
;;;     — the ballot tally's rule and the hand's are two doors, not one;
;;;   • a re-cast supersedes: the previous hand is revoked, the standing rows
;;;     are the new hand's (stances stand until changed);
;;;   • a wrong-key signature and an out-of-range portion are refused.
;;;
;;; Run:  guile -q -L module tests/governance/test-part-stance.scm

(use-modules (playnet governance expression) (playnet boot scope) (playnet governance service) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri said-portable) (playnet scope root) (srfi srfi-1) (playnet test harness)
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid sign-said))
             ((playnet governance expression) #:select (validate-distribution))
             (playnet vf facts parts)
             (goblins) (goblins utils hashmap) (srfi srfi-1))

(define (preimage-fields pre) (lambda (k) (let ((p (assq k pre))) (and p (cdr p)))))
(define (said-of ar) (compute-said (ar 'issuer) (ar 'holder) (ar 'schema) (ar 'claims) (or (ar 'edges) '())))
(define (claim ar k) (let ((p (assq k (ar 'claims)))) (and p (cdr p))))
(define (raises? thunk) (catch #t (lambda () (thunk) #f) (lambda _ #t)))

(display "\n── the hand's grammar ──\n")
(let ((h (validate-hand '(("process=bake;place=town" . -0.5) ("" . 1)))))
  (check "a hand parses to (part . portion), signed" (and (= 2 (length h)) (= -0.5 (cdar h))))
  (check "the empty string is the scope's own part" (part-empty? (car (cadr h)))))
(check "a portion beyond [−1, 1] is refused" (raises? (lambda () (validate-hand '(("process=bake" . 2))))))
(check "the ballot tally's rule refuses what the hand accepts (two doors)"
       (raises? (lambda () (validate-distribution (hashmap ("a" -0.5)) '("a")))))

(display "\n── the client-signed round trip ──\n")
(with-vat (spawn-vat)
  (let* ((sid (make-keri-identity)) (skp (keri-identity-keypair sid)) (scope-aid (keri-identity-aid sid))
         (cid (make-keri-identity)) (ckp (keri-identity-keypair cid)) (citizen (keri-identity-aid cid))
         (root (spawn-scope-root "Bakery")) (store (spawn-acdc-store))
         (scope (spawn-scope "Bakery" #:kind 'commune #:scope-root-ref root
                             #:scope-aid scope-aid #:keypair skp #:acdc-store store))
         (svc (spawn-governance-service (list root) ($ root 'ballot-store)
                                        #:acdc-store store #:home-scope scope))
         (hand '(("process=bake;place=town" . -0.5) ("process=mill" . 0.25))))
    (let* ((pre ($ svc 'part-stance-preimage citizen "bakery" hand))
           (ar (preimage-fields (cadr pre)))
           (ts (claim ar 'timestamp)) (u (claim ar 'u))
           (said (said-of ar)) (sig (sign-said said ckp)))
      (check "preimage answers ok" (eq? 'ok (car pre)))
      (check "domain plan-part, expression-id names the scope"
             (and (equal? (claim ar 'domain) "plan-part") (equal? (claim ar 'expression-id) "plan-part:bakery")))
      (check "the distribution is the hand, key-sorted, signed values kept"
             (equal? (claim ar 'distribution) '(("process=bake;place=town" . -0.5) ("process=mill" . 0.25))))
      (check "cast-part-signed accepted" (eq? 'ok ($ svc 'cast-part-signed citizen "bakery" hand ts sig u)))
      (check "without the echoed nonce it is refused"
             (let ((r ($ svc 'cast-part-signed citizen "bakery" hand ts sig)))
               (and (pair? r) (eq? 'error (car r)))))
      (let ((rows ($ svc 'plan-part-hands "bakery")))
        (check "the standing hands are rows (owner part-string portion)"
               (equal? rows `((,citizen "process=bake;place=town" -0.5) (,citizen "process=mill" 0.25))))
        (check "every part-string round-trips through the grammar"
               (every (lambda (r) (part? (string->part (cadr r)))) rows)))
      (let* ((eve (make-keri-identity))
             (r ($ svc 'cast-part-signed citizen "bakery" hand ts (sign-said said (keri-identity-keypair eve)) u)))
        (check "wrong-key signature REJECTED" (and (pair? r) (eq? 'error (car r)))))
      (check "an out-of-range portion is refused at the preimage"
             (let ((r ($ svc 'part-stance-preimage citizen "bakery" '(("process=bake" . 3)))))
               (and (pair? r) (eq? 'error (car r))))))

    (display "\n── a re-cast supersedes: stances stand until changed ──\n")
    (let* ((hand2 '(("" . 1)))
           (ar (preimage-fields (cadr ($ svc 'part-stance-preimage citizen "bakery" hand2))))
           (ts (claim ar 'timestamp)) (u (claim ar 'u))
           (sig (sign-said (said-of ar) ckp)))
      (check "second cast accepted" (eq? 'ok ($ svc 'cast-part-signed citizen "bakery" hand2 ts sig u)))
      (check "the standing hand is the new one, the old revoked"
             (equal? ($ svc 'plan-part-hands "bakery") `((,citizen "" 1.0))))
      (check "the rail keeps both credentials, one revoked"
             (= 2 (length (filter (lambda (c) (equal? (cred-claim c 'domain) "plan-part")) ($ store 'all))))))

    (display "\n── another scope's rail is another rail ──\n")
    (check "no hands stand on a scope nobody cast on" (null? ($ svc 'plan-part-hands "mill")))))

(test-summary!)
