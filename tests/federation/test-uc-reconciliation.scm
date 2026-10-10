;;; test-uc-reconciliation.scm — cross-gateway UC collision policy
;;;
;;; The UC singularity check is vat-local, so two independently-booted
;;; graphs can each carry their own Universal Commune and then meet over
;;; cross-gateway federation. The one-UC telos resolves that by CONSENT:
;;; a genuine collision is surfaced as a *proposed* merge (ratified through
;;; merge-bottom-up!), never auto-executed; a UC already lineally unified
;;; with ours (a recomposition ancestor/descendant) is NOT a collision.

(use-modules (playnet test harness))
(use-modules (playnet credentials recomposition) (playnet keri acdc-store))
(use-modules (playnet federation universal-commune))
(use-modules (goblins) (goblins vat))


(define vat (spawn-vat))

(display "\n── UC collision classification ──\n")

(with-vat vat
  (define store (spawn-acdc-store))
  (define mine "E_uc_alpha")
  (define peer "E_uc_beta")

  ;; No peer UC yet → nothing to reconcile.
  (check "missing peer UC → none" (uc-collision-status store mine #f) 'none)
  (check "missing own UC → none"  (uc-collision-status store #f peer) 'none)

  ;; Same UC → already unified.
  (check "identical UC → identical" (uc-collision-status store mine mine) 'identical)

  ;; Two unrelated roots → a genuine collision.
  (check "unrelated UCs → collision" (uc-collision-status store mine peer) 'collision)
  (check "collision recommends a PROPOSED (not executed) merge"
         (uc-reconcile-action store mine peer)
         (list 'propose-merge mine peer))
  (check "non-collision recommends no-op"
         (uc-reconcile-action store mine mine)
         (list 'no-op 'identical)))


(display "\n── Lineage-aware: a merged-in UC is not a rival ──\n")

(with-vat vat
  (define store (spawn-acdc-store))
  (define alpha "E_uc_alpha")       ; my UC before merge
  (define beta  "E_uc_beta")        ; peer UC before merge
  (define gamma "E_uc_merged")      ; the merged successor UC

  ;; Before any merge: alpha and beta genuinely collide.
  (check "pre-merge alpha vs beta → collision"
         (uc-collision-status store alpha beta) 'collision)

  ;; Alpha + beta merge into gamma (ratified scope-merger).
  ($ store 'issue (make-scope-merger-credential
                    #:predecessor-a-aid alpha
                    #:predecessor-b-aid beta
                    #:new-scope-aid gamma
                    #:kind 'universal-commune
                    #:merged-at 100))

  ;; Now gamma is the one UC. A peer still reporting alpha (a predecessor)
  ;; is NOT a collision — it is lineally the same UC across the merge.
  (check "gamma vs its predecessor alpha → lineal (already one UC)"
         (uc-collision-status store gamma alpha) 'lineal)
  (check "gamma vs its predecessor beta → lineal"
         (uc-collision-status store gamma beta) 'lineal)
  (check "lineal → no-op, no duplicate merge proposed"
         (uc-reconcile-action store gamma alpha) (list 'no-op 'lineal))

  ;; A truly foreign UC still collides with the merged one.
  (check "gamma vs an unrelated UC → collision"
         (uc-collision-status store gamma "E_uc_delta") 'collision))


(display "\n── Merge-proposal registry (surface → ratify handoff) ──\n")

(with-vat vat
  (define props (spawn-uc-merge-proposals))
  (check "starts empty" ($ props 'count) 0)
  (check "first proposal recorded" ($ props 'propose "E_uc_a" "E_uc_b") 'recorded)
  (check "one pending" ($ props 'count) 1)
  ;; The pair is unordered — proposing the mirror is a duplicate, not a second.
  (check "mirror pair is a duplicate" ($ props 'propose "E_uc_b" "E_uc_a") 'duplicate)
  (check "still one pending" ($ props 'count) 1)
  (check "a distinct pair records" ($ props 'propose "E_uc_a" "E_uc_c") 'recorded)
  (check "two pending" ($ props 'count) 2)
  ;; On ratification + merge, governance resolves the proposal.
  (check "resolve drops it" ($ props 'resolve "E_uc_a" "E_uc_b") 'resolved)
  (check "one pending after resolve" ($ props 'count) 1))


(newline)
(test-summary!)
