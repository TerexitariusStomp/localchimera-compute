;;; test-provenance.scm — tests for (playnet lang provenance)
;;; The prose→computation bridge: claims grounded by executable facts,
;;; with proof traces, over the same miniKanren combinators as system-kb.
;;; Run with:  guile -L module tests/playnet/test-provenance.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (playnet test harness))
(use-modules (playnet lang kanren)
             (playnet lang knowledge)
             (playnet lang provenance)
             (playnet planner doors service provenance-trace)
             (srfi srfi-1))

(display "\n── provenance: direct grounding ──\n")

(check "what-grounds: duress-from-diff is backed by legal-aspects"
       (what-grounds 'duress-from-diff)
       '(legal-aspects))

;; DERIVED, not pinned. This set GROWS — `compliance-is-valueflows` joined it
;; with the legal-compliance lifecycle — so a literal list turns every new
;; grounded claim into a test failure that teaches nobody anything, and the
;; only available repair is to retype the census. What must actually hold is
;; that the two DIRECTIONS AGREE: c comes back from the backward query exactly
;; when legal-aspects is in c's own forward set. That is the relation being
;; tested, it cannot go stale, and it still fails loudly if either direction
;; breaks.
(define (sorted syms) (sort (map symbol->string syms) string<?))
(check "grounds-o backward: what does legal-aspects ground?"
       (sorted (run* (c) (grounds-o c 'legal-aspects)))
       (sorted (filter (lambda (c) (memq 'legal-aspects (what-grounds c))) (all-claims))))

(check "where-defined: legal-aspects resolves to its .scm"
       (where-defined 'legal-aspects)
       "module/playnet/planner/knowledge/law/aspects.scm")

(display "\n── provenance: transitive grounding + proof ──\n")

(check "grounded-by-o: claim transitively rests on reform (via legal-aspects)"
       (not (null? (run* (p) (grounded-by-o 'duress-from-diff 'reform p))))
       #t)

(check "proof-for: the derivation chain is claim → ref → parent-ref"
       (proof-for 'duress-from-diff 'reform)
       '(duress-from-diff legal-aspects reform))

(check "all-grounds: whole computational basis of the claim"
       (sort (map symbol->string (all-grounds 'duress-from-diff)) string<?)
       (sort (map symbol->string '(legal-aspects reform)) string<?))

(check "proof-length of the chain is 2 hops"
       (proof-length (proof-for 'duress-from-diff 'reform))
       2)

(display "\n── provenance: the prose work-list ──\n")

(check "claims-in: legal-crossings.md argues duress-from-diff"
       (claims-in "docs/planning/legal/legal-crossings.md")
       '(duress-from-diff))

(check "ungrounded-claims surfaces the eco ratchet (argued, not yet grounded)"
       (and (memq 'eco-tipping-ratchet (ungrounded-claims)) #t)
       #t)

(check "ungrounded-claims excludes grounded ones"
       (not (memq 'duress-from-diff (ungrounded-claims)))
       #t)

(display "\n── provenance: the realizes hop + free inverse ──\n")

(check "what-realizes: duress-from-diff realizes the plan-review aspect"
       (what-realizes 'duress-from-diff)
       '(plan-review))

(check "claims-realizing: INVERSE — who is implicated by plan-review?"
       (claims-realizing 'plan-review)
       '(duress-from-diff))

;; same reasoning as the backward query above: agreement, not a census
(check "claims-grounding: INVERSE — who rests on legal-aspects?"
       (sorted (claims-grounding 'legal-aspects))
       (sorted (filter (lambda (c) (memq 'legal-aspects (what-grounds c))) (all-claims))))
;; …and the relation is not vacuous — the claim this file was written around is
;; still in it, whatever else has joined since
(check "…and duress-from-diff is still one of them"
       (and (memq 'duress-from-diff (claims-grounding 'legal-aspects)) #t)
       #t)

(check "plan-review is a real realized id"
       (and (memq 'plan-review (realized-ids)) #t)
       #t)

(display "\n── provenance: self-application ──\n")

(check "the bridge grounds its own claims in provenance.scm"
       (sort (map symbol->string (claims-grounding 'provenance)) string<?)
       (sort (map symbol->string '(grounding-is-verified provenance-is-self-hosted)) string<?))

(check "provenance is a defined ref (self-hosted)"
       (and (memq 'provenance (all-refs)) #t)
       #t)

(display "\n── provenance: claim → convex-number trace (injected, decoupled) ──\n")

;; a fake plan + fake recipe lookup — no solver, no coupling
(define fake-plan
  '((labour-pulls)
    (good-pulls ("lg|prod_wheat|world" . 4.25)
                ("lg|prod_steel|world" . 9.0))))

(check "make-pull-of matches a spec id as a substring of the good key"
       ((make-pull-of fake-plan) "wheat")
       4.25)

(check "make-pull-of returns #f for a structural id, which no pull stands on"
       ((make-pull-of fake-plan) "plan-review")
       #f)

(define trace
  (explain-claim 'duress-from-diff fake-plan
                 #:gated-by (lambda (aspect) (list 'recipe-a 'recipe-b))))

(check "explain-claim: grounds carry the whole basis"
       (sort (map symbol->string (assoc-ref trace 'grounds)) string<?)
       (sort (map symbol->string '(legal-aspects reform)) string<?))

(check "explain-claim: proof chain is present"
       (not (null? (assoc-ref trace 'proof)))
       #t)

(check "explain-claim: the realized aspect gates the injected recipes"
       (assoc-ref trace 'gated)
       '((plan-review recipe-a recipe-b)))

(check "explain-claim: a structural (legal) claim carries no number"
       (assoc-ref trace 'numbers)
       '())

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
