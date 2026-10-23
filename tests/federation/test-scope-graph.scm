;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/federation/test-scope-graph.scm
;;; ^scope-graph reactive topology view: orphans, parent links, decompose.

(use-modules (playnet test harness)
             (playnet federation scope-graph)
             (goblins) (goblins utils hashmap))

(define vat (spawn-vat))
(define g (with-vat vat (spawn ^scope-graph)))

(display "\n── 1. note-spawn populates kind-map; UC excluded from orphans ──\n")
(with-vat vat
  ($ g 'note-spawn "E_UC"  'universal-commune '())
  ($ g 'note-spawn "E_FED" 'federation '())
  ($ g 'note-spawn "E_COM" 'commune '())
  (check-pred "orphan count is 2 (UC excluded)"
              (= 2 (length ($ g 'orphans))))
  (check-pred "UC discoverable via find-by-kind"
              (equal? '("E_UC") ($ g 'find-by-kind 'universal-commune))))

(display "\n── 2. note-parent-link moves child out of orphan set ──\n")
(with-vat vat
  ($ g 'note-parent-link "E_COM" "E_FED")
  (check-pred "only FED remains orphan"
              (equal? '("E_FED") ($ g 'orphans)))
  (check-pred "COM's parent is FED"
              (equal? '("E_FED")
                      (map car ($ g 'get-parents "E_COM"))))
  (check-pred "FED's children include COM"
              (member "E_COM" ($ g 'get-children "E_FED"))))

(display "\n── 3. note-unlink restores orphan status ──\n")
(with-vat vat
  ($ g 'note-unlink "E_COM" "E_FED")
  (check-pred "both orphans again"
              (= 2 (length ($ g 'orphans))))
  (check-pred "COM has no parents"
              (null? ($ g 'get-parents "E_COM"))))

(display "\n── 4. note-decompose tears down all edges ──\n")
(with-vat vat
  ($ g 'note-parent-link "E_COM" "E_FED")     ; relink
  ($ g 'note-decompose "E_FED")
  (check-pred "FED gone from kind-map"
              (not ($ g 'get-kind "E_FED")))
  (check-pred "COM is orphan again (parent dissolved)"
              (member "E_COM" ($ g 'orphans))))

(display "\n── 5. count reflects current population ──\n")
(with-vat vat
  (check-pred "count = 2 after decompose"
              (= 2 ($ g 'count))))

(display "\n── 6. refs-map + aid-names-map populated by note-spawn kwargs ──\n")
(define vat2 (spawn-vat))
(define g2 (with-vat vat2 (spawn ^scope-graph)))
(define fake-ref-X (with-vat vat2 (spawn (lambda (b) (lambda _ 'X)))))
(with-vat vat2
  ($ g2 'note-spawn "E_X" 'commune '()
     #:ref fake-ref-X
     #:aid-name "scope-E_X")
  (check-pred "find-ref returns the registered ref"
              (eq? fake-ref-X ($ g2 'find-ref "E_X")))
  (check-pred "get-aid-name returns the registered alias"
              (equal? "scope-E_X" ($ g2 'get-aid-name "E_X")))
  (check-pred "has-aid? sees the AID"
              ($ g2 'has-aid? "E_X"))
  (check-pred "find-ref on unknown returns #f"
              (not ($ g2 'find-ref "E_unknown")))
  (check-pred "get-aid-name on unknown returns #f"
              (not ($ g2 'get-aid-name "E_unknown"))))

(display "\n── 7. note-decompose tears down refs + aid-names ──\n")
(with-vat vat2
  ($ g2 'note-decompose "E_X")
  (check-pred "find-ref returns #f after decompose"
              (not ($ g2 'find-ref "E_X")))
  (check-pred "get-aid-name returns #f after decompose"
              (not ($ g2 'get-aid-name "E_X"))))

(display "\n── 8. the reparent sink: spawn-time parents, replay on install, one order ──\n")
;; The derived aggregation tree is a projection of this graph through the
;; sink. Three claims: a scope spawned WITH parents (boot hydration) reaches
;; the sink like an admitted one; installing the sink replays every edge
;; already held, so hydration before installation loses nothing; and the
;; parents arrive in one order whatever order the edges came, with
;; aggregating-parent picking the same head from either.
(define vat3 (spawn-vat))
(define g3 (with-vat vat3 (spawn ^scope-graph)))
(define fired '())
(with-vat vat3
  ($ g3 'note-spawn "E_UC"  'universal-commune '())
  ($ g3 'note-spawn "E_FB" 'federation '())
  ($ g3 'note-spawn "E_FA" 'federation '())
  ($ g3 'note-spawn "E_C1" 'commune '("E_FB"))          ; hydrated with its parent
  ($ g3 'note-parent-link "E_C1" "E_FA")                 ; a second parent, later
  (check-pred "a spawn naming parents is no orphan"
              (not (member "E_C1" ($ g3 'orphans))))
  (check-pred "no sink installed yet: nothing fired"
              (null? fired))
  ($ g3 'set-on-reparent (lambda (child parents) (set! fired (cons (cons child parents) fired))))
  (check-pred "installing the sink replays the held edge"
              (equal? '(("E_C1" "E_FA" "E_FB")) fired))
  (set! fired '())
  ($ g3 'note-spawn "E_C2" 'commune '("E_FA" "E_FB"))
  (check-pred "a spawn with parents fires the sink, parents in string order"
              (equal? '(("E_C2" "E_FA" "E_FB")) fired))
  (check-pred "aggregating-parent is the smallest AID, whichever order it is asked in"
              (and (equal? "E_FA" (aggregating-parent '("E_FB" "E_FA")))
                   (equal? "E_FA" (aggregating-parent '("E_FA" "E_FB")))
                   (not (aggregating-parent '()))))
  (set! fired '())
  ($ g3 'note-unlink "E_C2" "E_FA")
  (check-pred "dropping the aggregating parent hands the sink the one that stays"
              (equal? '(("E_C2" "E_FB")) fired)))

(display "\n=== test-scope-graph PASSED ===\n")
