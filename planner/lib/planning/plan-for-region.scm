;;; plan-for-region.scm — Region-level planning wrapper
;;;
;;; Translated from src/lib/planning/plan-for-region.ts
;;; Thin wrapper over plan-for-unit with region-specific (H3 cell) policies.

;; Assumes plan-for-unit.scm and all dependencies are loaded.

(use-modules (srfi srfi-1))


;; ═════════════════════════════════════════════════════════════════════════
;; Region spatial model
;; ═════════════════════════════════════════════════════════════════════════

(define (normalize-cells cells)
  "Deduplicate H3 cell IDs. Note: H3 parent-child filtering would require
   the H3 library. For now, just deduplicates."
  (delete-duplicates cells))


;; ═════════════════════════════════════════════════════════════════════════
;; plan-for-region — main entry point
;; ═════════════════════════════════════════════════════════════════════════

(define* (plan-for-region cell-ids horizon
                          recipe-store plan-store observer
                          #:key (agents #f)
                                (buffer-zone-store #f) (buffer-profiles #f)
                                (buffered-specs '()) (location-store #f))
  "Plan for a set of H3 cells. Normalizes cell IDs, then delegates to
   plan-for-unit with region-specific normalization."
  (plan-for-unit cell-ids horizon
                 recipe-store plan-store observer
                 #:agents agents
                 #:normalize-fn normalize-cells
                 #:plan-name "Region Plan"
                 #:buffer-zone-store buffer-zone-store
                 #:buffer-profiles buffer-profiles
                 #:buffered-specs buffered-specs
                 #:location-store location-store))
