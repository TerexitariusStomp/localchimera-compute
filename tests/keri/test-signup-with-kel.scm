;;; tests/keri/test-signup-with-kel.scm — an identity takes a seat at a
;;; commune that has never seen it, by bringing its own KEL.
;;;
;;; The controller authored every event in its log and kept it. A fresh
;;; gateway verifies that log end to end — icp self-signed, each rot
;;; revealing the key the previous event committed to, chained by SAID —
;;; and lands the entry in ^oobi-host under the rotated key state. The
;;; same bran then passes the nonce challenge under the CURRENT key.
;;;
;;; Also covers the storage round trip: the KEL as ordered JSON (what the
;;; browser keeps and what the recovery file holds) parses back to the
;;; exact event alists, so the signatures still verify after a reload.

(use-modules (playnet test harness)
             (playnet keri signify-portable)
             ((playnet keri cesr) #:select (cesr-bytes->qb64))
             ((playnet keri citizen-sig) #:select (verify-said-signature))
             (playnet identity seat)
             (playnet identity oobi-host)
             (goblins)
             (goblins utils hashmap)
             (rnrs bytevectors)
             (ice-9 format))

(define vat (spawn-vat #:name "signup-with-kel-test"))

;; ── The controller's own log: icp + two rotations ───────────────────────────

(define bran "kel-carrier-passcode-21x")

(define kp0 (bran->signing-keypair bran))
(define kp1 (bran->rotation-keypair bran 1))
(define kp2 (bran->rotation-keypair bran 2))
(define kp3 (bran->rotation-keypair bran 3))
(define (q kp) (public-key->aid-prefix (ed25519-keypair-public kp)))
(define (nd kp) (next-key-digest (ed25519-keypair-public kp)))

(define-values (icp-json icp-said icp-alist)
  (build-icp #:keys (list (q kp0)) #:nkeys (list (nd kp1))))
(define aid (assoc-ref icp-alist "i"))
(define icp-sigs (vector (sign-event icp-json kp0)))

(define-values (rot1-json rot1-said rot1-alist)
  (build-rot aid icp-said #:keys (list (q kp1)) #:nkeys (list (nd kp2)) #:sn 1))
(define rot1-sigs (vector (sign-event rot1-json kp1)))

(define-values (rot2-json rot2-said rot2-alist)
  (build-rot aid rot1-said #:keys (list (q kp2)) #:nkeys (list (nd kp3)) #:sn 2))
(define rot2-sigs (vector (sign-event rot2-json kp2)))

(define rotations (vector (cons rot1-alist rot1-sigs)
                          (cons rot2-alist rot2-sigs)))

;; ── Storage round trip: ordered JSON ⇄ event alists ─────────────────────────

(format #t "~%=== KEL as ordered JSON ===~%")

(define kel-json
  (scm->json-canonical
   `(("icp" . ,icp-alist)
     ("sigs" . ,icp-sigs)
     ("rotations" . ,(vector `(("rot" . ,rot1-alist) ("sigs" . ,rot1-sigs))
                             `(("rot" . ,rot2-alist) ("sigs" . ,rot2-sigs)))))))

(define kel-back (json-read-ordered kel-json))

(check "icp survives the round trip byte-for-byte"
       (string=? icp-json (scm->json-canonical (assoc-ref kel-back "icp"))))
(check "rot2 survives the round trip byte-for-byte"
       (string=? rot2-json
                 (scm->json-canonical
                  (assoc-ref (vector-ref (assoc-ref kel-back "rotations") 1) "rot"))))
(check "sigs come back as a vector"
       (vector? (assoc-ref kel-back "sigs")))
(check "re-emitting the parsed KEL reproduces the stored text"
       (string=? kel-json (scm->json-canonical kel-back)))

;; ── A fresh gateway accepts the whole log ───────────────────────────────────

(define-values (signup-agent oobi-host)
  (with-vat vat
    (let ((host  (spawn ^oobi-host))
          (agent (spawn ^signup-agent (hashmap) (hashmap))))
      (values agent host))))

(format #t "~%=== register-with-kel! at a gateway that never saw this AID ===~%")

(let ((rv (with-vat vat
            ($ signup-agent 'register-with-kel!
               "carrier" "carrier@example.org" aid
               icp-alist icp-sigs rotations oobi-host))))
  (check "register-with-kel! returns 'ok" (eq? 'ok rv)))

(let ((entry (with-vat vat ($ oobi-host 'get aid))))
  (check "oobi-host holds the entry" (pair? entry))
  (check "oobi-host holds both rotations"
         (= 2 (length (assq-ref entry 'rotations))))
  (check "last event is rot sn=2"
         (string=? "2" (assoc-ref (oobi-entry-last-event entry) "s"))))

(check "current-key is the sn=2 key, not the inception key"
       (string=? (q kp2)
                 (with-vat vat ($ oobi-host 'current-key aid))))

;; The challenge flow lobby runs: sign a nonce with the CURRENT key.
(let* ((nonce "nonce-for-the-kel-carrier")
       (sig (cesr-bytes->qb64 "0B" (sign-bytes (string->utf8 nonce) kp2)))
       (key (with-vat vat ($ oobi-host 'current-key aid))))
  (check "nonce signed under kp2 verifies under current-key"
         (verify-said-signature nonce sig key))
  (let ((stale (cesr-bytes->qb64 "0B" (sign-bytes (string->utf8 nonce) kp0))))
    (check "nonce signed under the inception key no longer verifies"
           (not (verify-said-signature nonce stale key)))))

;; The same AID cannot be registered twice here.
(let ((rv (with-vat vat
            ($ signup-agent 'register-with-kel!
               "carrier-again" "" aid icp-alist icp-sigs rotations oobi-host))))
  (check "second registration of the AID → error"
         (and (pair? rv) (eq? 'error (car rv)))))

;; ── A chain that breaks anywhere is refused whole ───────────────────────────

(format #t "~%=== refusals ===~%")

(define (fresh-pair)
  (with-vat vat
    (let ((host  (spawn ^oobi-host))
          (agent (spawn ^signup-agent (hashmap) (hashmap))))
      (cons agent host))))

;; rot2 presented before rot1: rot.s and rot.p both fail against the icp.
(let* ((pair (fresh-pair))
       (rv (with-vat vat
             ($ (car pair) 'register-with-kel!
                "shuffled" "" aid icp-alist icp-sigs
                (vector (cons rot2-alist rot2-sigs)
                        (cons rot1-alist rot1-sigs))
                (cdr pair)))))
  (check "rotations out of order → error"
         (and (pair? rv) (eq? 'error (car rv))))
  (check "nothing lands in oobi-host on refusal"
         (not (with-vat vat ($ (cdr pair) 'get aid)))))

;; rot2 signed by a stranger: the chain verifies to sn=1 and breaks at 2.
(let* ((pair (fresh-pair))
       (mallory (bran->rotation-keypair "mallory-passcode-21chars" 2))
       (forged (vector (sign-event rot2-json mallory)))
       (rv (with-vat vat
             ($ (car pair) 'register-with-kel!
                "forged" "" aid icp-alist icp-sigs
                (vector (cons rot1-alist rot1-sigs)
                        (cons rot2-alist forged))
                (cdr pair)))))
  (check "rot signed by a stranger → error"
         (and (pair? rv) (eq? 'error (car rv))))
  (check "a chain refused at sn=2 leaves no partial entry"
         (not (with-vat vat ($ (cdr pair) 'get aid)))))

;; A rotation that skips sn (1 then 3) is refused.
(let* ((pair (fresh-pair))
       (rv (call-with-values
            (lambda ()
              (build-rot aid rot1-said #:keys (list (q kp2)) #:nkeys (list (nd kp3)) #:sn 3))
            (lambda (j _s a)
              (with-vat vat
                ($ (car pair) 'register-with-kel!
                   "gappy" "" aid icp-alist icp-sigs
                   (vector (cons rot1-alist rot1-sigs)
                           (cons a (vector (sign-event j kp2))))
                   (cdr pair)))))))
  (check "rotation with a gap in sn → error"
         (and (pair? rv) (eq? 'error (car rv)))))

;; A KEL with no rotations is exactly register-with-icp!.
(let* ((pair (fresh-pair))
       (rv (with-vat vat
             ($ (car pair) 'register-with-kel!
                "unrotated" "" aid icp-alist icp-sigs (vector) (cdr pair)))))
  (check "empty rotations → 'ok" (eq? 'ok rv))
  (check "current-key is the inception key"
         (string=? (q kp0) (with-vat vat ($ (cdr pair) 'current-key aid)))))

;; The parsed-from-JSON KEL registers identically — what a recovery file
;; or a localStorage reload hands the browser.
(let* ((pair (fresh-pair))
       (rots (list->vector
              (map (lambda (r) (cons (assoc-ref r "rot") (assoc-ref r "sigs")))
                   (vector->list (assoc-ref kel-back "rotations")))))
       (rv (with-vat vat
             ($ (car pair) 'register-with-kel!
                "from-file" "" aid
                (assoc-ref kel-back "icp") (assoc-ref kel-back "sigs")
                rots (cdr pair)))))
  (check "KEL parsed from its JSON registers → 'ok" (eq? 'ok rv))
  (check "…with the rotated key current"
         (string=? (q kp2) (with-vat vat ($ (cdr pair) 'current-key aid)))))

;; ── A commune behind the controller's log catches up ────────────────────────
;; Registered with the icp alone (the state a commune keeps from before a
;; rotation made elsewhere), then handed the two rotations as one run.
;; No session: a rot proves its own authorship.

(format #t "~%=== register-rotations!: a commune catches up ===~%")

(let* ((pair (fresh-pair))
       (agent (car pair)) (host (cdr pair)))
  (with-vat vat ($ agent 'register-with-icp! "behind" "" aid icp-alist icp-sigs host))
  (check "registered at depth 0"
         (string=? (q kp0) (with-vat vat ($ host 'current-key aid))))
  (let ((rv (with-vat vat ($ agent 'register-rotations! aid rotations ($ host 'get aid) host))))
    (check "register-rotations! with both rots → 'ok" (eq? 'ok rv)))
  (check "…and the commune is now at depth 2 under kp2"
         (string=? (q kp2) (with-vat vat ($ host 'current-key aid))))
  ;; replaying the same run: rot1 is stale against the new state
  (let ((rv (with-vat vat ($ agent 'register-rotations! aid rotations ($ host 'get aid) host))))
    (check "replaying the run → error (stale sn)"
           (and (pair? rv) (eq? 'error (car rv)))))
  ;; an empty run is a no-op
  (check "empty run → 'ok" (eq? 'ok (with-vat vat ($ agent 'register-rotations! aid (vector) ($ host 'get aid) host)))))

;; a run that breaks midway lands nothing
(let* ((pair (fresh-pair))
       (agent (car pair)) (host (cdr pair))
       (mallory (bran->rotation-keypair "mallory-passcode-21chars" 2)))
  (with-vat vat ($ agent 'register-with-icp! "behind2" "" aid icp-alist icp-sigs host))
  (let ((rv (with-vat vat
              ($ agent 'register-rotations! aid
                 (vector (cons rot1-alist rot1-sigs)
                         (cons rot2-alist (vector (sign-event rot2-json mallory))))
                 ($ host 'get aid) host))))
    (check "a run forged at sn=2 → error" (and (pair? rv) (eq? 'error (car rv))))
    (check "…and sn=1 did not land either"
           (string=? (q kp0) (with-vat vat ($ host 'current-key aid))))))

;; an unknown AID cannot be extended into existence
(let* ((pair (fresh-pair))
       (rv (with-vat vat ($ (car pair) 'register-rotations! aid rotations ($ (cdr pair) 'get aid) (cdr pair)))))
  (check "rotations for an unregistered AID → error" (and (pair? rv) (eq? 'error (car rv)))))

;; ── witnessing and seating, apart ───────────────────────────────────────────
;; A gateway witnesses any verifiable log without seating it; a seat is a
;; separate act that presupposes the witnessing; a different history under
;; one AID is refused rather than levelled.

(format #t "~%=== witness-kel! / join! / has-seat? ===~%")

(let* ((pair (fresh-pair)) (agent (car pair)) (host (cdr pair)))
  (check "join! before witnessing → error (AID not witnessed here)"
         (let ((rv (with-vat vat ($ agent 'join! "early" "" aid (and ($ host 'get aid) #t)))))
           (and (pair? rv) (eq? 'error (car rv)))))
  (check "witness-kel! with the full log → 'ok"
         (eq? 'ok (with-vat vat ($ agent 'witness-kel! aid icp-alist icp-sigs rotations ($ host 'get aid) host))))
  (check "witnessed at depth 2"
         (string=? (q kp2) (with-vat vat ($ host 'current-key aid))))
  (check "…but no seat" (not (with-vat vat ($ agent 'has-seat? aid))))
  (check "members unchanged by witnessing"
         (null? (with-vat vat ($ agent 'members))))
  (check "witnessing again (same log) → 'ok, idempotent"
         (eq? 'ok (with-vat vat ($ agent 'witness-kel! aid icp-alist icp-sigs rotations ($ host 'get aid) host))))
  (check "witnessing a shorter copy of the same log → 'ok, nothing lost"
         (and (eq? 'ok (with-vat vat ($ agent 'witness-kel! aid icp-alist icp-sigs (vector) ($ host 'get aid) host)))
              (string=? (q kp2) (with-vat vat ($ host 'current-key aid)))))
  (let* ((mallory (bran->rotation-keypair "mallory-passcode-21chars" 2))
         (forged  (vector (cons rot1-alist rot1-sigs)
                          (cons rot2-alist (vector (sign-event rot2-json mallory))))))
    ;; rot2's SAID is the same (the event is the same bytes); only the sig
    ;; differs — already held, so nothing to verify: 'ok, nothing changes.
    ;; A genuinely different history: a rot2 over different keys.
    (call-with-values
     (lambda () (build-rot aid rot1-said #:keys (list (q kp3)) #:nkeys (list (nd kp3)) #:sn 2))
     (lambda (j _s a)
       (let ((rv (with-vat vat
                   ($ agent 'witness-kel! aid icp-alist icp-sigs
                      (vector (cons rot1-alist rot1-sigs) (cons a (vector (sign-event j kp3))))
                      ($ host 'get aid) host))))
         (check "a diverging history under the same AID → error"
                (and (pair? rv) (eq? 'error (car rv))))))))
  (check "join! with \"\" username mints a handle → 'ok"
         (eq? 'ok (with-vat vat ($ agent 'join! "" "" aid (and ($ host 'get aid) #t)))))
  (check "…now seated" (with-vat vat ($ agent 'has-seat? aid)))
  (check "the minted handle starts with u + the AID's first chars"
         (let ((m (with-vat vat ($ agent 'members))))
           (and (= 1 (length m))
                (string-prefix? (string-append "u" (string-downcase (substring aid 0 4)))
                                (car (car m))))))
  (check "a second join! for the AID → error (already seated)"
         (let ((rv (with-vat vat ($ agent 'join! "again" "" aid (and ($ host 'get aid) #t)))))
           (and (pair? rv) (eq? 'error (car rv))))))

;; a witnessed-but-unseated AID's key still resolves for verifiers (OOBI
;; serves it) — the seat gate is keri-authenticate's, not the resolver's
(let* ((pair (fresh-pair)) (agent (car pair)) (host (cdr pair)))
  (with-vat vat ($ agent 'witness-kel! aid icp-alist icp-sigs (vector) ($ host 'get aid) host))
  (check "witnessed-only AID resolves its current key"
         (string=? (q kp0) (with-vat vat ($ host 'current-key aid)))))

(test-summary!)
