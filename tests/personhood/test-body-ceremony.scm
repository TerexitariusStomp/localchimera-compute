;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/personhood/test-body-ceremony.scm — a body's AID is its stewards' k-of-n group
;;;
;;; What this pins (module/playnet/personhood/body-ceremony.scm and the
;;; threshold reader in keri/key-state.scm):
;;;   • three stewards, k = 2: any two signatures publish the body's log,
;;;     `current-keys` on the body AID reads the member keys in roster order,
;;;     and the body AID is a function of the roster, whoever signs;
;;;   • one signature leaves the body unpublished; a non-steward, a wrong
;;;     key, a duplicate and a mis-indexed signature are refused;
;;;   • `close!` runs once, with the body AID;
;;;   • a rotation with cuts and adds, signed by the continuing stewards from
;;;     their rotated dial AIDs, verifies under the threshold reader and
;;;     moves the body's keys and quorum along;
;;;   • the threshold reader counts distinct valid indices against kt.
;;; The single-key path is pinned by tests/identity/test-kel-in-hand.scm.
;;;
;;; Run: guile -L module tests/personhood/test-body-ceremony.scm
(use-modules (playnet test harness)
             (playnet keri signify)   ; installs the native crypto backend
             ((playnet keri crypto-primitives) #:select (ed25519-keypair-public))
             ((playnet keri signify-portable)
              #:select (bran->signing-keypair bran->rotation-keypair next-key-digest
                        public-key->aid-prefix build-icp build-rot sign-event
                        sign-event/indexed sign-bytes))
             ((playnet keri cesr) #:select (cesr-bytes->qb64))
             ((playnet keri key-state)
              #:select (check-icp check-sigs/threshold events->key-state
                        state-keys state-kt state-nexts))
             (playnet identity oobi-host)
             (playnet personhood body-ceremony)
             (goblins)
             (rnrs bytevectors)
             (srfi srfi-1))

(define vat (spawn-vat #:name "body-ceremony-test"))
(define dir (string-append (or (getenv "TMPDIR") "/tmp")
                           "/body-ceremony-test-" (number->string (getpid))))

;; ── stewards: dial AIDs with their own key logs ──
(define (key-of kp) (public-key->aid-prefix (ed25519-keypair-public kp)))
(define (digest-of kp) (next-key-digest (ed25519-keypair-public kp)))

(define (make-steward bran)
  "A steward as the browser makes one: keypairs along the passcode's chain,
   the inception and its signature. An alist."
  (let* ((kp0 (bran->signing-keypair bran))
         (kp1 (bran->rotation-keypair bran 1))
         (kp2 (bran->rotation-keypair bran 2)))
    (call-with-values
        (lambda () (build-icp #:keys (list (key-of kp0)) #:nkeys (list (digest-of kp1))))
      (lambda (json said icp)
        `((aid . ,(assoc-ref icp "i")) (kp0 . ,kp0) (kp1 . ,kp1) (kp2 . ,kp2)
          (icp . ,icp) (sigs . ,(vector (sign-event json kp0))))))))

(define (s-aid s) (assq-ref s 'aid))
(define (s-kp s n) (assq-ref s (case n ((0) 'kp0) ((1) 'kp1) (else 'kp2))))

(define alice (make-steward "0ADEMOalice000000000X"))
(define bob   (make-steward "0ADEMObob00000000000X"))
(define carol (make-steward "0ADEMOcarol000000000X"))
(define dave  (make-steward "0ADEMOdave0000000000X"))
(define mallory (make-steward "0ADEMOmallory0000000X"))

(define (fresh-host . stewards)
  (with-vat vat
    (let ((host (spawn ^oobi-host)))
      (for-each (lambda (s) ($ host 'put! (s-aid s) (assq-ref s 'icp) (assq-ref s 'sigs)))
                stewards)
      host)))

(define (sign-0b json kp)
  "The browser's form: the bytes signed as itself, code 0B."
  (cesr-bytes->qb64 "0B" (sign-bytes (string->utf8 json) kp)))

;; ── the ceremony: three stewards, k = 2 ──
(display "\n── the inception preimage ──\n")
(define host (fresh-host alice bob carol mallory))
(define closed '())
(define ceremony
  (with-vat vat
    (spawn-body-ceremony #:scope-aid "scope-1" #:initiator-aid (s-aid alice)
                         #:steward-aids (list (s-aid alice) (s-aid bob) (s-aid carol))
                         #:k 2 #:oobi-host host #:witness-dir dir
                         #:close! (lambda (aid) (set! closed (cons aid closed))))))
(define pre (with-vat vat ($ ceremony 'preimage (s-aid bob))))
(define fields (assq-ref pre 'fields))
(check "the round is the inception" "inception" (assq-ref pre 'what))
(check "the SAID is the inception's" (assoc-ref fields "d") (assq-ref pre 'said))
(check "the inception is self-addressing" (assoc-ref fields "i") (assoc-ref fields "d"))
(check "kt is k" "2" (assoc-ref fields "kt"))
(check "nt is k" "2" (assoc-ref fields "nt"))
(check "k holds each steward's current key in roster order"
       (list (key-of (s-kp alice 0)) (key-of (s-kp bob 0)) (key-of (s-kp carol 0)))
       (vector->list (assoc-ref fields "k")))
(check "n holds each steward's committed next digest"
       (list (digest-of (s-kp alice 1)) (digest-of (s-kp bob 1)) (digest-of (s-kp carol 1)))
       (vector->list (assoc-ref fields "n")))
(check "the caller's index is their roster position" 1 (assq-ref pre 'index))
(check "a non-steward has no index" #f (assq-ref (with-vat vat ($ ceremony 'preimage (s-aid mallory))) 'index))
(define body-aid (assq-ref pre 'said))
(define json (assq-ref pre 'json))
(check "the record stands from the first moment"
       'collecting (assq-ref (body-ceremony-record dir body-aid) 'state))

(display "\n── refusals ──\n")
(check-error "a non-steward's signature is refused"
             (lambda () (with-vat vat ($ ceremony 'sign (s-aid mallory) (sign-0b json (s-kp mallory 0))))))
(check-error "a steward's signature under another key is refused"
             (lambda () (with-vat vat ($ ceremony 'sign (s-aid bob) (sign-0b json (s-kp mallory 0))))))
(check-error "a signature over other bytes is refused"
             (lambda () (with-vat vat ($ ceremony 'sign (s-aid bob) (sign-0b (string-append json " ") (s-kp bob 0))))))
(check-error "an indexed signature at another steward's index is refused"
             (lambda () (with-vat vat ($ ceremony 'sign (s-aid bob) (sign-event/indexed json (s-kp bob 0) 0)))))
(check-error "garbage is not a signature"
             (lambda () (with-vat vat ($ ceremony 'sign (s-aid bob) "not-a-signature"))))
(check "nothing counted" 0 (assq-ref (with-vat vat ($ ceremony 'status)) 'have))

(display "\n── one signature: unpublished ──\n")
(define r1 (with-vat vat ($ ceremony 'sign (s-aid alice) (sign-0b json (s-kp alice 0)))))
(check "one of two" '(1 . 2) (cons (assq-ref r1 'have) (assq-ref r1 'need)))
(check "not published" #f (assq-ref r1 'published))
(check "the body is unknown to the oobi-host" #f (with-vat vat ($ host 'known? body-aid)))
(check "close! has not run" '() closed)
(check-error "the same steward cannot sign twice"
             (lambda () (with-vat vat ($ ceremony 'sign (s-aid alice) (sign-0b json (s-kp alice 0))))))
(check "the record carries the one signature"
       (list (s-aid alice)) (map car (assq-ref (body-ceremony-record dir body-aid) 'signatures)))

(display "\n── the second signature publishes ──\n")
(define r2 (with-vat vat ($ ceremony 'sign (s-aid carol) (sign-event/indexed json (s-kp carol 0) 2))))
(check "two of two" '(2 . 2) (cons (assq-ref r2 'have) (assq-ref r2 'need)))
(check "published under the body AID" body-aid (assq-ref r2 'published))
(check "close! ran once, with the body AID" (list body-aid) closed)
(check "the oobi-host holds the body" #t (with-vat vat ($ host 'known? body-aid)))
(check "current-keys on the body reads the member keys"
       (list (key-of (s-kp alice 0)) (key-of (s-kp bob 0)) (key-of (s-kp carol 0)))
       (with-vat vat ($ host 'current-keys body-aid)))
(check "current-key is the first member's (single-sig readers keep working)"
       (key-of (s-kp alice 0)) (with-vat vat ($ host 'current-key body-aid)))
(check "current-next-digest is the first member's commitment"
       (digest-of (s-kp alice 1)) (with-vat vat ($ host 'current-next-digest body-aid)))
(define entry (with-vat vat ($ host 'get body-aid)))
(check "the stored signatures stand in member order: alice at 0, carol at 2"
       '(#\A #\C) (map (lambda (s) (string-ref s 1)) (vector->list (assq-ref entry 'sigs))))
(define state0 (events->key-state body-aid (list `(("icp" . ,(assq-ref entry 'icp)) ("sigs" . ,(assq-ref entry 'sigs))))))
(check "the log verifies under the threshold reader" (pair? state0))
(check "its quorum reads as kt" 2 (and (pair? state0) (state-kt state0)))
(check "the record says published" 'published (assq-ref (body-ceremony-record dir body-aid) 'state))
(check "the record names the body" body-aid (assq-ref (body-ceremony-record dir body-aid) 'body))
(check-error "a closed round takes no signature"
             (lambda () (with-vat vat ($ ceremony 'sign (s-aid bob) (sign-0b json (s-kp bob 0))))))

(display "\n── any two stewards: the body AID is the roster's ──\n")
(define host2 (fresh-host alice bob carol))
(define closed2 '())
(define ceremony2
  (with-vat vat
    (spawn-body-ceremony #:scope-aid "scope-1" #:initiator-aid (s-aid carol)
                         #:steward-aids (list (s-aid alice) (s-aid bob) (s-aid carol))
                         #:k 2 #:oobi-host host2 #:witness-dir dir
                         #:close! (lambda (aid) (set! closed2 (cons aid closed2))))))
(define json2 (assq-ref (with-vat vat ($ ceremony2 'preimage)) 'json))
(check "the same roster incepts the same body" body-aid (assq-ref (with-vat vat ($ ceremony2 'preimage)) 'said))
(with-vat vat ($ ceremony2 'sign (s-aid bob) (sign-0b json2 (s-kp bob 0))))
(define r2b (with-vat vat ($ ceremony2 'sign (s-aid carol) (sign-0b json2 (s-kp carol 0)))))
(check "bob and carol publish it" body-aid (assq-ref r2b 'published))
(check "close! once" (list body-aid) closed2)
(check "the member keys read the same" (with-vat vat ($ host 'current-keys body-aid))
       (with-vat vat ($ host2 'current-keys body-aid)))

;; ── the threshold reader on its own ──
(display "\n── the threshold reader ──\n")
(define icp (assq-ref entry 'icp))
(define sA (sign-event/indexed json (s-kp alice 0) 0))
(define sB (sign-event/indexed json (s-kp bob 0) 1))
(define sC (sign-event/indexed json (s-kp carol 0) 2))
(check "two indexed signatures meet kt = 2" #t (check-icp body-aid icp (vector sA sC)))
(check "three do too" #t (check-icp body-aid icp (vector sA sB sC)))
(check "one does not" (string? (check-icp body-aid icp (vector sB))))
(check "the same index twice counts once" (string? (check-icp body-aid icp (vector sA sA))))
(check "a signature at the wrong index does not count"
       (string? (check-icp body-aid icp (vector sA (sign-event/indexed json (s-kp bob 0) 2)))))
(check "a signature by a stranger at a member's index does not count"
       (string? (check-icp body-aid icp (vector sA (sign-event/indexed json (s-kp mallory 0) 1)))))
(check "order among the signatures does not matter" #t (check-icp body-aid icp (vector sC sA)))
(check "kt above the key count is refused"
       (string? (check-sigs/threshold (list (key-of (s-kp alice 0))) 2 icp (vector sA))))
(check "kt = 1 over one key is the single-signature path"
       #t (check-sigs/threshold (list (key-of (s-kp alice 0))) 1 icp (vector sA)))

;; ── a rotation: carol leaves, dave joins, k stays 2 ──
(display "\n── rotation: cuts, adds, the pre-rotation constraint ──\n")
(define (rotate-dial! host s)
  "The steward rotates their own dial AID first: reveals kp1, commits kp2."
  (let ((icp (assq-ref s 'icp)))
    (call-with-values
        (lambda () (build-rot (s-aid s) (assoc-ref icp "d")
                              #:keys (list (key-of (s-kp s 1)))
                              #:nkeys (list (digest-of (s-kp s 2))) #:sn 1))
      (lambda (json said rot)
        (with-vat vat ($ host 'append-rotation! (s-aid s) rot (vector (sign-event json (s-kp s 1)))))))))
(with-vat vat ($ host 'put! (s-aid dave) (assq-ref dave 'icp) (assq-ref dave 'sigs)))
(define unpublished
  (with-vat vat
    (spawn-body-ceremony #:scope-aid "scope-1" #:initiator-aid (s-aid alice)
                         #:steward-aids (list (s-aid alice) (s-aid bob))
                         #:k 1 #:oobi-host host #:witness-dir dir #:close! (lambda (aid) #t))))
(check-error "a rotation before the body is published is refused"
             (lambda () (with-vat vat ($ unpublished 'rotate '() '() 1))))
(check-error "the threshold cannot exceed the continuing stewards"
             (lambda () (with-vat vat ($ ceremony 'rotate (list (s-aid carol)) (list (s-aid dave)) 3))))
(rotate-dial! host alice)
(rotate-dial! host bob)
(define rot-pre (with-vat vat ($ ceremony 'rotate (list (s-aid carol)) (list (s-aid dave)) 2)))
(define rot (assq-ref rot-pre 'fields))
(define rot-json (assq-ref rot-pre 'json))
(check "the round is a rotation" "rotation" (assq-ref rot-pre 'what))
(check "it follows the inception" "1" (assoc-ref rot "s"))
(check "its prior is the inception" body-aid (assoc-ref rot "p"))
(check "k reveals the continuing stewards' rotated keys"
       (list (key-of (s-kp alice 1)) (key-of (s-kp bob 1))) (vector->list (assoc-ref rot "k")))
(check "n commits the continuing and the added stewards' next keys"
       (list (digest-of (s-kp alice 2)) (digest-of (s-kp bob 2)) (digest-of (s-kp dave 1)))
       (vector->list (assoc-ref rot "n")))
(check "br names the cut" (list (s-aid carol)) (vector->list (assoc-ref rot "br")))
(check "ba names the added" (list (s-aid dave)) (vector->list (assoc-ref rot "ba")))
(check-error "the cut steward cannot sign the rotation"
             (lambda () (with-vat vat ($ ceremony 'sign (s-aid carol) (sign-0b rot-json (s-kp carol 0))))))
(check-error "the added steward signs from the rotation after this one"
             (lambda () (with-vat vat ($ ceremony 'sign (s-aid dave) (sign-0b rot-json (s-kp dave 0))))))
(check-error "a continuing steward's old key is refused"
             (lambda () (with-vat vat ($ ceremony 'sign (s-aid alice) (sign-0b rot-json (s-kp alice 0))))))
(define rr1 (with-vat vat ($ ceremony 'sign (s-aid bob) (sign-0b rot-json (s-kp bob 1)))))
(check "one of two on the rotation" #f (assq-ref rr1 'published))
(check "the body's log is still at depth 0"
       0 (length (assq-ref (with-vat vat ($ host 'get body-aid)) 'rotations)))
(define rr2 (with-vat vat ($ ceremony 'sign (s-aid alice) (sign-0b rot-json (s-kp alice 1)))))
(check "two publish the rotation" body-aid (assq-ref rr2 'published))
(check "close! did not run again" (list body-aid) closed)
(define entry1 (with-vat vat ($ host 'get body-aid)))
(check "the log is one rotation deep" 1 (length (assq-ref entry1 'rotations)))
(check "current-keys moved to the continuing stewards' rotated keys"
       (list (key-of (s-kp alice 1)) (key-of (s-kp bob 1))) (with-vat vat ($ host 'current-keys body-aid)))
(define state1
  (events->key-state body-aid
                     (cons `(("icp" . ,(assq-ref entry1 'icp)) ("sigs" . ,(assq-ref entry1 'sigs)))
                           (map (lambda (r) `(("rot" . ,(car r)) ("sigs" . ,(cdr r))))
                                (assq-ref entry1 'rotations)))))
(check "the whole log verifies under the threshold reader" (pair? state1))
(check "quorum stays 2" 2 (and (pair? state1) (state-kt state1)))
(check "three next keys are committed" 3 (and (pair? state1) (length (state-nexts state1))))
(define status1 (with-vat vat ($ ceremony 'status)))
(check "the roster is alice, bob, dave" (list (s-aid alice) (s-aid bob) (s-aid dave)) (assq-ref status1 'stewards))
(check "the record counts the rotation" 1 (assq-ref (body-ceremony-record dir body-aid) 'rotations))

;; ── a rotation whose continuing steward did not rotate first ──
(display "\n── a steward who did not rotate: the reveal fails ──\n")
(define host3 (fresh-host alice bob carol))
(define ceremony3
  (with-vat vat
    (spawn-body-ceremony #:scope-aid "scope-1" #:initiator-aid (s-aid alice)
                         #:steward-aids (list (s-aid alice) (s-aid bob) (s-aid carol))
                         #:k 2 #:oobi-host host3 #:witness-dir dir #:close! (lambda (aid) #t))))
(define json3 (assq-ref (with-vat vat ($ ceremony3 'preimage)) 'json))
(with-vat vat ($ ceremony3 'sign (s-aid alice) (sign-0b json3 (s-kp alice 0))))
(with-vat vat ($ ceremony3 'sign (s-aid bob) (sign-0b json3 (s-kp bob 0))))
(rotate-dial! host3 alice)                 ; bob keeps his inception key
(define rot3 (with-vat vat ($ ceremony3 'rotate (list (s-aid carol)) '() 2)))
(with-vat vat ($ ceremony3 'sign (s-aid alice) (sign-0b (assq-ref rot3 'json) (s-kp alice 1))))
(check-error "the rotation does not land: bob's key is not one the body committed to"
             (lambda () (with-vat vat ($ ceremony3 'sign (s-aid bob) (sign-0b (assq-ref rot3 'json) (s-kp bob 0))))))
(check "the body's log stays at depth 0"
       0 (length (assq-ref (with-vat vat ($ host3 'get body-aid)) 'rotations)))

;; ── the KERIA path ──
(display "\n── create-group ──\n")
(define closed4 '())
(define ceremony4
  (with-vat vat
    (spawn-body-ceremony #:scope-aid "scope-1" #:initiator-aid (s-aid alice)
                         #:steward-aids (list (s-aid alice) (s-aid bob))
                         #:k 2 #:oobi-host host #:witness-dir dir
                         #:close! (lambda (aid) (set! closed4 (cons aid closed4)))
                         #:create-group (lambda () "EGROUPAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))))
(check "the group AID is the body" "EGROUPAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" (with-vat vat ($ ceremony4 'body-aid)))
(check "closed at once" '("EGROUPAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") closed4)
(check "nothing to sign" #f (with-vat vat ($ ceremony4 'preimage)))

;; ── spawn-time refusals ──
(display "\n── what cannot open ──\n")
(check-error "k above the roster"
             (lambda () (with-vat vat (spawn-body-ceremony #:scope-aid "s" #:initiator-aid (s-aid alice)
                                                           #:steward-aids (list (s-aid alice)) #:k 2
                                                           #:oobi-host host #:witness-dir dir #:close! (lambda (a) #t)))))
(check-error "an initiator outside the roster"
             (lambda () (with-vat vat (spawn-body-ceremony #:scope-aid "s" #:initiator-aid (s-aid mallory)
                                                           #:steward-aids (list (s-aid alice) (s-aid bob)) #:k 1
                                                           #:oobi-host host #:witness-dir dir #:close! (lambda (a) #t)))))
(check-error "a steward whose log the host does not hold"
             (lambda () (with-vat vat (spawn-body-ceremony #:scope-aid "s" #:initiator-aid (s-aid alice)
                                                           #:steward-aids (list (s-aid alice) "EUNKNOWNAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") #:k 1
                                                           #:oobi-host host #:witness-dir dir #:close! (lambda (a) #t)))))

(test-summary!)
