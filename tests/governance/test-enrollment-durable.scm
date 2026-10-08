;;; test-enrollment-durable.scm — the ask as a durable, self-opened thing.
;;;
;;; A candidate opens their own ceremony (no sponsor); opening again finds the
;;; standing one; a candidate cannot sign for themself; a witness who has
;;; signed as many enrollments as the window allows is refused; an ask older
;;; than the ttl lapses on the next read, its record says so, and its rails
;;; clear; a witness recognised elsewhere is admitted when their ecosystem
;;; chains to the root, refused when it does not.
;;;
;;; Run:  guile --no-auto-compile -L module -L tests tests/governance/test-enrollment-durable.scm

(setenv "PLAYNET_STATE_DIR"
        (string-append (or (getenv "TMPDIR") "/tmp") "/pn-enroll-durable-" (number->string (getpid))))

;; the host crypto backend: loading (playnet keri signify) installs it
(use-modules ((playnet keri signify) #:select ()))
(use-modules (playnet test harness)
             
             (playnet governance enrollment-ceremony) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet openvtc credentials) (playnet openvtc first-person)
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid sign-said))
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(define ECO "EEco")
(define (aid id) (keri-identity-aid id))
(define (sign id said) (sign-said said (keri-identity-keypair id)))

(define vat (spawn-vat))
(with-vat vat
  (let* ((store (spawn-acdc-store))
         (ana (make-keri-identity)) (cy (make-keri-identity))
         (bo (make-keri-identity)) (dee (make-keri-identity)))
    (for-each (lambda (id) ($ store 'issue (make-personhood-credential ECO (aid id) 100)))
              (list ana cy))

    (display "\n── the candidate's own ask ──\n")
    (let* ((c (spawn-enrollment-ceremony ECO (aid bo) *self-request-evidence* #f 2 store))
           (said ($ c 'statement-said)))
      (check "it collects with no sponsor" ($ c 'status) 'collecting)
      (check "opening again is the same ceremony"
             (eq? c (spawn-enrollment-ceremony ECO (aid bo) *self-request-evidence* #f 2 store)) #t)
      (check "the candidate index finds it" (eq? c (enroll-ceremony-for-candidate ECO (aid bo))) #t)
      (check "the record stands on disk" (assq-ref (enrollment-record said) 'state) 'collecting)
      (check "the candidate cannot sign for themself"
             (catch #t (lambda () ($ c 'attest (aid bo) (sign bo said)) 'signed) (lambda _ 'refused))
             'refused)
      (check "the rule, asked ahead, says why" (string? ($ c 'eligible? (aid bo))) #t)
      (check "a recognised person may" ($ c 'eligible? (aid ana)) #t)
      (check "Ana signs" ($ c 'attest (aid ana) (sign ana said)) 1)
      (check "the vouch is on disk with its time"
             (let ((a (car (assq-ref (enrollment-record said) 'attestations))))
               (and (equal? (car a) (aid ana)) (number? (caddr a))))
             #t)
      (check "Ana has signed one enrollment this window" (witness-recent-enrollments (aid ana) 3600) 1))

    (display "\n── the witness cap ──\n")
    ;; a second ask, with a cap of one: Ana has already signed one
    (let* ((c (spawn-enrollment-ceremony ECO (aid dee) *self-request-evidence* #f 2 store
                                         #:witness-cap 1))
           (said ($ c 'statement-said)))
      (check "Ana, at the cap, is refused" (string? ($ c 'eligible? (aid ana))) #t)
      (check "Cy, under it, may" ($ c 'eligible? (aid cy)) #t)
      (check "…and signs" ($ c 'attest (aid cy) (sign cy said)) 1))

    (display "\n── lapse ──\n")
    (let ((gone (expire-stale-enrollments! 0 (+ (current-time) 10))))
      (check "both open asks lapse past the ttl" (length gone) 2)
      (check "the lapsed ask is off the candidate index" (enroll-ceremony-for-candidate ECO (aid bo)) #f)
      (check "its record says abandoned"
             (assq-ref (enrollment-record (car gone)) 'state) 'abandoned)
      (check "no ask stands" (enroll-asks ECO) '()))

    (display "\n── who may witness: recognised elsewhere ──\n")
    (let* ((root (make-keri-identity)) (root-aid (aid root))
           (far  (make-keri-identity)) (far-aid (aid far))      ; another ecosystem
           (lone (make-keri-identity)) (lone-aid (aid lone))    ; one nobody blessed
           (w-far (make-keri-identity)) (w-lone (make-keri-identity))
           (cand (make-keri-identity)))
      ;; the root blesses ECO and FAR as issuers; LONE is unblessed
      (for-each (lambda (eco)
                  ($ store 'issue (make-authorized-issuer-credential
                                   root-aid eco 5 #:signing-keypair (keri-identity-keypair root))))
                (list ECO far-aid))
      ($ store 'issue (make-personhood-credential far-aid (aid w-far) 100))
      ($ store 'issue (make-personhood-credential lone-aid (aid w-lone) 100))
      (let* ((c (spawn-enrollment-ceremony ECO (aid cand) *self-request-evidence* #f 2 store
                                           #:root-aid root-aid))
             (said ($ c 'statement-said)))
        (check "a person of a root-chained ecosystem may witness here" ($ c 'eligible? (aid w-far)) #t)
        (check "a person of an unchained ecosystem may not" (string? ($ c 'eligible? (aid w-lone))) #t)
        (check "the far witness signs" ($ c 'attest (aid w-far) (sign w-far said)) 1)
        (check "Ana signs — quorum" ($ c 'attest (aid ana) (sign ana said)) 2)
        (let ((phc ($ c 'finalize)))
          (check "the credential issued" (holds-live-phc? store ECO (aid cand)) #t)
          (check "its far witness edge points at the far credential"
                 (let ((e (assq (string->symbol (string-append "witness-" (aid w-far)))
                                (cred-edges (phc-for store ECO (aid cand))))))
                   (and e (equal? (edge-target (cdr e))
                                  (cred-said (any-live-phc-for store (aid w-far))))))
                 #t))))))

(test-summary!)
