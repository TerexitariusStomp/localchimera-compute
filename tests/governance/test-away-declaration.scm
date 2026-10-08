;;; test-away-declaration.scm — a citizen's own signature over an away: tag.
;;;
;;; docs/planning/food/reproduction-of-labour-power.md §2c/§7: signing an away
;;; declaration is a citizen signing their own statement, nothing more — the
;;; tag text itself is the whole content, so this locks in the round-trip
;;; (sign under the person's own AID, verify under it) and the two ways it
;;; must fail: a tampered statement, and a signature from someone else.

(use-modules (playnet governance away-declaration)
             (playnet keri signify)   ; installs the server crypto backend, load-time
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid))
             (playnet test harness))

(define ana (make-keri-identity))
(define bo  (make-keri-identity))
(define tag "away:2026-09-28..2026-09-30:sick")

(display "\n── a citizen's own signature over their own declaration ──\n")
(let ((sig (sign-away-declaration tag (keri-identity-keypair ana))))
  (check "verifies under the signer's own AID"
         (verify-away-declaration tag sig (keri-identity-aid ana)))
  (check "does not verify under someone else's AID"
         (not (verify-away-declaration tag sig (keri-identity-aid bo))))
  (check "does not verify over a different statement (a changed span)"
         (not (verify-away-declaration "away:2026-09-28..2026-09-29:sick" sig
                                       (keri-identity-aid ana))))
  (check "does not verify over a different kind (sick vs. rest)"
         (not (verify-away-declaration "away:2026-09-28..2026-09-30:rest" sig
                                       (keri-identity-aid ana)))))

(display "\n── sick, rest and leave sign the same way — the kind is inside the text ──\n")
(for-each
 (lambda (kind)
   (let* ((t (string-append "away:2026-10-05..2026-10-06:" kind))
          (sig (sign-away-declaration t (keri-identity-keypair bo))))
     (check (string-append "a " kind " declaration verifies under its own signer")
            (verify-away-declaration t sig (keri-identity-aid bo)))))
 '("sick" "rest" "leave"))

(test-summary!)
