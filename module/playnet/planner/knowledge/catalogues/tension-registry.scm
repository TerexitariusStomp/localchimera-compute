;;; tension-registry.scm — the fragility catalogue as a governance actor.
;;;
;;; The document (§2.0.8) is explicit: WHICH fragilities the federation tracks,
;;; where it sets their tipping points, how steeply the curves rise — these are
;;; "political-economic choices, made by stewardship scopes and ratified at the
;;; UC level."  Governance-set, not engineering-set.  That is a BOUNDARY, so by
;;; the coinductive-at-boundaries principle it is an actor: register a kind
;;; (a production-governance act), persist the catalogue, hand the solver an
;;; attenuated read-only view.
;;;
;;; But the per-kind math — value φ(s), gradient-coeff φ′(s), curvature-coeff
;;; φ″(s) — is read in the innermost numeric loops (csr-grad / term-coeffs /
;;; obj-value, and their C twins).  So the actor COMPILES DOWN to a plain inline
;;; dispatch table: ONE ($ registry 'compile) per solve, then raw closure calls
;;; per form — zero actor overhead in the hot path.  Coinductive at the boundary,
;;; inductive in the core.
;;;
;;; The per-kind math this compiles is itself read from tension-kinds.scm's
;;; *kind-spec* — the actual single source of truth, generating both the
;;; Scheme closures here and kernel.c's own kernel_kinds.h (gen-kernels.scm),
;;; pinned bit-for-bit by test-tension-parity.scm. So Scheme and C no longer
;;; drift; only relaxation.scm's dormant barrier stays a hand-written third,
;;; by the same standalone-module constraint its other primitives keep (it
;;; cannot import the umbrella from its primitive-load boundary). The finite-
;;; difference test below checks each kind's (φ, φ′, φ″) triple against
;;; itself — catching the factor/sign bugs a solve-level parity-assert can't
;;; see, whichever backend is in question.
;;;
;;; Run:  guile -L . module/playnet/planner/knowledge/catalogues/tension-registry.scm

(define-module (playnet planner knowledge catalogues tension-registry)
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib facet)
  #:export (sibling ^tension-registry restore-registry fd rel check-kind rule main
            compile-table))

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins actor-lib facet)
             (srfi srfi-1)
             (ice-9 format))
(fluid-set! %default-port-encoding "UTF-8")
(set-port-encoding! (current-output-port) "UTF-8")

;;; ─── the kinds — loaded from the SINGLE SOURCE OF TRUTH ──────────────────
;;; The very file planner.scm's hot loops read. Governance actor and solver
;;; dispatch through one definition of every kind's (φ, φ′, φ″); `frag` is the
;;; fragility-profile barrier, added there as one library row.
(define (sibling f)   ; path to a sibling file, robust to current-filename being #f (the script-main case)
  (or (find file-exists? (filter-map (lambda (p) (and (string? p) (string-append (dirname p) "/" f)))
                                     (cons (current-filename) (command-line))))
      (string-append "module/playnet/planner/" f)))
;; a module now: use-modules imports into the CURRENT module without switching
;; it, so this stays safe in a file that is itself primitive-load'ed.
(use-modules (playnet planner formulas tension-kinds))
;;; …and the FRAGILITY CATALOGUE — the real planetary-boundary / tipping-point figures the registry
;;; custodies (DRAFT, ratified at the UC level). Governance owns the numbers; the solver gets a view.
(use-modules (playnet planner knowledge catalogues eco))

;;; ─── the actor : the catalogue, custodied ────────────────────────────────
;;; Two things are custodied here: the KIND library (φ shapes) and the ECO catalogue (which fragilities
;;; the federation tracks, with their ranges/weights/α — political-economic choices, §2.0.8). The solver
;;; never sees the raw catalogue; it gets the attenuated `eco-policy` view (the planner's eco-* lists).
(define (^tension-registry bcom tags catalogue)
  (methods
   [(kinds) tags]                                    ; governance view of the kind library
   [(register! tag)                                  ; a production-governance act
    (cond ((memq tag tags) (bcom (^tension-registry bcom tags catalogue) 'already))
          ((assq tag *kind-library*)
           (bcom (^tension-registry bcom (cons tag tags) catalogue) 'ok))
          (else (error "no such kind in library" tag)))]
   [(compile)                                        ; → inline alist tag→(φ φ′ φ″)
    (map (lambda (tag) (cons tag ((cdr (assq tag *kind-library*))))) tags)]
   ;; ── the fragility catalogue (the eco governance custody) ──
   [(eco-catalogue) catalogue]                       ; governance VIEW: the full entries, with sources
   [(register-agent! entry)                          ; a stewardship act: ratify / add a fragility agent
    (bcom (^tension-registry bcom tags (cons entry catalogue)) 'ok)]
   [(eco-policy)                                     ; → (eco-spec-frag eco-budget eco-couple): the attenuated SOLVER view
    (call-with-values (lambda () (catalogue->policy catalogue)) list)]
   ;; The other solver view of the SAME ratified catalogue: every limit whose
   ;; witnessed character says it returns, as a regenerating stock of headroom
   ;; (eco-catalogue.scm §the migration). `eco-policy` reads a limit as a wall the
   ;; draw approaches; this reads it as a level the draw spends and labour rebuilds.
   ;; A limit is in exactly one of the two — `migrate-limit` yields #f for an
   ;; irreversible one, which `eco-policy` then carries as the fragility it is.
   [(eco-stocks . opt)                               ; → (migrated-limit …)
    (apply migrated-limits catalogue opt)]
   [(portrait) (list tags catalogue)]))              ; persistence: tags + catalogue (plain data)
(define (restore-registry p) (spawn ^tension-registry (car p) (cadr p)))

;;; ─── the property test : φ′ ≈ FD(φ), φ″ ≈ FD(φ′) ─────────────────────────
;;; One value function, its analytic grad, its analytic curvature — checked
;;; against each other by central differences. A factor-of-2 or a flipped sign
;;; shows on the first sample. This is the decode∘encode=id discipline, applied
;;; to derivatives: every analytic coefficient must invert its value function.
(define (fd f s) (/ (- (f (+ s 1e-6)) (f (- s 1e-6))) 2e-6))
(define (rel a b) (/ (abs (- a b)) (+ 1.0 (abs b))))
(define (check-kind tag table t D w samples)
  (let* ((k (cdr (assq tag table))) (v (kind-value k)) (g (kind-grad k)) (c (kind-curv k)))
    (format #t "  ~6a  (t=~a D=~a w=~a)\n" tag t D w)
    (fold (lambda (s ok)
            (let* ((ag (g s t D w)) (vg (fd (lambda (x) (v x t D w)) s))
                   (ac (c s t D w)) (gc (fd (lambda (x) (g x t D w)) s))
                   (eg (< (rel ag vg) 1e-4)) (ec (< (rel ac gc) 1e-4)))
              (format #t "    s=~6,2f   φ′=~9,4f vs fd ~9,4f ~a    φ″=~9,4f vs fd ~9,4f ~a\n"
                      s ag vg (if eg "✓" "✗") ac gc (if ec "✓" "✗"))
              (and ok eg ec)))
          #t samples)))

;;; ─── demonstration ───────────────────────────────────────────────────────
(define (rule t) (format #t "\n── ~a ~a\n" t (make-string (max 0 (- 56 (string-length t))) #\─)))
(define (main)
  (define vat (spawn-vat))
  (with-vat vat
    (define registry (spawn-named "fragility-catalogue" ^tension-registry '(des bar qc) *planetary-catalogue*))

    (rule "1 · the catalogue (governance view)")
    (format #t "  active kinds: ~a\n" ($ registry 'kinds))

    (rule "2 · compile → inline table, then FD-check each kind")
    (let* ((table (compile-table registry))
           (ok (and (check-kind 'des table 0.5 2.0 1.3 '(0.3 0.8 1.4 1.9))
                    (check-kind 'bar table 0.5 2.0 1.3 '(0.3 0.7 1.5 3.0))
                    (check-kind 'qc  table 0.5 2.0 1.3 '(-1.5 -0.3 0.5 2.0)))))
      (format #t "\n  ~a all analytic coefficients invert their value functions\n"
              (if ok "✓" "✗")))

    (rule "3 · one source of truth — vs the hand-coded constant")
    (let* ((k (cdr (assq 'des (compile-table registry))))
           (s 0.8) (D 2.0) (w 1.3)
           (reg ((kind-grad k) s 0.0 D w))
           (hand (/ (* -2.0 w (- D s)) (* D D))))     ; planner.scm csr-grad des branch
      (format #t "  registry des φ′(0.8) = ~,4f\n  planner −2w(D−s)/D²  = ~,4f   ~a\n"
              reg hand (if (< (abs (- reg hand)) 1e-12) "✓ identical" "✗ DRIFT")))

    (rule "4 · governance — add a fragility profile as DATA")
    (format #t "  register! frag → ~a    catalogue now: ~a\n"
            ($ registry 'register! 'frag) ($ registry 'kinds))
    (format #t "  and it is verified the instant it exists — no hot loop touched:\n")
    (let ((ok (check-kind 'frag (compile-table registry) 0.5 2.0 1.3 '(0.3 0.7 1.5 3.0))))
      (format #t "\n  ~a frag fragility consistent\n" (if ok "✓" "✗")))

    (rule "5 · the eco catalogue → the solver policy")
    (format #t "  governance view — ~a fragility agents (with sources)\n" (length ($ registry 'eco-catalogue)))
    (let ((pol ($ registry 'eco-policy)))                    ; (eco-spec-frag eco-budget eco-couple)
      (format #t "  eco-policy → rate boundaries: ~a\n" (map car (car pol)))
      (format #t "             → cumulative budgets: ~a\n" (map car (cadr pol)))
      (format #t "             → cascade couplings:  ~a\n" (caddr pol)))

    (rule "6 · attenuation — the solver gets a read-only view")
    (let ((solver (facet registry 'compile 'kinds 'eco-policy)))
      (format #t "  solver sees kinds: ~a\n" ($ solver 'kinds))
      (format #t "  solver gets eco-policy: ~a budgets\n" (length (cadr ($ solver 'eco-policy))))
      (format #t "  solver register! qc → ~a\n"
              (catch #t (lambda () ($ solver 'register! 'qc) "UNEXPECTED: allowed")
                     (lambda _ "✓ denied (method not on facet)"))))

    (rule "7 · persistence — portrait → restore the catalogue")
    (let* ((saved ($ registry 'portrait))
           (revived (restore-registry saved)))
      (format #t "  kinds round-trip: ~a   catalogue round-trip: ~a\n"
              (if (equal? ($ registry 'kinds) ($ revived 'kinds)) "✓" "✗")
              (if (equal? ($ registry 'eco-catalogue) ($ revived 'eco-catalogue)) "✓" "✗")))

    (rule "the boundary, kept")
    (format #t "  governance act  : ($ registry 'register! …)   — one actor turn\n")
    (format #t "  per solve       : ($ registry 'compile)        — one actor turn\n")
    (format #t "  per form (hot)  : ((kind-grad k) s t D w)      — raw closure, no send\n")
    (newline)))

;; helper: compile is a near call, but pull it out so the demo reads clean
(define (compile-table registry) ($ registry 'compile))

;; The demo runs when this file IS the script, and never on import. As a
;; fragment it ran unless REGISTRY_LIB=1 said otherwise — the same ritual
;; PLANNER_LIB was, and with the same failure: every importer that forgot the
;; env var got a demo, and a module importer gets one at load time with a vat
;; to block in. Asking the command line is the question actually being asked,
;; and it needs nothing of the caller.
(when (and (pair? (command-line))
           (string-suffix? "tension-registry.scm" (car (command-line))))
  (main))
