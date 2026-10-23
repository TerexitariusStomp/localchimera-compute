;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; economy/demand-fold.scm — the scope tree's declared needs → a solve's demand
;;;
;;; A citizen declares a need on the share face and it lands as a standing
;;; `<intent>` with receiver = them (`need:AID:SPEC`, planner service.scm). This
;;; is the other end of that wire: the demand a solve answers for is the sum of
;;; those needs over the subtree of the root being planned.
;;;
;;; It is the federation fold (vf/aggregation/fold-node.scm) over demand's three
;;; pieces:
;;;
;;;   monoid   quantities summed by cell (the shared `sum-by-key`)
;;;   writes   needs-changed: re-read this scope's own needs
;;;   reads    demand-for: project the total onto a solve's periods
;;;
;;; ── The cell is (spec, place, window) — never a period ─────────────────────
;;;
;;; A standing aggregate cannot be keyed by PERIOD: the horizon is laid out per
;;; solve (`set-daily-horizon!`), so a period number decided when a need was
;;; declared means something else by the next solve. So what rises through the
;;; tree is `spec ⇥ place ⇥ from ⇥ until` — horizon-independent — and
;;; `demand-for` projects it onto whatever periods the solve has, at read time.
;;;
;;; ── The place is resolved where the person is known ────────────────────────
;;;
;;; A need that names no place ("anywhere", the share face's default) is located
;;; at its person's HOME by the scope that holds it. Not by their trajectory:
;;; that would make the cell depend on the horizon again, and it would require
;;; knowing WHOSE need it is at read time — which is exactly what must not
;;; travel. Someone who wants provisioning where they will be says so; the
;;; share face's place picker and its `here` chip are that act.
;;;
;;; ── What crosses a boundary is a total ─────────────────────────────────────
;;;
;;; The summing happens where the needs live, so a parent never reads a member's
;;; plan-store and the receiver's AID never survives into a key. Folding a need
;;; up to a wider root discloses how much of a thing is wanted where, and
;;; nothing about who wants it — which is why needs fold freely where a custody
;;; grant does not (a grant names its counterparty; a need names no one).
;;;

(define-module (playnet economy demand-fold)
  #:use-module (srfi srfi-1)
  #:use-module (playnet pools credit-fold)
  #:use-module (playnet vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (playnet utils clock)
  #:use-module ((playnet utils clock) #:select ((now . clock-now)))   ; the clock's now under a name no local `now` shadows
  #:use-module (playnet vf aggregation fold-node)
  #:use-module (playnet scope live)
  #:use-module ((playnet vf facts person-facts) #:select (declared-need?))
  #:use-module (playnet vf aggregation scope-tree)
  #:use-module ((playnet pools credit-fold) #:select (consumer-voices))   ; every holder's voice off one reading
  #:use-module (playnet vf facts tension-terms)
  #:use-module ((playnet solve emphasis) #:select (emphasis-masses fill-default))  ; the spec's law: shares × voice
  #:use-module ((playnet solve engine) #:select (*desire-w0*))
  #:use-module ((playnet vf facts located) #:select (cell lg))
  #:use-module ((playnet solve ingest) #:select (owned-spec resource-window-hours))         ; one citizen's whole emphasis; the citizen's own good
  #:use-module (goblins)
  #:export (%cell-sep %demand-key %demand-key-parts %need-cells %need-cell %declared-need?
            %needs-of-plan-store scope-own-demand demand-monoid %live-in-period?
            demand-for demand-terms-for demand-reads %apply-need %prune-empty demand-writes
            ^demand-node scope-subtree-demand wire-demand-node! demand-of
            federation-home-of federation-voice-of name-own-rows %iso-epoch demand-cells-of cells->horizon
            demand-scope-horizon merge-demand))

(define %cell-sep #\tab)                   ; term ids never contain a tab

;; ── The cell carries the KIND, and its emphasis rides as a twin cell ───────
;;
;; A need is a right, a need or a want (tension-terms.scm), and wants and held
;; needs carry attached VOICE — the citizen's stated emphasis. The kind is a
;; partition of the total, so it is part of the KEY — `spec ⇥ place ⇥ from ⇥
;; until ⇥ kind` — and the same keyed sum folds rights, needs and wants as
;; three totals. The emphasis folds as the spec's social desire (playnet.typ
;; §Desire as harmony, solve/emphasis.scm): at the owning scope, where the citizen
;; is still known, their attachments are normalised to a SIMPLEX — shares of
;; one across everything they want — scaled by their consumer voice, and the
;; masses sum into a TWIN cell under `… ⇥ kind ⇥ w`. A parent reads a cell's
;; whole emphasis without anyone's name; a citizen's influence on a shared
;; cell is exactly their share of their own hand, weighted by their voice —
;; linear, so a coalition places what its members place, however split. A row
;; graded on the legacy level ladder enters the hand as β^level × qty, the
;; same statement on the older rungs.
;;
;; A four-part key (every cell stored before this vocabulary) reads as a want
;; at level 0, which is what it always was.
(define (%demand-key spec place from until . kind)
  (string-join (append (list spec place (or from "") (or until ""))
                       (if (pair? kind) (list (symbol->string (car kind))) '()))
               (string %cell-sep)))
(define (%demand-key-parts k)
  "(spec place from until kind twin?) — kind a symbol, twin? #t for the Σw·q cell."
  (let ((p (string-split k %cell-sep)))
    (and (<= 4 (length p) 6)
         (list (list-ref p 0) (list-ref p 1)
               (let ((f (list-ref p 2))) (and (not (string-null? f)) f))
               (let ((u (list-ref p 3))) (and (not (string-null? u)) u))
               (if (>= (length p) 5) (kind-string->symbol (list-ref p 4)) 'des)
               (and (= (length p) 6) (equal? (list-ref p 5) "w"))))))
(define (%twin-key k) (string-append k (string %cell-sep) "w"))
(define (%twin-cell? k) (string-suffix? (string-append (string %cell-sep) "w") k))

;; ── one intent → its (spec, place, window, kind) cell + weight twin, or '() ─
;; HOME-OF is (aid → place-id or #f), read locally where the person is known.
(define* (%need-cells i home-of #:optional (owned? #f))
  (let* ((spec  (let ((s (intent-resource-conforms-to i)))
                  ;; OWNED?: a want a citizen states for themselves is keyed on
                  ;; THEIR good, "spec~aid" — the scope's own rows, named, for
                  ;; the scope's own solve (name-own-rows). Rights and held
                  ;; needs stay the scope's aggregate.
                  (if (and owned? s (intent-receiver i)
                           (eq? (tension-kind-of (intent-resource-classified-as i)) 'des))
                      (owned-spec s (intent-receiver i))
                      s)))
         (m     (or (intent-resource-quantity i) (intent-effort-quantity i)))
         (qty   (and m (measure-has-numerical-value m)))
         (place (or (intent-at-location i)
                    (and home-of (intent-receiver i) (home-of (intent-receiver i)))))
         (cats  (intent-resource-classified-as i))
         (kind  (tension-kind-of cats)))
    (if (and spec qty (> qty 0) place)
        (let* ((k (%demand-key spec place (intent-has-beginning i) (intent-has-end i) kind))
               ;; the twin's RAW value — the citizen's stated attachment
               ;; (tension-mass-of: voice, else a legacy ladder row), and for
               ;; a held need nobody graded, the quantity itself. Raw:
               ;; %cells-of normalises it into the citizen's hand. A want with
               ;; nothing stated carries NO twin — the fold's read fills it
               ;; with the aggregate (demand-terms-for). A right takes no
               ;; voice and enters no hand (family.scm's rule): a floor is a
               ;; wall, read from its quantity cell alone, so it never dilutes
               ;; the shares of the wants beside it.
               (raw (or (tension-mass-of cats qty)
                        (and (eq? kind 'held) qty)))
               ;; a right stated `against:Γ` lays its budget cell beside itself:
               ;; the same spec/place/window under kind budget, valued Γ. The
               ;; fold reads the pair as one floor held against any Γ sources
               ;; lost (demand-terms-for → #:budgeted-floors). Two citizens'
               ;; statements on one cell add, as every cell does: the floor
               ;; then defends against the sum — the conservative reading.
               (against (and (eq? kind 'floor) (tension-against-of cats)))
               (budget (if against
                           (list (cons (%demand-key spec place (intent-has-beginning i) (intent-has-end i) 'budget) against))
                           '())))
          (append (if raw (list (cons k qty) (cons (%twin-key k) raw)) (list (cons k qty))) budget))
        '())))
(define (%need-cell i home-of)            ; the quantity cell alone (readers that want one)
  (let ((cs (%need-cells i home-of))) (and (pair? cs) (car cs))))

;; ── the cells of a set of needs held by ONE scope — the fold's one law ─────
;; Quantities sum as they are. Emphasis goes through solve/emphasis.scm: each
;; citizen's raw attachments become their simplex, scaled by VOICE-OF (their
;; relative consumer voice, 1 = an equal citizen; #f = no voice known = equal),
;; one whole hand = *desire-w0*. Every path that turns needs into cells — the
;; seed, the repair, the incremental apply — is this function over some set,
;; which is what keeps them one value.
(define* (%cells-of needs home-of voice-of #:optional (owned? #f))
  ;; an intent lays its quantity cell, its twin (the attachment, read by
  ;; key: `…|w`), and — a right stated `against:Γ` — its budget cell; every
  ;; cell that is not the twin sums as a quantity, the twin alone is emphasis
  (let* ((per    (map (lambda (i) (cons i (%need-cells i home-of owned?))) needs))
         (qcells (append-map (lambda (p) (filter (lambda (c) (not (%twin-cell? (car c)))) (cdr p))) per))
         (rows   (filter-map (lambda (p)
                               (let ((tw (find (lambda (c) (%twin-cell? (car c))) (cdr p))))
                                 (and tw (list (intent-receiver (car p)) (car tw) (cdr tw)))))
                             per))
         (masses (emphasis-masses rows (or voice-of (lambda (_) 1.0)) *desire-w0*)))
    (sum-cells (append qcells (map (lambda (m) (cons (cadr m) (caddr m))) masses)))))

;; What counts as a citizen's declared need is asked in exactly ONE place
;; (planner/facts/person-facts.scm), so the incremental path, the full re-read and
;; the partition guard cannot come to differ about it.
(define %declared-need? declared-need?)

(define (%needs-of-plan-store ps)
  "The live standing needs a scope holds."
  (filter %declared-need? ($ ps 'all-intents)))

(define* (scope-own-demand scope-root #:key (home-of #f) (voice-of #f))
  "One scope's OWN contribution to the fold: the declared needs its plan-store
   holds, summed per (spec, place, window), their emphasis folded as social
   desire (%cells-of). The value that rises to its parent — a total, with no
   one's name in it."
  (%cells-of (%needs-of-plan-store ($ scope-root 'plan-store)) home-of voice-of))

(define demand-monoid keyed-sum-monoid)

(define* (name-own-rows cells scope-root #:key (home-of #f) (voice-source #f)
                        (voice-of (federation-voice-of scope-root voice-source)))
  "CELLS (a subtree's standing total, everyone summed) with THIS scope's own
   want rows named: each citizen's want keyed on their own good \"spec~aid\",
   its twin their own mass — so the scope's solve feels a want on the good
   it delivers to that citizen, and a padded quantity moves only the
   padder's term (truth-telling.md, the path to dominance at scale). The
   scope reads its own plan-store, which it owns; what climbed from below
   stays summed, and what climbs from here is untouched (scope-own-demand)
   — the AID never crosses a fold. Rights and held needs stay aggregate.
   VOICE-OF defaults to the scope's own voice off its root — the function
   `wire-demand-node!` wrote the cells with — so the read side subtracts
   exactly what the write side added."
  (let ((needs (%needs-of-plan-store ($ scope-root 'plan-store))))
    (%prune-empty
     (sum-cells (append cells
                        (map (lambda (c) (cons (car c) (- (cdr c)))) (%cells-of needs home-of voice-of))
                        (%cells-of needs home-of voice-of #t))))))

;; ── projection: the standing cells → a particular solve's periods ──────────

(define (%live-in-period? from until t)
  "Does a need's [from, until] reach period T? ISO days order
   lexicographically, so the overlap test needs no epoch arithmetic. An
   UNBOUNDED need is live in every period — that is what makes it standing, and
   what makes it felt in period 3 rather than only today. A solve with no spans
   laid out (single-period planning) has no bounds to test against."
  (let* ((span  (period-span t))
         (day   (lambda (s) (and (string? s) (not (string-null? s))
                                 (substring s 0 (min 10 (string-length s))))))
         (start (day (car span)))
         (end   (day (cdr span)))
         (f     (day from))
         (u     (day until)))
    (or (not (and start end))
        (and (or (not f) (string<=? f end))
             (or (not u) (string>=? u start))))))

(define (%located-key parts t)
  (lg (list-ref parts 0) (cell (list-ref parts 1) t)))
(define (%project cells periods keep?)
  "CELLS whose parts satisfy KEEP?, projected onto PERIODS as ((\"spec#place@t\" . v) …)."
  (sum-cells
   (append-map
    (lambda (cell)
      (let ((parts (%demand-key-parts (car cell))) (v (cdr cell)))
        (if (not (and parts (keep? parts)))
            '()
            (filter-map
             (lambda (t)
               (and (%live-in-period? (list-ref parts 2) (list-ref parts 3) t)
                    (cons (%located-key parts t) v)))
             periods))))
    cells)))
(define (demand-for total periods)
  "TOTAL (the fold's cells) projected onto PERIODS, in the keyed form
   `plan-scope` consumes — ((\"spec#place@t\" . qty) …): the WANTS, which is
   what #:demand has always meant. The one place a period number is decided,
   and it is decided at read time against the horizon the solve actually laid
   out. The rights and the held needs come out of `demand-terms-for`."
  (%project total periods (lambda (p) (and (eq? (list-ref p 4) 'des) (not (list-ref p 5))))))
(define (demand-terms-for total periods)
  "TOTAL projected onto PERIODS as every term a solve takes from the fold:
     ((demand . ((g . q) …))            the wants                → #:demand
      (desire-weights . ((g . w) …))    social desire per want   → #:desire-weights
      (repro-floors . ((g . q) …))      the rights               → #:repro-floors
      (budgeted-floors . ((g q Γ) …))   rights held against any Γ sources lost → #:budgeted-floors
      (insurance . ((g 0 q 1.0 w) …)))  the held needs: wall at zero, at ease at
                                        q, felt at their emphasis → #:insurance
   A cell's weight is its twin — the citizens' shares of their own hands,
   scaled by their voices and summed (solve/emphasis.scm) — the engine's whole
   mass on the good. A want cell nobody weighted takes the mean of the
   weighted ones (the spec's default: the aggregate stands); where nobody
   has weighted anything, no weight is handed over and the engine's own
   default is the whole of the information. A four-part (legacy) cell is a
   want at weight 1."
  (define (of kind) (%project total periods (lambda (p) (and (eq? (list-ref p 4) kind) (not (list-ref p 5))))))
  (define (wq kind) (%project total periods (lambda (p) (and (eq? (list-ref p 4) kind) (list-ref p 5)))))
  (let* ((wants (of 'des)) (held (of 'held))
         (w-wants (fill-default (map car wants) (wq 'des)))
         (w-held  (fill-default (map car held)  (wq 'held)))
         ;; a floor with a budget cell beside it is a BUDGETED floor: (g q Γ)
         ;; → #:budgeted-floors, and it leaves #:repro-floors — the budget
         ;; row carries the quantity (engine lay-budgeted-floors)
         (budgets (of 'budget))
         (floors  (of 'floor))
         (budgeted (filter-map (lambda (f) (let ((g (assoc-ref budgets (car f))))
                                             (and g (list (car f) (cdr f) g))))
                               floors))
         (bare (filter (lambda (f) (not (assoc-ref budgets (car f)))) floors)))
    `((demand . ,wants)
      (desire-weights . ,w-wants)
      (repro-floors . ,bare)
      (budgeted-floors . ,budgeted)
      (insurance . ,(map (lambda (c) (list (car c) 0.0 (cdr c) 1.0 (assoc-ref w-held (car c)))) held)))))
(define demand-reads
  `((demand-for . ,(lambda (total periods) (demand-for total periods)))
    (cells      . ,(lambda (total) total))))

;; ── applying ONE change, and re-reading EVERYTHING ─────────────────────────
;; The same relationship the tree has, one level down: the full re-read is the
;; DEFINITION of a scope's own value, and applying a single change is its
;; incremental evaluation. They agree because both are %cells-of over sets of
;; needs, and a change to one citizen's row changes exactly that citizen's
;; hand: their shares re-normalise, nobody else's move. So the apply replaces
;; one hand — subtract the citizen's cells as they were, add them as they are.
;;
;; The citizen's OTHER rows are read from the store; the row that changed is
;; taken from the event, never the store. `on-intent-change` fires from inside
;; the write, so whether the store has committed this row yet is exactly what
;; must not matter: the other rows are the same either way, and the event
;; carries this one whole. Editing a need arrives as a removal then an
;; addition (declare-need re-declares through the deterministic id), so a
;; moved cell empties and a new one fills, with nothing left at the old key.
(define (%apply-need own intent action home-of voice-of scope-root)
  (if (not (%declared-need? intent))
      own
      (let* ((aid    (intent-receiver intent))
             (id     (intent-id intent))
             (others (filter (lambda (i) (and (equal? (intent-receiver i) aid)
                                              (not (equal? (intent-id i) id))))
                             (%needs-of-plan-store ($ scope-root 'plan-store))))
             (hand   (lambda (with-this?)
                       (%cells-of (if with-this? (cons intent others) others) home-of voice-of)))
             (old    (hand (eq? action 'removed)))
             (new    (hand (not (eq? action 'removed)))))
        (%prune-empty
         (sum-cells (append own
                            (map (lambda (c) (cons (car c) (- (cdr c)))) old)
                            new))))))

;; A cell that has fallen to nothing is not a cell wanted in zero quantity —
;; it is a want that went away, and it should stop occupying a key.
(define (%prune-empty cells)
  (filter (lambda (c) (> (cdr c) 0)) cells))

(define demand-writes
  `(;; apply one change — the fast path, and the one the live wire uses
    (need-changed  . ,(lambda* (own intent action home-of #:optional (voice-of #f) (scope-root #f))
                        (%apply-need own intent action home-of voice-of scope-root)))
    ;; re-read this scope's needs entire — the seed, and the repair. The scope
    ;; is handed its OWN root, so nothing outside it is ever read.
    (needs-changed . ,(lambda* (own scope-root home-of #:optional (voice-of #f))
                        (scope-own-demand scope-root #:home-of home-of #:voice-of voice-of)))))

;; A scope's demand aggregate: its OWN declared needs, with its members' totals
;; held keyed beside them — so a refederation is a drop and a delivery.
(define ^demand-node
  (fold-aggregate demand-monoid demand-reads demand-writes #:prefix "demand"))

;; ── the pull: the same fold, as its definition ─────────────────────────────

(define* (scope-subtree-demand scope periods #:key (home-of #f) (voice-of #f))
  "The demand a solve rooted at SCOPE answers for, read straight off the live
   tree. This is what a node's standing total MEANS — the same monoid folded in
   a different order — so it is both the specification the push is checked
   against and the way a node is seeded or repaired.

   The SUM is the point. Ten people wanting one loaf each in one place is
   demand for ten loaves there, and the individuals do not survive into the
   key — so this is both the aggregation and the anonymisation.

   Which root you fold decides the extent: fold a commune and the walk reaches
   its members; fold the commons and it reaches everyone under it."
  (demand-for
   (fold-tree-total demand-monoid scope
                    (lambda (root) (scope-own-demand root #:home-of home-of #:voice-of voice-of)))
   periods))

;;; ── wiring a scope into the fold ───────────────────────────────────────────

(define* (wire-demand-node! scope-root node
                            #:key (home-of #f) (voice-source #f)
                                  (voice-of (federation-voice-of scope-root voice-source))
                                  (parent #f) (scope-id #f) (schedule #f))
  "Wire a scope's demand node into the federation fold:
     1. plan-store on-intent → this node re-reads its OWN needs
     2. this node hands its TOTAL up to PARENT, keyed by SCOPE-ID
   SCOPE-ID is the key the parent files this subtree under, so it can be
   dropped exactly when the scope refederates (`fold-node-reparent!`).
   SCHEDULE (from `make-fold-coalescer`) makes a burst of declarations cost one
   climb instead of one per need. Seeds OWN immediately, so a node is correct
   from the moment it is wired rather than from the first change after it.

   VOICE-OF (emphasis × consumer voice, solve/emphasis.scm) defaults to the voice off
   VOICE-SOURCE (the federation's credit node) or, absent one, the scope's own
   subtree — the same default `name-own-rows` reads with.

   The plan-store fires on EVERY intent — a declared need, a retired one, and
   also work intents and materialized suggestions this fold ignores. The refold
   re-reads the store rather than trusting the event, so an irrelevant one costs
   a re-read and changes nothing."
  (when schedule ($ node 'set-schedule schedule))
  ;; The change event carries the intent AND what happened to it, so the node
  ;; applies it directly — no store read, and therefore no dependence on
  ;; whether the write that fired this has committed yet.
  ($ ($ scope-root 'plan-store) 'add-intent-listener
     (lambda (intent action) ($ node 'need-changed intent action home-of voice-of scope-root)))
  ($ node 'needs-changed scope-root home-of voice-of)   ; seed NOW from what is already declared
  (wire-fold-parent! node parent scope-id))

(define* (demand-of source periods #:key (home-of #f) (voice-of #f))
  "The demand from either end of the same fold: a standing ^demand-node is
   READ, a live ^scope is WALKED. One call site, so a solve never has to know
   which end it was handed."
  (or (false-if-exception ($ source 'demand-for periods))
      (scope-subtree-demand source periods #:home-of home-of #:voice-of voice-of)))

;; ── a citizen's home, read off the SAME tree a need's demand is ────────────
;;
;; A need naming no place resolves at its person's home (%need-cell, above) —
;; but only where a caller SUPPLIES a #:home-of, and one was never derived: a
;; placeless need silently dropped out of demand rather than reaching a home
;; nobody looked up. The lookup does not need a new channel; a citizen's home
;; is exactly what their OWN agent record already says (agent-primary-
;; location), and that record lives on some scope's agent-store somewhere in
;; the very subtree demand-of is already walking — scope-subtree-collect (the
;; general "gather a list off every scope" walk demand-cells-of's own tree-
;; fold sits beside) reads it the same way, once, and needs no scope to have
;; been visited twice for it to agree with itself.

;; A reading recomputed at most once a SECOND of the clock: a refold burst (a
;; landing lays hundreds of shifts, each one a refold) pays one walk of the
;; tree, never one per need — a per-need walk held the vat for minutes after a
;; solve (found live). → a thunk answering THUNK's latest value.
(define (fresh-each-second thunk)
  (let ((at #f) (value #f))
    (lambda ()
      (let ((now (clock-now)))
        (unless (eqv? at now) (set! at now) (set! value (thunk)))
        value))))

(define* (federation-home-of scope)
  "An (aid → home place) function, read fresh off SCOPE's whole subtree — one
   entry per agent, wherever in the federation their own record lives. The
   default #:home-of for plan-commune-scope's demand fold, so a need naming no
   place resolves at its citizen's actual home rather than contributing
   nothing.

   A citizen with NO agent record anywhere in the subtree — a browser-born AID
   that has not yet declared a position — resolves to the subtree's own first
   known place: their need is felt AT THE COMMUNE until they say where they
   live. A subtree that knows no place at all resolves to \"hearth\" — a
   synthetic place, one ordinary label to the solve (an EMPTY place is not:
   \"spec#@0\" is a cell the engine cannot parse, and the demand keyed there
   fills 0 while the same demand at any named label fills). Without these
   floors every such need dissolves out of the fold, and a fresh commune of
   fresh citizens plans an empty day no matter what anyone declares."
  ;; READ FRESH, per call: the table and the hearth are taken off the tree
  ;; when a need is resolved, never when the resolver is made — a resolver
  ;; made at wire time, before a boot's seeds land, froze an empty subtree
  ;; (and the placeholder) into every later resolution (found live).
  (define (hearth)
    ;; the commune's hearth is a CELL: a place that holds stock — the
    ;; first the subtree's observers name — so a need felt there has
    ;; columns to pull on. A declared place that holds nothing (the
    ;; biosphere, the shed, a bare label) is no cell, and a want keyed
    ;; there stood on a phantom the program could not clear (found live:
    ;; citizens' wants at a placeholder starved the whole plan).
    (let* ((stocked (delete-duplicates
                     (scope-subtree-collect scope
                       (lambda (root)
                         (filter-map economic-resource-current-location
                                     ($ ($ root 'observer) 'all-resources))))))
           (places  (scope-subtree-collect scope
                      (lambda (root)
                        (map spatial-thing-id
                             ($ ($ root 'spatial-thing-store) 'all-locations))))))
      (cond ((pair? stocked) (car stocked))
            ((pair? places) (car places))
            (else "hearth"))))
  (let ((read (fresh-each-second
               (lambda ()
                 (cons (hearth)
                       (let ((h (make-hash-table)))
                         (for-each (lambda (pair) (hash-set! h (car pair) (cdr pair)))
                                   (scope-subtree-collect scope
                                     (lambda (root)
                                       (filter-map (lambda (a) (and (agent-primary-location a)
                                                                    (cons (agent-id a) (agent-primary-location a))))
                                                   ($ ($ root 'agent-store) 'all-agents)))))
                         h))))))
    (lambda (aid)
      (let ((r (read)))
        (or (hash-ref (cdr r) aid #f) (car r))))))

;; ── a citizen's voice, read off the SAME tree a need's demand is ───────────
;;
;; The spec scales a citizen's emphasis by their consumer voice (playnet.typ
;; §The credit identity: contribution by ability + citizenship, converging
;; to the equal share as social free time rises). It is a standing, read where
;; it lives — the account layer over the subtree's roots, the same walk
;; federation-home-of makes for a home — never stored beside the need.
;; Relative: 1 = an equal citizen (the federation share × the citizen count),
;; so a fresh table with no labour ledger reads everyone at one — no credit
;; identity yet is no information, and solve/emphasis.scm reads #f as equality.

(define* (federation-voice-of scope #:optional (source #f))
  "An (aid → relative consumer voice) function over SCOPE's subtree: the
   citizen's share of the claimable pool, scaled so an equal citizen reads
   1; #f where the pool is empty (no confirmed plan yet), which the fold
   reads as equal. SOURCE, a credit node (or a list of roots), is the pool the
   share is read against instead: the FEDERATION's, so a citizen's voice is
   theirs however many scopes there are and wherever they are at home, not a
   share of whichever subtree their need happens to sit in. Read once a
   second off one reading of the holders, never re-summed per need."
  (let* ((src (or source (scope-subtree-collect scope (lambda (root) (list root)))))
         (read (fresh-each-second
                (lambda ()
                  (cons (or (false-if-exception (consumer-voices src)) '())
                        (or (false-if-exception (global-citizen-count src)) 0))))))
    (lambda (aid)
      (let* ((r (read)) (v (assoc-ref (car r) aid)))
        (and v (* v (cdr r)))))))

;; ── arcs → periods: the horizon a solve needs, decided before any period
;; exists to project onto ─────────────────────────────────────────────────
;;
;; demand-for needs PERIODS to project a standing cell onto; deriving how
;; MANY periods a horizon needs from a period-keyed demand list is exactly
;; the chicken looking for its egg. The fold's own cells sidestep it — they
;; are keyed by real ISO dates (`from`/`until`), independent of any solve —
;; so the horizon a caller needs is read straight off the SAME standing
;; cells `demand-of` will later project, before any period is decided.

(define (%iso-epoch s)   ; the same one clock set-daily-horizon! itself reads
  (civil->instant (substring s 0 (min 10 (string-length s)))))

(define* (demand-cells-of source #:key (home-of #f) (voice-of #f))
  "The RAW (spec,place,from,until)→qty cells from either end of the fold, no
   period projection — a standing ^demand-node is READ, a live ^scope is
   WALKED, same dispatch as demand-of."
  (or (false-if-exception ($ source 'cells))
      (fold-tree-total demand-monoid source
        (lambda (root) (scope-own-demand root #:home-of home-of #:voice-of voice-of)))))

(define* (cells->horizon cells #:key (today #f))
  "The pure half of demand-scope-horizon: how many daily periods, starting
   TODAY (default: today, real date), a solve needs to reach the FURTHEST
   bounded `until` any of CELLS names — (start . n), the shape #:horizon
   already takes. NO cells at all still answers (start . 1): a scope with
   nothing declared still deserves a DATED day, for the same reason a
   standing need does — a schedule row emitted from an unlaid period
   carries the empty `when` no calendar can place. An UNBOUNDED need (no
   `until`) is demanded at every period regardless of how many are laid out —
   that is what makes it standing — so it does not by itself ask for more
   than one; only a need that named its own end can widen the horizon, the
   same way a caller's own #:horizon always could. It DOES still ask for that
   one period to be DATED: standing needs alone yield (start . 1), today on
   the real clock, so every schedule row the solve emits carries a calendar
   coordinate instead of the empty `when` an unlaid period leaves behind.
   A need that starts in the past or today contributes at least period 0; one
   starting later still needs a horizon long enough to REACH it, so a start
   date counts the same as an end date for how far out the horizon must run.

   Takes CELLS already fetched rather than a source to walk, so a caller who
   also needs the projected demand (plan-commune-scope) reads the subtree
   once and derives both from it, instead of walking it twice."
  (let* ((start   (or today (instant->civil (now) "%Y-%m-%d")))
         (start-e (%iso-epoch start))
         (day-of  (lambda (d) (and d (max 1 (+ 1 (quotient (- (%iso-epoch d) start-e) 86400))))))
         (spans   (filter-map
                   (lambda (cell)
                     (let ((parts (%demand-key-parts (car cell))))
                       (and parts
                            (let ((f (day-of (list-ref parts 2))) (u (day-of (list-ref parts 3))))
                              (and (or f u) (max (or f 1) (or u 1)))))))
                   cells)))
    (if (pair? spans) (cons start (apply max spans))
        ;; standing needs alone — or NOTHING declared at all — still lay one
        ;; dated day: every row a solve emits then carries a calendar
        ;; coordinate a face can place
        (cons start 1))))

(define* (demand-scope-horizon source #:key (home-of #f) (today #f))
  "cells->horizon off SOURCE's own subtree, walked once for this call — the
   standalone entry point; plan-commune-scope calls cells->horizon directly
   over cells it has already fetched, so its own solve costs one walk, not
   two."
  (cells->horizon (demand-cells-of source #:home-of home-of) #:today today))

;; ── merging a caller's what-if over the fold ───────────────────────────────
;; Merging a scenario INTO the tree's demand is the same operation as merging
;; two scopes' demand, which is the same operation as pooling two members'
;; socialized capacity: the keyed sum. Named here for what it means at this
;; call site.
;;
;; A what-if ADDS to what people actually asked for rather than replacing it, so
;; `solve` with no overrides is the plan for the real demand and `(demand …)`
;; asks what one more want would cost on top of it.
(define merge-demand sum-by-key)
