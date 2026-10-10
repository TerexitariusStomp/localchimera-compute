;;; test-end-to-end.scm — full-stack smoke driving every hardening layer
;;;
;;; A single-scenario test that exercises the protocol from genesis
;;; through capture-detection. Catches cross-module misalignment that
;;; per-component tests can miss. Not exhaustive — meant to verify
;;; the whole stack composes as designed.

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet planner scope root) (srfi srfi-1))
(use-modules (playnet governance auditor) (playnet credentials audit) (playnet credentials commitments) (playnet credentials voting) (playnet credentials work) (playnet keri acdc) (playnet governance scope) (playnet governance structural-invariants) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri first-person predicates))
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


;;; Scenario: FED admits LA and LB.
;;; LA admits alice. LB admits bob.
;;; LA picks one-person-one-voice; FED uses labor-share.
;;; LA gets a redistribution mandate (custody-of-spec-above wheat 100).
;;; Phase 1: 50 wheat — compliant. Audit → audit-pass (signed).
;;; Phase 2: an additional 200 wheat — over threshold. Audit → alert.
;;; Phase 3: transfer all wheat away. Audit → audit-pass.

(display "\n── End-to-end smoke ──\n")

(with-vat vat
  (clear-spec-generalizations!)
  (let* ((store (spawn-acdc-store))
         (id-aud (make-keri-identity (make-bytevector 32 9)))
         ;; the federation carries a real keypair so it can sign its own
         ;; audit records (the auditor is the federation's own checker).
         (fed-aid (keri-identity-aid id-aud))
         (la  (make-leaf store "LA" "ELA"))
         (lb  (make-leaf store "LB" "ELB"))
         (fed (spawn-scope "FED"
                           #:kind 'federation
                           #:scope-aid fed-aid
                           #:keypair (keri-identity-keypair id-aud)
                           #:acdc-store store))
         (gla  ($ la 'mint-gov-cap "op"))
         (glb  ($ lb 'mint-gov-cap "op"))
         (gfed ($ fed 'mint-gov-cap "op")))

    ;; Genesis. Phase-6: communes ratify joining the federation (issuer
    ;; = commune-aid; in tests we hand-issue, production runs ballots).
    ($ la  'admit-member  gla "alice")
    ($ lb  'admit-member  glb "bob")
    (let ((rat-la (make-recomposition-ratification-credential
                   "ELA" 'admit-commune '(admit-commune "la" "ELA")
                   "E_e2e_snap_la" '((yes . 1))))
          (rat-lb (make-recomposition-ratification-credential
                   "ELB" 'admit-commune '(admit-commune "lb" "ELB")
                   "E_e2e_snap_lb" '((yes . 1)))))
      ($ store 'issue rat-la)
      ($ store 'issue rat-lb)
      ($ fed 'admit-commune gfed "la" la 'ratification (cred-said rat-la))
      ($ fed 'admit-commune gfed "lb" lb 'ratification (cred-said rat-lb)))

    (check "FED has 2 leaves" (length (federation-leaves fed)) 2)
    (check-pred "alice in LA" (member "alice" (leaf-member-aids la)))
    (check-pred "bob in LB"   (member "bob" (leaf-member-aids lb)))

    ;; Both voice and federation aggregation are universal
    ;; labor-proportional (gross/total at every level; commune-weight-async
    ;; for aggregation). Neither is configurable.

    ;; Redistribution mandate from FED → LA
    ($ store 'issue
       (make-redistribution-mandate-credential
        fed-aid "ELA"
        '(custody-of-spec-above "spec:wheat" 100)
        'federation-pool))

    ;; Phase 1: 50 wheat + a labor event — compliant
    ($ la 'attest-custody gla "spec:wheat" 50)
    ($ store 'issue
       (make-work-event-credential
        "ELA" "alice" "evt-1" 4 %effort-unit
        #:timestamp "2026-04-26T09:00:00Z"))

    (check-pred "phase-1 redistribution coherent"
                (redistribution-coherent? fed))
    (check-pred "phase-1 tree coherent"
                (federation-tree-coherent? fed))

    ;; Audit #1 — pass
    (let* ((auditor (spawn-federation-auditor
                     fed
                     #:auditor-aid (keri-identity-aid id-aud)
                     #:keypair     (keri-identity-keypair id-aud)))
           (s1 ($ auditor 'audit!)))
      (let ((p1 (find (lambda (c) (equal? s1 (cred-said c)))
                      ($ store 'by-schema *schema-playnet-audit-pass*))))
        (check-pred "phase-1 audit-pass present" (not (not p1)))
        (check-pred "phase-1 pass is signed"      (cred-signature p1))
        (check-pred "phase-1 signature verifies"  (cred-signature-valid? p1)))

      ;; Phase 2: add 200 more wheat — sum 250 > 100 threshold → breach
      ($ la 'attest-custody gla "spec:wheat" 200)
      (check-pred "phase-2 redistribution incoherent"
                  (not (redistribution-coherent? fed)))

      ;; Audit #2 — alert with redistribution-breaches
      (let* ((s2 ($ auditor 'audit!))
             (a2 (find (lambda (c) (equal? s2 (cred-said c)))
                       ($ store 'by-schema
                          *schema-playnet-incoherence-alert*))))
        (check-pred "phase-2 alert present" (not (not a2)))
        (check-pred "alert is signed"        (cred-signature a2))
        (check-pred "alert signature verifies"
                    (cred-signature-valid? a2))
        (let ((vios (cred-claim a2 'violations)))
          (check-pred "alert reports redistribution-breaches"
                      (assq-ref vios 'redistribution-breaches))))

      ;; Phase 3: transfer all wheat to FED pool. Iterate over current
      ;; live attestations so we drain the leaf cleanly.
      (let loop ()
        (let ((live (filter (lambda (a)
                              (equal? "spec:wheat"
                                      (cred-claim a 'resource-spec)))
                            ($ la 'live-custody-attestations))))
          (cond
           ((null? live) 'done)
           (else
            (let ((qty (cred-claim (car live) 'qty)))
              ($ la 'transfer-custody gla "spec:wheat" qty "EPool"
                 'carries '()))
            (loop)))))

      (check-pred "phase-3 redistribution coherent"
                  (redistribution-coherent? fed))

      ;; Audit #3 — pass again
      (let* ((s3 ($ auditor 'audit!))
             (p3 (find (lambda (c) (equal? s3 (cred-said c)))
                       ($ store 'by-schema
                          *schema-playnet-audit-pass*))))
        (check-pred "phase-3 audit-pass present" (not (not p3)))
        (check "auditor cycle bumped to 3" ($ auditor 'cycle) 3))

      ;; Lineage check — kind held throughout
      (check-pred "LA still leaf"           (scope-leaf? la))
      (check-pred "FED still federation"    (not (scope-leaf? fed)))
      (check-pred "LA kind verifies"        (verify-kind-from-lineage la))
      (check-pred "FED kind verifies"       (verify-kind-from-lineage fed)))))


(display "\n")
(test-summary!)
