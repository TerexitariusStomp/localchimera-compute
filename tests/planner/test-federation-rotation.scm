;;; test-federation-rotation.scm — a scope's key rotates and the wire follows.
;;;
;;; An AID names an inception; after a rotation the key that signs for it is the
;;; one its key event log leaves in force. So that a verifier who holds only the
;;; AID can follow, a rotated scope's words carry its log, and the verifier
;;; reads the key off it (keri/key-state.scm):
;;;
;;;   • a scope's log is a valid log — the events after the inception carry the
;;;     inception's own identifier, and rotations reveal the keys the last
;;;     committed to (`events->key-state`);
;;;   • the key a rotation commits to as the next is derived from the bran, so a
;;;     restart finds it and the scope can rotate again;
;;;   • a word from a rotated scope verifies under the key now in force; the key
;;;     it incepted with no longer speaks, and a verifier that has seen it
;;;     rotated refuses a word that arrives without its log;
;;;   • a credential is checked under the key in force when the log sealed it;
;;;   • a member's census, signed after a rotation, carries the log;
;;;   • the federation's desk answers under its rotated key and a commune takes
;;;     its word, the credentials it issued before the rotation still standing.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-federation-rotation.scm

(use-modules (playnet test harness)
             (playnet credentials membership) (playnet credentials registry) (playnet keri acdc) (playnet keys kel-store) (playnet boot scope) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri inception)
             (playnet gateway federate)
             ((playnet keys kel-store) #:select (spawn-kel-store))
             ((playnet governance sturdyref-credential) #:select (verified-spec sturdyref-credential-end census-credential-goods))
             ((playnet keri inception) #:select (governance-create-scope-aid! scope-inception-aid scope-inception-bran
                                                 scope-inception-keypair scope-inception-next-keypair
                                                 scope-inception-signed-icp))
             ((playnet keri key-state) #:select (events->key-state key-in-force-at state-key state-sn))
             ((playnet keri citizen-sig) #:select (sign-bytes-under-aid sign-said))
             ((playnet keri signify-portable) #:select (ed25519-keypair-public public-key->aid-prefix
                                                         next-key-digest))
             ((playnet utils hex) #:select (bv->hex))
             ((playnet federation wire) #:select (signed-reply verify-signed make-key-ledger))
             ((playnet federation peer) #:select (^attestation-fold))
             (goblins) (goblins vat) (rnrs bytevectors) (srfi srfi-1))

(define vat (spawn-vat))
(define (key-of kp) (public-key->aid-prefix (ed25519-keypair-public kp)))

;; a scope with a real inception, a key log, and the means to rotate: what the
;; gateway mints, built here by hand
(define (mint! name)
  (let* ((inc (governance-create-scope-aid!))
         (aid (scope-inception-aid inc))
         (ks (spawn-kel-store)))
    ($ ks 'append (scope-inception-signed-icp inc))
    (register-rotation-keypair-fn! aid (rotation-keypair-fn (scope-inception-bran inc)))
    (values (spawn-scope name #:kind 'federation #:scope-aid aid
                         #:keypair (scope-inception-keypair inc)
                         #:next-keypair (scope-inception-next-keypair inc)
                         #:kel-store ks #:acdc-store (spawn-acdc-store))
            aid inc ks)))

(with-vat vat
  (call-with-values (lambda () (mint! "Valley"))
    (lambda (fed aid inc ks)
      (display "\n── a scope's log is a valid log ──\n")
      (define (log) ($ ks 'all))
      (check "the inception alone: the inception key speaks, sequence 0"
             (let ((s (events->key-state aid (log)))) (list (state-key s) (state-sn s)))
             (list aid 0))
      (define word-0 (signed-reply (scope-signer aid fed) `((aid . ,aid) (said . "hello"))))
      (check "before a rotation the word carries no log" (assq-ref (call-with-input-string (car word-0) read) 'kel) #f)
      (check "and verifies under the AID" (call-with-values (lambda () (verify-signed word-0 aid)) (lambda (p a) a)) aid)

      (define cred-before (cred-signed-by-scope
                           (make-federation-sturdyref-credential aid "EMember" "m" "ocapn://m/s/1" 'websocket "2026-10-02")
                           fed))
      ($ fed 'anchor-acdc (cred-said cred-before))
      ($ fed 'rotate-keys)
      ($ fed 'rotate-keys)
      (define after (events->key-state aid (log)))
      (check "after two rotations the log verifies, at sequence 3 (icp, ixn, rot, rot)"
             (and (not (string? after)) (state-sn after)) 3)
      (check "the key in force is the third the bran derives (index 2)"
             (and (not (string? after)) (state-key after))
             (key-of ((rotation-keypair-fn (scope-inception-bran inc)) 2)))
      (check "and the key it has committed to is the fourth (index 3), which a restart derives again"
             (let ((last-rot (assoc-ref (last (log)) "rot")))
               (vector-ref (assoc-ref last-rot "n") 0))
             (next-key-digest (ed25519-keypair-public ((rotation-keypair-fn (scope-inception-bran inc)) 3))))
      (check "a log with an event dropped does not chain"
             (string? (events->key-state aid (append (list (car (log))) (cddr (log))))) #t)
      (check "a log that is not this AID's is refused"
             (string? (events->key-state "EAnotherAid" (log))) #t)

      (display "\n── a word after the rotation ──\n")
      (define signer (scope-signer aid fed))
      (define word-1 (signed-reply signer `((aid . ,aid) (said . "after"))))
      (check "it carries the log" (pair? (assq-ref (call-with-input-string (car word-1) read) 'kel)) #t)
      (check "and verifies under the key now in force"
             (call-with-values (lambda () (verify-signed word-1 aid)) (lambda (p a) (assq-ref p 'said))) "after")
      (check "the inception key no longer speaks: its signature over the same words is refused"
             (let* ((text (car word-1))
                    (old (sign-bytes-under-aid (string->utf8 text) (scope-inception-keypair inc))))
               (raises? (lambda () (verify-signed (list text old) aid))))
             #t)
      (check "a log from another identifier cannot stand in"
             (raises? (lambda () (verify-signed word-1 "EAnotherAid")))
             #t)
      (let ((ledger (make-key-ledger)))
        (verify-signed word-1 aid #:ledger ledger)
        (check "a verifier that has seen the rotation refuses a word without the log"
               (raises? (lambda () (verify-signed word-0 aid #:ledger ledger))) #t)
        (check "and one without it that a verifier who has seen nothing still takes (the old behaviour)"
               (call-with-values (lambda () (verify-signed word-0 aid)) (lambda (p a) a)) aid))

      (display "\n── the ledger is kept and read back ──\n")
      (let* ((kept #f)
             (l1 (make-key-ledger #:keep (lambda (states) (set! kept states)))))
        (verify-signed word-1 aid #:ledger l1)
        (check "what the verifier read is handed to its keeper" (and kept (assoc aid kept) #t) #t)
        (let ((l2 (make-key-ledger #:resume kept)))      ; a restart
          (check "a restarted verifier still refuses a word without the log"
                 (raises? (lambda () (verify-signed word-0 aid #:ledger l2))) #t)
          (check "and still takes the word that carries it"
                 (call-with-values (lambda () (verify-signed word-1 aid #:ledger l2)) (lambda (p a) a)) aid))
        (let* ((state (cdr (assoc aid kept)))
               (forked (acons 'said "EAForkedEventSaid" (alist-delete 'said state)))
               (l3 (make-key-ledger #:resume (list (cons aid forked)))))
          (check "a log that differs at a sequence already read is a fork, and is refused"
                 (raises? (lambda () (verify-signed word-1 aid #:ledger l3))) #t)))

      (display "\n── credentials ──\n")
      (define cred-after (cred-signed-by-scope
                          (make-federation-sturdyref-credential aid "EMember2" "m2" "ocapn://m/s/2" 'websocket "2026-10-03")
                          fed))
      (define (end c kel)
        (call-with-values (lambda () (sturdyref-credential-end c #:issuer aid #:kel kel)) (lambda (a u) u)))
      (check "issued and sealed before the rotation: read under the key of its day"
             (end cred-before (log)) "ocapn://m/s/1")
      (check "issued after: under the key now in force" (end cred-after (log)) "ocapn://m/s/2")
      (check "a credential signed by the inception key AFTER the rotation is refused"
             (let* ((forged (cred-with-signature
                             (make-federation-sturdyref-credential aid "EMember3" "m3" "ocapn://m/s/3" 'websocket "2026-10-04")
                             (sign-said (cred-said (make-federation-sturdyref-credential aid "EMember3" "m3" "ocapn://m/s/3" 'websocket "2026-10-04"))
                                        (scope-inception-keypair inc)))))
               (raises? (lambda () (end forged (log)))))
             #t)
      (check "the key in force at the seal is the inception key's"
             (key-in-force-at aid (log) (cred-said cred-before)) aid)

      (display "\n── a member whose key rotated tells its census ──\n")
      (call-with-values (lambda () (mint! "Granary"))
        (lambda (member maid minc mks)
          ($ member 'rotate-keys)
          (let ((c (census-credential (scope-signer maid member) aid '("flour" "bread") "t1")))
            (check "the census carries the member's log" (pair? (cred-claim c 'kel)) #t)
            (check "and its goods read under the key now in force" (census-credential-goods c) '("bread" "flour"))
            (let ((gov ($ fed 'mint-gov-cap "bootstrap")))
              ($ fed 'admit-commune-remote gov "granary-rotated" maid "ocapn://g/s/rot")
              ($ fed 'accept-census c)
              (check "the federation holds the census that carries the log"
                     (and (assoc maid (assq-ref ($ fed 'federation-spec) 'census)) #t) #t)
              (let ((stale (let ((plain (make-federation-census-credential maid aid '("gold") "t2")))
                             (cred-with-signature plain (sign-said (cred-said plain) (scope-inception-keypair minc))))))
                (check "a later census under the retired inception key, no log, is refused: the federation has read the rotation"
                       (raises? (lambda () ($ fed 'accept-census stale))) #t)
                (check "and the standing census is still the one that carries the log"
                       (map (lambda (g) g)
                            (census-credential-goods (cdr (assoc maid (assq-ref ($ fed 'federation-spec) 'census)))))
                       '("bread" "flour"))))
            (check "signed with the inception key instead, it is refused"
                   (raises? (lambda ()
                              (census-credential-goods
                               (cred-with-signature c (sign-said (cred-said c) (scope-inception-keypair minc))))))
                   #t))))

      (display "\n── the desk answers under the rotated key ──\n")
      (let* ((gov ($ fed 'mint-gov-cap "bootstrap"))
             (store ($ fed 'acdc-store))
             (fold (spawn ^attestation-fold '()))
             (desk (spawn ^federation-desk fed signer fold "ocapn://the-fold")))
        ($ fed 'admit-commune-remote gov "granary" "EGranaryAid" "ocapn://g/s/1")
        ($ fed 'admit-commune-remote gov "table" "ETableAid" "ocapn://t/s/2")
        (let* ((word ($ desk 'spec "n1"))
               (payload (call-with-input-string (car word) read)))
          (check "the word carries the federation's log" (pair? (assq-ref payload 'kel)) #t)
          (check "a commune reads the credentials the federation issued under the key of their day"
                 (length (assq-ref (verified-spec aid (assq-ref payload 'credentials) #:kel (assq-ref payload 'kel)) 'credentials))
                 3)       ; the two admitted here and the rotated member admitted above
          (check "without the log it cannot: the inception key no longer signs the newer ones"
                 (raises? (lambda () (verified-spec aid (assq-ref payload 'credentials)))) #t))))))

(test-summary!)
