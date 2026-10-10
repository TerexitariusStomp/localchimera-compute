;;; test-state-snapshot.scm — completeness anchor (follow-on #3)
;;;
;;; A derived-state-snapshot ACDC edges to every input it covers, so a holder of
;;; the snapshot + the inputs can confirm they have the COMPLETE expected set —
;;; chains prove existence, not absence (caveat 3).
;;; Constructs ACDCs ⇒ needs blake3:
;;;   GUIX_ENVIRONMENT=<profile-with-libblake3> guile -L module \
;;;     tests/planner/test-state-snapshot.scm

(use-modules (playnet test harness))
(use-modules )
(use-modules (playnet governance acdc-bridge) (playnet credentials work) (playnet keri acdc) (playnet keri acdc) (playnet keri acdc-store))
(use-modules (goblins) (goblins vat) (srfi srfi-1))

(define vat (spawn-vat))
(with-vat vat
  (let ((acdc (spawn-acdc-store))
        (s1 (make-skill-credential "ES" "EAda"   "spec:bake" "Ew1"))
        (s2 (make-skill-credential "ES" "EBob"   "spec:weld" "Ew2")))
    ($ acdc 'issue s1)
    ($ acdc 'issue s2)

    (display "\n── Snapshot crystallizes the expected set ──\n")
    (define snap (snapshot-over acdc "EAuditor" "EScope"
                                (list *schema-playnet-skill*) '((note . "skills@t1"))))
    (check "snapshot edges to both skill creds" (length (snapshot-input-saids snap)) 2)
    (check-pred "complete against the full held set" (snapshot-complete? snap (list s1 s2)))

    (display "\n── A gap is detected (proves what's missing) ──\n")
    (let ((missing (snapshot-missing snap (list s1))))   ; hold s1 only
      (check "exactly one missing"        (length missing) 1)
      (check "the missing SAID is s2's"   (car missing) (cred-said s2))
      (check-pred "not complete with a gap" (not (snapshot-complete? snap (list s1)))))

    (display "\n── A superset is still complete (presence, not exclusivity) ──\n")
    (let ((s3 (make-skill-credential "ES" "ECarol" "spec:cook" "Ew3")))
      (check-pred "extra creds don't break completeness"
                  (snapshot-complete? snap (list s1 s2 s3))))))

(display "\n")
(test-summary!)
