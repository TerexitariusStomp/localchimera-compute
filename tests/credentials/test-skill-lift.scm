;;; test-skill-lift.scm — lift-skill-facts + skill-cred-live? (Stage 5a)
;;;
;;; Mirrors test-custody-lift. Constructs skill ACDCs ⇒ needs blake3:
;;;   GUIX_ENVIRONMENT=<profile-with-libblake3> guile -L module \
;;;     tests/credentials/test-skill-lift.scm

(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (playnet credentials work) (playnet keri acdc) (playnet keri acdc))
(use-modules (srfi srfi-1))

(display "\n── Lift live skill credentials → (holds-skill …) ──\n")
(let* ((s1 (make-skill-credential "EScope" "EAda" "spec:bake"     "Ew1"))
       (s2 (make-skill-credential "EScope" "EBob" "spec:electric" "Ew2"))
       (facts (lift-skill-facts (list s1 s2))))
  (check-pred "two facts lifted" (= 2 (length facts)))
  (check-pred "fact head is holds-skill"
              (every (lambda (f) (eq? 'holds-skill (car f))) facts))
  (let ((ada (find (lambda (f) (equal? "EAda" (cadr f))) facts)))
    (check-pred "ada lifted"  (pair? ada))
    (check "ada holds bake"   (caddr ada) "spec:bake")
    (check "founding event carried" (cadddr ada) "Ew1")))

(display "\n── Expiry filter ──\n")
(let* ((live    (make-skill-credential "ES" "EA" "spec:x" "Ee"
                                       #:valid-until "2099-12-31T23:59:59Z"))
       (expired (make-skill-credential "ES" "EB" "spec:y" "Ee"
                                       #:valid-until "2000-01-01T00:00:00Z"))
       (facts   (lift-skill-facts (list live expired))))
  (check-pred "expired filtered out" (= 1 (length facts)))
  (check "live one survives" (caddr (car facts)) "spec:x"))

(display "\n── Revocation filter ──\n")
(let* ((live (make-skill-credential "ES" "EA" "spec:x" "Ee"))
       (gone (cred-with-revoked (make-skill-credential "ES" "EB" "spec:y" "Ee") #t))
       (facts (lift-skill-facts (list live gone))))
  (check-pred "revoked filtered out" (= 1 (length facts))))

(display "\n── skill-cred-live? primitive ──\n")
(let ((open   (make-skill-credential "ES" "EH" "s" "Ee"))
      (future (make-skill-credential "ES" "EH" "s" "Ee" #:valid-until "2099-12-31T00:00:00Z"))
      (past   (make-skill-credential "ES" "EH" "s" "Ee" #:valid-until "1999-01-01T00:00:00Z")))
  (check-pred "open-ended is live" (skill-cred-live? open))
  (check-pred "future is live"     (skill-cred-live? future))
  (check-pred "past is not live"   (not (skill-cred-live? past))))

(display "\n")
(test-summary!)
