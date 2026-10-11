;;; module/playnet/doors/planner/solving.scm — the solves: a plan over the scope's live state, the federated and means plans, the census and record a federation reads, what a withdrawal displaces, and the stale sweep
;;;
;;; A fragment of the planner service (playnet doors service): a procedure from
;;; the service's context to the doors it serves, composed into every service by
;;; doors/service.scm. `with-planner-ctx` binds the context's fields under their
;;; own names, so each clause reads as it did inside the actor
;;; (docs/planning/codebase-layout.md §12). What this fragment alone reads and
;;; writes is defined here, above its doors.

(define-module (playnet doors planner solving)
  #:use-module ((goblins) #:select ($))
  #:use-module ((playnet doors assignments) #:select (willing-predicate))
  #:use-module ((playnet doors inventory) #:select (recipes-conforming))
  #:use-module ((playnet doors planner solve-cache) #:select (cache-solve! externality-history-ref last-solve-ref means-cap-rows))
  #:use-module ((playnet doors position) #:select (agent-position-predicate demand->keyed demand-horizon federated-horizon))
  #:use-module ((playnet doors service brief) #:select (parse-overrides plan-brief->string))
  #:use-module ((playnet doors service provenance-trace) #:select (explain-claim make-pull-of))
  #:use-module ((playnet federation crossing-set) #:select (crossing-goods))
  #:use-module ((playnet scope live) #:select (allocate-means-consensus federated-dilemma federated-per-scope federated-relaxed-scopes federated-result federated-scope-pulls federated-solve federated-withdrawal-displacement lg loose-gives records-means-world svc-good warm-boundary-flows))
  #:use-module ((playnet solve engine) #:select (*desire-w0* cap-scale-of want-as-cap?))
  #:use-module ((playnet solve externality) #:select (marginal-displacement moved-summary))
  #:use-module ((playnet utils envelope) #:select (catch-as-failure failure success))
  #:use-module ((srfi srfi-1) #:select (append-map every find))
  #:use-module (playnet doors planner ctx)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (planner-solving-doors))

(define (planner-solving-doors ctx)
  (with-planner-ctx ctx

    (declared-doors planner

      ((resolve-stale! #:optional (max-age 3600))
       (resolve-stale-scopes! max-age))

      ;; the paced spelling: ONE due scope per turn — the scope id it solved,
      ;; or #f when the pass is complete. SEEN = the sids this sweep already
      ;; handled (a list; '() opens the sweep and runs the re-stand hooks).
      ;; The gateway fiber threads it so snapshots interleave between solves.
      ((resolve-one-stale! max-age seen) (resolve-one-stale! max-age (if (list? seen) seen '())))

      ;; Run the CONVEX planner over the scope's live state and return the implied
      ;; VF `work` commitments. demand = ((spec place period target) …); the engine
      ;; reads stock/labour/recipes/skills/hours from the observer + stores. opts is
      ;; an alist that may carry (movable . (…)) (storable . (…)) (commute-km . n).
      ((plan scope-id demand #:optional (opts '()))
       (with-scope scope-id
         (lambda (root)
           (catch-as-failure
             (lambda ()
               (let ((o opts))
                 (on-plan
                   (plan-fn* root scope-id
                     #:demand (demand->keyed demand)       ; the UC allocation rides in through standing-kw
                     #:movable (or (assq-ref o 'movable) '())
                     #:storable (or (assq-ref o 'storable) '())
                     #:whole (or (assq-ref o 'whole) '())
                     #:tau (or (assq-ref o 'tau) 0.0)
                     ;; (willing-only . #t) ⇒ the MATERIALIZATION binding: gate the
                     ;; solve to those who marked status=willing (the bundle hour-cap
                     ;; then bounds them). Default/off ⇒ the ungated candidate FIELD —
                     ;; today's behaviour, the offer over all reachable workers.
                     #:willing? (and (assq-ref o 'willing-only)
                                     (willing-predicate root))
                     #:agent-position (agent-position-predicate root)  ; live/expected positions
                     #:horizon (demand-horizon demand o)   ; derive multi-period from the demand (explicit opt wins)
                     ;; reproduction of labour-power: per-person nutrition floors + eat
                     ;; recipes over the scope's foods (live.scm). STRUCTURAL — on by
                     ;; default (a no-op unless the scope has people AND nutritious food),
                     ;; so every real commune reproduces its members automatically. Opt
                     ;; OUT with (reproduce . #f), not in.
                     #:reproduce? (not (eq? (assq-ref o 'reproduce) #f))
                     #:backend 'native-c)
                   (lambda (al) (success (cache-solve! cache scope-id demand al)))
                   #:catch (lambda (e) (failure (format #f "~a" e))))))))))

      ;; FEDERATION ACROSS VATS — several communes' provisioning composed through
      ;; one pull per crossing good (dual decomposition), so what one commune
      ;; lacks another supplies. Each commune keeps its own records in its own
      ;; scope; only flows and the pull cross. `boundary-good` is the INTERMEDIATE
      ;; that crosses (the input moves, each commune bakes locally — see
      ;; engine/federation-solve.scm). `communes` = ((scope-id (demand-good . qty)) …);
      ;; every commune named crosses the good, and which of them supplies and
      ;; which draws is the solve's answer, read off the sign of its flow.
      ;; Returns the met and rounds the crossing settled at and the good's pull λ.
      ;; Same-vat here (all roots near); the SAME shape goes cross-vat when roots
      ;; become remote (docs/planning/federation/FEDERATED-SOLVE.md, Rung 3).
      ;; OPTS (optional alist): `displacement-of` — a member scope-id whose
      ;; membership is to be read for what it displaces in the others
      ;; (truth-telling.md stage 4): one more
      ;; federated solve without it, its border shut, differenced on what the
      ;; others are delivered. Asked for, never run by default — it is a solve.
      ;; a member's record for a solve across scopes (scope-record-of): DEM its
      ;; demand (good . qty) or #f; OPTS as federated-plan's
      ;; the goods this scope deals in (planner/federation/crossing-set.scm) — what a
      ;; federation's crossing set is made of; DEMAND as scope-record's
      ((census scope-id #:optional (demand #f))
       (catch-as-failure (lambda () (success (scope-census scope-id demand)))))

      ((scope-record scope-id goods #:optional (demand #f) (opts '()))
       (catch-as-failure
         (lambda ()
           (let ((r (scope-record-of scope-id goods demand (federated-horizon (if (pair? opts) opts '())))))
             ;; a scope not on the roster answers with-scope's failure as it is
             (if (and (pair? r) (eq? (car r) 'error)) r (success r))))))

      ((federated-plan boundary-good communes #:optional (opts '()))
       (catch-as-failure
         (lambda ()
           (define (resources-of sid)             ; the same projected view the record was built from
             (and=> (roster-ref sid)
                    (lambda (root)
                      (false-if-exception (assq-ref (world-of* root sid) 'view)))))
           (let* ((o (if (pair? opts) opts '()))
                  ;; one dated day for every member, so each roster window
                  ;; meets a calendar day and enters as the hours it holds
                  (hz (federated-horizon o))
                  (_ (let ((bad (communes-overlap (map car communes))))
                       (when (pair? bad)
                         (error (format #f "communes overlap — ~a held by more than one program"
                                        (string-join (map (lambda (b) (format #f "~a ~a (~a)" (caar b) (cdar b)
                                                                              (string-join (cdr b) " + ")))
                                                          bad)
                                                     "; "))))))
                  ;; WHAT CROSSES: the goods named, or — when none is named — every
                  ;; good at least two of the communes deal in, read off their
                  ;; records (federation/crossing-set.scm); nobody declares a supply
                  (goods (cond ((string? boundary-good) (list boundary-good))
                               ((list? boundary-good) boundary-good)
                               (else (crossing-goods
                                      (map (lambda (c)
                                             (cons (list-ref c 0)
                                                   (scope-census (list-ref c 0)
                                                                 (and (pair? (cdr c)) (list-ref c 1)))))
                                           communes)))))
                  (recs (map (lambda (c)
                               (scope-record-of (list-ref c 0) goods
                                                (and (pair? (cdr c)) (list-ref c 1)) hz))
                             communes)))
             (call-with-values
                 (lambda ()
                   ;; the folds feed the dual: start the consensus at the bound
                   ;; the communes' own deficit and stock already state
                   (federated-solve recs #:z0 (warm-boundary-flows recs resources-of)))
               (lambda (plans met rounds pulls)
                 ;; cache each commune's FEDERATED per-location result where
                 ;; location-slacks reads it → the desire overlay shows the deficit
                 ;; commune draining to green as the boundary flow fills it.
                 ;; the landing is the solve DESCENT: the rows enter at the
                 ;; root, each scope's node receives and caches its own
                 ($ (nodes-solve uc) 'set-value
                    (filter car (federated-per-scope plans recs)))
                 (success `((met     . ,met)
                            (rounds  . ,rounds)
                            (pull    . ,(if (pair? goods) (hash-ref pulls (car goods) 0.0) 0.0))
                            (boundary . ,(if (string? boundary-good) boundary-good goods))
                            (pulls   . ,(map (lambda (g) (cons g (hash-ref pulls g 0.0))) goods))
                            ;; the two horns, always reported: what must cross
                            ;; and what can — so a run at its cap names a
                            ;; shortfall or a surplus nobody claimed, by quantity
                            (dilemma . ,(federated-dilemma recs resources-of))
                            ;; scopes whose declared batches / whole counts this
                            ;; solve kept relaxed — a federated plan is a relaxation
                            (relaxed . ,(federated-relaxed-scopes recs))
                            ;; crossings a scope stayed out of because it makes the
                            ;; good without bound and so has no measure to cross by
                            (unbounded . ,(append-map
                                           (lambda (r)
                                             (map (lambda (u) `((scope . ,(assq-ref r 'scope-id))
                                                                (good . ,(car u)) (column . ,(cdr u))))
                                                  (or (assq-ref r 'unbounded) '())))
                                           recs))
                            ;; stage 4: λ per member scope — each good it crosses,
                            ;; its signed flow and the pull the crossing settled
                            ;; at: what one more unit of that scope's ask moves
                            ;; in the scopes across it. Pulls stand between
                            ;; scopes, persons never.
                            (scopes  . ,(federated-scope-pulls recs plans pulls))
                            ;; a crossing whose give-bound stands far above what
                            ;; crossed: the verdict's noise on its rows, in the
                            ;; good's unit, is a share of the flow worth reading
                            ,@(let ((l (loose-gives recs plans)))
                                (if (pair? l)
                                    `((loose . ,(map (lambda (r)
                                                       `((scope . ,(list-ref r 0)) (good . ,(list-ref r 1))
                                                         (gives . ,(list-ref r 2)) (crossed . ,(list-ref r 3))
                                                         (noise . ,(list-ref r 4))))
                                                     l)))
                                    '()))
                            ,@(let ((ps (assq-ref o 'displacement-of)))
                                (if ps
                                    `((scope-displacement
                                       . ((scope . ,ps)
                                          (moved . ,(federated-withdrawal-displacement
                                                     recs ps #:base (federated-result plans recs))))))
                                    '()))))))))))

      ;; THE UC GATEWAY LOOP (patchwork §5 item 1): the consensus row, run live.
      ;; COMMUNES = ((scope-id place keyed-demand) …). Each scope's world is built
      ;; from ITS OWN stores inside its closure (records-means-world — sovereignty
      ;; is the records never leaving), the bar TOTAL and the willingness CEILINGS
      ;; arrive from the caller (the governance side computes them off the means
      ;; fold and live-willingness-of — governance→planner, one direction), the
      ;; start is warm from whatever each scope held last time, and the result
      ;; LANDS: every subsequent `plan`/`solve` for these scopes carries its
      ;; allocation as a standing eco-cap until the next run moves it.
      ((means-plan spec total communes ceilings)
       (catch-as-failure
         (lambda ()
           ;; total 'auto reads the bar off the standing means fold — the input
           ;; the fold exists to supply, so no caller has to conjure it
           (let* ((total (if (eq? total 'auto) (means-fold-total spec) total))
                  (scopes
                   (map (lambda (c)
                          (let ((sid (list-ref c 0)) (place (list-ref c 1))
                                (dem (list-ref c 2)))
                            (cons sid
                                  (with-scope sid
                                    (lambda (root)
                                      (let ((as ($ root 'agent-store))
                                            (sts ($ root 'spatial-thing-store)) (rs ($ root 'recipe-store))
                                            (world (world-of* root sid)))   ; the one custody view
                                        (call-with-values (lambda () (gather rs root sid))
                                          (lambda (procs flows)
                                            (records-means-world
                                              (assq-ref world 'view) ($ as 'all-agents)
                                              ($ sts 'all-locations) procs flows spec place
                                              #:demand dem
                                              #:eco-caps (assq-ref world 'caps) #:span-of (assq-ref world 'span)
                                              #:proc-frag (or (assq-ref (standing root sid) 'proc-frag) '()))))))))))
                        communes))
                  (prev (map (lambda (c)
                               (let ((rt (roster-ref (car c))))
                                 (and rt (and=> (assoc-ref (means-cap-rows cache rt) spec) cdr))))
                             communes))
                  (init (and (every number? prev) prev)))
             (call-with-values
                 (lambda () (allocate-means-consensus scopes spec total
                                                      #:ceilings ceilings
                                                      #:init init))
               (lambda (allocs duals rounds)
                 ;; the landing is the allocation DESCENT: one value enters at
                 ;; the root, each scope's node receives its row and applies it.
                 ;; The key is period-free (`Svc|spec#place`): the engine lays
                 ;; it on every period a later solve declares.
                 ($ (nodes-allocation uc) 'set-value
                    (map (lambda (c)
                           (let ((sid (list-ref c 0)) (place (list-ref c 1)))
                             (list sid spec
                                   (cons (lg (svc-good spec) place)
                                         (assoc-ref allocs sid)))))
                         communes))
                 (success `((allocations . ,allocs)
                            (duals       . ,duals)
                            (rounds      . ,rounds)
                            (spec        . ,spec)
                            (total       . ,total)))))))))

      ;; NON-BINDING what-if / read — the conversational verb (the orb, the NL
      ;; interface, docs/planning/faces/nl-interface.md). One uniform OVERRIDES alist of
      ;; plan-scope inputs, merged over the scope's LIVE state, computed but NEVER
      ;; persisted. The current plan is (solve scope-id '()); a scenario overrides
      ;; (demand …)/(eco-caps …)/(reserve …)/(tau …). Returns the full result —
      ;; met, work, material, prices (the duals λ = the "why"), social (L, free
      ;; time f), candidates, and the duality-gap certificate — every
      ;; conversational read is a field of it. Binding lives only in MATERIALIZE
      ;; (separate, behind governance), so `solve` is safe to hand to anyone.
      ((solve scope-id overrides)
       (with-scope scope-id
         (lambda (root)
           (catch-as-failure
             (lambda ()
               (let ((o (if (pair? overrides) overrides '())))
                 (on-plan
                   (plan-fn* root scope-id
                     #:demand     (demand->keyed (or (assq-ref o 'demand) '()))
                     #:eco-caps   (or (assq-ref o 'eco-caps) '())   ; the UC allocation stands under it (standing-kw)
                     #:reserve    (or (assq-ref o 'reserve) '())
                     #:movable    (or (assq-ref o 'movable) '())
                     #:storable   (or (assq-ref o 'storable) '())
                     #:whole      (or (assq-ref o 'whole) '())
                     #:tau        (or (assq-ref o 'tau) 0.0)
                     #:willing?   (and (assq-ref o 'willing-only) (willing-predicate root))
                     #:agent-position (agent-position-predicate root)
                     #:horizon    (demand-horizon (or (assq-ref o 'demand) '()) o)
                     #:backend 'native-c)
                   (lambda (al) (success (cache-solve! cache scope-id (or (assq-ref o 'demand) '()) al)))
                   #:catch (lambda (e) (failure (format #f "~a" e))))))))))

      ;; NON-BINDING provenance read: trace a prose CLAIM to what this scope's convex
      ;; solve produced. The bridge (playnet lang provenance) stays decoupled; here we
      ;; inject the live plan (its rents μ) and recipe store. A legal aspect is
      ;; STRUCTURAL — it reports which recipes it gates, not a slack — so `numbers` is
      ;; empty for a legal claim and populated for a commodity one. The `#` in a
      ;; claim's tag (grounds: REF#ID) is what names the id we join on. See
      ;; docs/planning/provenance-bridge.md.
      ((explain scope-id claim)
       (with-scope scope-id
         (lambda (root)
           (catch-as-failure
             (lambda ()
               (let* ((rs   ($ root 'recipe-store))
                      (sym  (if (string? claim) (string->symbol claim) claim)))
                 ;; pure-Scheme backend: explain is a read/debug path, no FFI dep
                 (on-plan (plan-fn* root scope-id #:backend 'native)
                   (lambda (plan)
                     (success
                       (explain-claim sym plan
                         #:pull-of (make-pull-of plan)
                         #:gated-by (lambda (aspect) (recipes-conforming rs aspect)))))
                   #:catch (lambda (e) (failure (format #f "~a" e))))))))))

      ;; Wire-safe COMPACT summary for the browser orb: satisfaction, the social
      ;; ledger (L, free time), the loudest pulls (the duals λ), and the
      ;; near-optimality certificate — every number stringified (the dial's JSON
      ;; writer emits integers only). The orb NARRATES this; it never redraws the
      ;; dial, so there is no PLAN-shape mapping. NON-BINDING; (solve-brief id '())
      ;; is the current plan, (solve-brief id ((demand . …))) a what-if.
      ((solve-brief scope-id overrides)
       (with-scope scope-id
         (lambda (root)
           (catch-as-failure
             (lambda ()
               ;; overrides: a JSON string (browser orb) or an alist (Scheme) →
               ;; symbol-keyed plan-scope inputs. Parsing + prose live in (playnet
               ;; planner brief) — pure, so they unit-test without a vat/scope.
               (let ((o (parse-overrides overrides)))
                 (on-plan
                   (plan-fn* root scope-id
                     #:demand     (demand->keyed (or (assq-ref o 'demand) '()))
                     #:eco-caps   (or (assq-ref o 'eco-caps) '())
                     #:reserve    (or (assq-ref o 'reserve) '())
                     #:tau        (or (assq-ref o 'tau) 0.0)
                     #:agent-position (agent-position-predicate root)
                     #:horizon    (demand-horizon (or (assq-ref o 'demand) '()) o)
                     #:backend 'native-c)
                   (lambda (full)
                     ;; No demand override means the orb asked for the CURRENT plan,
                     ;; not a what-if — and the current plan is exactly what the
                     ;; snapshot's plan/schedule wires serve, so it lands in the
                     ;; same cache the `solve` verb fills. A what-if stays unstored.
                     (unless (pair? (or (assq-ref o 'demand) '()))
                       (cache-solve! cache scope-id '() full))
                     (success (plan-brief->string full)))
                   #:catch (lambda (e) (failure (format #f "~a" e))))))))))

      ;; the declaration-time read: what one unit of SPEC currently displaces
      ;; elsewhere in the plan, off the scope's LAST solve's duals (its
      ;; `good-pulls` μ — solve/externality.scm `marginal-displacement` over
      ;; provenance-trace's `make-pull-of`). Shown BEFORE a citizen states a kind
      ;; and level, so what asking moves is visible while the ask is still being
      ;; shaped. No re-solve, no identity, nothing written; a scope with no
      ;; cached solve reads nothing (read? #f) — the same silence spec-met keeps.
      ((need-displacement scope-id spec qty)
       (catch-as-failure
         (lambda ()
           (let* ((cached   (last-solve-ref cache scope-id))
                  (pull-of (and cached (make-pull-of (cdr cached))))
                  (mu       (and pull-of (pull-of spec)))
                  (q        (if (and (number? qty) (> qty 0)) (exact->inexact qty) 1.0))
                  ;; the burn-meter's read of the same spec: how often it was
                  ;; read across the kept solves and the mean of what it
                  ;; moved — the "lately" beside the live read
                  (lately (and mu
                               (let ((s (find (lambda (r) (equal? (assq-ref r 'spec) spec))
                                              (assq-ref (moved-summary (externality-history-ref cache scope-id))
                                                        'specs))))
                                 (and s `((solves . ,(assq-ref s 'solves))
                                          (mean-moved . ,(assq-ref s 'mean-moved))))))))
             ;; the HONESTY RADIUS, read off the same solve: the certificate's
             ;; strong-convexity modulus σ bounds how far ANY rewrite of a
             ;; citizen's asks can move the plan — ‖Δplan‖ ≤ 2·W·v/σ
             ;; (deviation_gain_le, InTheLarge.lean; W = one whole hand,
             ;; reported at v = 1 and scaled by the reader's voice). The same
             ;; σ, composed with the certificate's OWN residual ‖r‖ (never
             ;; zero — the solver reports an ε-KKT point, not an exact one),
             ;; bounds how far the certified plan can already sit from the
             ;; exact optimum: ‖r‖/σ (dist_from_optimum_of_curvature_gap,
             ;; InTheLarge.lean) — the honest floor beneath the radius above,
             ;; shown alongside it rather than folded silently in. The
             ;; certificate states both bounds, per solve.
             ;; L_Φ — the term map's own Lipschitz constant. The shipped cap
             ;; shape emits an owned want through a zero-labour delivery
             ;; column whose own coefficient on the good is exactly 1.0
             ;; (claim-recipes, live.scm), so the wall's whole
             ;; coefficient vector has norm 1 and L_Φ is exactly
             ;; 1/cap-scale-of(spec) — the shown radius needed no correction
             ;; at the catalogue's default scale of 1.0, and now carries the
             ;; exact one where a spec's scale is governed away from it. The
             ;; `des` shape's squared-gap term has a different, unproven
             ;; L_Φ, so the correction applies only under the cap default.
             (let* ((cert  (and cached (or (assq-ref (cdr cached) 'certificate) '())))
                    (sigma (assq-ref cert 'sigma))
                    (rnorm (assq-ref cert 'residual))
                    (lphi  (if (want-as-cap?) (/ 1.0 (cap-scale-of spec)) 1.0))
                    (honesty (and (number? sigma) (> sigma 0)
                                  `((sigma . ,sigma)
                                    (l-phi . ,lphi)
                                    (radius-whole-hand . ,(/ (* 2.0 lphi *desire-w0*) sigma))
                                    ,@(if (and (number? rnorm) (>= rnorm 0))
                                          `((solve-tolerance . ,(/ rnorm sigma)))
                                          '())))))
               (success
                (if mu
                    `((read? . #t) (per-unit . ,mu)
                      (moved . ,(marginal-displacement pull-of (list (cons spec q))))
                      ,@(if lately `((lately . ,lately)) '())
                      ,@(if honesty `((honesty . ,honesty)) '()))
                    `((read? . #f)
                      ,@(if honesty `((honesty . ,honesty)) '()))))))))))))
