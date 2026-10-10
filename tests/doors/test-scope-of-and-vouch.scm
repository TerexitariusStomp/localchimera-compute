;;; test-scope-of-and-vouch.scm — whose act is it.
;;;
;;; A COMMUNE's own acts resolve the commune they name (scope-of, the scope
;;; graph's find-ref in production): a grant made to a commune that is not
;;; the gateway's founding one is accepted by THAT commune, and an unknown
;;; commune is refused by name. A PERSON's act — a vouch — carries the
;;; person's own signature, a forged one is refused, and a retag ends the
;;; prior vouch so the gate reads one group, the current one.
;;;
;;; Run:  guile --no-auto-compile -L module -L tests tests/doors/test-scope-of-and-vouch.scm

(use-modules (playnet boot scope) (playnet boot governance) (playnet economy socialization) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri said-portable) (playnet keri first-person credentials) (playnet scope root) (srfi srfi-1) (playnet doors service)
             (playnet test harness)
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid
                        sign-said verify-said-signature))
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(define (preimage-fields pre) (lambda (k) (let ((p (assq k pre))) (and p (cdr p)))))
(define (said-of ar)
  (compute-said (ar 'issuer) (ar 'holder) (ar 'schema) (ar 'claims) (or (ar 'edges) '())))
(define FUTURE "2099-01-01T00:00:00Z")
(define OWNER  "EOwner00000000000000000000000000000000000000")
(define MEMBER "EMember0000000000000000000000000000000000000")
(define TIA    "ETia0000000000000000000000000000000000000000")

(display "\n── scope-for: the commune named is the commune that acts ──\n")
(with-vat (spawn-vat)
  (let* ((store (spawn-acdc-store))
         (home-id (make-keri-identity)) (away-id (make-keri-identity))
         (home-aid (keri-identity-aid home-id)) (away-aid (keri-identity-aid away-id))
         (root-h (spawn-scope-root "Home")) (root-a (spawn-scope-root "Away"))
         (home (spawn-scope "Home" #:kind 'commune #:scope-root-ref root-h
                            #:scope-aid home-aid #:keypair (keri-identity-keypair home-id)
                            #:acdc-store store))
         (away (spawn-scope "Away" #:kind 'commune #:scope-root-ref root-a
                            #:scope-aid away-aid #:keypair (keri-identity-keypair away-id)
                            #:acdc-store store))
         ;; the gateway's founding commune is Home; Away is another commune on
         ;; the same box, reachable only through scope-of
         (svc (spawn-governance-service (list root-h) ($ root-h 'ballot-store)
                                        #:acdc-store store #:home-scope home
                                        #:scope-of (lambda (aid) (and (equal? aid away-aid) away))))
         ;; grants with a care term — the commune's consent is its own act
         (to-away (socialize-private-resource store OWNER away-aid "press" 1
                                              #:until FUTURE #:return-to "barn"))
         (to-home (socialize-private-resource store OWNER home-aid "press" 1
                                              #:until FUTURE #:return-to "barn")))
    (check "Away accepts a grant made to Away"
           (car ($ svc 'accept-socialization MEMBER away-aid (cred-said to-away))) 'ok)
    (check "Home accepts its own, through home-scope"
           (car ($ svc 'accept-socialization MEMBER home-aid (cred-said to-home))) 'ok)
    (check "a commune this process cannot reach is refused by name"
           (car ($ svc 'accept-socialization MEMBER "ENobody" (cred-said to-away))) 'error)
    (check "Home never acts for Away's grant"
           (car ($ svc 'accept-socialization MEMBER home-aid (cred-said to-away))) 'error)))

(display "\n── scope-for resolves the commune; personhood decides who may act for it ──\n")
(with-vat (spawn-vat)
  (let* ((store (spawn-acdc-store))
         (home-id (make-keri-identity)) (away-id (make-keri-identity))
         (home-aid (keri-identity-aid home-id)) (away-aid (keri-identity-aid away-id))
         (root-h (spawn-scope-root "Home2")) (root-a (spawn-scope-root "Away2"))
         (home (spawn-scope "Home2" #:kind 'commune #:scope-root-ref root-h
                            #:scope-aid home-aid #:keypair (keri-identity-keypair home-id)
                            #:acdc-store store))
         (away (spawn-scope "Away2" #:kind 'commune #:scope-root-ref root-a
                            #:scope-aid away-aid #:keypair (keri-identity-keypair away-id)
                            #:acdc-store store))
         (svc (spawn-governance-service (list root-h) ($ root-h 'ballot-store)
                                        #:acdc-store store #:home-scope home
                                        #:scope-of (lambda (aid) (and (equal? aid away-aid) away))))
         (grant (socialize-private-resource store OWNER away-aid "press" 1
                                            #:until FUTURE #:return-to "barn"))
         (citizen (make-keri-identity)) (citizen-aid (keri-identity-aid citizen)))
    ;; Away has recognised nobody yet — the bootstrap read fails open, same
    ;; as every other personhood gate in this codebase.
    (check "before Away's first PHC: a stranger still accepts (bootstrap open)"
           (car ($ svc 'accept-socialization MEMBER away-aid (cred-said grant))) 'ok)
    ;; Away recognises its actual citizen.
    ($ store 'issue (make-personhood-credential away-aid citizen-aid "2026-01-01T00:00:00Z"))
    (let ((grant2 (socialize-private-resource store OWNER away-aid "press" 2
                                              #:until FUTURE #:return-to "barn")))
      (check "post-bootstrap: a stranger with no PHC from Away is refused"
             (car ($ svc 'accept-socialization MEMBER away-aid (cred-said grant2))) 'error)
      (check "post-bootstrap: Away's own recognised citizen still accepts"
             (car ($ svc 'accept-socialization citizen-aid away-aid (cred-said grant2))) 'ok)
      ;; Home2 shares this SAME store and has recognised nobody of its own —
      ;; Away2's bootstrap must stay Away2's alone. may-govern? reads
      ;; phcs-in-ecosystem (scoped to scope-aid), never the store-wide
      ;; personhood-bootstrapped?; the latter would have closed Home2's
      ;; window the instant ANY commune sharing the store recognised anyone.
      (let ((home-grant (socialize-private-resource store OWNER home-aid "press" 3
                                                    #:until FUTURE #:return-to "barn")))
        (check "Home2's own bootstrap window is untouched by Away2's"
               (car ($ svc 'accept-socialization MEMBER home-aid (cred-said home-grant))) 'ok)))))

(display "\n── the vouch is the voucher's own signature; a retag ends the prior ──\n")
(with-vat (spawn-vat)
  (let* ((store (spawn-acdc-store))
         (eco-id (make-keri-identity)) (eco-aid (keri-identity-aid eco-id))
         (root (spawn-scope-root "Eco"))
         (scope (spawn-scope "Eco" #:kind 'commune #:scope-root-ref root
                             #:scope-aid eco-aid #:keypair (keri-identity-keypair eco-id)
                             #:acdc-store store))
         (svc (spawn-governance-service (list root) ($ root 'ballot-store)
                                        #:acdc-store store #:home-scope scope))
         (alice (make-keri-identity)) (alice-kp (keri-identity-keypair alice))
         (alice-aid (keri-identity-aid alice)))
    (check "no personhood, no vouch"
           (car ($ svc 'fp-vouch-preimage alice-aid eco-aid TIA "friends" "t1")) 'error)
    ;; Alice holds a personhood in Eco — the precondition to vouch
    ($ store 'issue (make-personhood-credential eco-aid alice-aid "2026-01-01T00:00:00Z"))
    (let* ((ar   (preimage-fields (cadr ($ svc 'fp-vouch-preimage alice-aid eco-aid TIA "friends" "t1"))))
           (said (said-of ar))
           (sig  (sign-said said alice-kp)))
      (check "the preimage's issuer is the voucher" (equal? (ar 'issuer) alice-aid))
      (check "a wrong key is refused"
             (car ($ svc 'fp-vouch-signed alice-aid eco-aid TIA "friends" "t1"
                     (sign-said said (keri-identity-keypair (make-keri-identity)))))
             'error)
      (check "the signed vouch is issued"
             (car ($ svc 'fp-vouch-signed alice-aid eco-aid TIA "friends" "t1" sig)) 'ok)
      (let ((vrc (find (lambda (c) (and (equal? (cred-schema c) *schema-playnet-relationship*)
                                        (not (cred-revoked? c))))
                       ($ store 'all))))
        (check "it carries Alice's signature, not the scope's"
               (and (cred-signature vrc)
                    (verify-said-signature (cred-said vrc) (cred-signature vrc) alice-aid)))
        (check "the gate reads the group off it, as the kind's one name"
               (vrc-groups-of store alice-aid TIA) '("friend")))
      ;; retag: colleague replaces friends
      (let* ((ar2  (preimage-fields (cadr ($ svc 'fp-vouch-preimage alice-aid eco-aid TIA "colleague" "t2"))))
             (sig2 (sign-said (said-of ar2) alice-kp)))
        (check "the retag is issued"
               (car ($ svc 'fp-vouch-signed alice-aid eco-aid TIA "colleague" "t2" sig2)) 'ok)
        (check "the prior rel is ended — one group stands, the current one"
               (vrc-groups-of store alice-aid TIA) '("colleague"))))))

(display "\n── what stands between two people: the pair's reading, and a vouch withdrawn ──\n")
(with-vat (spawn-vat)
  (let* ((store (spawn-acdc-store))
         (eco-id (make-keri-identity)) (eco-aid (keri-identity-aid eco-id))
         (root (spawn-scope-root "Pair"))
         (scope (spawn-scope "Pair" #:kind 'commune #:scope-root-ref root
                             #:scope-aid eco-aid #:keypair (keri-identity-keypair eco-id)
                             #:acdc-store store))
         (svc (spawn-governance-service (list root) ($ root 'ballot-store)
                                        #:acdc-store store #:home-scope scope))
         (aid-of (lambda () (keri-identity-aid (make-keri-identity))))
         (ana (aid-of)) (ben (aid-of)) (cy (aid-of)) (dee (aid-of))
         (row (lambda (me them)
                (let ((r (find (lambda (r) (equal? them (assq-ref r 'aid)))
                               (cdr ($ svc 'relationships me eco-aid (list them))))))
                  (lambda (k) (assq-ref r k))))))
    ;; Ana, Ben and Cy are recognised; Dee is a contact with nothing signed
    (for-each (lambda (p) ($ store 'issue (make-personhood-credential eco-aid p "2026-01-01T00:00:00Z")))
              (list ana ben cy))
    (check "nothing signed: recognised, and no vouch either way"
           (let ((r (row ana ben))) (list (r 'recognised) (r 'mine) (r 'theirs))) '(#t #f #f))
    (check "a contact with no personhood reads unrecognised"
           ((row ana dee) 'recognised) #f)
    (check "Ana vouches for Ben as friends" (car ($ svc 'fp-vouch ana eco-aid ben "friends")) 'ok)
    (check "Ana's row for Ben: her vouch, by the kind's one name"
           (let ((r (row ana ben))) (list (r 'mine) (r 'theirs))) '("friend" #f))
    (check "Ben's row for Ana: the same vouch, read from his side"
           (let ((r (row ben ana))) (list (r 'mine) (r 'theirs))) '(#f "friend"))
    (check "Cy vouches for Ben as a colleague" (car ($ svc 'fp-vouch cy eco-aid ben "colleague")) 'ok)
    (check "a third person's vouch is in nobody else's reading"
           (let ((r (row ana ben))) (list (r 'mine) (r 'theirs))) '("friend" #f))
    (check "Ben vouches back as family" (car ($ svc 'fp-vouch ben eco-aid ana "family")) 'ok)
    (check "each side reads both vouches"
           (list (let ((r (row ana ben))) (list (r 'mine) (r 'theirs)))
                 (let ((r (row ben ana))) (list (r 'mine) (r 'theirs))))
           '(("friend" "family") ("family" "friend")))
    (check "a vouch with no kind said is the default kind"
           (begin ($ svc 'fp-vouch ana eco-aid cy "") ((row ana cy) 'mine)) "contact")
    (check "the caller is in no row of their own reading"
           (cdr ($ svc 'relationships ana eco-aid (list ana))) '())
    ;; withdrawing is the voucher's own act
    (check "Ana withdraws her vouch for Ben" (car ($ svc 'fp-withdraw-vouch ana eco-aid ben)) 'ok)
    (check "her vouch is gone; his stands"
           (let ((r (row ana ben))) (list (r 'mine) (r 'theirs))) '(#f "family"))
    (check "Cy's vouch for Ben is untouched by Ana's withdrawal"
           ((row cy ben) 'mine) "colleague")
    (check "the gate reads no group from Ana for Ben" (vrc-groups-of store ana ben) '())
    (check "withdrawing where nothing stands is the same ok"
           (car ($ svc 'fp-withdraw-vouch ana eco-aid ben)) 'ok)
    ;; an open ask rides the row
    (check "Dee asks to be recognised" (car ($ svc 'fp-request-enroll dee eco-aid)) 'ok)
    (let ((ask ((row ana dee) 'ask)))
      (check "Dee's row carries the ask: its id, none signed, not by Ana"
             (and (pair? ask) (string? (assq-ref ask 'said))
                  (list (assq-ref ask 'count) (assq-ref ask 'signed)))
             '(0 #f))
      (check "the quorum is at least one" (>= (assq-ref ask 'quorum) 1)))
    (check "a recognised contact has no ask" ((row ana ben) 'ask) #f)))

(test-summary!)
