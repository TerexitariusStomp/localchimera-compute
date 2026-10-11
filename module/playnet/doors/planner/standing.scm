;;; module/playnet/doors/planner/standing.scm — what stands at a scope and above it: the folds and descents read, the snapshot, the legal exterior, the readings, the hands, the burn-meter
;;;
;;; A fragment of the planner service (playnet doors service): a procedure from
;;; the service's context to the doors it serves, composed into every service by
;;; doors/service.scm. `with-planner-ctx` binds the context's fields under their
;;; own names, so each clause reads as it did inside the actor
;;; (docs/planning/codebase-layout.md §12). What this fragment alone reads and
;;; writes is defined here, above its doors.

(define-module (playnet doors planner standing)
  #:use-module ((goblins) #:select ($))
  #:use-module ((playnet doors plan-wire) #:select (build-snapshot))
  #:use-module ((playnet doors planner solve-cache) #:select (externality-history-ref last-solve-ref solve-stale?))
  #:use-module ((playnet knowledge catalogues subsistence) #:select (sub-spec subsistence-species-base))
  #:use-module ((playnet knowledge catalogues substances) #:select (leaf-substitutes))
  #:use-module ((playnet knowledge law snapshot-build) #:select (law-snapshot-string rules-with))
  #:use-module ((playnet pools reading-fold) #:select (node-readings-reply readings-between-reply))
  #:use-module ((playnet scope live) #:select (gather-recipes scope-food-specs))
  #:use-module ((playnet solve externality) #:select (moved-summary))
  #:use-module ((playnet utils common) #:select (string-or-false))
  #:use-module ((playnet utils envelope) #:select (catch-as-failure failure success))
  #:use-module ((playnet vf facts parts) #:select (part->string))
  #:use-module ((srfi srfi-1) #:select (append-map))
  #:use-module (playnet doors planner ctx)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (planner-standing-doors))

(define (planner-standing-doors ctx)
  (with-planner-ctx ctx

    (declared-doors planner

      ;; ── the standing deployment reads — the descent's own answer ──
      ;; What the last matching round landed on a scope, without a plan-store
      ;; scan: the descent node's slice. Standing ACCEPTS stay the plan-store's
      ;; to answer (deployment-bindings reads them there): an accept arrives on
      ;; its own rail and outlives any one deployment, so the store is the
      ;; truth for bindings and the node for the round.
      ((deployment-of scope-id)
       (let ((n (node-of scope-id nodes-deployment)))
         (if n ($ n 'deployment) '())))

      ((deployed-hours-of scope-id)
       (let ((n (node-of scope-id nodes-deployment)))
         (if n ($ n 'deployed-hours) 0)))

      ;; ── the standing labour roster reads ──
      ;; labour-total answers over the UC root — every scope's availability ×
      ;; skills, one keyed pool; labour-pool hands back one scope's node for
      ;; finer reads (query/free/by-agent live on the node itself).
      ((labour-pool scope-id) (labour-pool-of scope-id))

      ((labour-total) ($ (nodes-labour uc) 'pool))

      ;; SKILL/CELL+RADIUS/TIME-WINDOW fold into 'total-hours' own keyword-arg
      ;; query (pools/availability-pool.scm pool-query) — built back into that
      ;; shape here since fold-node's own dispatch takes it as a flat plist.
      ;; #:key, not #:optional — pool-total-hours (pools/availability-pool.scm
      ;; pool-query) takes these as real Guile keyword args, and so does every
      ;; existing caller of THIS door ($ svc 'labour-total-hours #:skill "x"),
      ;; a calling convention #:optional cannot match positionally.
      ((labour-total-hours #:key (skill #f) (cell #f) (radius #f) (time-window #f))
       (apply $ (nodes-labour uc) 'total-hours
              (append (if skill (list #:skill skill) '())
                      (if cell (list #:cell cell) '())
                      (if radius (list #:radius radius) '())
                      (if time-window (list #:time-window time-window) '()))))

      ((demand-total periods) ($ (nodes-demand uc) 'demand-for periods))

      ((means-total spec) (means-fold-total spec))

      ((means-rebuild!) (means-rebuild!) 'ok)

      ;; the pool's push rail (see slots-changed! above)
      ((slots-watch scope-id ref)   (slots-watch! scope-id ref)   'ok)

      ((slots-unwatch scope-id ref) (slots-unwatch! scope-id ref) 'ok)

      ((slots-changed! scope-id)    (slots-changed! scope-id)     'ok)

      ;; the folksonomy fold's two ends: the commons' aggregate (the lobby's
      ;; contribution + template surface) and one scope's node
      ((folksonomy-uc) (nodes-folksonomy uc))

      ((folksonomy scope-id) (node-of scope-id nodes-folksonomy))

      ;; the credit fold's two ends: the UC root (every global-* read is a
      ;; method on it) and one scope's node
      ((credit-uc) (nodes-credit uc))

      ((credit scope-id) (node-of scope-id nodes-credit))

      ;; the voice fold's two ends, and the door the governance side hands the
      ;; hands reader through (the rail is its store); a cast refolds the scope
      ((voice-uc) (nodes-voice uc))

      ((voice scope-id) (node-of scope-id nodes-voice))

      ;; the reading fold's two ends, and the door a contrary cast refolds through
      ((readings-uc) (nodes-reading uc))

      ((readings scope-id) (node-of scope-id nodes-reading))

      ;; the face's read of the reading fold: SPEC's cells at this scope's node, every
      ;; technique, act and source apart, and the drift between counts and ledger —
      ;; plain data for the wire (docs/observation/readings-are-counts.md §1.1)
      ((scope-readings scope-id spec)
       (let ((n (node-of scope-id nodes-reading)))
         (if (not n) (failure "no such scope")
             (success (node-readings-reply n spec)))))

      ((observed! scope-id) (refold-readings! scope-id) 'ok)

      ;; the history behind the fold: what every source reported of SPEC between two
      ;; instants, off the scope's own event-sourced observer and the rail's standing
      ;; contrary observations, and what the fold would say from those readings alone
      ((readings-between scope-id spec from until)
       (with-scope scope-id
         (lambda (root)
           (catch-as-failure
             (lambda ()
               (success (readings-between-reply ($ ($ root 'observer) 'standing-log) scope-id spec
                                                (string-or-false from) (string-or-false until)
                                                #:contrary (and contrary-of (contrary-of scope-id)))))))))

      ;; substitution as a reading: the scope's foods ranked by how far each covers
      ;; SPEC's leaves, against the floors a body states
      ((substitutes-for scope-id spec)
       (with-scope scope-id
         (lambda (root)
           (catch-as-failure
             (lambda ()
               (call-with-values (lambda () (gather-recipes ($ root 'recipe-store)))
                 (lambda (procs flows)
                   (success (map (lambda (p) `((spec . ,(car p)) (cover . ,(cdr p))))
                                 (leaf-substitutes spec (scope-food-specs flows)
                                                   #:against (map sub-spec (subsistence-species-base))))))))))))

      ;; the rail's door: the standing hands of SCOPE-ID as rows ((owner part-string portion) …),
      ;; parsed here (parts.scm validate-hand) and refolded at once — what the
      ;; lobby hands over after a cast, and what the wiring seeds from HANDS-OF.
      ((hands! scope-id)
       (catch-as-failure (lambda () (success (refold-voice! scope-id)))))

      ((hands scope-id) (map (lambda (r) (list (car r) (part->string (cadr r)) (caddr r))) (rail-hands scope-id)))

      ((credit-read method . args) (apply $ (nodes-credit uc) method args))

      ;; the slack fold: the commons' desire overlay as one read, or one scope's
      ((slack-uc) (nodes-slack uc))

      ((slack scope-id) (node-of scope-id nodes-slack))

      ((slack-read method . args) (apply $ (nodes-slack uc) method args))

      ;; acting-aid (optional) → the snapshot's `proposals` are the social invites
      ;; directed at that agent. Older callers (tests) pass two args and get none.
      ((scope-snapshot scope-id plan-id #:optional (acting-aid #f))
       (with-scope scope-id
         (lambda (root)
           ;; each recipe's record as the solve takes it (scope-standing): the
           ;; face shows the very record the plan reads
           (let ((st (standing root scope-id)))
              (build-snapshot root scope-id plan-id acting-aid
                              #:cached (last-solve-ref cache scope-id)
                              #:stale? (solve-stale? cache scope-id)
                              #:extra-locations (federation-sibling-locations scope-id root)
                              #:recipe-responses (or (assq-ref st 'responses) '())
                              #:credit-roots (credit-roots acting-aid))))))

      ;; ── The legal exterior, derived LIVE — the law face's snapshot, folded
      ;;    over the activity catalogue (legal-crossings.md §§Law,Dual power) and
      ;;    over the law this planner's communes stand under: the static library
      ;;    with the rules each commune's own registry carries. Returns the JSON
      ;;    string, the shape of the bundled browser/data/snapshots/law-snapshot.json
      ;;    (which is what a seat reads; this door is the operator's).
      ;; budget optional: pass a DERIVED budget (federation-budget over the scopes'
      ;; composed strategy plans) to size the program's bundle to real leverage;
      ;; omit ⇒ the stewarded *program-budget* fallback (no live strategy scopes).
      ((legal-snapshot #:optional (budget #f))
       (let ((rules (rules-with
                     (append-map (lambda (e)
                                   (or (false-if-exception ($ ($ (cdr e) 'legal-registry) 'rules)) '()))
                                 (roster-entries)))))
         (if budget
             (law-snapshot-string #:budget budget #:rules rules)
             (law-snapshot-string #:rules rules))))

      ;; the burn-meter entire: the externality display accumulated per solve
      ;; (note-externalities!, one snapshot per landing) summarized as the
      ;; scope's moved-distribution — stage 0's calibration data, and the
      ;; scope's measured VCG bill (truth-telling.md). A read of standing
      ;; metadata; nothing re-solves.
      ((externality-history scope-id)
       (catch-as-failure
         (lambda ()
           (success (moved-summary (externality-history-ref cache scope-id)))))))))
