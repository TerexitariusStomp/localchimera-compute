;;; test-observation-evidence.scm — the picture a photo read was made from rides
;;; the observation credential as a claim of its own.
;;;
;;; What this pins:
;;;
;;;   • a credential that names no picture keeps the SAID it had before the
;;;     claim existed (the golden values below were taken from the constructor
;;;     before the claim was added);
;;;   • a credential that names one has another SAID, and the claim reads back;
;;;   • the credential bridge reads the hash off an event's evidence: tag, so a
;;;     count recorded with a picture issues a credential carrying it, and one
;;;     recorded without issues the claim-free credential;
;;;   • the tag grammar: only a sha256 hash is evidence.
;;;
;;; Run from project root:
;;;   tools/own-ccache.sh guile --no-auto-compile -q -L module tests/governance/test-observation-evidence.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)
(add-to-load-path "module")

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness)
             (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1)
             (playnet governance acdc-bridge) (playnet keri acdc) (playnet keri acdc-store)
             (playnet credentials work) (playnet keri acdc)
             ((playnet governance acdc-bridge) #:select (make-credentialing-on-event))
             (playnet planner observation evidence)
             (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1))

(define SCOPE "ESCOPEAID000000000000000000000000000000000")
(define HOLDER "EHOLDERAID00000000000000000000000000000000")
(define pic (string-append "sha256:" (make-string 64 #\b)))

(display "\n── 1. the SAID without a picture is the one it always had ──\n")

(define plain
  (make-observation-event-credential
   SCOPE HOLDER "evt-count-1" "lower"
   #:qty 2.5 #:unit "kg" #:scope-id "org:commune" #:resource-conforms-to "rice"
   #:at-location "place:pantry" #:timestamp "2026-10-01T10:00:00Z" #:fulfills #f))
(check "a count with no picture" (assq-ref plain 'said) "EHyIKXi1CgNb3R0SSUmxzvFoc9vHVeebnU0t3HHIcUUL")

(define committed
  (make-observation-event-credential
   SCOPE HOLDER "evt-count-2" "raise"
   #:qty 1 #:unit %count-unit #:scope-id "org:commune" #:resource-conforms-to "jam"
   #:fulfills "cmt-1" #:timestamp "2026-10-01T11:00:00Z"))
(check "a count that fulfils a commitment" (assq-ref committed 'said) "EOGTdzcGbTddVAmRy3UQcsfhIfKhtZv7R7mfpy9WWGdr")
(check "…with no claim to a picture" (assq-ref (assq-ref plain 'claims) 'evidence) #f)

(display "\n── 2. a picture is a claim, and moves the SAID ──\n")

(define seen
  (make-observation-event-credential
   SCOPE HOLDER "evt-count-1" "lower"
   #:qty 2.5 #:unit "kg" #:scope-id "org:commune" #:resource-conforms-to "rice"
   #:at-location "place:pantry" #:timestamp "2026-10-01T10:00:00Z" #:fulfills #f
   #:evidence pic))
(check "the claim reads back" (assq-ref (assq-ref seen 'claims) 'evidence) pic)
(check-pred "…and the SAID differs from the same count without it"
            (not (equal? (assq-ref seen 'said) (assq-ref plain 'said))))
(check "…and a picture is the last claim, after every claim a record always held"
       (car (last-pair (assq-ref seen 'claims))) (cons 'evidence pic))

(display "\n── 3. the tag grammar ──\n")

(check-pred "a sha256 hash is evidence" (evidence-hash? pic))
(check-pred "upper-case hex is not" (not (evidence-hash? (string-append "sha256:" (make-string 64 #\B)))))
(check-pred "a short hash is not" (not (evidence-hash? "sha256:abc123")))
(check-pred "another digest is not" (not (evidence-hash? (string-append "md5:" (make-string 64 #\a)))))
(check "the tag names the hash" (evidence-tag pic) (string-append "evidence:" pic))
(check "the tags give the hash back"
       (tags-evidence (list "count-of:rice" (evidence-tag pic))) pic)
(check "tags with no picture give none" (tags-evidence (list "count-of:rice")) #f)
(check "a tag that names a malformed hash gives none" (tags-evidence (list "evidence:sha256:abc")) #f)
(check "no tags give none" (tags-evidence #f) #f)

(display "\n── 4. the bridge issues the claim ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Evidence")) store))

(define (count-event id tags)
  (make-economic-event
   #:id id #:action 'lower #:resource-inventoried-as "rice" #:resource-conforms-to "rice" #:resource-classified-as tags
   #:provider "ada" #:receiver "ada" #:resource-quantity (make-measure 2.5 "kg") #:has-point-in-time "2026-10-01T10:00:00Z" #:created "2026-10-01T10:00:00Z"
   #:at-location "place:pantry"
   #:note "a count" #:in-scope-of '("org:commune")))

(with-vat vat
  (let ((obs ($ scope 'observer))
        (acdc (spawn-acdc-store)))
    ($ obs 'set-callback 'on-event (make-credentialing-on-event acdc SCOPE))
    ($ obs 'seed-resource
       (make-economic-resource #:id "rice" #:name "rice" #:conforms-to "rice" #:classified-as '()
                               #:accounting-quantity (make-measure 10.0 "kg") #:onhand-quantity (make-measure 10.0 "kg") #:primary-accountable "ada"))
    ($ obs 'record-event (count-event "evt-seen" (list (evidence-tag pic))))
    ($ obs 'record-event (count-event "evt-plain" '()))
    (define (claim-of event-id)
      (let ((c (find (lambda (c) (equal? event-id (cred-claim c 'event-id))) ($ acdc 'all))))
        (and c (cred-claim c 'evidence))))
    (check "a count with a picture issues a credential naming it" (claim-of "evt-seen") pic)
    (check-pred "a count without one issues the credential all the same"
                (find (lambda (c) (equal? "evt-plain" (cred-claim c 'event-id))) ($ acdc 'all)))
    (check "…naming none" (claim-of "evt-plain") #f)))

(test-summary!)
