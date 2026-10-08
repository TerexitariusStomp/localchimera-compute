;;; test-bioregion-containment.scm — a bioregion is an ECOLOGICAL AGENT = a
;;; SpatialThing CONTAINER (playnet.typ §bioregion). It is NOT a bespoke index:
;;; the containment relation the planner already has IS the index. This test binds
;;; BOTH things a bioregion carries to ONE container id ("doon-shed"), each reached
;;; by containment the codebase already walks:
;;;
;;;   A. its CLIMATE SCENARIOS   — resolved up the SpatialThing `contained-in` tree
;;;      (bioregions.scm). A farm/terrace deep inside the shed inherits the shed's
;;;      weather futures; it does not carry its own.
;;;   B. its REGENERATIVE ENVELOPE — the existing *frag-container* cascade
;;;      (test-frag-container.scm): a fragility on the shed reads draws on every
;;;      resource contained-in it. Same id, same containment idea, zero new machinery.
;;;
;;; The punchline: onboarding any scope in any bioregion is "place its SpatialThing
;;; contained-in the bioregion" — both its weather and its ecological limits then
;;; resolve by the walk up the containment tree. No per-region code.
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner tests/planner/test-bioregion-containment.scm

(use-modules (playnet planner knowledge dsl shorthand))
(use-modules (playnet test planner prelude)
             (playnet planner solve engine)
             (playnet planner solve compile)
             (playnet planner vf schemas)
             (playnet planner knowledge worlds bioregions)
             (srfi srfi-1)
             (ice-9 format))
(use-modules (playnet planner knowledge worlds doon-valley))     ; *doon-valley-scenarios/tail-robust* (data)

;; ── The SpatialThing containment tree: a terrace inside a farm inside the shed ──
;; biosphere ⊃ doon-shed (the bioregion, at Dehradun) ⊃ navdanya-plot ⊃ terrace-3.
(define (st id parent lat lon) (place* id #:lat lat #:lon lon #:parent parent))
(define spatials
  (list (st "biosphere"    #f            0.0   0.0)
        (st "doon-shed"     "biosphere"  30.32 78.03)   ; THE BIOREGION — an ecological agent
        (st "navdanya-plot" "doon-shed"  30.32 78.03)
        (st "terrace-3"     "navdanya-plot" 30.32 78.03)
        (st "sahel-plot"    "biosphere"  13.51  2.11)))  ; a place in NO scenario-bearing shed

;; The bioregion carries its weather futures — attached by the SAME id the envelope uses.
(attach-bioregion-scenarios! "doon-shed" *doon-valley-scenarios/tail-robust*)

;; ── Part A — scenarios resolve UP the containment tree ────────────────────────
(define from-terrace (bioregion-scenarios-for spatials "terrace-3"))   ; 2 hops up to doon-shed
(define from-plot    (bioregion-scenarios-for spatials "navdanya-plot"))
(define from-sahel   (bioregion-scenarios-for spatials "sahel-plot"))  ; no bioregion ⇒ #f
(define shed-of-terrace (bioregion-of spatials "terrace-3"))

(format #t "~%── A. a bioregion's SCENARIOS reach a contained plot via contained-in ──~%")
(format #t "  terrace-3 → bioregion: ~a  (~a scenarios inherited)~%"
        shed-of-terrace (if from-terrace (length from-terrace) 0))
(define a1 (equal? shed-of-terrace "doon-shed"))                        ; walked terrace→plot→shed
(define a2 (and from-terrace (eq? from-terrace *doon-valley-scenarios/tail-robust*)))
(define a3 (eq? from-terrace from-plot))                                ; same shed ⇒ same futures
(define a4 (not from-sahel))                                            ; a place in no shed inherits nothing
(format #t "  [~a] terrace-3 resolves to doon-shed (2 hops up the tree)~%" (if a1 "✓" "✗"))
(format #t "  [~a] it inherits the shed's ~a scenarios; plot inherits the same set~%"
        (if (and a2 a3) "✓" "✗") (if from-terrace (length from-terrace) 0))
(format #t "  [~a] a plot in no scenario-bearing shed inherits none (#f, not a guess)~%" (if a4 "✓" "✗"))

;; ── Part B — the SAME bioregion id caps draws via the existing frag cascade ────
;; A water-hungry crop resource contained-in "doon-shed": its place IS the shed, and
;; it is one of the shed's contents. A regenerative-envelope fragility on the shed
;; then reads the draw on it — the exact *frag-container* mechanism, no new code.
(define (crop-stock)
  (er "paddy-1" "paddy" #f #:place #f #:qty 1000.0 #:unit "kg" #:contained-in "doon-shed"))
(define (draw-recipe)
  (compile-recipe (list (rp "draw" "Draw"))
                  (list (out "o1" "grain" 1.0 "draw") (wrk "o2" 0.01 "draw") (in "o3" "paddy" 1.0 "draw"))))

(define (run-envelope envelope?)
  (set-templates! (draw-recipe))
  (ingest-located! (list (crop-stock)) '() spatials
    #:periods '(0)
    #:eco-container (if envelope? (list (cons "doon-shed" (list 80.0 120.0 0.5 50.0))) '())  ; shed water envelope, tip 100
    #:demand (list (cons (lg "grain" (cell "doon-shed" 0)) 1000.0)))
  (hash-set! *A* (cell "doon-shed" 0) 1000000.0)
  (call-with-values solve-located
    (lambda (x idx) ((Vof x idx) "p|draw|doon-shed@0"))))

(define shed-tip 100.0)
(define free (run-envelope #f))                                ; no envelope — draws to the stock
(define capd (run-envelope #t))                                ; envelope, tip 100 — eases off below it
(define contained (hash-ref *contained* "doon-shed" '()))      ; built from the crop's contained-in

(format #t "~%── B. the SAME bioregion id caps draws via *frag-container* (existing) ──~%")
(format #t "  *contained*[doon-shed] = ~a  (built from the paddy's contained-in)~%" contained)
(format #t "  draw without the shed envelope: ~,1f   WITH it (tip ~a): ~,1f~%" free shed-tip capd)
(define b1 (and (member "paddy" contained) #t))                ; ingest mapped paddy ∈ doon-shed
(define b2 (and (< capd shed-tip) (> (- shed-tip capd) 0.1)))  ; envelope holds the line, with margin
(define b3 (> free (* 2.0 shed-tip)))                          ; without it, draw runs far past the tip
(format #t "  [~a] ingest built the containment map from contained-in (paddy ∈ doon-shed)~%" (if b1 "✓" "✗"))
(format #t "  [~a] the shed's regenerative envelope eases the draw off below its tip (~,1f < ~a)~%" (if b2 "✓" "✗") capd shed-tip)
(format #t "  [~a] without it the draw runs far past — the container barrier holds, not the crop's own cap~%" (if b3 "✓" "✗"))

(define ok (and a1 a2 a3 a4 b1 b2 b3))
(format #t "~%  ~a one bioregion id (\"doon-shed\") carries BOTH its weather futures~%" (if ok "✓" "✗"))
(format #t "     (up the SpatialThing tree) AND its regenerative envelope (the frag~%")
(format #t "     cascade) — both reached by containment, no bespoke bioregion index.~%~%")
(exit (if ok 0 1))
