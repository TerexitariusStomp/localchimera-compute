;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; validity.scm — a credential's validity, read and dated.
;;;
;;; A conformance or skill credential carries a `valid-until` claim. This module
;;; is both ends of one loop: `custody-cred-live?` READS that claim (the law
;;; itself, `cred-live?`, lives in (playnet keri acdc) beside the credential
;;; shape), and `cred-with-valid-until` / `apply-recert-schedule` WRITE it, from the
;;; recert schedule a plan's reliance gives (formulas/cadence). Pure over plain alists.

(define-module (playnet vf facts validity)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet keri acdc) #:select (cred-live?))
  #:re-export (cred-live?)
  #:export (cred-claim-of custody-cred-live? cred-with-valid-until apply-recert-schedule))

(define (cred-claim-of cred key)
  (let ((claims (assq-ref cred 'claims)))
    (and claims (assq-ref claims key))))

;; cred-live? — THE credential-liveness law — lives in (playnet keri acdc),
;; beside the credential shape it reads, and is re-exported here.
(define custody-cred-live? cred-live?)

(define (cred-with-valid-until cred valid-until)
  "Stamp VALID-UNTIL onto CRED's `claims` alist (replacing any prior), returning a new
   cred; #f leaves the credential OPEN (drops any `valid-until`).  `custody-cred-live?`
   reads exactly this claim — writer and reader are the two ends of the same loop."
  (let* ((claims   (or (assq-ref cred 'claims) '()))
         (stripped (filter (lambda (kv) (not (eq? (car kv) 'valid-until))) claims))
         (claims*  (if valid-until (cons (cons 'valid-until valid-until) stripped) stripped)))
    (cons (cons 'claims claims*)
          (filter (lambda (kv) (not (eq? (car kv) 'claims))) cred))))

(define* (apply-recert-schedule schedule creds skill-of #:key (now 0) (period-span 1.0))
  "The consumer of a plan's `conformance-recert` field: stamp each credential in CREDS
   with the recert `valid-until` its skill's SCHEDULE entry implies.  SCHEDULE =
   ((skill . interval | #f) …) as `plan-scope` emits it (interval in periods, now=0);
   SKILL-OF extracts a cred's skill (e.g. (lambda (c) (cred-claim-of c 'skill))).  The
   issuer supplies its own clock: valid-until = NOW + interval·PERIOD-SPAN, or #f (OPEN)
   when the skill is absent from the schedule or its interval is #f.  Keys are strings,
   so the lookup is `assoc`, not `assq`.  Returns the creds re-stamped
   (cred-with-valid-until) — the plan's reliance flowing onto the credential the issuer
   signs, gated thereafter by `custody-cred-live?`."
  (map (lambda (cred)
         (let* ((sk (skill-of cred))
                (p  (and (string? sk) (assoc sk schedule)))
                (iv (and p (cdr p)))
                (vu (and iv (+ now (* iv period-span)))))
           (cred-with-valid-until cred vu)))
       creds))
