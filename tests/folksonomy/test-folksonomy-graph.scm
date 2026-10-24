;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-folksonomy-graph.scm — the weighted-DAG core.
;;;
;;; Proves the folksonomy folds per-AID structure edge-sets exactly like the
;;; labour pool folds per-agent availability: weighted aggregation, competing
;;; nestings of one flat term-id, incremental re-fold of a single AID, and
;;; template extraction (most-asserted parent) with a CF lens.
;;;
;;; Run:  guile --no-auto-compile -q -L module \
;;;         -l tests/folksonomy/test-folksonomy-graph.scm

(use-modules (localchimera test harness)
             (localchimera folksonomy graph)
             (srfi srfi-1))

(define (assq-ref alist key) (let ((p (assq key alist))) (and p (cdr p))))
(define (child-of node label)
  (find (lambda (c) (equal? (assq-ref c 'label) label))
        (assq-ref node 'children)))

;;; ── Fixtures: three AIDs cutting the world of food ──────────────────────────
;;; AID-1 and AID-2 nest Grain under Food; AID-3 nests it under Staples.
;;; A weighted DAG must hold BOTH nestings of the one flat term:grain.

(define doc1
  '((terms ((id . "term:food")  (label . "Food"))
           ((id . "term:grain") (label . "Grain")))
    (structure ((broader . "term:food") (narrower . "term:grain")))))

(define doc2
  '((terms ((id . "term:food")   (label . "Food"))
           ((id . "term:grain")  (label . "Grain"))
           ((id . "term:millet") (label . "Millet")))
    (structure ((broader . "term:food")  (narrower . "term:grain"))
               ((broader . "term:grain") (narrower . "term:millet")))))

(define doc3
  '((terms ((id . "term:staples") (label . "Staples"))
           ((id . "term:grain")   (label . "Grain")))
    (structure ((broader . "term:staples") (narrower . "term:grain")))))

(display "\n── Build + weighted aggregation ──\n")

(define fk
  (build-folksonomy `(("AID-1" . ,doc1) ("AID-2" . ,doc2) ("AID-3" . ,doc3))))

(check "food→grain asserted by 2"
       (folksonomy-edge-count fk "term:food" "term:grain") 2)
(check "staples→grain asserted by 1 (competing nesting of SAME term)"
       (folksonomy-edge-count fk "term:staples" "term:grain") 1)
(check "grain→millet asserted by 1"
       (folksonomy-edge-count fk "term:grain" "term:millet") 1)

(check "term:grain has TWO parents in the DAG"
       (length (folksonomy-parents fk "term:grain")) 2)
(check "label carried through"
       (folksonomy-term-label fk "term:grain") "Grain")

;;; ── Template = most-asserted parent ─────────────────────────────────────────

(display "\n── Template extraction ──\n")

(define tpl (folksonomy-template fk))
(define food (child-of tpl "Food"))
(define staples (child-of tpl "Staples"))

(check "Food is a root under 'all'" (and food #t) #t)
(check "Staples is also a root (its grain edge lost, but Staples itself roots)"
       (and staples #t) #t)
(check "Grain nests under Food (2 > 1), not Staples"
       (and food (child-of food "Grain") #t) #t)
(check "Grain does NOT appear under Staples in the spanning tree"
       (and staples (child-of staples "Grain")) #f)
(check "winning count rides along: 2 nest Grain under Food"
       (assq-ref (child-of food "Grain") 'count) 2)
(check "Millet nests under Grain"
       (and food (child-of (child-of food "Grain") "Millet") #t) #t)

;;; ── Incremental re-fold of ONE AID (the pool's agent-changed twin) ──────────

(display "\n── Single-AID re-fold ──\n")

;; AID-2 re-publishes, dropping its grain→millet and moving grain under staples.
(define fk2
  (folksonomy-set-aid fk "AID-2"
    '(("term:staples" . "term:grain"))          ; new structure
    '(("term:grain" . "Grain"))))

(check "food→grain drops to 1 (only AID-1 now)"
       (folksonomy-edge-count fk2 "term:food" "term:grain") 1)
(check "staples→grain rises to 2 (AID-3 + AID-2)"
       (folksonomy-edge-count fk2 "term:staples" "term:grain") 2)
(check "grain→millet fully gone (only AID-2 asserted it)"
       (folksonomy-edge-count fk2 "term:grain" "term:millet") 0)

(define tpl2 (folksonomy-template fk2))
(check "after re-fold, Grain moves under Staples (2 > 1)"
       (and (child-of (child-of tpl2 "Staples") "Grain") #t) #t)

;;; ── CF lens: same DAG, different neighbourhood ──────────────────────────────

(display "\n── Lens weighting ──\n")

;; Restrict the weighting to AID-3's neighbourhood: only its assertions count.
(define tpl-lens
  (folksonomy-template fk #:lens (lambda (aid) (equal? aid "AID-3"))))
(check "under AID-3's lens, Grain nests under Staples"
       (and (child-of (child-of tpl-lens "Staples") "Grain") #t) #t)
(check "under AID-3's lens, Food has no Grain child"
       (and (child-of tpl-lens "Food")
            (child-of (child-of tpl-lens "Food") "Grain")) #f)

;;; ── Idempotence: re-asserting the same edge twice by one AID ────────────────

(display "\n── Idempotence ──\n")
(define fk-idem (folksonomy-set-aid fk "AID-1"
                  '(("term:food" . "term:grain") ("term:food" . "term:grain"))
                  '()))
(check "double-assert by one AID does not double-count"
       (folksonomy-edge-count fk-idem "term:food" "term:grain") 2)

;;; ── Adopt closes the loop: template → doc → template is stable ──────────────

(display "\n── template ↔ doc round trip (using is voting) ──\n")

;; Adopt the commune's cut as a personal doc, re-fold it as a lone AID, and the
;; extracted template must match the cut you adopted — the loop is a fixpoint.
(define adopted-doc (template->doc tpl))
(define fk-adopted (build-folksonomy `(("AID-solo" . ,adopted-doc))))
(define tpl-adopted (folksonomy-template fk-adopted))

(check "adopted doc re-extracts the same top-level shape"
       (map (lambda (c) (assq-ref c 'label)) (assq-ref tpl-adopted 'children))
       (map (lambda (c) (assq-ref c 'label)) (assq-ref tpl 'children)))
(check "Grain still nests under Food after adopt round-trip"
       (and (child-of (child-of tpl-adopted "Food") "Grain") #t) #t)
(check "Millet still nests under Grain after adopt round-trip"
       (and (child-of (child-of (child-of tpl-adopted "Food") "Grain") "Millet") #t)
       #t)
(check "adopt emits edges in canonical (broader . narrower) shape"
       (and (pair? (assq 'broader (car (assq-ref adopted-doc 'structure))))
            (pair? (assq 'narrower (car (assq-ref adopted-doc 'structure))))) #t)

;;; ── Seed from legacy slash-paths (the migration bootstrap) ──────────────────

(display "\n── paths->seed-doc: slash-paths → flat terms + edges ──\n")

(define seed (paths->seed-doc '("Food/Grain" "Staples/Grain" "Food/Grain/Sourdough")))
(define fk-seed (build-folksonomy `(("seed:commons" . ,seed))))

(check "Grain is ONE flat term with two parents (Food + Staples)"
       (length (folksonomy-parents fk-seed "Grain")) 2)
(check "Food→Grain edge exists"
       (folksonomy-edge-count fk-seed "Food" "Grain") 1)
(check "Staples→Grain edge exists (competing nesting)"
       (folksonomy-edge-count fk-seed "Staples" "Grain") 1)
(check "Grain→Sourdough deeper edge exists"
       (folksonomy-edge-count fk-seed "Grain" "Sourdough") 1)

(define seed-tpl (folksonomy-template fk-seed))
(check "seed renders: Grain under Food (both root-tied at 1 → alpha), Sourdough under Grain"
       (and (child-of (child-of seed-tpl "Food") "Grain")
            (child-of (child-of (child-of seed-tpl "Food") "Grain") "Sourdough") #t)
       #t)
(check "term-ids are FLAT segments, not path-encoded"
       (and (assoc "Grain" (map (lambda (t) (cons (assq-ref t 'id) #t))
                                (assq-ref seed 'terms))) #t)
       #t)

;;; ── categories->seed-doc filters control-plane tags ─────────────────────────

(display "\n── seed filters the NON_CATEGORY denylist ──\n")

(define dirty-seed
  (categories->seed-doc
   '("Food/Grain" "tag:plan:deficit" "tag:buffer:strategic"
     "vf:allergen-free:peanut" "communal" "isPrimary"
     "vf:allergen:contains-peanut")))
(define fk-dirty (build-folksonomy `(("seed:commons" . ,dirty-seed))))
(check "genuine category (Food/Grain) survives"
       (folksonomy-edge-count fk-dirty "Food" "Grain") 1)
(check "vf:allergen:contains- (a real category) survives"
       (and (member "vf:allergen:contains-peanut"
                    (map (lambda (t) (assq-ref t 'id)) (assq-ref dirty-seed 'terms))) #t)
       #t)
(check "tag:plan:* stripped" (category-term? "tag:plan:deficit") #f)
(check "tag:buffer:* stripped" (category-term? "tag:buffer:strategic") #f)
(check "vf:allergen-free:* stripped" (category-term? "vf:allergen-free:peanut") #f)
(check "communal flag stripped" (category-term? "communal") #f)
(check "no denylisted term leaked into the graph"
       (folksonomy-edge-count fk-dirty "communal" "isPrimary") 0)

;;; ── adjacency indexes stay consistent under churn ───────────────────────────

(display "\n── by-broader/by-narrower indexes track edge create/destroy ──\n")

(define ix (build-folksonomy
            `(("A" . ((terms) (structure ((broader . "food") (narrower . "grain")))))
              ("B" . ((terms) (structure ((broader . "food") (narrower . "grain"))
                                         ((broader . "grain") (narrower . "rice"))))))))
(check "children(food) = grain (index lookup)"
       (map edge-narrower (folksonomy-children ix "food")) '("grain"))
(check "parents(grain) = food (index lookup)"
       (map edge-broader (folksonomy-parents ix "grain")) '("food"))
(check "children(grain) = rice"
       (map edge-narrower (folksonomy-children ix "grain")) '("rice"))

;; B retracts everything → grain→rice edge is DESTROYED, food→grain survives (A)
(define ix2 (folksonomy-drop-aid ix "B"))
(check "after B drops: grain→rice edge destroyed → children(grain) empty"
       (folksonomy-children ix2 "grain") '())
(check "after B drops: food→grain survives (A still asserts) "
       (map edge-narrower (folksonomy-children ix2 "food")) '("grain"))
(check "index has no stale rice entry"
       (folksonomy-parents ix2 "rice") '())

;; A re-publishes with grain moved under staples → food→grain destroyed
(define ix3 (folksonomy-set-aid ix2 "A"
             '(("staples" . "grain")) '()))
(check "food→grain destroyed (no asserter) → children(food) empty"
       (folksonomy-children ix3 "food") '())
(check "staples→grain created → indexed"
       (map edge-broader (folksonomy-parents ix3 "grain")) '("staples"))
(check "template still correct off the indexes (grain under staples)"
       (and (child-of (child-of (folksonomy-template ix3) "staples") "grain") #t) #t)

(display "\n── merge: one AID with two documents, whichever side it is on ──\n")
(let* ((a (build-folksonomy `(("AID-1" . ,doc1))))
       (b (build-folksonomy `(("AID-1" . ,doc2))))
       (c (build-folksonomy `(("AID-1" . ,doc3))))
       (counts (lambda (fk)
                 (map (lambda (e) (folksonomy-edge-count fk (car e) (cdr e)))
                      '(("term:food" . "term:grain") ("term:grain" . "term:millet") ("term:staples" . "term:grain")))))
       (m (lambda (x y) (counts (folksonomy-merge x y)))))
  (check "commutative: the same document stands either way round" (m a b) (m b a))
  (check "and the same for another pair" (m b c) (m c b))
  (check "associative" (counts (folksonomy-merge (folksonomy-merge a b) c))
         (counts (folksonomy-merge a (folksonomy-merge b c))))
  (check "idempotent" (m a a) (counts a))
  (check "one AID's document is asserted once, not once per side" (apply + (m a b)) (apply + (counts (folksonomy-merge b a)))))

(test-summary!)
