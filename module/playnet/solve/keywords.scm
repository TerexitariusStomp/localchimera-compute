;;; module/playnet/solve/keywords.scm — the keywords a solve takes, stated once, each with its kind
;;;
;;; Every layer between a scope and its program used to carry its own list of
;;; the solve's keywords: the world list a scenario forwards, the two held
;;; back, the settings written after ingest, the deterministic branch's
;;; forward, the robust filter, a test's private copy. Thirteen lists, kept in
;;; step by hand, and three had drifted (measured 2026-10-12: a keyword in the
;;; world list that plan-from-records refused; two computed by every live scope
;;; and dropped before ingest). This table is the one statement. A kind says
;;; who consumes a keyword:
;;;
;;;   world    a fact of the world: ingest-records! reads it, every assembly
;;;            forwards it to each scenario's ingest
;;;   held     ingest-records! reads it, a scenario's world does not take it —
;;;            each switches on an engine mode the live solve has never run and
;;;            moves plans that stand (solve/records.scm says which); held by
;;;            name until decided
;;;   setting  the voice field and the governed dials, written after ingest's
;;;            reset by apply-solve-settings! (solve/engine.scm)
;;;   band     a reproduction wall, poured after ingest (repro-bands)
;;;   solve    one solve's own: its warm start, its decided discrete state, its
;;;            futures, its pins and holds, its search budget, what may be bought
;;;
;;; What derives from it: `%world-keywords` and `%held-back-world-keywords`
;;; (solve/records.scm), robust's forward of the world (`world-opts`), the
;;; deterministic branch's forward (solve/plan.scm), and the test that holds
;;; ingest-records!, plan-from-records and apply-solve-settings! to it
;;; (tests/scope/test-solve-settings-reach-every-path.scm).

(define-module (playnet solve keywords)
  #:use-module (srfi srfi-1)
  #:export (%solve-keywords solve-keywords-of solve-keyword-kind pick-keywords))

(define %solve-keywords
  '(;; ── the world ──
    (#:periods world) (#:movable world) (#:storable world) (#:whole world) (#:proc-frag world)
    (#:tau world) (#:hold world) (#:demand world) (#:eco-caps world) (#:reserve world) (#:backend world)
    (#:eco-frag world) (#:eco-spec-frag world) (#:eco-budget world) (#:eco-container world)
    (#:eco-couple world) (#:couplings world) (#:eco-prior world) (#:stock-frag world) (#:stock-prices world)
    (#:agent-hours world) (#:agent-skills world) (#:agent-position world)
    (#:horizon world) (#:period-spans world) (#:refine-periods? world)
    (#:willing? world) (#:legal-forbids? world) (#:legal-decorate world) (#:per-agent? world)
    (#:desire-weights world)
    (#:certificates world)            ; each citizen's drawable credit — the bar over their claims
    (#:arc-table world) (#:arc-topology? world) (#:manners world) (#:never-raw world) (#:raws world)
    (#:resource-suppliers world) (#:specs world) (#:span-of world)
    (#:live-avail world)              ; the registry's reservations: a registered resource ingests at what is free
    ;; ── held back ──
    (#:skill-dynamics held) (#:composition held)
    ;; ── the settings ──
    (#:voice-tau setting) (#:voice-pushes setting) (#:voice-hours setting) (#:scope-path setting)
    (#:pref-bound setting) (#:emp-rho setting) (#:kappa setting) (#:want-as-cap setting) (#:stock-draw-hours setting)
    ;; ── the bands ──
    (#:repro-floors band) (#:budgeted-floors band) (#:repro-caps band) (#:insurance band) (#:bands band)
    ;; ── one solve's own ──
    (#:allow-infeasible? solve) (#:acquire solve) (#:promote solve) (#:node-budget solve)
    (#:warm-x solve) (#:tstart solve) (#:decided solve) (#:maximin? solve)
    (#:scenarios solve) (#:first-stage-procs solve) (#:pins solve) (#:holds solve)))

(define (solve-keywords-of kind)
  "The keywords of KIND, in the table's order."
  (filter-map (lambda (r) (and (eq? (cadr r) kind) (car r))) %solve-keywords))

(define (solve-keyword-kind kw)
  "KW's kind, or #f for a keyword no solve takes."
  (and=> (assq kw %solve-keywords) cadr))

(define (pick-keywords opts kinds)
  "The (keyword value …) pairs of OPTS whose keyword is of one of KINDS, in OPTS' order:
   a keyword list ready to `apply` onto the consumer of those kinds."
  (let loop ((o opts) (out '()))
    (cond ((or (null? o) (null? (cdr o))) (reverse out))
          ((memq (solve-keyword-kind (car o)) kinds)
           (loop (cddr o) (cons (cadr o) (cons (car o) out))))
          (else (loop (cddr o) out)))))
