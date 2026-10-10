;;; test-netter-custody.scm — Netter sidecar: claim-witness, migrate, orphan

(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (goblins utils hashmap)
             (srfi srfi-1))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Witness sidecar populated by ns-allocate / ns-allocate+track
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Witness sidecar ──\n")

(let* ((ns0 (empty-netter-state))
       (ns1 (ns-allocate ns0 'flow-A #:custody-witness "ECustody1"))
       (ns2 (ns-allocate+track ns1 'flow-B 'plan-P
                               #:custody-witness "ECustody1"))
       (ns3 (ns-allocate+track ns2 'flow-C 'plan-Q
                               #:custody-witness "ECustody2")))
  (check-pred "flow-A witness = ECustody1"
              (equal? "ECustody1"
                      (hashmap-ref (ns-claim-witness ns3) 'flow-A #f)))
  (check-pred "flow-B witness = ECustody1"
              (equal? "ECustody1"
                      (hashmap-ref (ns-claim-witness ns3) 'flow-B #f)))
  (check-pred "flow-C witness = ECustody2"
              (equal? "ECustody2"
                      (hashmap-ref (ns-claim-witness ns3) 'flow-C #f))))

(let* ((ns0 (empty-netter-state))
       (ns1 (ns-allocate ns0 'flow-X)))
  (check-pred "no witness when not supplied"
              (not (hashmap-ref (ns-claim-witness ns1) 'flow-X #f))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. netter-migrate-witness rewrites entries
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Migrate witness ──\n")

(let* ((ns0 (empty-netter-state))
       (ns1 (ns-allocate+track ns0 'fa 'plan-P #:custody-witness "EOld"))
       (ns2 (ns-allocate+track ns1 'fb 'plan-P #:custody-witness "EOld"))
       (ns3 (ns-allocate+track ns2 'fc 'plan-Q #:custody-witness "EOther"))
       (ns4 (netter-migrate-witness ns3 "EOld" "ENew")))
  (check-pred "fa witness migrated to ENew"
              (equal? "ENew" (hashmap-ref (ns-claim-witness ns4) 'fa #f)))
  (check-pred "fb witness migrated to ENew"
              (equal? "ENew" (hashmap-ref (ns-claim-witness ns4) 'fb #f)))
  (check-pred "fc witness untouched"
              (equal? "EOther" (hashmap-ref (ns-claim-witness ns4) 'fc #f))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. netter-break-on-orphan reports affected plans
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Break on orphan ──\n")

(let* ((ns0 (empty-netter-state))
       (ns1 (ns-allocate+track ns0 'fa 'plan-P #:custody-witness "EOrphan"))
       (ns2 (ns-allocate+track ns1 'fb 'plan-Q #:custody-witness "EOrphan"))
       (ns3 (ns-allocate+track ns2 'fc 'plan-R #:custody-witness "ESurvivor"))
       (orphans (netter-break-on-orphan ns3 "EOrphan")))
  (check-pred "plan-P in orphans"   (memq 'plan-P orphans))
  (check-pred "plan-Q in orphans"   (memq 'plan-Q orphans))
  (check-pred "plan-R NOT orphaned" (not (memq 'plan-R orphans)))
  (check-pred "exactly 2 orphans"   (= 2 (length orphans))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. netter-retract clears witness alongside claims
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Retract clears witness ──\n")

(let* ((ns0 (empty-netter-state))
       (ns1 (ns-allocate+track ns0 'fa 'plan-P #:custody-witness "EW"))
       (ns2 (ns-allocate+track ns1 'fb 'plan-Q #:custody-witness "EW"))
       (ns3 (netter-retract ns2 'plan-P)))
  (check-pred "fa witness cleared after retract"
              (not (hashmap-ref (ns-claim-witness ns3) 'fa #f)))
  (check-pred "fb witness preserved"
              (equal? "EW" (hashmap-ref (ns-claim-witness ns3) 'fb #f))))


(display "\n")
(test-summary!)
