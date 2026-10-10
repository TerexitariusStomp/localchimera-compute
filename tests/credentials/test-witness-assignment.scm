;;; tests/credentials/test-witness-assignment.scm —
;;; Federation-member witness assignment ACDC + auditor.
;;;
;;; Run: guile -L module -L tests tests/credentials/test-witness-assignment.scm

(use-modules (playnet test harness)
             (playnet credentials keys) (playnet keri acdc) (playnet keri acdc)
             (srfi srfi-1))   ;; every

(define %federation "EFederation_alpha_00000000000000000000000000")
(define %member-1   "EMember_one_00000000000000000000000000000000")
(define %member-2   "EMember_two_00000000000000000000000000000000")
(define %member-3   "EMember_three_000000000000000000000000000000")
(define %member-4   "EMember_four_0000000000000000000000000000000")

(define %group-aid  "EGroup_governance_0000000000000000000000000")

(define (witness-aid-for label)
  (string-append "EWitness_" label "_______________________________"))
(define (oobi-for label)
  (string-append "http://wit-" label ".onion:5642/oobi/"
                 (witness-aid-for label) "/controller?role=witness"))

(define (assignment member n)
  "Issue a witness-assignment from %federation to MEMBER for the Nth witness."
  (let ((label (string-append (substring member 0 14) "-" (number->string n))))
    (make-witness-assignment-credential
      #:federation-aid %federation
      #:member-aid member
      #:witness-aid (witness-aid-for label)
      #:witness-oobi (oobi-for label)
      #:group-aid %group-aid
      #:assigned-at 1700000000)))

(define (witness-aid-of cred) (cred-claim cred 'witness-aid))

;;; ── Constructor + claims ─────────────────────────────────────────────

(let ((c (assignment %member-1 1)))
  (check "schema is set"
         (cred-schema c) *schema-playnet-witness-assignment*)
  (check "issuer is the federation"
         (cred-issuer c) %federation)
  (check "holder is the member operating the witness"
         (cred-holder c) %member-1)
  (check "witness-aid claim non-empty"
         (and (string? (cred-claim c 'witness-aid))
              (> (string-length (cred-claim c 'witness-aid)) 0)))
  (check "witness-oobi claim non-empty"
         (and (string? (cred-claim c 'witness-oobi))
              (> (string-length (cred-claim c 'witness-oobi)) 0)))
  (check "group-aid claim" (cred-claim c 'group-aid) %group-aid)
  (check "assigned-at claim" (cred-claim c 'assigned-at) 1700000000)
  (check "SAID is set"
         (and (string? (cred-said c))
              (> (string-length (cred-said c)) 0)))
  (check "not revoked at issuance" (not (cred-revoked? c))))

;;; ── Enumeration ──────────────────────────────────────────────────────

(let* ((c1 (assignment %member-1 1))
       (c2 (assignment %member-2 1))
       (c3 (assignment %member-3 1))
       (other-fed-cred
        (make-witness-assignment-credential
          #:federation-aid "EFederation_other_0000000000000000000000000000"
          #:member-aid %member-4
          #:witness-aid (witness-aid-for "other")
          #:witness-oobi (oobi-for "other")
          #:group-aid %group-aid
          #:assigned-at 1700000000))
       (revoked
        (cred-with-revoked (assignment %member-4 1) #t))
       (all (list c1 c2 c3 other-fed-cred revoked))
       (found (witness-assignments-for-federation %federation all)))
  (check "ignores other federations and revoked" (length found) 3)
  (check "all returned creds belong to the queried federation"
         (every (lambda (c) (equal? (cred-issuer c) %federation)) found)))

;;; ── count-witness-attestors (governance dashboard) ───────────────────

(let ((all (list (assignment %member-1 1)
                 (assignment %member-1 2)   ;; same member, two witnesses
                 (assignment %member-2 1)
                 (assignment %member-3 1))))
  (check "count-witness-attestors dedupes by member"
         (count-witness-attestors %federation all) 3)
  (check "empty federation → 0 attestors"
         (count-witness-attestors %federation '()) 0))

;;; ── audit-witness-quorum-independence (KEL-grounded) ─────────────────
;;;
;;; The truthful check: only witnesses ACTUALLY in the federation's
;;; group KEL `b` list count toward quorum. Caller passes the backer
;;; list, fetched from KERIA via the group AID's establishment event.

;; Happy: 4 distinct members, all 4 in KEL, toad=4 → independent.
(let* ((cs (list (assignment %member-1 1)
                 (assignment %member-2 1)
                 (assignment %member-3 1)
                 (assignment %member-4 1)))
       (kel (map witness-aid-of cs)))
  (check "4 distinct, 4 in KEL, toad=4 → independent"
         (audit-witness-quorum-independence %federation 4 cs kel)))

;; Concentrated: 1 member runs 3 of 4 witnesses, all in KEL → 2 distinct
;; operators for 4 witnesses → toad=4 fails, toad=2 passes.
(let* ((cs (list (assignment %member-1 1)
                 (assignment %member-1 2)
                 (assignment %member-1 3)
                 (assignment %member-2 1)))
       (kel (map witness-aid-of cs)))
  (check "concentrated 3+1 toad=4 → NOT independent"
         (not (audit-witness-quorum-independence %federation 4 cs kel)))
  (check "concentrated 3+1 toad=2 → still independent"
         (audit-witness-quorum-independence %federation 2 cs kel)))

;; Off-KEL credentials don't count: 4 assignments issued, only 2 in KEL.
(let* ((c1 (assignment %member-1 1))
       (c2 (assignment %member-2 1))
       (c3 (assignment %member-3 1))
       (c4 (assignment %member-4 1))
       (cs (list c1 c2 c3 c4))
       (kel (list (witness-aid-of c1) (witness-aid-of c2))))
  (check "4 assigned, 2 in KEL, toad=4 → NOT independent"
         (not (audit-witness-quorum-independence %federation 4 cs kel)))
  (check "4 assigned, 2 in KEL, toad=2 → independent"
         (audit-witness-quorum-independence %federation 2 cs kel)))

;; Empty KEL → never independent for any toad ≥ 1.
(check "no KEL backers, toad=1 → NOT independent"
       (not (audit-witness-quorum-independence
             %federation 1 (list (assignment %member-1 1)) '())))

;; Revoked credentials don't count even when their witness is in KEL.
(let* ((live    (assignment %member-1 1))
       (revoked (cred-with-revoked (assignment %member-2 1) #t))
       (kel (list (witness-aid-of live) (witness-aid-of revoked))))
  (check "revoked assignment doesn't count even if its AID is in KEL"
         (not (audit-witness-quorum-independence
               %federation 2 (list live revoked) kel))))

(test-summary!)
