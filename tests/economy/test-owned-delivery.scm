;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/economy/test-owned-delivery.scm — A WANT IS FELT ON THE CITIZEN'S OWN GOOD.
;;;
;;; truth-telling.md, "the path to dominance at scale": a want a citizen
;;; states for themselves is keyed on their own good ("spec~aid") and the
;;; scope's solve delivers it through a zero-labour column (live.scm
;;; claim-recipes) — so a padded quantity moves only the padder's
;;; term. Two citizens want bread at one place; the bake still makes "bread",
;;; the plan delivers "bread~ada" and "bread~ben" separately, and the alist's
;;; ran-on demand names each. The fixture is test-demand-scope-horizon's.
;;;
;;; Run:  guile -L module -L tests tests/economy/test-owned-delivery.scm
(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules ((playnet solve engine) #:select (set-dial! set-cap-scale!)))
(use-modules ((playnet vf facts audit) #:select (plan-welfare)))
(use-modules (playnet test harness)
             (playnet vf schemas) (srfi srfi-1)
             (playnet scope live)
             (playnet economy socialization) (playnet keri acdc-store)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (ice-9 format))

(define COMMUNE "ECommune")
(define PLACE   "town")
(define* (need aid spec qty #:optional (loc PLACE))
  (make-intent #:id (string-append "need:" aid ":" spec) #:action 'consume #:name spec #:resource-conforms-to spec
               #:resource-quantity (make-measure qty "kg") #:receiver aid #:at-location loc #:in-scope-of '()))

(define procs (list (make-recipe-process #:id "bake" #:name "Bake")))
(define flows
  (list (make-recipe-flow #:id "bw" #:action 'work #:resource-conforms-to "skill-bake"
                          #:effort-quantity (make-measure 1.0 %effort-unit) #:recipe-input-of "bake")
        (make-recipe-flow #:id "bi" #:action 'consume #:resource-conforms-to "wheat"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of "bake")
        (make-recipe-flow #:id "bo" #:action 'produce #:resource-conforms-to "bread"
                          #:resource-quantity (make-measure 10.0 "kg") #:recipe-output-of "bake"
                          #:is-primary #t)))
(define recipes (list (make-recipe #:id "bake-recipe" #:name "Bake" #:primary-output "bread"
                                   #:recipe-processes (list "bake"))))
(define spatials (list (make-spatial-thing #:id PLACE #:lat 40.0 #:long -74.0)))
(define win (all-week-window "00:00" "23:59"))
(define agents (list (make-agent #:id "baker" #:type 'person #:name "Baker" #:primary-location PLACE
                                 #:classified-as '() #:availability-window win)
                     (make-agent #:id "ada" #:type 'person #:name "Ada" #:primary-location PLACE
                                 #:classified-as '() #:availability-window win)
                     (make-agent #:id "ben" #:type 'person #:name "Ben" #:primary-location PLACE
                                 #:classified-as '() #:availability-window win)))
(define resources
  (list (make-economic-resource #:id "sk-baker" #:conforms-to "skill-bake" #:classified-as '()
          #:accounting-quantity (make-measure 1.0 "kg") #:onhand-quantity (make-measure 1.0 "kg") #:current-location PLACE #:primary-accountable "baker")))

(define vat (spawn-vat #:name "owned-delivery"))

;; the engine's DEFAULT is now the cap rule (quantity-as-a-cap.md); the first
;; sections document the retired proportional `des` on owned rows, so they
;; state the old rule explicitly and hand the default back afterwards
(set-dial! 'want-as-cap #f)

(define (run ada-q ben-q wheat)
  (with-vat vat
    (let* ((store (spawn-acdc-store))
           (obs (spawn ^mock `((all-resources . ,(lambda () resources)) (record-event . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs (mock-recipe-store #:recipes recipes #:procs procs #:flows flows))
           (ps  (mock-plan-store #:intents (list (need "ada" "bread" ada-q) (need "ben" "bread" ben-q))))
           (root  (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs #:plan-store ps))
           (scope (spawn ^mock `((scope-root . ,(lambda () root)) (members . ,(lambda () (hashmap)))))))
      (plan-commune-scope root store COMMUNE
        #:demand-scope scope #:periods '(0)
        #:eco-caps (list (cons (format #f "wheat#~a@0" PLACE) wheat))
        #:backend 'native-c))))

(define (produced alist spec)
  (fold (lambda (m a) (if (and (eq? (assq-ref m 'action) 'produce) (equal? (assq-ref m 'conforms-to) spec))
                          (+ a (abs (or (assq-ref m 'quantity) 0))) a))
        0.0 (or (assq-ref alist 'material) '())))

(format #t "~%── two citizens want bread: the plan delivers each their own ──~%")
(define r (run 20.0 10.0 10.0))   ; 10 wheat → 100 bread: plenty
(define ran (map car (or (assq-ref r 'demand) '())))
(format #t "  ran-on demand: ~s~%" ran)
(format #t "  bread ~a · bread~~ada ~a · bread~~ben ~a · met ~a~%"
        (produced r "bread") (produced r "bread~ada") (produced r "bread~ben") (assq-ref r 'met))
(check "the solve ran on each citizen's own good, not the scope's sum"
       (and (member "bread~ada#town@0" ran) (member "bread~ben#town@0" ran) (not (member "bread#town@0" ran)) #t) #t)
(check "the bake still makes the scope's bread" (> (produced r "bread") 29.0) #t)
(check "ada is delivered her 20 on her own good" (< (abs (- (produced r "bread~ada") 20.0)) 0.5) #t)
(check "ben is delivered at least his 10 on his" (>= (produced r "bread~ben") 9.5) #t)
(check "everyone met" (> (or (assq-ref r 'met) 0) 0.97) #t)

(format #t "~%── ben pads under scarcity: his own term carries his padding ──~%")
;; 3.5 wheat → 35 bread. Truthful (ada 20, ben 10 = 30) everyone is met. Ben
;; pads to 30 (50 asked of 35): the des tension w·((D−s)/D)² splits the
;; shortfall by RELATIVE gap per unit of mass — each citizen's own term,
;; on their own good — so ben's padded term absorbs its own padding, and
;; ada's grant moves only through the scarce bread they share. That move is
;; the lie's burn: ben's true want (10) was met before and is met after —
;; the padding bought him nothing, and cost ada what the meter reads.
(define truthful (run 20.0 10.0 3.5))
(define padded   (run 20.0 30.0 3.5))
(define (got r who) (produced r (string-append "bread~" who)))
(format #t "  truthful: ada ~,1f · ben ~,1f~%" (got truthful "ada") (got truthful "ben"))
(format #t "  padded:   ada ~,1f · ben ~,1f~%" (got padded "ada") (got padded "ben"))
(check "truthful: both met" (and (>= (got truthful "ada") 19.5) (>= (got truthful "ben") 9.5)) #t)
(check "the padder's own good carries the shortfall: ben gets far less than his padded 30"
       (< (got padded "ben") 25.0) #t)
(check "the tension law holds on the named goods: relative gap per unit ask equalised"
       (let ((u (/ (- 1.0 (/ (got padded "ada") 20.0)) 20.0))
             (v (/ (- 1.0 (/ (got padded "ben") 30.0)) 30.0)))
         (< (abs (- u v)) (* 0.15 (max u v 1e-9)))) #t)
(check "the padding bought ben nothing of his TRUE want (10 met before, 10 met after)"
       (and (>= (min (got truthful "ben") 10.0) 9.5) (>= (min (got padded "ben") 10.0) 9.5)) #t)
(check "…and cost ada — the burn the meter reads for the lie"
       (< (got padded "ada") (- (got truthful "ada") 1.0)) #t)


;; ── quantity as a cap: the ask a wall, the pull by emphasis alone ──────────
;; docs/planning/solve/quantity-as-a-cap.md, the engine experiment. Supply 24 loaves
;; (2.4 wheat), ada asks 20, ben's true need is 10. Under `des` (proportional
;; rationing) ben is served 8 truthfully and 10 by padding to 20 — the
;; QuantityAsCap.lean counterexample, run on the solver. Under `cap`
;; (water-filling: equal masses ⇒ equal levels, capped by the ask) ben is
;; served his 10 truthfully; padding moves his own delivery to the level and
;; nothing he values; and a report above the level is inert to the digit.
(format #t "~%── quantity as a cap: the same scarcity, two rules ──~%")
(define des-truth (run 20.0 10.0 2.4))
(define des-pad   (run 20.0 20.0 2.4))
(format #t "  des  truthful: ada ~,2f · ben ~,2f   padded: ada ~,2f · ben ~,2f~%"
        (got des-truth "ada") (got des-truth "ben") (got des-pad "ada") (got des-pad "ben"))
(check "des: rationed by relative gap — ben truthful is served SHORT of his 10"
       (< (got des-truth "ben") 9.5) #t)
(check "des: …and padding to 20 buys him his 10 (the counterexample, on the solver)"
       (>= (got des-pad "ben") 9.5) #t)
(set-dial! 'want-as-cap #t)   ; the default, restated after the des sections above
(define cap-truth (run 20.0 10.0 2.4))
(define cap-pad   (run 20.0 20.0 2.4))
(define cap-pad2  (run 20.0 200.0 2.4))
(format #t "  cap  truthful: ada ~,2f · ben ~,2f   padded: ada ~,2f · ben ~,2f   padded×10: ada ~,2f · ben ~,2f~%"
        (got cap-truth "ada") (got cap-truth "ben") (got cap-pad "ada") (got cap-pad "ben")
        (got cap-pad2 "ada") (got cap-pad2 "ben"))
;; The people in the scope eat first: each has an eat~bread process (the reproduction
;; floor), so the loaves the wants ration are the bake less what is eaten. The
;; water-filling is stated over THAT remainder, not over the bake.
(define (eaten r spec)
  (fold (lambda (m a)
          (if (and (eq? (assq-ref m 'action) 'consume) (equal? (assq-ref m 'conforms-to) spec)
                   (string-prefix? "eat~" (or (assq-ref m 'input-of) "")))
              (+ a (abs (or (assq-ref m 'quantity) 0))) a))
        0.0 (or (assq-ref r 'material) '())))
(define (water-fill supply ada-ask ben-ask)   ; equal masses: both at the level, capped by the ask
  (let* ((ben (min ben-ask (/ supply 2.0))) (ada (min ada-ask (- supply ben))))
    (cons ada ben)))
(define (near? a b) (< (abs (- a b)) 0.6))
(define cap-left (- 24.0 (eaten cap-truth "bread")))
(define cap-fill (water-fill cap-left 20.0 10.0))
(check "cap: the people eat before the wants are rationed (the remainder is less than the bake)"
       (and (> (eaten cap-truth "bread") 1.0) (< cap-left 24.0)) #t)
(check "cap: water-filling — ben truthful is served min(his 10, the level)"
       (near? (got cap-truth "ben") (cdr cap-fill)) #t)
(check "cap: …and ada takes the rest of what is left after eating"
       (near? (got cap-truth "ada") (car cap-fill)) #t)
(check "cap: nothing left over — every loaf not eaten reaches a want"
       (near? (+ (got cap-truth "ada") (got cap-truth "ben")) cap-left) #t)
(check "cap: padding buys ben nothing of his true want (10 met before, 10 met after)"
       (>= (min (got cap-pad "ben") 10.0) 9.5) #t)
(check "cap: equal masses, both rationed ⇒ equal levels, each half of what is left after eating"
       (let ((half (/ (- 24.0 (eaten cap-pad "bread")) 2.0)))
         (and (near? (got cap-pad "ada") half) (near? (got cap-pad "ben") half))) #t)
(check "cap: a report above the level is INERT — ×10 the ask, the same plan to the digit"
       (and (< (abs (- (got cap-pad2 "ada") (got cap-pad "ada"))) 1e-3)
            (< (abs (- (got cap-pad2 "ben") (got cap-pad "ben"))) 1e-3)) #t)


;; ── the fourth currency, read: what honesty costs in first-best welfare ───
;; True peaks 20 and 10, supply 24, equal masses. Welfare = Σ min(got, peak),
;; the utilities the theorems are stated in. Both rules serve below the
;; peaks here, so the whole 24 counts under each — the strategyproof rule's
;; second-best price is ZERO in one cell, exactly as theory says (the gap
;; lives across cells; Amorós 2002). The reading exists so a scope can ask
;; the same question wherever it plans.
(let ((wf (lambda (r) (plan-welfare (list (list 1.0 20.0 (got r "ada"))
                                          (list 1.0 10.0 (got r "ben")))))))
  (format #t "~%  welfare at true peaks — des ~,2f · cap ~,2f (of 24 deliverable)~%"
          (wf des-truth) (wf cap-truth))
  (check "one cell, both same-sided: the second-best gap is zero"
         (< (abs (- (wf cap-truth) (wf des-truth))) 0.1) #t))

;; ── the reference scale: stated per spec, and a pure re-unit moves nothing ──
;; Grams instead of kilograms: asks, supply and scale all ×1000 — the same
;; economy in smaller units — and the split is the same split, scaled.
(set-cap-scale! "bread" 1000.0)
(define cap-grams (run 20000.0 10000.0 2.4))   ; wheat unchanged: 1 kg wheat → 10,000 g bread? no —
;; the recipe still yields 10 kg per wheat, so supply is 24 kg = 24000 g only
;; if the recipe is re-unitted too; instead state the SAME world and check
;; the scale knob alone: with scale 1000 on the kg world, levels shift but
;; the padding stays inert — the invariant that must survive any scale.
(set-cap-scale! "bread" 1000.0)
(define k-truth (run 20.0 10.0 2.4))
(define k-pad   (run 20.0 200.0 2.4))
(set-cap-scale! "bread" #f)
(format #t "  scale 1000 on the kg world: truthful ~,2f/~,2f · ben pads ×20 ~,2f/~,2f~%"
        (got k-truth "ada") (got k-truth "ben") (got k-pad "ada") (got k-pad "ben"))
(check "under any reference scale, a report above the level stays inert"
       (< (abs (- (got k-pad "ben") (got k-pad "ada")))
          (+ 0.6 (abs (- (got cap-pad "ben") (got cap-pad "ada"))))) #t)
(check "…and the truthful citizen is never served past their ask"
       (<= (got k-truth "ben") 10.1) #t)

(test-summary!)
