;;; test-recomposition-ballot.scm — Phase 6: recomposition ratification
;;;
;;; Four scenarios:
;;;   A. Genesis path — gov-cap-only admit-commune; auditor passes.
;;;   B. Post-genesis without ratification — gov-cap-only admit-commune;
;;;      auditor flags `unratified-recompositions`.
;;;   C. Post-genesis with ratification — admit-commune carrying a valid
;;;      ratification ACDC; auditor passes; emitted membership cred has
;;;      a `ratification` edge.
;;;   D. Wrong-spec ratification — three error branches: type mismatch,
;;;      spec mismatch, threshold not met.

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet scope root) (playnet vf schemas) (srfi srfi-1))
(use-modules (playnet governance auditor) (playnet credentials audit) (playnet credentials membership) (playnet credentials voting) (playnet credentials work) (playnet keri acdc) (playnet boot scope) (playnet voice scope-ballots) (playnet governance structural-invariants) (playnet keri acdc) (playnet keri acdc-store))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
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
;;; A. Genesis path: gov-cap-only admit-commune, auditor passes
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── A. Genesis: no ratification, audit clean ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la    (make-leaf store "GLA" "EGLA"))
         (top   (make-fed  store "GTOP" "EGTOP"))
         (gtop  ($ top 'mint-gov-cap "op")))
    ;; No work-events — pure genesis. admit-commune without ratification.
    ($ top 'admit-commune gtop "la" la)
    (let ((cred (find (lambda (c) (equal? "EGLA" (cred-holder c)))
                      ($ store 'by-schema
                         *schema-playnet-federation-membership*))))
      (check-pred "membership cred issued"   (not (not cred)))
      (check-pred "no ratification edge"     (not (cred-edge cred 'ratification)))
      (check-pred "tree coherent (genesis)"
                  (federation-tree-coherent? top))
      (check-pred "no unratified recompositions"
                  (null? (unratified-recomposition-acdcs top)))
      (check-pred "auditor passes"
                  (recomposition-ratified? top)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; B. Post-genesis, gov-cap only, audit flags
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── B. Post-genesis without ratification: audit flags ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la    (make-leaf store "BLA" "EBLA"))
         (top   (make-fed  store "BTOP" "EBTOP"))
         (gtop  ($ top 'mint-gov-cap "op")))
    ;; Admit LA at genesis (no work-events yet) — no ratification needed.
    ($ top 'admit-commune gtop "la" la)
    (check-pred "before contributors: tree coherent"
                (federation-tree-coherent? top))
    ;; LA gains a contributor → LA is now post-genesis. The previously-
    ;; issued admit-LA ACDC retroactively requires a ratification per
    ;; the conservative approximation (target-scope-was-genesis? checks
    ;; "no contributors NOW" rather than "no contributors at issue time").
    ($ store 'issue
       (make-work-event-credential
        "EBLA" "alice" "B-evt-1" 4 %effort-unit
        #:timestamp "2026-04-26T10:00:00Z"))
    (check-pred "post-contributors: validator flags retroactively"
                (not (recomposition-ratified? top)))
    (check-pred "tree-coherent? = #f"
                (not (federation-tree-coherent? top)))
    (let* ((unrat (unratified-recomposition-acdcs top)))
      (check-pred "the unratified ACDC is admit-LA"
                  (and (= 1 (length unrat))
                       (equal? "EBLA" (cred-holder (car unrat))))))
    ;; Auditor surfaces the violation
    (let* ((auditor (spawn-federation-auditor top))
           (_      ($ auditor 'audit!))
           (alerts ($ store 'by-schema
                      *schema-playnet-incoherence-alert*)))
      (check-pred "incoherence-alert emitted"  (= 1 (length alerts)))
      (let ((vios (cred-claim (car alerts) 'violations)))
        (check-pred "unratified-recompositions in alert"
                    (assq-ref vios 'unratified-recompositions))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; C. Post-genesis with ratification, audit clean
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── C. Post-genesis with ratification ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la    (make-leaf store "CLA" "ECLA"))
         (lb    (make-leaf store "CLB" "ECLB"))
         (top   (make-fed  store "CTOP" "ECTOP"))
         (gtop  ($ top 'mint-gov-cap "op")))
    ;; Issue ratification ACDCs (issuer = target = each commune itself)
    ;; for both admissions, then admit with ratification.
    (let* ((rat-la (make-recomposition-ratification-credential
                    "ECLA" 'admit-commune
                    '(admit-commune "la" "ECLA")
                    "E_C_snap_la" '((yes . 5) (no . 0))))
           (rat-lb (make-recomposition-ratification-credential
                    "ECLB" 'admit-commune
                    '(admit-commune "lb" "ECLB")
                    "E_C_snap_lb" '((yes . 5) (no . 0)))))
      ($ store 'issue rat-la)
      ($ store 'issue rat-lb)
      ($ top 'admit-commune gtop "la" la 'ratification (cred-said rat-la))
      ;; Add a contributor to LA — the post-genesis state that would
      ;; trigger the validator without ratification.
      ($ store 'issue
         (make-work-event-credential
          "ECLA" "alice" "C-evt-1" 4 %effort-unit
          #:timestamp "2026-04-26T10:00:00Z"))
      ($ top 'admit-commune gtop "lb" lb 'ratification (cred-said rat-lb))
      ;; Both membership creds carry ratification edges.
      (let* ((memship-lb
              (find (lambda (c) (equal? "ECLB" (cred-holder c)))
                    ($ store 'by-schema
                       *schema-playnet-federation-membership*)))
             (edge (cred-edge memship-lb 'ratification)))
        (check-pred "ratification edge present" (not (not edge)))
        (check-pred "edge target = ratification SAID"
                    (equal? (cred-said rat-lb) (edge-target edge)))
        (check-pred "edge schema = recomposition-ratification"
                    (equal? *schema-playnet-recomposition-ratification*
                            (edge-schema edge))))
      (check-pred "validator passes"
                  (recomposition-ratified? top))
      (check-pred "tree-coherent? = #t"
                  (federation-tree-coherent? top)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; D. Wrong-spec ratification — method rejects with explicit errors
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── D. Wrong-spec ratification rejected ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la    (make-leaf store "DLA" "EDLA"))
         (lb    (make-leaf store "DLB" "EDLB"))
         (top   (make-fed  store "DTOP" "EDTOP"))
         (gtop  ($ top 'mint-gov-cap "op")))
    ;; D1: type mismatch — ratification for merge-with used in admit-commune
    (let* ((rat-merge
            (make-recomposition-ratification-credential
             "EDLB" 'merge-with
             '(merge-with "EOTHER")
             "E_d1_snap" '((yes . 1)))))
      ($ store 'issue rat-merge)
      (check-pred "merge-with rat rejected by admit-commune"
                  (catch #t
                    (lambda ()
                      ($ top 'admit-commune gtop "lb" lb
                         'ratification (cred-said rat-merge))
                      #f)
                    (lambda (key . args) #t))))

    ;; D2: spec mismatch — right type, wrong commune-aid
    (let* ((rat-wrong-spec
            (make-recomposition-ratification-credential
             "EDLB" 'admit-commune
             '(admit-commune "lb" "WRONG-AID")
             "E_d2_snap" '((yes . 1)))))
      ($ store 'issue rat-wrong-spec)
      (check-pred "wrong-spec rat rejected"
                  (catch #t
                    (lambda ()
                      ($ top 'admit-commune gtop "lb" lb
                         'ratification (cred-said rat-wrong-spec))
                      #f)
                    (lambda _ #t))))

    ;; D3: threshold not met
    (let* ((rat-not-met
            (make-recomposition-ratification-credential
             "EDLB" 'admit-commune
             '(admit-commune "lb" "EDLB")
             "E_d3_snap" '((yes . 0) (no . 5))
             #:threshold-met? #f)))
      ($ store 'issue rat-not-met)
      (check-pred "threshold-not-met rat rejected"
                  (catch #t
                    (lambda ()
                      ($ top 'admit-commune gtop "lb" lb
                         'ratification (cred-said rat-not-met))
                      #f)
                    (lambda _ #t))))

    ;; D4: revoked ratification
    (let* ((rat-revoked
            (make-recomposition-ratification-credential
             "EDLB" 'admit-commune
             '(admit-commune "lb" "EDLB")
             "E_d4_snap" '((yes . 5)))))
      ($ store 'issue rat-revoked)
      ($ store 'revoke (cred-said rat-revoked))
      (check-pred "revoked rat rejected"
                  (catch #t
                    (lambda ()
                      ($ top 'admit-commune gtop "lb" lb
                         'ratification (cred-said rat-revoked))
                      #f)
                    (lambda _ #t))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; E. open-recomposition-ballot derives deterministic proposal-id
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── E. open-recomposition-ballot ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (top   (make-fed store "ETOP" "EE_TOP")))
    (let ((b1 (open-recomposition-ballot
               top 'admit-commune
               '(admit-commune "x" "EX")
               "Admit X" (hashmap) (hashmap)))
          (b2 (open-recomposition-ballot
               top 'admit-commune
               '(admit-commune "x" "EX")
               "Admit X" (hashmap) (hashmap))))
      (check-pred "two ballots spawned" (and b1 b2 #t))
      ;; Same proposal-spec produces same proposal-id:
      (check-pred "ballots have equal proposal-id"
                  (equal? ($ b1 'proposal-id) ($ b2 'proposal-id))))))


(display "\n")
(test-summary!)
