;;; test-demand-fold.scm — declared needs → the demand a solve answers for.
;;;
;;; The share face writes a standing `need:AID:SPEC` intent; this is the other
;;; end of that wire. The demand is the SUM over the subtree of the root being
;;; planned, read fresh at planning time — because the root is CONSTITUTED by
;;; the fold (scope.scm resolve-merge-ratifier: two scopes sharing no parent
;;; are ratified by the Universal Commune), never a standing place to deposit
;;; into. So the same needs answer differently under a different tree, with
;;; nothing rewired.

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet plan store) (playnet vf schemas) (srfi srfi-1))
(use-modules (playnet scope live))       ; set-daily-horizon! — periods ↔ days
(use-modules (playnet economy demand-fold))
(use-modules (playnet vf aggregation fold-node))   ; fold-node-reparent!, coalescer
(use-modules (goblins))
(use-modules (goblins utils hashmap))
(use-modules (srfi srfi-1))
(use-modules ((playnet vf facts tension-terms) #:select (with-tension-terms)))
(use-modules ((playnet economy demand-fold) #:select (demand-terms-for name-own-rows)))
(use-modules ((playnet solve engine) #:select (*desire-w0*)))

(define vat (spawn-vat))

;; generic mock actor (as in test-socialization-live)
;; a NEED slot exactly as planner service.scm `declare-need` builds it: an
;; <intent> with receiver = the citizen, id "need:AID:SPEC", goods carrying
;; resource-quantity + action consume, hours effort-quantity + action use.
(define* (need aid spec qty #:key (unit %count-unit) (loc #f) (from #f) (until #f))
  (let ((hours? (member unit '("hour" "hours")))
        (m      (make-measure qty unit)))
    (make-intent
     #:id (string-append "need:" aid ":" spec)
     #:action (if hours? 'use 'consume) #:name spec #:resource-conforms-to spec
     #:resource-quantity (if hours? #f m) #:effort-quantity (if hours? m #f) #:receiver aid
     #:has-beginning from #:has-end until
     #:at-location loc #:in-scope-of '())))

;; a scope whose plan-store holds NEEDS, and whose members are MEMBERS
(define (mk-scope needs members)
  (let* ((ps   (spawn ^mock `((all-intents . ,(lambda () needs)))))
         (root (spawn ^mock `((plan-store . ,(lambda () ps))))))
    (spawn ^mock `((scope-root . ,(lambda () root))
                   (members    . ,(lambda () members))))))

(define (hm . pairs)
  (fold (lambda (p h) (hashmap-set h (car p) (cdr p))) (hashmap) pairs))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. One scope: a declared need becomes demand
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. a declared need is the solve's demand ──\n")

(with-vat vat
  (let* ((s (mk-scope (list (need "EAlice" "bread" 3 #:loc "town")) (hashmap)))
         (d (scope-subtree-demand s '(0))))
    (check-pred "one need ⇒ one demand cell" (= 1 (length d)))
    (check-pred "keyed spec#place@period" (equal? "bread#town@0" (caar d)))
    (check-pred "carries the quantity asked for" (= 3 (cdar d)))))

;; An hours need rides effort-quantity; it is demand for the spec all the same.
(with-vat vat
  (let* ((s (mk-scope (list (need "EAlice" "childcare" 6 #:unit %effort-unit #:loc "town"))
                      (hashmap)))
         (d (scope-subtree-demand s '(0))))
    (check-pred "an hours need is demand too" (equal? '(("childcare#town@0" . 6)) d))))

;; No place named ("anywhere", the share face's default) and no way to resolve
;; one ⇒ it contributes nothing rather than being guessed into a cell.
(with-vat vat
  (let* ((s (mk-scope (list (need "EAlice" "bread" 3)) (hashmap))))
    (check-pred "a placeless need with no home resolver contributes nothing"
                (null? (scope-subtree-demand s '(0))))
    ;; …and follows its person when the caller supplies the trajectory.
    (check-pred "home-of locates it where that person lives"
                (equal? '(("bread#park@0" . 3))
                        (scope-subtree-demand s '(0)
                          #:home-of (lambda (aid) (and (equal? aid "EAlice") "park")))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. The SUM is the aggregation — and the anonymisation
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. many people, one cell: the sum, and no one's name in it ──\n")

(with-vat vat
  (let* ((s (mk-scope (list (need "EAlice" "bread" 3 #:loc "town")
                            (need "EBob"   "bread" 2 #:loc "town")
                            (need "ECaro"  "bread" 5 #:loc "town"))
                      (hashmap)))
         (d (scope-subtree-demand s '(0))))
    (check-pred "three people wanting bread in one place ⇒ ONE cell" (= 1 (length d)))
    (check-pred "the cell is their sum (3+2+5)" (= 10 (cdar d)))
    ;; the receiver's AID does not survive into the key — what crosses a scope
    ;; boundary is how much is wanted where, never who wants it
    (check-pred "no citizen's AID survives the fold"
                (not (string-contains (caar d) "EAlice")))))

;; Same spec, different places stays two cells: bread in the next town over is
;; not this town's bread.
(with-vat vat
  (let* ((s (mk-scope (list (need "EAlice" "bread" 3 #:loc "town")
                            (need "EBob"   "bread" 2 #:loc "hillside"))
                      (hashmap)))
         (d (scope-subtree-demand s '(0))))
    (check-pred "two places ⇒ two cells" (= 2 (length d)))
    (check-pred "each carries its own total"
                (equal? '(3 2) (map cdr d)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. The fold: arbitrarily deep, one visit per scope
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. the subtree fold — every member, at any depth ──\n")

(with-vat vat
  (let* ((leaf-a (mk-scope (list (need "EAlice" "bread" 3 #:loc "town")) (hashmap)))
         (leaf-b (mk-scope (list (need "EBob" "bread" 2 #:loc "town")) (hashmap)))
         (commune (mk-scope (list (need "ECaro" "bread" 1 #:loc "town"))
                            (hm (cons "a" leaf-a) (cons "b" leaf-b))))
         (fed     (mk-scope '() (hm (cons "c" commune)))))
    ;; a leaf answers only for itself
    (check-pred "the leaf's own solve sees only its own need"
                (equal? '(("bread#town@0" . 3)) (scope-subtree-demand leaf-a '(0))))
    ;; the commune answers for itself AND its members
    (check-pred "the commune's solve sums its members' (3+2+1)"
                (equal? '(("bread#town@0" . 6)) (scope-subtree-demand commune '(0))))
    ;; the federation reaches through the commune to the leaves — arbitrarily deep
    (check-pred "the federation reaches members' members"
                (equal? '(("bread#town@0" . 6)) (scope-subtree-demand fed '(0))))))

;; A commune shared by two federations is ONE member, not two — the visited-set
;; keeps a DAG from double-counting, and a cycle from sinking the walk.
(with-vat vat
  (let* ((shared (mk-scope (list (need "EAlice" "bread" 4 #:loc "town")) (hashmap)))
         (fed-a  (mk-scope '() (hm (cons "s" shared))))
         (fed-b  (mk-scope '() (hm (cons "s" shared))))
         (top    (mk-scope '() (hm (cons "a" fed-a) (cons "b" fed-b)))))
    (check-pred "a scope reachable twice is counted once"
                (equal? '(("bread#town@0" . 4)) (scope-subtree-demand top '(0))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Why a PULL: the same needs, a different tree, no rewiring
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. refederation: the answer changes, nothing is rewired ──\n")

;; The root is an outcome of the fold at planning time. A commune that moves
;; from one federation to another is not an event anything has to replay: the
;; next solve simply walks the tree that now exists. A standing aggregate
;; pushed upward would have banked the commune's needs in the federation it
;; left (see ^labour-pool / ^folksonomy — set-parent re-links the pointer, and
;; nothing retracts the departing subtree's contribution from the old parent).
(with-vat vat
  (let* ((commune (mk-scope (list (need "EAlice" "bread" 4 #:loc "town")) (hashmap)))
         (fed-old (mk-scope '() (hm (cons "c" commune))))
         (fed-new (mk-scope '() (hashmap)))
         ;; before: the commune's needs answer under fed-old
         (before-old (scope-subtree-demand fed-old '(0)))
         (before-new (scope-subtree-demand fed-new '(0)))
         ;; refederate: the SAME commune, a different parent. Only membership
         ;; moved; no aggregate was touched.
         (fed-old* (mk-scope '() (hashmap)))
         (fed-new* (mk-scope '() (hm (cons "c" commune))))
         (after-old (scope-subtree-demand fed-old* '(0)))
         (after-new (scope-subtree-demand fed-new* '(0))))
    (check-pred "before: the old parent answers for it"
                (equal? '(("bread#town@0" . 4)) before-old))
    (check-pred "before: the new parent answers for nothing" (null? before-new))
    (check-pred "after: the old parent no longer carries it" (null? after-old))
    (check-pred "after: the new parent answers for it"
                (equal? '(("bread#town@0" . 4)) after-new))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Standing across periods, and bounded within them
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. a standing need is felt in every period; a bounded one is not ──\n")

(with-vat vat
  (let* ((s (mk-scope (list (need "EAlice" "bread" 3 #:loc "town")) (hashmap)))
         (d (scope-subtree-demand s '(0 1 2))))
    (check-pred "an unbounded need is demand in EVERY period — that is what standing means"
                (= 3 (length d)))
    (check-pred "each period carries the full quantity"
                (equal? '("bread#town@0" "bread#town@1" "bread#town@2") (map car d)))))

;; With a horizon laid out, a need's [from, until] confines it to its own days.
(set-daily-horizon! "2026-03-01" 3)      ; periods 0,1,2 = 1, 2, 3 March
(with-vat vat
  (let* ((s (mk-scope (list (need "EAlice" "bread" 3 #:loc "town"
                                  #:from "2026-03-02" #:until "2026-03-02"))
                      (hashmap)))
         (d (scope-subtree-demand s '(0 1 2))))
    (check-pred "a one-day need caps exactly its period" (= 1 (length d)))
    (check-pred "and it is the day it named" (equal? "bread#town@1" (caar d)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. A caller's what-if ADDS to what people asked for
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 6. a scenario rides on the real demand, never instead of it ──\n")

(check-pred "merge sums a scenario onto the same cell"
            (equal? '(("bread#town@0" . 14))
                    (merge-demand '(("bread#town@0" . 10)) '(("bread#town@0" . 4)))))
(check-pred "a scenario's new cell is added, order stable"
            (equal? '(("bread#town@0" . 10) ("cake#town@0" . 2))
                    (merge-demand '(("bread#town@0" . 10)) '(("cake#town@0" . 2)))))
(check-pred "no scenario ⇒ the tree's demand, untouched"
            (equal? '(("bread#town@0" . 10))
                    (merge-demand '(("bread#town@0" . 10)) '())))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. The push: the same fold, evaluated incrementally
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 7. a ^demand-node holds what the walk would have found ──\n")

;; The standing cell is (spec, place, window) — never a period, because the
;; horizon is laid out per solve. `demand-for` is where a period is decided.
(with-vat vat
  (let* ((leaf-root (spawn ^mock `((plan-store . ,(lambda ()
                      (spawn ^mock `((all-intents . ,(lambda ()
                        (list (need "EAlice" "bread" 3 #:loc "town")))))))))))
         (own  (scope-own-demand leaf-root))
         (leaf (spawn ^demand-node own '()))
         (fed  (spawn ^demand-node '() '())))
    (check-pred "the standing cell carries no period"
                (not (string-contains (caar ($ leaf 'cells)) "@")))
    ($ leaf 'set-parent fed "leaf")
    ($ fed 'child-changed "leaf" ($ leaf 'fold-total))
    (check-pred "the parent answers for the member's need"
                (equal? '(("bread#town@0" . 3)) ($ fed 'demand-for '(0))))
    ;; the SAME standing total answers a different horizon differently
    (check-pred "and projects onto whatever periods the solve laid out"
                (equal? 3 (length ($ fed 'demand-for '(0 1 2)))))
    ;; a refederation is a drop and a delivery — nothing left behind
    (let ((fed2 (spawn ^demand-node '() '())))
      (fold-node-reparent! leaf "leaf" #:from fed #:to fed2)
      (check-pred "the old parent no longer answers for it" (null? ($ fed 'demand-for '(0))))
      (check-pred "the new parent does"
                  (equal? '(("bread#town@0" . 3)) ($ fed2 'demand-for '(0)))))))

;; push == pull, on the same tree: the node's total and the walk agree, which is
;; what lets `demand-of` take either end without a solve knowing which.
(with-vat vat
  (let* ((leaf   (mk-scope (list (need "EAlice" "bread" 3 #:loc "town")) (hashmap)))
         (commune (mk-scope (list (need "EBob" "bread" 2 #:loc "town"))
                            (hm (cons "leaf" leaf))))
         (pulled (scope-subtree-demand commune '(0)))
         ;; the same values, delivered link by link
         (n-leaf (spawn ^demand-node (scope-own-demand ($ leaf 'scope-root)) '()))
         (n-comm (spawn ^demand-node (scope-own-demand ($ commune 'scope-root)) '())))
    ($ n-leaf 'set-parent n-comm "leaf")
    ($ n-comm 'child-changed "leaf" ($ n-leaf 'fold-total))
    (check-pred "the walk totals 3+2" (equal? '(("bread#town@0" . 5)) pulled))
    (check-pred "the push arrives at the same demand"
                (equal? pulled ($ n-comm 'demand-for '(0))))
    (check-pred "demand-of reads a node"
                (equal? pulled (demand-of n-comm '(0))))
    (check-pred "demand-of walks a scope"
                (equal? pulled (demand-of commune '(0))))))




;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. The live wire: declare moves the fold, retire moves it back
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 8. declare → the fold hears it; retire → the fold forgets it ──\n")

;; A REAL ^plan-store, driving itself: the node applies the store's change
;; events, so nothing here pokes the fold by hand. Applying rather than
;; re-reading is also what makes this correct synchronously — the event fires
;; from inside the write, before the store commits, and carries everything the
;; cell needs without looking at the store at all.
(with-vat vat
  (let* ((ps   (spawn ^plan-store (empty-plan-store-state) '()))
         (root (spawn ^mock `((plan-store . ,(lambda () ps)))))
         (node (spawn ^demand-node '() '()))
         (fed  (spawn ^demand-node '() '())))
    (wire-demand-node! root node #:parent fed #:scope-id "commune")
    (check-pred "an empty scope contributes nothing" (null? ($ fed 'demand-for '(0))))

    ($ ps 'add-intent (need "EAlice" "bread" 3 #:loc "town"))       ; declare-need
    (check-pred "a declared need reaches the federation"
                (equal? '(("bread#town@0" . 3)) ($ fed 'demand-for '(0))))

    ($ ps 'add-intent (need "EBob" "bread" 2 #:loc "town"))
    (check-pred "a second declaration sums into the same cell"
                (equal? '(("bread#town@0" . 5)) ($ fed 'demand-for '(0))))

    ($ ps 'remove-intent "need:EAlice:bread")                       ; retire-need
    (check-pred "a retired need stops being demanded"
                (equal? '(("bread#town@0" . 2)) ($ fed 'demand-for '(0))))

    ;; editing IS re-declaring: remove then add, so the old cell empties and the
    ;; new one fills, with nothing stranded at the old key
    ($ ps 'remove-intent "need:EBob:bread")
    ($ ps 'add-intent (need "EBob" "bread" 2 #:loc "hillside"))
    (check-pred "moving a need moves its cell, leaving nothing behind"
                (equal? '(("bread#hillside@0" . 2)) ($ fed 'demand-for '(0))))

    ;; …and the last withdrawal leaves no empty cell occupying a key
    ($ ps 'remove-intent "need:EBob:bread")
    (check-pred "the last withdrawal empties the fold entirely"
                (null? ($ fed 'demand-for '(0))))

    ;; an intent that is not a declared need is not demand
    ($ ps 'add-intent (make-intent #:id "mi|EBob|skill:cook|town@0" #:action 'work #:resource-conforms-to "skill:cook"
                                   #:effort-quantity (make-measure 4 %effort-unit) #:receiver "EBob" #:at-location "town" #:in-scope-of '()))
    (check-pred "a work intent is not a declared need"
                (null? ($ fed 'demand-for '(0))))))

;; APPLY == RE-READ. The same property the tree has, one level down: the
;; incremental path and the full re-read are the same value, which is why the
;; re-read stays available as a repair.
(with-vat vat
  (let* ((ps   (spawn ^plan-store (empty-plan-store-state) '()))
         (root (spawn ^mock `((plan-store . ,(lambda () ps)))))
         (node (spawn ^demand-node '() '())))
    (wire-demand-node! root node)
    (for-each (lambda (i) ($ ps 'add-intent (need (string-append "E" (number->string i))
                                                  "bread" i #:loc "town")))
              '(1 2 3))
    ($ ps 'remove-intent "need:E2:bread")
    (let ((applied ($ node 'fold-total)))
      ($ node 'needs-changed root #f)                    ; the definition, re-read
      (check-pred "applying every change lands where re-reading does"
                  (equal? applied ($ node 'fold-total))))))

;; …and coalesced: a burst of declarations costs ONE climb to the federation.
(with-vat vat
  (call-with-values make-fold-coalescer
    (lambda (schedule drain!)
      (let* ((ps    (spawn ^plan-store (empty-plan-store-state) '()))
             (root  (spawn ^mock `((plan-store . ,(lambda () ps)))))
             (node  (spawn ^demand-node '() '()))
             (fed   (spawn ^demand-node '() '()))
             (climbs 0))
        ($ fed 'set-on-update (lambda (_) (set! climbs (+ climbs 1))))
        (wire-demand-node! root node #:parent fed #:scope-id "commune" #:schedule schedule)
        (set! climbs 0)
        (for-each (lambda (who) ($ ps 'add-intent (need who "bread" 1 #:loc "town")))
                  '("E1" "E2" "E3" "E4" "E5"))
        (check "five declarations park, none climbs" climbs 0)
        (drain!)
        (check "one climb settles them all" climbs 1)
        (check-pred "and the federation has all five"
                    (equal? '(("bread#town@0" . 5)) ($ fed 'demand-for '(0))))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 9. One channel, many readers
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 9. a store has several readers of change, and silences none ──\n")

;; The reason the intent channel fans out rather than shadows: the moment a
;; demand node wires onto a scope, that store ALREADY has a listener — the
;; credential minter, and the observer's mirror. A second registration that
;; silenced the first would be a silent, total failure of whichever lost.
(with-vat vat
  (let* ((ps (spawn ^plan-store (empty-plan-store-state) '()))
         (root (spawn ^mock `((plan-store . ,(lambda () ps)))))
         (node (spawn ^demand-node '() '()))
         (minted '()) (changes '()))
    ;; an existing single-record listener (what observation/credentials / scope-root bind)
    ($ ps 'set-on-intent (lambda (i) (set! minted (cons (intent-id i) minted))))
    ;; a second, folding listener on the same store
    ($ ps 'add-intent-listener (lambda (i a) (set! changes (cons a changes))))
    (wire-demand-node! root node)                      ; …and a third

    ($ ps 'add-intent (need "EAlice" "bread" 3 #:loc "town"))
    (check "the arrival reached the minter" (length minted) 1)
    (check "…and the folding listener" (length changes) 1)
    (check-pred "…and the demand node"
                (equal? '(("bread#town@0" . 3)) ($ node 'demand-for '(0))))

    ($ ps 'remove-intent "need:EAlice:bread")
    ;; `set-on-intent` means "an intent came into being" — a withdrawal is not
    ;; one, so the minter must NOT hear it (it would mint from a retirement)
    (check "a withdrawal does not reach an arrivals-only listener" (length minted) 1)
    (check "…but does reach the channel" (length changes) 2)
    (check-pred "…and empties the fold" (null? ($ node 'demand-for '(0))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 10. Arcs → the HORIZON itself, not only the quantities on it
;;; ════════════════════════════════════════════════════════════════════════════
;;;
;;; demand-for needs periods to project a standing cell onto; deciding how MANY
;;; periods a horizon needs is the other half — demand-scope-horizon, read off
;;; the SAME standing cells before any period exists, via each need's own real
;;; ISO dates rather than a period number decided by a solve that has not run.

(display "\n── 10. a need's own dates decide how far a horizon must reach ──\n")

(with-vat vat
  (let ((s (mk-scope '() (hashmap))))
    ;; nothing declared still lays ONE dated day (cells->horizon): a schedule
    ;; row emitted from an unlaid period carries the empty `when` no calendar
    ;; can place, so the empty scope answers (today . 1) exactly as a standing
    ;; need does — a horizon of one day, never a horizon of no days
    (check-pred "no standing needs ⇒ one DATED day, no widening"
                (equal? (cons "2026-04-01" 1)
                        (demand-scope-horizon s #:today "2026-04-01")))))

(with-vat vat
  (let ((s (mk-scope (list (need "EAlice" "bread" 3 #:loc "town")) (hashmap))))
    (check-pred "an UNBOUNDED need has no date of its own to WIDEN a horizon by —\n                but it still asks for its one period DATED (today . 1), so every\n                schedule row the solve emits lands on a calendar day"
                (equal? (cons "2026-04-01" 1)
                        (demand-scope-horizon s #:today "2026-04-01")))))

(with-vat vat
  (let ((s (mk-scope (list (need "EAlice" "bread" 3 #:loc "town" #:until "2026-04-03")) (hashmap))))
    (check-pred "a need ending 2 days out asks for a 3-day horizon (today + 2)"
                (equal? (cons "2026-04-01" 3) (demand-scope-horizon s #:today "2026-04-01")))))

(with-vat vat
  (let ((s (mk-scope (list (need "EAlice" "bread" 3 #:loc "town" #:from "2026-04-05"))
                     (hashmap))))
    (check-pred "a need starting LATER also widens the horizon — it must be reached, not just ended"
                (equal? (cons "2026-04-01" 5) (demand-scope-horizon s #:today "2026-04-01")))))

(with-vat vat
  (let ((s (mk-scope (list (need "EAlice" "bread" 3 #:loc "town" #:until "2026-04-02")
                           (need "EBob"   "milk"  1 #:loc "town" #:until "2026-04-06"))
                     (hashmap))))
    (check-pred "the FURTHEST bounded need across every citizen wins"
                (equal? (cons "2026-04-01" 6) (demand-scope-horizon s #:today "2026-04-01")))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 12. Emphasis folds as social desire — the spec's law (solve/emphasis.scm)
;;; ════════════════════════════════════════════════════════════════════════════
;;; playnet.typ §Desire as harmony: w_d = Σ_p v_p · x̂_p(d). A citizen's
;;; attachments are their simplex, scaled by their voice; a cell's weight is
;;; the sum over citizens; a want nobody weighted takes the aggregate's mean.

(display "\n── 12. emphasis folds as social desire ──\n")

(define* (need/voice aid spec qty voice #:key (loc "town"))
  (let ((i (need aid spec qty #:loc loc)))
    (make-intent #:id (intent-id i) #:action 'consume #:name spec #:resource-conforms-to spec #:resource-classified-as (with-tension-terms '() "des" voice)
                 #:resource-quantity (intent-resource-quantity i) #:receiver aid #:at-location loc #:in-scope-of '())))
(define (~= a b) (< (abs (- a b)) 1e-6))

(with-vat vat
  (let* ((s (mk-scope (list (need/voice "EAda" "bread" 1 464) (need/voice "EAda" "milk" 1 5)
                            (need/voice "EBen" "bread" 1 10)  (need/voice "EBen" "milk" 1 10)
                            (need "ECara" "eggs" 2 #:loc "town"))
                      (hashmap)))
         (terms (demand-terms-for (demand-cells-of s) '(0)))
         (w (assq-ref terms 'desire-weights))
         (W *desire-w0*))
    (check-pred "a cell's weight is the citizens' shares × voice, summed"
                (~= (assoc-ref w "bread#town@0") (+ (* W (/ 464.0 469.0)) (* W 0.5))))
    (check-pred "…every citizen's hand sums to one whole emphasis"
                (~= (+ (assoc-ref w "bread#town@0") (assoc-ref w "milk#town@0")) (* 2 W)))
    (check-pred "a want nobody weighted takes the aggregate's mean"
                (~= (assoc-ref w "eggs#town@0")
                    (/ (+ (assoc-ref w "bread#town@0") (assoc-ref w "milk#town@0")) 2)))))

;; voice scales the whole hand: an equal citizen and a citizen heard twice
(with-vat vat
  (let* ((s (mk-scope (list (need/voice "EAda" "bread" 1 1) (need/voice "EBen" "bread" 1 1)) (hashmap)))
         (voice-of (lambda (aid) (if (equal? aid "EAda") 2.0 1.0)))
         (w (assq-ref (demand-terms-for (demand-cells-of s #:voice-of voice-of) '(0)) 'desire-weights)))
    (check-pred "consumer voice scales a citizen's whole hand"
                (~= (assoc-ref w "bread#town@0") (* 3 *desire-w0*)))))

;; the incremental path re-normalises the one hand that changed
(with-vat vat
  (let* ((ps   (spawn ^plan-store (empty-plan-store-state) '()))
         (root (spawn ^mock `((plan-store . ,(lambda () ps)))))
         (node (spawn ^demand-node '() '())))
    (wire-demand-node! root node)
    ($ ps 'add-intent (need/voice "EAda" "bread" 1 100))
    ($ ps 'add-intent (need/voice "EAda" "milk" 1 100))     ; Ada's hand splits in two
    (let ((w (assq-ref (demand-terms-for ($ node 'fold-total) '(0)) 'desire-weights)))
      (check-pred "a second row halves the first's share"
                  (~= (assoc-ref w "bread#town@0") (* 0.5 *desire-w0*))))
    ($ ps 'remove-intent "need:EAda:milk")
    (let ((w (assq-ref (demand-terms-for ($ node 'fold-total) '(0)) 'desire-weights)))
      (check-pred "…and removing it gives the whole hand back"
                  (~= (assoc-ref w "bread#town@0") *desire-w0*)))))

;; A right takes no voice and enters no hand (family.scm's rule, demand-fold
;; %need-cells): a floor beside a person's wants is a wall read from its
;; quantity cell, and it leaves the shares of the wants exactly where they were.
(define* (need/floor aid spec qty #:key (loc "town"))
  (let ((i (need aid spec qty #:loc loc)))
    (make-intent #:id (intent-id i) #:action 'consume #:name spec #:resource-conforms-to spec #:resource-classified-as '("tension:floor")
                 #:resource-quantity (intent-resource-quantity i) #:receiver aid #:at-location loc #:in-scope-of '())))
(with-vat vat
  (let* ((wants (list (need/voice "EAda" "bread" 1 464) (need/voice "EAda" "milk" 1 5)))
         (w0 (assq-ref (demand-terms-for (demand-cells-of (mk-scope wants (hashmap))) '(0)) 'desire-weights))
         (t1 (demand-terms-for (demand-cells-of (mk-scope (cons (need/floor "EAda" "rice" 10) wants) (hashmap))) '(0)))
         (w1 (assq-ref t1 'desire-weights)))
    (check-pred "a floor beside the wants leaves every want's weight where it was"
                (and (~= (assoc-ref w0 "bread#town@0") (assoc-ref w1 "bread#town@0"))
                     (~= (assoc-ref w0 "milk#town@0") (assoc-ref w1 "milk#town@0"))))
    (check-pred "…and stands as a floor on its own quantity"
                (equal? '(("rice#town@0" . 10)) (assq-ref t1 'repro-floors)))))

(display "\n── 13. the scope's own rows, named: a want on the citizen's own good ──\n")
;; name-own-rows keys THIS scope's want rows per citizen ("spec~aid") for its
;; own solve; the climb (the node's cells) never carries a name; rights stay
;; aggregate; quantities and masses are conserved under the naming.
(with-vat vat
  (let* ((s (mk-scope (list (need/voice "EAda" "bread" 2 10) (need/voice "EBen" "bread" 3 10)
                            (need/voice "EAda" "milk" 1 10))
                      (hashmap)))
         (cells (demand-cells-of s))
         (named (name-own-rows cells ($ s (quote scope-root))))
         (q  (lambda (cs k) (or (assoc-ref cs k) 0)))
         (key (lambda (spec) (string-append spec "\ttown\t\t\tdes")))
         (twin (lambda (k) (string-append k "\tw"))))
    (check "the climb carries no citizen: no cell of the node's total names one"
           (not (any (lambda (c) (string-index (car c) #\~)) cells)) #t)
    (check "named: ada's and ben's bread are two rows on their own goods"
           (list (q named (key "bread~EAda")) (q named (key "bread~EBen"))) '(2 3))
    (check "named: the scope's summed bread cell is gone"
           (q named (key "bread")) 0)
    (check "quantity is conserved under the naming"
           (= (+ (q named (key "bread~EAda")) (q named (key "bread~EBen"))) (q cells (key "bread"))) #t)
    (check "each named twin is exactly that citizen's mass, and the two sum to the cell's"
           (let ((a (q named (twin (key "bread~EAda")))) (b (q named (twin (key "bread~EBen")))))
             (and (> a 0) (> b 0) (< (abs (- (+ a b) (q cells (twin (key "bread"))))) 1e-9))) #t)
    (let ((terms (demand-terms-for named '(0))))
      (check "the terms hand the solve a want per citizen on their own good"
             (sort (map car (assq-ref terms 'demand)) string<?)
             '("bread~EAda#town@0" "bread~EBen#town@0" "milk~EAda#town@0")))))

(test-summary!)
