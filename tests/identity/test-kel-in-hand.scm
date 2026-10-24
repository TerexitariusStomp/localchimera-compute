;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/identity/test-kel-in-hand.scm — the key log in hand, pinned natively
;;;
;;; What this pins (module/localchimera/identity/kel.scm, the pure half of the
;;; browser's identity code):
;;;   • a passcode incepts a log the module verifies, and opens it; another
;;;     passcode does not;
;;;   • after a rotation the passcode's chain has moved one key along, and the
;;;     log still verifies and still opens;
;;;   • the retirement rotation commits to no next key, the gateway's reader
;;;     (keri/key-state.scm check-rotation) accepts it, and refuses any
;;;     rotation after it — the identity is abandoned, not transferable;
;;;   • a tampered log does not verify; a log of another identifier does not
;;;     yield a sealed-to key; the forget receipt renders as the page reads it.
;;;
;;; Run: guile -L module tests/identity/test-kel-in-hand.scm
(use-modules (localchimera test harness)
             (localchimera identity kel)
             (localchimera keri signify)   ; installs the native crypto backend
             ((localchimera keri crypto-primitives) #:select (ed25519-keypair-public))
             ((localchimera keri signify-portable)
              #:select (bran->signing-keypair bran->next-keypair next-key-digest
                        build-icp build-rot sign-event json-read-ordered scm->json-canonical))
             ((localchimera keri key-state) #:select (check-rotation))
             ((localchimera keri reticulum-binding) #:select (kel-reticulum-pub))
             (srfi srfi-1))

(define bran  "0ADEMOpasscode000000X")
(define other "0ADEMOotherpasscode0X")

;; ── inception, as handle-signup makes it ──
(define kp0 (bran->signing-keypair bran))
(define nkp (bran->next-keypair bran))
(define-values (icp-json icp-said icp)
  (build-icp #:keys (list (keypair-key kp0))
             #:nkeys (list (next-key-digest (ed25519-keypair-public nkp)))))
(define aid (assoc-ref icp "i"))
(define kel0 (make-kel icp (vector (sign-event icp-json kp0)) '()))

(display "\n── a fresh log ──\n")
(check "well formed" (kel-well-formed? kel0))
(check "the identifier is the inception's" aid (kel-aid kel0))
(check "depth 0" 0 (kel-depth kel0))
(check "the log verifies" (kel-verifies? kel0))
(check "the passcode's chain begins at the inception" 0 (passcode-base kel0 bran))
(check "the passcode opens it" (passcode-opens? kel0 bran))
(check "another passcode does not" (not (passcode-opens? kel0 other)))
(check "another passcode's chain is nowhere in the log" #f (passcode-base kel0 other))
(check "the current keypair is the inception key"
       (keypair-key kp0) (keypair-key (kel-current-keypair kel0 bran)))

;; ── the stored shape round-trips through canonical JSON ──
(define kel0* (json-read-ordered (scm->json-canonical kel0)))
(check "round-trips and still verifies" (and (kel-well-formed? kel0*) (kel-verifies? kel0*)))
(check "a server entry reads as the same log"
       (kel-aid kel0) (kel-aid (entry->kel `((icp . ,icp) (sigs . ,(vector (sign-event icp-json kp0))) (rotations . ())))))

;; ── one rotation: the chain moves a key along ──
(define kp1 (passcode-keypair bran 1))
(define kp2 (passcode-keypair bran 2))
(define-values (rot1-json rot1-said rot1)
  (build-rot aid icp-said
             #:keys (list (keypair-key kp1))
             #:nkeys (list (next-key-digest (ed25519-keypair-public kp2)))
             #:sn 1))
(define kel1 (make-kel icp (vector (sign-event icp-json kp0))
                       (list (cons rot1 (vector (sign-event rot1-json kp1))))))

(display "\n── after a rotation ──\n")
(check "the rotation index 1 key is the committed next key"
       (keypair-key kp1) (keypair-key nkp))
(check "depth 1" 1 (kel-depth kel1))
(check "the log verifies" (kel-verifies? kel1))
(check "the passcode still opens it" (passcode-opens? kel1 bran))
(check "the current keypair is one along the chain"
       (keypair-key kp1) (keypair-key (kel-current-keypair kel1 bran)))
(check "the last event is the rotation" rot1 (kel-last-event kel1))

;; ── retiring the identity ──
(define-values (rots-closed kel-closed) (retirement-rotation kel1 bran))
(define rot-end (car (last rots-closed)))
(define sigs-end (cdr (last rots-closed)))

(display "\n── the retirement rotation ──\n")
(check "one more rotation" 2 (kel-depth kel-closed))
(check "it commits to no next key" #() (assoc-ref rot-end "n"))
(check "its next threshold is zero" "0" (let ((nt (assoc-ref rot-end "nt"))) (if (number? nt) (number->string nt) nt)))
(check "it reveals the key the last event committed to" (keypair-key kp2) (car (vector->list (assoc-ref rot-end "k"))))
(check "the closed log verifies on its own terms" (kel-verifies? kel-closed))
(define prior-state `((sn . 1) (said . ,(assoc-ref rot1 "d")) (next . ,(next-key-digest (ed25519-keypair-public kp2)))))
(check "the gateway's reader accepts it" #t (check-rotation aid prior-state rot-end sigs-end))
;; a rotation after the end: the reader refuses, as test-forget pins on the gateway
(define-values (rot-after-json _s rot-after)
  (build-rot aid (assoc-ref rot-end "d")
             #:keys (list (keypair-key (passcode-keypair bran 3)))
             #:nkeys (list (next-key-digest (ed25519-keypair-public (passcode-keypair bran 4))))
             #:sn 3))
(define end-state `((sn . 2) (said . ,(assoc-ref rot-end "d")) (next . ,(assoc-ref rot-end "n"))))
(check "and refuses any rotation after it"
       (string? (check-rotation aid end-state rot-after (vector (sign-event rot-after-json (passcode-keypair bran 3))))))

;; ── what does not verify ──
(display "\n── tampering ──\n")
(define forged-icp (map (lambda (kv) (if (equal? (car kv) "i") (cons "i" "EFORGEDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") kv)) icp))
(check "a log whose inception names another identifier does not verify"
       (not (kel-verifies? (make-kel forged-icp (assoc-ref kel0 "sigs") '()))))
(check "a rotation signed by the wrong key does not verify"
       (not (kel-verifies? (make-kel icp (vector (sign-event icp-json kp0))
                                     (list (cons rot1 (vector (sign-event rot1-json kp0))))))))
(check "a malformed value is not a log" (not (kel-well-formed? '(("icp" . 42)))))

;; ── the key a card is sealed to ──
(display "\n── the sealed-to key ──\n")
(define entry1 `((icp . ,icp) (sigs . ,(vector (sign-event icp-json kp0))) (rotations . ,(list (cons rot1 (vector (sign-event rot1-json kp1)))))))
(check "no reticulum key anchored → no key" #f (anchored-key-hex entry1 aid))
(check "another identifier's entry → no key" #f (anchored-key-hex entry1 "EOTHERAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))

;; ── the forget receipt ──
(display "\n── the receipt ──\n")
(check "renders dropped counts and kept names as the page reads them (keys in canonical order)"
       "{\"dropped\":{\"member\":1,\"bindings\":2},\"kept\":[\"key-log\",\"credentials\"]}"
       (receipt->json '((dropped . ((member . 1) (bindings . 2))) (kept . (key-log credentials)))))

(test-summary!)
