;;; provenance.scm — playnet's knowledge of what grounds its claims.
;;; @defines provenance
;;;
;;; The bridge between prose and computation. `system-kb.scm` knows the shape
;;; of the system; this knows which *claims* (argued in docs) are backed by which
;;; *executable refs* (knowledge/*.scm), and — one level finer — which concrete
;;; planner *id* a claim realizes (a spec/aspect the convex model is built from).
;;; Because grounding is an edge relation, `transitive-o` derives the whole chain
;;; with a proof trace, exactly like `trigger-chain-o`. No new engine: provenance
;;; is just more facts, queried by the same combinators — in BOTH directions.
;;;
;;; The knowledge spectrum, left→right as an idea hardens:
;;;   prose → claim id → knowledge ref → the facts it builds on → a planner id
;;; A claim with no `grounds` edge is still *only argued* — see `ungrounded-claims`.
;;;
;;; Facts are regenerated from greppable tags by docs/_scripts/extract-provenance.scm
;;; and verified by docs/_scripts/check-provenance.scm. Tags (examples angle-bracketed
;;; so this file can ground its OWN claims without the extractor eating them):
;;;   md:  <!-- @claim <ID> grounds: <REF> ... -->     REF may be REF#PLANNER-ID
;;;   scm: ;; @defines <REF>       ;; @builds <REF> <PARENT>
;;; See docs/planning/provenance-bridge.md.
;;;
;;; Usage:
;;;   (use-modules (playnet lang provenance) (playnet lang kanren))
;;;   (what-grounds 'duress-from-diff)          ; forward: refs backing a claim
;;;   (proof-for 'duress-from-diff 'reform)     ; the derivation chain
;;;   (claims-realizing 'plan-review)           ; INVERSE: claims touching a planner id
;;;   (ungrounded-claims)                       ; claims still only argued in prose
;;;
;;; Hoot/WASM compatible (only in-list-o, transitive-o, run*, srfi-1 sets).

(define-module (playnet lang provenance)
  #:use-module (playnet lang kanren)
  #:use-module (playnet lang knowledge)
  #:use-module (srfi srfi-1)
  #:export (*provenance-facts*
            ;; Relations (all run in either direction)
            grounds-o builds-o defines-o argues-o realizes-o
            backs-o grounded-by-o
            ;; Forward queries
            what-grounds all-grounds proof-for what-realizes
            claims-in where-defined
            ;; Inverse queries (the payoff of a relational substrate)
            claims-grounding claims-realizing
            ;; Sets
            all-claims grounded-claims ungrounded-claims
            all-refs realized-ids))


;;; ── Facts ─────────────────────────────────────────────────────────────────────
;;; Plain tagged tuples. One fact per relationship.
;;;   (grounds  CLAIM REF)   — CLAIM is backed by knowledge ref REF   (the edge)
;;;   (realizes CLAIM ID)    — CLAIM is realized by a concrete planner id ID
;;;   (builds   REF PARENT)  — REF is built on top of PARENT ref       (the edge)
;;;   (defines  REF PATH)    — REF's executable facts live in PATH
;;;   (argues   CLAIM PATH)  — CLAIM originates in prose note PATH
;;;
;;; BEGIN generated
(define *provenance-facts*
  '(;; ── grounded claims ──
    (grounds binder-is-a-siting-decision stone-paper)
    (grounds buffer-absorbs-excess buffer-zones)
    (grounds compliance-is-valueflows filings)
    (grounds compliance-is-valueflows compliance)
    (grounds compliance-is-valueflows legal-aspects)
    (grounds composition-is-three-slots stone-paper)
    (grounds coords-inherit-chain spatial-things)
    (grounds duress-from-diff legal-aspects)
    (grounds end-of-life-routes-compete stone-paper)
    (grounds entry-at-any-spec stone-paper)
    (grounds grades-are-ratios stone-paper)
    (grounds grounding-is-verified provenance)
    (grounds infinity-is-a-cycle beenius-wax)
    (grounds infinity-is-a-cycle stone-paper)
    (grounds provenance-is-self-hosted provenance)
    (grounds tools-split-by-scale beenius-wax)
    (grounds tools-split-by-scale stone-paper)
    (realizes binder-is-a-siting-decision recipe-stone-paper-compost)
    (realizes binder-is-a-siting-decision recipe-stone-paper-bio)
    (realizes compliance-is-valueflows render-filing)
    (realizes composition-is-three-slots recipe-stone-paper-bio)
    (realizes composition-is-three-slots recipe-stone-paper)
    (realizes duress-from-diff plan-review)
    (realizes end-of-life-routes-compete recipe-stone-paper-compost)
    (realizes end-of-life-routes-compete recipe-stone-paper-reclaim)
    (realizes entry-at-any-spec recipe-stone-paper-reclaim)
    (realizes entry-at-any-spec recipe-stone-paper)
    (realizes grades-are-ratios recipe-stone-paper-bio)
    (realizes infinity-is-a-cycle recipe-beenius-remelt)
    (realizes infinity-is-a-cycle recipe-stone-paper-reclaim)
    (realizes tools-split-by-scale recipe-beenius-wax)
    (realizes tools-split-by-scale recipe-stone-paper)
    (argues binder-is-a-siting-decision "docs/solarpunk-now/infinity-tools.md")
    (argues buffer-absorbs-excess "docs/planner/README.md")
    (argues compliance-is-valueflows "docs/legal/legal-compliance-lifecycle.md")
    (argues composition-is-three-slots "docs/solarpunk-now/material-composition.md")
    (argues coords-inherit-chain "docs/clock/scope-cell-spec.typ")
    (argues duress-from-diff "docs/legal/legal-crossings.md")
    (argues end-of-life-routes-compete "docs/solarpunk-now/breaking-it-down.md")
    (argues entry-at-any-spec "docs/solarpunk-now/small-scale-production.md")
    (argues grades-are-ratios "docs/solarpunk-now/infinity-tools.md")
    (argues grounding-is-verified "docs/planning/provenance-bridge.md")
    (argues infinity-is-a-cycle "docs/solarpunk-now/infinity-tools.md")
    (argues provenance-is-self-hosted "docs/planning/provenance-bridge.md")
    (argues tools-split-by-scale "docs/solarpunk-now/infinity-tools.md")

    ;; ── still only argued (no `grounds` edge yet) ──
    (argues eco-tipping-ratchet "docs/planning/solve/ecological-tipping-tensions.md")
    (argues photodegradation-is-not-biodegradation "docs/solarpunk-now/breaking-it-down.md")
    (argues stone-paper-lacks-independent-lca "docs/solarpunk-now/infinity-tools.md")

    ;; ── how the executable refs build on one another ──
    (builds buffer-zones capacity-buffers)
    (builds legal-aspects reform)

    ;; ── where each ref's facts live ──
    (defines beenius-wax "module/playnet/planner/knowledge/recipes/beenius-wax.scm")
    (defines buffer-zones "module/playnet/planner/ddmrp/buffer-zones.scm")
    (defines capacity-buffers "module/playnet/planner/ddmrp/capacity-buffers.scm")
    (defines compliance "module/playnet/planner/legal/compliance.scm")
    (defines filings "module/playnet/planner/legal/filings.scm")
    (defines legal-aspects "module/playnet/planner/knowledge/law/aspects.scm")
    (defines provenance "module/playnet/lang/provenance.scm")
    (defines reform "module/playnet/planner/legal/reform.scm")
    (defines spatial-things "module/playnet/planner/scope/spatial-things.scm")
    (defines stone-paper "module/playnet/planner/knowledge/recipes/stone-paper.scm")))
;;; END generated


;;; ── Relations ─────────────────────────────────────────────────────────────────

(define (grounds-o claim ref)
  "CLAIM is directly grounded by knowledge REF."
  (in-list-o `(grounds ,claim ,ref) *provenance-facts*))

(define (realizes-o claim id)
  "CLAIM is realized by concrete planner id ID (a spec/aspect the model uses)."
  (in-list-o `(realizes ,claim ,id) *provenance-facts*))

(define (builds-o ref parent)
  "REF is built on top of PARENT ref."
  (in-list-o `(builds ,ref ,parent) *provenance-facts*))

(define (defines-o ref path)
  "REF's executable facts live in PATH."
  (in-list-o `(defines ,ref ,path) *provenance-facts*))

(define (argues-o claim path)
  "CLAIM is argued in prose note PATH."
  (in-list-o `(argues ,claim ,path) *provenance-facts*))

(define (backs-o a b)
  "The unified grounding edge: A is backed by B, whether A is a claim grounded
   by a ref, or a ref built on a parent ref. Closing over this walks
   claim → ref → parent-ref → … in one relation."
  (conde
    ((grounds-o a b))
    ((builds-o a b))))

(define (grounded-by-o claim ref proof)
  "CLAIM is transitively grounded by REF; PROOF is the derivation chain.
   Reuses transitive-o — the proof trace comes for free."
  (transitive-o backs-o claim ref proof))


;;; ── Forward queries ───────────────────────────────────────────────────────────

(define (what-grounds claim)
  "The refs directly grounding CLAIM."
  (run* (r) (grounds-o claim r)))

(define (all-grounds claim)
  "Every ref CLAIM transitively rests on (claim's whole computational basis)."
  (delete-duplicates
   (run* (r) (fresh (p) (grounded-by-o claim r p)))))

(define (proof-for claim ref)
  "The derivation chain from CLAIM down to REF, or '() if none."
  (let ((proofs (run 1 (p) (grounded-by-o claim ref p))))
    (if (null? proofs) '() (car proofs))))

(define (what-realizes claim)
  "The concrete planner ids CLAIM realizes (join keys into the convex model)."
  (run* (id) (realizes-o claim id)))

(define (claims-in path)
  "The claims argued in prose note PATH."
  (run* (c) (argues-o c path)))

(define (where-defined ref)
  "The file REF's facts live in, or #f."
  (let ((paths (run* (p) (defines-o ref p))))
    (if (null? paths) #f (car paths))))


;;; ── Inverse queries (free from the relational substrate) ──────────────────────

(define (claims-grounding ref)
  "Which claims rest on REF? — grounds-o run backward."
  (run* (c) (grounds-o c ref)))

(define (claims-realizing id)
  "Which claims are implicated by planner id ID? — realizes-o run backward.
   Given a surprising number on ID, this is who to go read."
  (run* (c) (realizes-o c id)))


;;; ── Sets ──────────────────────────────────────────────────────────────────────

(define (all-claims)
  "Every claim that appears anywhere (argued, grounded, or realized)."
  (delete-duplicates
   (append (run* (c) (fresh (p) (argues-o c p)))
           (run* (c) (fresh (r) (grounds-o c r)))
           (run* (c) (fresh (i) (realizes-o c i))))))

(define (grounded-claims)
  "Claims that have at least one grounding ref."
  (delete-duplicates (run* (c) (fresh (r) (grounds-o c r)))))

(define (ungrounded-claims)
  "Claims still ONLY argued in prose — no executable grounding yet.
   The work-list for promoting prose → facts."
  (lset-difference eq? (all-claims) (grounded-claims)))

(define (all-refs)
  "Every knowledge ref that has a defining file."
  (delete-duplicates (run* (r) (fresh (p) (defines-o r p)))))

(define (realized-ids)
  "Every concrete planner id some claim realizes."
  (delete-duplicates (run* (i) (fresh (c) (realizes-o c i)))))
