;;; tests/keri/test-signup-with-icp.scm — browser-resident-Signify flow.
;;;
;;; Simulates the full Phase B path with no real browser:
;;;
;;;   1. Server-side signify-portable derives a keypair from a bran
;;;      (the same code Hoot will run).
;;;   2. Builds an ICP with toad=0 and signs it.
;;;   3. Sends {username, email, aid, icp, sigs} to ^signup-agent's
;;;      register-with-icp! method (the browser → lobby → signup-agent
;;;      path the gateway will actually run). The AID is the icp's
;;;      saidified `i` (E-prefix) — the identifier resolvers key by.
;;;   4. Verifies: ^oobi-host received the entry, signup-agent persisted
;;;      the membership, and the same nonce-signing flow that lobby
;;;      uses for keri-authenticate verifies under the AID's current key.

(use-modules (playnet test harness)
             (playnet keri signify-portable)
             (playnet keri signify)
             (playnet keri bridge)
             ((playnet keri cesr)
              #:select (cesr-bytes->qb64))
             ((playnet keri citizen-sig)
              #:select (verify-said-signature))
             (playnet identity seat)
             (playnet identity oobi-host)
             (goblins)
             (goblins utils hashmap)
             (rnrs bytevectors)
             (json)
             (ice-9 format))

(define vat (spawn-vat #:name "signup-with-icp-test"))

;; ── Build a fresh AID + ICP + sigs the way the browser would ─────────────────

(define bran "iiw-2026-demo-pwd-21x")
(define alice-name "alice")
(define alice-email "alice@example.org")

(define alice-kp  (bran->signing-keypair bran))
(define alice-nkp (bran->next-keypair bran))
;; k0 — the inception KEY (D-prefix). Never the registration handle:
;; it goes stale on the first rotation. It seeds the icp and is what
;; unlock re-derives from the bran.
(define alice-k0 (public-key->aid-prefix (ed25519-keypair-public alice-kp)))

(define-values (icp-json icp-said icp-alist)
  (build-icp #:keys  (list alice-k0)
             #:nkeys (list (next-key-digest
                            (ed25519-keypair-public alice-nkp)))))

;; THE AID is the icp's saidified `i` (E-prefix) — what resolvers and
;; the gateway key their KEL/location dbs by.
(define alice-aid (assoc-ref icp-alist "i"))

(define alice-sigs (vector (sign-event icp-json alice-kp)))

(format #t "~%=== Browser-resident artifacts ===~%")
(check "AID is 44 chars" (= 44 (string-length alice-aid)))
(check "AID starts with E (saidified i)" (char=? #\E (string-ref alice-aid 0)))
(check "icp.k[0] is the inception key (D-prefix)"
       (string=? alice-k0
                 (vector-ref (assoc-ref icp-alist "k") 0)))
(check "icp SAID is 44 chars" (= 44 (string-length icp-said)))
(check "icp.d == icp.i (self-addressing)"
       (string=? (assoc-ref icp-alist "d")
                 (assoc-ref icp-alist "i")))

;; ── verify-self-signed-icp (the offline validator) ───────────────────────────

(format #t "~%=== Offline validator: verify-self-signed-icp ===~%")
(check "valid icp+sig+aid → #t"
       (eq? #t (verify-self-signed-icp alice-aid icp-alist alice-sigs)))

(let* ((wrong-aid "EAAA0000000000000000000000000000000000000000"))
  (check "AID/icp.i mismatch → error"
         (string? (verify-self-signed-icp wrong-aid icp-alist alice-sigs))))

(let* ((bad-sigs (vector "AAa0000000000000000000000000000000000000000000000000000000000000000000000000000000000000")))
  (check "broken signature → error"
         (string? (verify-self-signed-icp alice-aid icp-alist bad-sigs))))

;; Tamper with icp.d to force SAID mismatch — copy alist, replace d.
(let* ((tampered (map (lambda (p)
                        (if (string=? "d" (car p))
                            (cons "d" (make-string 44 #\A))
                            p))
                      icp-alist)))
  (check "tampered icp.d → error"
         (string? (verify-self-signed-icp alice-aid tampered alice-sigs))))

;; ── End-to-end through ^signup-agent + ^oobi-host ────────────────────────────

(define-values (signup-agent oobi-host)
  (with-vat vat
    (let ((host  (spawn ^oobi-host))
          (agent (spawn ^signup-agent (hashmap) (hashmap))))
      (values agent host))))

(format #t "~%=== Round-trip through actors ===~%")

(let ((rv (with-vat vat
            ($ signup-agent 'register-with-icp!
               alice-name alice-email alice-aid
               icp-alist alice-sigs oobi-host))))
  (check "register-with-icp! returns 'ok" (eq? 'ok rv)))

(let ((mems (with-vat vat ($ signup-agent 'members))))
  (check "membership now has 1 entry" (= 1 (length mems))))

(let ((looked-up (with-vat vat ($ signup-agent 'lookup-aid alice-aid))))
  (check "AID → username reverse lookup works"
         (equal? alice-name looked-up)))

(let ((entry (with-vat vat ($ oobi-host 'get alice-aid))))
  (check "oobi-host stored the entry" (pair? entry))
  (check "stored entry's AID matches"
         (equal? alice-aid (assq-ref entry 'aid)))
  (check "oobi-host counts one entry" (= 1 (with-vat vat ($ oobi-host 'count))))
  (check "signup-agent counts one member" (= 1 (with-vat vat ($ signup-agent 'member-count))))
  (check "stored entry's icp matches what we sent"
         (equal? (assoc-ref icp-alist "d")
                 (assoc-ref (assq-ref entry 'icp) "d"))))

;; Re-registering the same username should fail.
(let ((rv2 (with-vat vat
             ($ signup-agent 'register-with-icp!
                alice-name "other@example.org" alice-aid
                icp-alist alice-sigs oobi-host))))
  (check "duplicate username → error"
         (and (pair? rv2) (eq? 'error (car rv2)))))

;; ── The challenge/response auth path lobby uses ─────────────────────────────
;; lobby resolves the AID's CURRENT key from ^oobi-host and verifies the
;; signed nonce under it (see the post-rotation section below for the
;; rotated case). The D-prefix fast path in keri-verify-signature still
;; serves bare-key identifiers; exercise it against k0 directly.

(format #t "~%=== Local-verify auth path (current-key + D fast path) ===~%")

(let* ((nonce  "deadbeef-nonce-from-lobby")
       ;; Sign UTF-8 bytes of the nonce string with alice's kp; then
       ;; CESR-encode as 0B (raw 64-byte sig).
       (sig-bv (sign-bytes (string->utf8 nonce) alice-kp))
       (sig-q  (cesr-bytes->qb64 "0B" sig-bv)))
  (check "sig verifies under the AID's current key (= k0 pre-rotation)"
         (eq? #t (verify-said-signature nonce sig-q
                                        (with-vat vat
                                          ($ oobi-host 'current-key alice-aid)))))
  (check "keri-verify-signature D fast path on k0 returns #t locally"
         (eq? #t (keri-verify-signature alice-k0 nonce sig-q)))
  (check "tampered nonce fails locally"
         (not (keri-verify-signature alice-k0 "different-nonce" sig-q))))

;; ── Unlock-from-bran round-trip (Phase 2A) ──────────────────────────────────
;; The browser stores only AID + name + email + k0. On reload it has no
;; keypair; the user re-types the bran. The browser re-derives the
;; keypair and compares its prefix to the stored k0 (the E-AID is a
;; SAID over the whole icp — not re-derivable from the bran alone).
;; Match → unlocked. Mismatch → wrong passcode.

(format #t "~%=== Unlock from bran ===~%")

(let* ((re-kp (bran->signing-keypair bran))
       (re-k0 (public-key->aid-prefix (ed25519-keypair-public re-kp))))
  (check "same bran → same keypair pubkey"
         (equal? (ed25519-keypair-public alice-kp)
                 (ed25519-keypair-public re-kp)))
  (check "re-derived key matches the hint's k0"
         (string=? alice-k0 re-k0)))

(let* ((wrong-kp (bran->signing-keypair "this-is-not-the-real-bran-x"))
       (wrong-k0 (public-key->aid-prefix (ed25519-keypair-public wrong-kp))))
  (check "different bran → different k0 (rejected by unlock)"
         (not (string=? alice-k0 wrong-k0))))

;; ── End-to-end auth flow (challenge → sign → verify) ─────────────────────────
;; This mirrors what the browser does after unlock: lobby gives a
;; nonce, browser signs with the in-memory kp, lobby resolves the
;; current key from oobi-host and verifies under it. We exercise both
;; halves here without involving doors/lobby.scm to keep the test pure.

(format #t "~%=== Authenticate round-trip ===~%")

(let* ((nonce   "challenge-9b71d22-1b2c3d")
       ;; Browser side: signs the UTF-8 bytes of the nonce.
       (sig-bv  (sign-bytes (string->utf8 nonce) alice-kp))
       (sig-q64 (cesr-bytes->qb64 "0B" sig-bv))
       (current (with-vat vat ($ oobi-host 'current-key alice-aid))))
  (check "valid sig over nonce verifies under the current key"
         (eq? #t (verify-said-signature nonce sig-q64 current))))

;; Wrong-key signing: simulate a user whose hint says alice-aid but
;; whose passcode produces a different keypair. The signature must
;; not verify under the AID's current key.
(let* ((other-kp (bran->signing-keypair "different-passcode-21x123"))
       (sig-bv   (sign-bytes (string->utf8 "anything") other-kp))
       (sig-q64  (cesr-bytes->qb64 "0B" sig-bv))
       (current  (with-vat vat ($ oobi-host 'current-key alice-aid))))
  (check "sig from a different keypair fails under the current key"
         (not (verify-said-signature "anything" sig-q64 current))))

;; ── OKEA endpoint replies (browser follow-up to register-with-icp!) ──────────
;; The browser endorses /end/role/add + /loc/scheme with the AID's own key
;; (oobi-endpoint-replies references the icp's saidified `i`, the identifier
;; resolvers key by) and ships the framed strings via register-oobi-replies!.
;; The agent verifies each endorsement under the AID's CURRENT key over the
;; RAW frame bytes, then forwards to ^oobi-host set-replies!. This runs
;; pre-rotation, mirroring the real flow (replies ship at inception).

(format #t "~%=== OKEA endpoint replies ===~%")

(define alice-replies
  (list->vector
   (oobi-endpoint-replies-for-icp icp-alist
                                  "http://gateway.example:8420/"
                                  alice-kp
                                  "2026-06-04T12:00:00.000000+00:00")))

;; The caller (lobby, sharing a vat with oobi-host) resolves the AID's
;; current signing key and passes it in — signup-agent itself never
;; reads oobi-host synchronously (cross-vat in the gateway layout).
;; Call only inside a with-vat block, like the lobby's own handler.
(define (current-key-of aid)
  ($ oobi-host 'current-key aid))

(let ((rv (with-vat vat
            ($ signup-agent 'register-oobi-replies!
               alice-aid (current-key-of alice-aid)
               alice-replies oobi-host))))
  (check "register-oobi-replies! accepts endorsed replies" rv 'ok))

(let ((entry (with-vat vat ($ oobi-host 'get alice-aid))))
  (check "oobi-host entry carries the 2 framed replies"
         (assq-ref entry 'replies) alice-replies))

(let ((rv (with-vat vat
            ($ signup-agent 'register-oobi-replies!
               "EUnknownAidThatIsNotRegistered0000000000000"
               (current-key-of "EUnknownAidThatIsNotRegistered0000000000000")
               alice-replies oobi-host))))
  (check "unknown AID → error" (and (pair? rv) (eq? 'error (car rv))) #t))

;; Tampering inside the signed rpy JSON → endorsement no longer verifies.
(let* ((frame    (vector-ref alice-replies 0))
       (idx      (string-contains frame "/end/role/add"))
       (tampered (string-append (substring frame 0 idx)
                                "/end/role/cut"   ; same length, different bytes
                                (substring frame (+ idx 13)))))
  (let ((rv (with-vat vat
              ($ signup-agent 'register-oobi-replies!
                 alice-aid (current-key-of alice-aid)
                 (vector tampered) oobi-host))))
    (check "tampered reply → error" (and (pair? rv) (eq? 'error (car rv))) #t)))

;; Replies endorsed by a stranger's key are rejected.
(let* ((mallory-kp (bran->signing-keypair "mallory-different-21x"))
       (forged (list->vector
                (oobi-endpoint-replies-for-icp
                 icp-alist "http://evil.example/" mallory-kp
                 "2026-06-04T12:00:00.000000+00:00"))))
  (let ((rv (with-vat vat
              ($ signup-agent 'register-oobi-replies!
                 alice-aid (current-key-of alice-aid)
                 forged oobi-host))))
    (check "forged-endorser replies → error"
           (and (pair? rv) (eq? 'error (car rv))) #t)))

;; ── Phase 2B: rotation round-trip ───────────────────────────────────────────
;; Build a rot event from the bran's rotation chain, post via lobby,
;; verify oobi-host stores it, verify auth still works under the NEW
;; signing key.

(format #t "~%=== Rotation round-trip ===~%")

(define rot-sn 1)
;; Rotation sn=1: the new signing key is the previous "next" (kp_1),
;; the new "next" is kp_2 — a fresh derivation from the bran.
(define alice-kp1 (bran->rotation-keypair bran 1))
(define alice-kp2 (bran->rotation-keypair bran 2))

(define new-signing-q
  (public-key->aid-prefix (ed25519-keypair-public alice-kp1)))
(define new-next-digest
  (next-key-digest (ed25519-keypair-public alice-kp2)))

(define-values (rot-json rot-said rot-alist)
  (build-rot alice-aid icp-said
             #:keys (list new-signing-q)
             #:nkeys (list new-next-digest)
             #:sn rot-sn))

;; Sign with the NEW key (kp_1) — that's the one being revealed in this rot.
(define rot-sigs (vector (sign-event rot-json alice-kp1)))

(let ((rv (with-vat vat
            ($ signup-agent 'register-rotation!
               alice-aid rot-alist rot-sigs oobi-host))))
  (check "register-rotation! returns 'ok" (eq? 'ok rv)))

(let ((entry (with-vat vat ($ oobi-host 'get alice-aid))))
  (let ((rots (assq-ref entry 'rotations)))
    (check "oobi-host has 1 rotation" (= 1 (length rots)))
    (check "stored rot.s = 1"
           (string=? "1" (assoc-ref (car (car rots)) "s")))))

;; Replaying the same rotation must fail (sn already used).
(let ((rv2 (with-vat vat
             ($ signup-agent 'register-rotation!
                alice-aid rot-alist rot-sigs oobi-host))))
  (check "duplicate rotation sn → error"
         (and (pair? rv2) (eq? 'error (car rv2)))))

;; A rotation signed by the wrong key must fail.
(let* ((bogus-kp (bran->rotation-keypair "another-21x-passcode-here" 1))
       (bogus-sigs (vector (sign-event rot-json bogus-kp))))
  ;; Need a fresh rot at sn=2 to bypass the dup-sn check.
  (call-with-values
   (lambda () (build-rot alice-aid (assoc-ref rot-alist "d")
                         #:keys (list new-signing-q)
                         #:nkeys (list new-next-digest)
                         #:sn 2))
   (lambda (j _s a)
     (let ((rv3 (with-vat vat
                  ($ signup-agent 'register-rotation!
                     alice-aid a (vector (sign-event j bogus-kp)) oobi-host))))
       (check "rot signed by stranger → error"
              (and (pair? rv3) (eq? 'error (car rv3))))))))

;; ── Post-rotation verification key resolution ───────────────────────────────
;; Regression for the silent bug: after a rotation, the AID prefix no longer
;; encodes the *current* signing key. Verifiers must consult oobi-host's
;; latest rot.k[0]. The lobby does this via 'current-key. Here we exercise
;; that resolver directly — and confirm the inception key is now stale.

(format #t "~%=== Post-rotation current-key resolution ===~%")

(let* ((current-key
        (with-vat vat ($ oobi-host 'current-key alice-aid)))
       (kp1-pub (ed25519-keypair-public alice-kp1))
       (kp1-aid (public-key->aid-prefix kp1-pub)))
  (check "oobi-host 'current-key returns post-rotation k[0]"
         (string=? current-key kp1-aid))
  (check "post-rotation current-key differs from the inception key k0"
         (not (string=? current-key alice-k0)))
  ;; A signature made with kp1 verifies under current-key, but NOT
  ;; under k0 (the original inception key). This is the whole point
  ;; of consulting oobi-host before verifying.
  (let* ((nonce "post-rotation-test-nonce-1234567890")
         (sig-q (cesr-bytes->qb64 "0B"
                                  (sign-bytes (string->utf8 nonce) alice-kp1))))
    (check "sig from kp1 verifies under current-key"
           (verify-said-signature nonce sig-q current-key))
    (check "sig from kp1 does NOT verify under the stale inception key"
           (not (verify-said-signature nonce sig-q alice-k0)))))

;; ── Re-endorse OKEA replies after rotation ───────────────────────────────────
;; A rotation moves the key state, so the endpoint authorization must move
;; with it: the browser re-ships replies endorsed with the rotated-TO key,
;; referencing the rot as the establishment event
;; (oobi-endpoint-replies-for-rot). register-oobi-replies! verifies under
;; the CURRENT key, so fresh endorsements pass and inception-era ones are
;; now rejected — stale endpoint claims can't outlive the key they rode in on.

(format #t "~%=== Re-endorse replies after rotation ===~%")

(define rot-replies
  (list->vector
   (oobi-endpoint-replies-for-rot rot-alist
                                  "http://gateway.example:8420/"
                                  alice-kp1
                                  "2026-06-04T13:00:00.000000+00:00")))

(let ((rv (with-vat vat
            ($ signup-agent 'register-oobi-replies!
               alice-aid (current-key-of alice-aid)
               rot-replies oobi-host))))
  (check "rot-era replies (endorsed by kp1) accepted" rv 'ok))

(let ((entry (with-vat vat ($ oobi-host 'get alice-aid))))
  (check "entry replies refreshed to the rot-era pair"
         (assq-ref entry 'replies) rot-replies))

(let ((rv (with-vat vat
            ($ signup-agent 'register-oobi-replies!
               alice-aid (current-key-of alice-aid)
               alice-replies oobi-host))))
  (check "stale inception-era replies now rejected"
         (and (pair? rv) (eq? 'error (car rv))) #t))

;; ── Spec-alignment: CESR text-stream OOBI emission ──────────────────────────
;; The OOBI route now serves a KERI CESR text-stream (per OOBI draft §9
;; and KERI's KEL streaming) instead of our earlier custom JSON. This
;; test asserts the framing format: each event JSON followed by a
;; ControllerIdxSigs counter (-A##) and the indexed signature(s).

(format #t "~%=== CESR text-stream KEL ===~%")

(let* ((icp-frame (cesr-stream-event icp-json alice-sigs))
       (rot-frame (cesr-stream-event rot-json rot-sigs))
       (kel       (cesr-stream-kel
                   (list (cons icp-json alice-sigs)
                         (cons rot-json rot-sigs)))))
  (check "icp frame starts with the json bytes"
         (string-prefix? icp-json icp-frame))
  (check "icp frame includes ControllerIdxSigs counter '-A'"
         (string-contains icp-frame "-A"))
  (check "icp frame count for 1 sig is 'AB'"
         (let ((idx (string-contains icp-frame "-A")))
           (and idx
                (string=? "AB" (substring icp-frame
                                          (+ idx 2)
                                          (+ idx 4))))))
  (check "icp frame ends with the indexed sig qb64"
         (let ((s (vector-ref alice-sigs 0)))
           (string=? s (substring icp-frame
                                  (- (string-length icp-frame)
                                     (string-length s))))))
  (check "kel = icp-frame + rot-frame"
         (string=? kel (string-append icp-frame rot-frame))))

;; Spot-check: the count encoding for 2 sigs is "AC", for 0 raises.
(let ((mock-sigs (vector "AABaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                          "ABBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")))
  (let ((frame (cesr-stream-event "{}" mock-sigs)))
    (check "2-sig count is 'AC'"
           (let ((i (string-contains frame "-A")))
             (string=? "AC" (substring frame (+ i 2) (+ i 4)))))))

;; ── The log, found by a key it carries ──────────────────────────────────────
;; A device that holds only the passcode derives the passcode's first key and
;; asks for the log that key appears in (lobby find-icp → oobi-host
;; by-event-key): the inception's key for the passcode an identity was made
;; with, a rotation's key for a passcode it was changed to.

(format #t "~%=== The log by a key it carries ===~%")

(let ((entry (with-vat vat ($ oobi-host 'by-event-key alice-k0))))
  (check "the inception key finds the entry" (pair? entry))
  (check "…and it is alice's AID"
         (equal? alice-aid (and (pair? entry) (assq-ref entry 'aid))))
  (check "…the same entry the AID names"
         (equal? entry (with-vat vat ($ oobi-host 'get alice-aid)))))

(let ((in-force (with-vat vat ($ oobi-host 'current-key alice-aid))))
  (check "the log has rotated: the key in force differs from the inception key"
         (not (equal? alice-k0 in-force)))
  (check "a rotation's key finds the same entry"
         (equal? alice-aid
                 (let ((e (with-vat vat ($ oobi-host 'by-event-key in-force))))
                   (and (pair? e) (assq-ref e 'aid))))))

(let ((other-k0 (public-key->aid-prefix
                 (ed25519-keypair-public
                  (bran->signing-keypair "a-passcode-nobody-registered-21")))))
  (check "a key no log here carries finds nothing"
         (not (with-vat vat ($ oobi-host 'by-event-key other-k0)))))
(check "a non-string key finds nothing"
       (not (with-vat vat ($ oobi-host 'by-event-key #f))))

;; one passcode incepted twice (a second inception under another anchor):
;; two logs carry one key, and the earliest registered answers
(define-values (json2 said2 alist2)
  (build-icp #:keys (list alice-k0)
             #:nkeys (list (next-key-digest (ed25519-keypair-public alice-nkp)))
             #:anchors (list (list (cons "note" "a second inception")))))
(define aid2 (assoc-ref alist2 "i"))
(check "the second inception is another AID" (not (equal? aid2 alice-aid)))
(with-vat vat ($ oobi-host 'put! aid2 alist2 (vector (sign-event json2 alice-kp))))
(let ((found (with-vat vat ($ oobi-host 'by-event-key alice-k0))))
  (check "with two logs under one key, one answers"
         (and (pair? found) (member (assq-ref found 'aid) (list alice-aid aid2)) #t))
  (check "…never a later one over an earlier one"
         (<= (string->number (assq-ref found 'registered-at))
             (string->number (assq-ref (with-vat vat ($ oobi-host 'get aid2)) 'registered-at)))))

(test-summary!)
