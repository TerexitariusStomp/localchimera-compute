;;; test-auditor.scm — ^federation-auditor + ^custody-half-life-watcher

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness))
(use-modules (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1))
(use-modules (playnet governance auditor) (playnet governance credentials) (playnet governance scope) (playnet governance socialization) (playnet governance structural-invariants) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet openvtc first-person))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
             (rnrs bytevectors)
             (srfi srfi-1))


(define vat (spawn-vat))


(define (make-leaf store name aid)
  (let ((root (spawn-scope-root name)))
    (spawn-scope name
                 #:kind 'commune
                 #:scope-root-ref root
                 #:scope-aid aid
                 #:acdc-store store)))

(define (make-fed store name aid)
  (spawn-scope name
               #:kind 'federation
               #:scope-aid aid
               #:acdc-store store))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Auditor on a healthy tree → emits audit-pass
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Healthy tree → audit-pass ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la (make-leaf store "LA" "ELA"))
         (lb (make-leaf store "LB" "ELB"))
         (top (make-fed store "TOP" "ETOP"))
         (gtop ($ top 'mint-gov-cap "op"))
         (gla  ($ la  'mint-gov-cap "op"))
         (glb  ($ lb  'mint-gov-cap "op")))
    ($ la 'admit-member gla "alice")
    ($ lb 'admit-member glb "bob")
    ($ top 'admit-commune gtop "la" la)
    ($ top 'admit-commune gtop "lb" lb)
    (let* ((auditor (spawn-federation-auditor top
                                              #:auditor-aid "EAUDIT"))
           (said    ($ auditor 'audit!))
           (creds   ($ store 'by-schema *schema-playnet-audit-pass*)))
      (check-pred "audit returns SAID" (string? said))
      (check-pred "one audit-pass emitted" (= 1 (length creds)))
      (check-pred "no incoherence-alert"
                  (null? ($ store 'by-schema *schema-playnet-incoherence-alert*)))
      (check-pred "auditor cycle bumped"
                  (= 1 ($ auditor 'cycle))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Auditor on broken tree (double-count) → emits incoherence-alert
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Broken tree → incoherence-alert ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la (make-leaf store "LA" "ELA"))
         (lb (make-leaf store "LB" "ELB"))
         (top (make-fed store "TOP" "ETOP"))
         (gtop ($ top 'mint-gov-cap "op"))
         (gla  ($ la  'mint-gov-cap "op"))
         (glb  ($ lb  'mint-gov-cap "op")))
    ($ la 'admit-member gla "alice")
    ($ lb 'admit-member glb "alice")            ;; double-count
    ($ top 'admit-commune gtop "la" la)
    ($ top 'admit-commune gtop "lb" lb)
    (let* ((auditor (spawn-federation-auditor top
                                              #:auditor-aid "EAUDIT"))
           (said    ($ auditor 'audit!))
           (alerts  ($ store 'by-schema *schema-playnet-incoherence-alert*)))
      (check-pred "alert emitted" (= 1 (length alerts)))
      (let ((violations (cred-claim (car alerts) 'violations)))
        (check-pred "double-counted-members reported"
                    (assq-ref violations 'double-counted-members))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Half-life watcher: expired attestation → reversion + revoke
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Half-life watcher ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (root  (spawn-scope-root "Workshop"))
         (scope (spawn-scope "Workshop"
                             #:kind 'commune
                             #:scope-root-ref root
                             #:scope-aid "EWorkshop"
                             #:acdc-store store))
         (gov ($ scope 'mint-gov-cap "op"))
         ;; Issue an expired attestation directly so we don't depend on
         ;; clock movement during the test.
         (expired (make-custody-attestation-credential
                   "EWorkshop" "EWorkshop" "spec:loom" 5
                   #:valid-from "2020-01-01T00:00:00Z"
                   #:valid-until "2020-01-02T00:00:00Z")))
    ($ store 'issue expired)
    ;; Default custodian: a "commons" pool AID for any spec
    (let* ((default-fn (lambda (_spec) "ECommonsPool"))
           (watcher (spawn-custody-half-life-watcher
                     scope default-fn #:watcher-aid "EHalflife"))
           (results ($ watcher 'tick!)))
      (check-pred "one expired processed" (= 1 (length results)))
      (let* ((expired-said   (car (car results)))
             (reversion-said (cdr (car results)))
             (revs ($ store 'by-schema *schema-playnet-reversion-attestation*))
             (rev (find (lambda (c) (equal? reversion-said (cred-said c))) revs)))
        (check-pred "expired SAID matches" (equal? (cred-said expired) expired-said))
        (check-pred "reversion attestation issued" (not (not rev)))
        (check-pred "reversion credits commons pool"
                    (equal? "ECommonsPool" (cred-holder rev)))
        (check-pred "reversion edge points at expired"
                    (equal? expired-said
                            (edge-target (cred-edge rev 'reverted-from))))
        (check-pred "expired now revoked"
                    (let ((all ($ store 'by-schema
                                   *schema-playnet-custody-attestation*)))
                      (cred-revoked? (find (lambda (c)
                                             (equal? expired-said (cred-said c)))
                                           all))))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Half-life watcher idempotence: tick on no expired → no-op
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Watcher no-op ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (root  (spawn-scope-root "Stable"))
         (scope (spawn-scope "Stable"
                             #:kind 'commune
                             #:scope-root-ref root
                             #:scope-aid "EStable"
                             #:acdc-store store))
         (gov   ($ scope 'mint-gov-cap "op")))
    ($ scope 'attest-custody gov "spec:thread" 100
       'valid-until "2099-12-31T00:00:00Z")
    (let* ((watcher (spawn-custody-half-life-watcher
                     scope (lambda (_) "ECommons")))
           (results ($ watcher 'tick!)))
      (check-pred "no expired" (null? results))
      (check-pred "no reversion attestations"
                  (null? ($ store 'by-schema
                             *schema-playnet-reversion-attestation*))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. UTC normalization: attest-custody timestamps are ISO-UTC
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. UTC timestamps ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (root  (spawn-scope-root "TZ"))
         (scope (spawn-scope "TZ"
                             #:kind 'commune
                             #:scope-root-ref root
                             #:scope-aid "ETZ"
                             #:acdc-store store))
         (gov ($ scope 'mint-gov-cap "op")))
    ($ scope 'attest-custody gov "spec:x" 1)
    (let* ((live ($ scope 'live-custody-attestations))
           (vf   (cred-claim (car live) 'valid-from)))
      (check-pred "valid-from is a string"  (string? vf))
      (check-pred "valid-from has Z suffix"
                  (and (> (string-length vf) 0)
                       (char=? #\Z (string-ref vf (- (string-length vf) 1))))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. KERI signing — the audited federation signs its own audit records
;;; ════════════════════════════════════════════════════════════════════════════
;;;
;;; The auditor is the federation's own runtime invariant checker, so the
;;; federation issues + signs the audit-pass (issuer = fed-aid, signed via the
;;; federation's own sign-said — keypair stays in the ^scope actor). Forgery-
;;; resistant provenance, not an independent auditor identity.

(display "\n── 6. Signed audit credentials ──\n")

(with-vat vat
  (let* ((id      (make-keri-identity (make-bytevector 32 7)))
         (fed-aid (keri-identity-aid id))
         (store   (spawn-acdc-store))
         (leaf    (make-leaf store "Signed" "ESigned"))
         ;; the federation carries a real keypair, so it can sign
         (top     (spawn-scope "TOPS" #:kind 'federation #:scope-aid fed-aid
                               #:keypair (keri-identity-keypair id)
                               #:acdc-store store))
         (gtop    ($ top 'mint-gov-cap "op")))
    ($ top 'admit-commune gtop "leaf" leaf)
    (let* ((auditor (spawn-federation-auditor top))
           (said ($ auditor 'audit!))
           (cred (find (lambda (c) (equal? said (cred-said c)))
                       ($ store 'by-schema *schema-playnet-audit-pass*))))
      (check-pred "credential issued"  (not (not cred)))
      (check "audit-pass issuer = the audited federation"
             (cred-issuer cred) fed-aid)
      (check-pred "signature attached (signed by the federation)"
                  (cred-signature cred))
      (check-pred "signature verifies against fed-aid"
                  (cred-signature-valid? cred)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Read-only auditor facet — no audit! exposed
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 7. Auditor facet ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la (make-leaf store "FL" "EFL"))
         (top (make-fed store "FTOP" "EFTOP"))
         (gtop ($ top 'mint-gov-cap "op")))
    ($ top 'admit-commune gtop "la" la)
    (let* ((auditor (spawn-federation-auditor top))
           (ro      (spawn-auditor-facet auditor)))
      (check-pred "facet exposes federation"
                  (eq? top ($ ro 'federation)))
      (check-pred "facet exposes cycle"
                  (number? ($ ro 'cycle)))
      (check-pred "facet rejects audit!"
                  (catch #t
                    (lambda () ($ ro 'audit!) #f)
                    (lambda _ #t))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. The ownership backstop: a field contradicting a standing title is a finding

(display "\n── 8. Forged primary-accountable → ownership-violations finding ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (leaf  (make-leaf store "OL" "EOL"))
         (top   (make-fed store "OTOP" "EOTOP"))
         (gtop  ($ top 'mint-gov-cap "op"))
         (rid   "means:EAlice:lathe"))
    ($ top 'admit-commune gtop "ol" leaf)
    ;; Mallory's field claim over Alice's titled lathe
    ($ ($ ($ leaf 'scope-root) 'observer) 'seed-resource
       (make-economic-resource
        #:id rid #:conforms-to "lathe"
        #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:primary-accountable "EMallory"))
    ($ store 'issue (ownership-credential "EAlice" rid "lathe"))
    (let* ((auditor (spawn-federation-auditor top))
           (said    ($ auditor 'audit!))
           (cred    (find (lambda (c) (equal? said (cred-said c)))
                          ($ store 'all))))
      (check "the audit emits an incoherence alert"
             (cred-schema cred) *schema-playnet-incoherence-alert*)
      (check "naming the contradicted resource and the claimed owner"
             (assq-ref (cred-claim cred 'violations) 'ownership-violations)
             (list (list "EOL" rid "EMallory"))))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 9. One record, one scope: a resource copied into two leaves is a finding

(display "\n── 9. A resource held by two leaves → records-held-twice finding ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la (make-leaf store "RL1" "ERL1"))
         (lb (make-leaf store "RL2" "ERL2"))
         (top (make-fed store "RTOP" "ERTOP"))
         (gtop ($ top 'mint-gov-cap "op"))
         (lathe (lambda () (make-economic-resource
                            #:id "means:EAlice:lathe" #:conforms-to "lathe"
                            #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:primary-accountable "EAlice"))))
    ($ top 'admit-commune gtop "rl1" la)
    ($ top 'admit-commune gtop "rl2" lb)
    ;; one lathe in one leaf: clean
    ($ ($ ($ la 'scope-root) 'observer) 'seed-resource (lathe))
    (check "held once: the invariant holds" (records-held-once? top) #t)
    ;; the SAME record copied into the second leaf: the fold would count it
    ;; twice and could not tell — the auditor can
    ($ ($ ($ lb 'scope-root) 'observer) 'seed-resource (lathe))
    (check "held twice: the invariant fails" (records-held-once? top) #f)
    (let* ((auditor (spawn-federation-auditor top))
           (said ($ auditor 'audit!))
           (cred (find (lambda (c) (equal? said (cred-said c))) ($ store 'all)))
           (rows (assq-ref (cred-claim cred 'violations) 'records-held-twice)))
      (check "the alert names the record and both leaves"
             (and (= 1 (length rows))
                  (eq? 'resource (car (car rows)))
                  (equal? "means:EAlice:lathe" (cadr (car rows)))
                  (lset= equal? (cddr (car rows)) '("ERL1" "ERL2")))
             #t))))

(display "\n")
(display "\n── 9b. A declared need held by two scopes — a person with no profile — is a finding ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la (make-leaf store "NL1" "ENL1"))
         (lb (make-leaf store "NL2" "ENL2"))
         (top (make-fed store "NTOP" "ENTOP"))
         (gtop ($ top 'mint-gov-cap "op"))
         (soap (lambda () (make-intent #:id "need:ECleo:spec-soap" #:action 'consume #:name "soap" #:resource-conforms-to "spec-soap"
                                       #:resource-quantity (make-measure 2 "bar") #:receiver "ECleo" #:in-scope-of '()))))
    ($ top 'admit-commune gtop "nl1" la)
    ($ top 'admit-commune gtop "nl2" lb)
    ($ ($ ($ la 'scope-root) 'plan-store) 'add-intent (soap))
    (check "her need in one scope: the invariant holds" (records-held-once? top) #t)
    ($ ($ ($ lb 'scope-root) 'plan-store) 'add-intent (soap))
    (check "in two: it fails" (records-held-once? top) #f)
    (check "the finding names the need and both scopes"
           (let ((rows (records-held-twice top)))
             (and (= 1 (length rows)) (eq? 'need (car (car rows)))
                  (equal? "need:ECleo:spec-soap" (cadr (car rows)))
                  (lset= equal? (cddr (car rows)) '("ENL1" "ENL2"))))
           #t)))

(test-summary!)
