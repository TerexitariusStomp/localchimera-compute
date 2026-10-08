;;; test-law-food-in-pompignac.scm — the food the federation already plans,
;;; planned in a real commune under that commune's real law.
;;;
;;; Everything here existed before and had never met: the surplus-recovery chain
;;; (knowledge/recipes/food-surplus.scm — pickup from a donor, sort at 90% yield,
;;; deliver, on a reefer van and volunteer hours) and Pompignac's legal packs.
;;; The recipes are the federation's actual work; the packs are the actual law of
;;; a commune in Gironde. This is the join.
;;;
;;; Two things it settles that argument could not:
;;;
;;;   · The zoning does not touch it. A PLU governs BUILDING, and recovering
;;;     surplus food trips `recover-surplus` and `share-food` — no zone rule can
;;;     fire, so 63% of the commune being agricultural is simply irrelevant to
;;;     whether food may be moved across it. That is the right answer, and before
;;;     the coverage diagnostic it was indistinguishable from a missing rule.
;;;
;;;   · The EU law does. `de.sexp` has carried food-business registration all
;;;     along, guarded on `in-jurisdiction "eu"`, and it reaches Pompignac now
;;;     that France sits under the EU rather than under `world`. So the chain
;;;     meets a real demand — and one nobody wrote for France.
;;;
;;; What it also shows, by absence: no FRENCH rule fires. The habilitation for
;;; food aid, the DDPP registration, the loi Garot donation regime — none of that
;;; is in any pack. The plan runs, and what it runs under is the EU baseline
;;; alone. That gap is the corpus work, and it is visible here rather than
;;; inferred.
;;;
;;; Run: guile -L module tests/planner/test-law-food-in-pompignac.scm

(use-modules (playnet test scope))
(use-modules (playnet test harness) (playnet planner knowledge recipes store) (playnet planner knowledge recipes food-surplus) (playnet planner scope spatial-things) (playnet planner observation observer) (playnet planner scope agents) (playnet planner vf schemas) (srfi srfi-1) (playnet planner scope live)
             (playnet planner legal registry) (playnet planner legal registry-actor)
             (playnet planner legal gate) (playnet planner legal crossings)
             (playnet planner knowledge law context-pack) (playnet planner facts places)
             (playnet planner knowledge recipes food-surplus)
             ((playnet planner solve engine) #:select (why-not requirements unmet req-kind req-name req-met? requirements->wire))
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (srfi srfi-13) (ice-9 format))

(define contexts "docs/legal/contexts")
(define %cell "fr-33330-Ud1")            ; a residential zone of the real PLU
(define %eu-registration "Registrierung als Lebensmittelunternehmer")
;; the EU asks TWO things of this chain, and the first run of this test seeded
;; only one — so the pickup column was pruned and nothing downstream could run.
;; A chain is as lawful as its least-permitted step.
(define %eu-traceability "Rückverfolgbarkeitssystem")

(define win (all-week-window "00:00" "23:59"))
(define (held nm place)
  (make-economic-resource #:id (string-append "res:" nm) #:name nm #:conforms-to nm #:classified-as '("credential")
    #:accounting-quantity (make-measure 1 "cert") #:onhand-quantity (make-measure 1 "cert") #:current-location place #:primary-accountable "fr-33330" #:custodian-scope "fr-33330" #:state "active"))

;;; the commune: donors' surplus, a van, volunteers — all standing in zone Ud1
(define (world registered?)
  (define vat (spawn-vat))
  (with-vat vat
    (let* ((rs  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))
           (sts (spawn ^spatial-thing-store (hashmap)))
           (obs (spawn ^observer (empty-observer-state) '()))
           (as  (spawn ^agent-store (hashmap) (hashmap) (hashmap)))
           (reg (spawn ^legal-registry (load-context-packs contexts))))
      (seed-food-surplus-donor-specs rs)
      (seed-food-surplus-recipient-specs rs)
      (seed-food-surplus-3step-recipe rs)
      ($ sts 'add-location (make-spatial-thing #:id "world" #:name "World"))
      (for-each (lambda (p) (seed-pack-places! sts (pack-place-rows p))) (pack-paths contexts))
      ($ obs 'seed-resource (er "surplus" "spec-produce" "donor" #:place %cell #:qty 400.0 #:custodian "donor"))
      ($ obs 'seed-resource (er "van" "spec-reefer-van" "commune" #:place %cell #:qty 1.0 #:custodian "commune"))
      ($ obs 'seed-resource (er "hands" "spec-volunteer-hours" "ada" #:place %cell #:qty 8.0 #:custodian "ada"))
      (when registered?
        ($ obs 'seed-resource (held %eu-registration %cell))
        ($ obs 'seed-resource (held %eu-traceability %cell)))
      ($ as 'add-agent (make-agent #:id "ada" #:type 'person #:name "Ada" #:primary-location %cell
                                   #:classified-as '() #:availability-window win))
      (let* ((resolve (lambda (id) ($ rs 'get-resource-spec id)))
             (path-of (spatial-path-reader sts))
             (bill (lambda (proc)
                     (let* ((paths (path-of %cell))
                            (flows (legal-proc-flows rs proc)))
                       (car ($ reg 'demands
                               (legal-context #:crossings (process-crossings rs proc)
                                              #:place-path (car paths) #:endpoints paths
                                              #:act (or (recipe-act flows resolve) 'activity)))))))
             (names (lambda (proc) (sort (map demand-name (append-map cdr (bill proc))) string<?)))
             (held? (lambda (p c s)
                      (pair? (filter (lambda (r) (equal? s (economic-resource-conforms-to r)))
                                     ($ obs 'all-resources)))))
             (dec (make-legal-decorate #:recipe-store rs #:spatial-thing-store sts
                                       #:registry reg #:observer obs #:agent-store as
                                       #:held? held?)))
        (call-with-values
            (lambda () (plan-scope
                        (spawn ^mock-root rs sts obs as)
                        #:demand (list (cons (string-append "spec-sorted-produce#" %cell "@0") 90.0))
                        #:backend 'native-c #:legal-decorate dec))
          (lambda (i c m fill x n r)
            (list fill
                  (names "rp-cd-pickup") (names "rp-cd-sort") (names "rp-cd-deliver")
                  (process-crossings rs "rp-cd-deliver")
                  (assq-ref r 'blocked)
                  (why-not (string-append "p|rp-cd-deliver|" %cell "@0"))
                  (requirements (string-append "p|rp-cd-pickup|" %cell "@0"))
                  c)))))))                                  ; the solve's own commitments, for the join

;; the scope-root the planner reads: four stores, nothing else
(define (^mock-root bcom rs sts obs as)
  (lambda (msg . args)
    (case msg
      ((recipe-store) rs) ((spatial-thing-store) sts)
      ((observer) obs) ((agent-store) as)
      ;; the optional parts this scope genuinely has none of. Answered #f rather
      ;; than raised, because the planner guards them (`scope-part`) — and a root
      ;; that cannot say "I have no live-registry" fails a solve that never
      ;; needed one.
      ((legal-registry live-registry plan-store alert-store
        buffer-zone-store account-store capacity-buffer-store) #f)
      (else (error "mock-root" msg)))))

(define unregistered (world #f))
(define registered   (world #t))
(define (ref l n) (list-ref l n))
(define (has? xs s) (and (member s xs) #t))

(display "\n── the federation's own food chain, in a real commune ──\n")
(format #t "  crossings the delivery trips : ~a\n" (ref registered 4))
(format #t "  pickup  asks : ~a\n" (ref registered 1))
(format #t "  sort    asks : ~a\n" (ref registered 2))
(format #t "  deliver asks : ~a\n" (ref registered 3))

(check-pred "recovering surplus and sharing food are what this work trips — not building"
            (and (pair? (ref registered 4))
                 (not (memq 'built-structure (ref registered 4)))))
(check-pred "so no PLU zone rule fires: a plan for food is not governed by a plan for building"
            (not (has? (ref registered 3) "construction non nécessaire à l'exploitation agricole")))
(check-pred "the EU food-business registration DOES reach it, through France's place in the union"
            (has? (ref registered 3) %eu-registration))
(check-pred "…and recovering surplus asks for traceability on top — the pickup step, not the delivery"
            (and (has? (ref registered 1) %eu-traceability)
                 (not (has? (ref registered 3) %eu-traceability))))

(display "\n── and it decides the plan ──\n")
(format #t "  met without the registration: ~,3f\n  met holding it              : ~,3f\n"
        (ref unregistered 0) (ref registered 0))
(check-pred "without the registration the delivery column is pruned — the demand goes unmet"
            (< (ref unregistered 0) 0.05))
(check-pred "holding it, the commune's surplus reaches people"
            (> (ref registered 0) 0.95))

;;; ─── why the work is not there ───────────────────────────────────────────
;;; Seven facts decide whether a column exists — the branch, the horizon, the
;;; material, the lead time, a prohibition, a licence, a competence — and until
;;; now `runnable` collapsed them into one boolean and threw away which. So a
;;; commune missing its food-business registration saw no delivery work in the
;;; calendar, indistinguishable from a day with nothing to do.
;;;
;;; The licence is ONE of the seven. Recording the failing conjunct makes the
;;; card's question a lookup, and the other six come along.
(display "\n── why the work is not there ──\n")
(format #t "  unregistered · delivery column: ~a\n" (ref unregistered 6))
(format #t "  registered   · delivery column: ~a\n" (ref registered 6))
(check-pred "an absent column now says WHY, instead of just being absent"
            (pair? (ref unregistered 6)))
(check-pred "…and the reason for the delivery is the permit nobody holds"
            (eq? 'forbidden (car (ref unregistered 6))))
(check-pred "holding the permits, that column stops being blocked at all"
            (not (ref registered 6)))
;;; NOT yet asserted: the tally reaching the plan's REPORT. `solve-report` adds
;;; it, and this solve's report is not solve-report's — only `social` survives
;;; from it here, so the robust path builds its own. The per-column lookup above
;;; is the mechanism and it works; carrying the summary out to a caller needs the
;;; same wire `legal` uses, and finding that wire is unfinished rather than
;;; assumed. Asserting it now would pin a snapshot of plumbing I have not read.

;;; ─── what the work is MADE OF ────────────────────────────────────────────
;;; The absences and the requirements are one object at two bindings, and the
;;; requirement is the one that exists first: a card that can only say "you
;;; cannot do this" is less use than one that says what the work needs and marks
;;; what is missing inside it. `why-not` is now a FILTER over this list.
;;;
;;; The material half is the recipe's and is place-free — 100 kg of produce is
;;; 100 kg anywhere. The legal half is place-bound, which is why this is keyed by
;;; COLUMN: what you must hold depends on where you stand, and no recipe knows it.
(display "\n── what a pickup needs, here ──\n")
(define (show reqs)
  (for-each (lambda (r)
              (format #t "    ~12a ~52a ~a\n" (req-kind r) (req-name r)
                      (case (req-met? r) ((#t) "held") ((#f) "MISSING") (else "—"))))
            reqs))
(show (ref unregistered 7))
(define kinds-of (lambda (l) (delete-duplicates (map req-kind l))))
;; The CONTRACT on met?, not a snapshot of today's answers: #t / #f / 'unknown
;; and nothing else. skilled-worker-at? answers with the worker record it found,
;; so a competence that was held arrived here truthy-but-not-#t and rendered as
;; "not known" — a fact the solve HAD, displayed as an absence. Asserted over
;; every requirement of every column, so any future met? source is held to it.
;; THE WIRE. A reader outside this module never sees a column key: it joins on
;; the three facts a calendar event already carries. Proven by finding the
;; pickup's own row by (process place) and reading the permits back out of it.
(define wire (requirements->wire))
(define (row-for proc)
  (find (lambda (r) (string-contains (assq-ref r 'process) proc)) wire))
;; ── AMBIGUITY, ruled out rather than made unlikely ──────────────────────────
;; A commitment takes its `when` from (car (period-span t)); a wire row carries
;; that same call's value as `begin`. So the join is three equalities on values
;; from ONE source — no containment rule, and therefore no instant landing on a
;; boundary — and the triple it matches IS the column key.
;;
;; BOTH halves are asserted here: at most one row can answer (no two rows share
;; the triple), and every work commitment finds exactly one (none finds zero,
;; none finds two). The second needs a solve that actually employs somebody,
;; which is why `(pair? work-coms)` guards it — the first draft of this check
;; passed over an empty commitment list, proving nothing, because the recipe's
;; labour was silently zero. A totality check with no commitments to check is
;; the absence-reads-as-success bug wearing a test's clothes.
(define (join-key r) (list (assq-ref r 'process) (assq-ref r 'place) (assq-ref r 'begin)))
(check-pred "no two rows share (process place begin) — at most one row can ever answer"
            (let ((ks (map join-key wire)))
              (and (pair? ks) (= (length ks) (length (delete-duplicates ks))))))
(check-pred "every row carries the instants of its own period, which is what a commitment's `when` is"
            (every (lambda (r) (assq 'begin r)) wire))
(define (rows-matching com)
  (filter (lambda (r)
            (and (equal? (assq-ref r 'process) (commitment-input-of com))
                 (equal? (assq-ref r 'place)   (commitment-at-location com))
                 (equal? (assq-ref r 'begin)   (commitment-has-beginning com))))
          wire))
(define work-coms
  (filter (lambda (c) (eq? 'work (commitment-action c))) (ref registered 8)))
(check-pred "the solve employs somebody — otherwise the next check proves nothing"
            (pair? work-coms))
(check-pred "every work commitment matches EXACTLY one requirements row"
            (every (lambda (c) (= 1 (length (rows-matching c)))) work-coms))

(check-pred "the wire keys each act by process, place and period — no column keys"
            (and (pair? wire)
                 (every (lambda (r) (and (string? (assq-ref r 'process))
                                         (string? (assq-ref r 'place))
                                         (number? (assq-ref r 'period))))
                        wire)))
(check-pred "a pickup's row carries the same permits the card showed"
            (let ((r (row-for "pickup")))
              (and r (lset<= equal?
                             '("Registrierung als Lebensmittelunternehmer"
                               "Rückverfolgbarkeitssystem")
                             (map (lambda (n) (assq-ref n 'name))
                                  (filter (lambda (n) (eq? 'obtain-entity (assq-ref n 'kind)))
                                          (assq-ref r 'needs)))))))

(check-pred "met? is #t, #f or 'unknown for every requirement, both solves"
            (every (lambda (r) (memq (req-met? r) (list #t #f 'unknown)))
                   (append (ref unregistered 7) (ref registered 7))))

;; A means OCCUPIED and a material CONSUMED are different facts about the work,
;; and a `use` flow compiles to a Svc| consume — so they arrive as one list and
;; only the prefix separates them. Both halves asserted: the kind comes back,
;; and no requirement name carries the engine's internal marker out to a reader.
(check-pred "a means occupied reads as `use`, not as a material consumed"
            (and (memq 'use     (kinds-of (ref registered 7)))
                 (memq 'consume (kinds-of (ref registered 7)))))
(check-pred "no requirement name leaks the Svc| prefix"
            (not (any (lambda (r) (string-prefix? "Svc|" (req-name r)))
                      (append (ref unregistered 7) (ref registered 7)))))

(check-pred "the list carries the recipe's own flows — what it consumes and the labour it works"
            (and (memq 'consume (kinds-of (ref registered 7)))
                 (memq 'work    (kinds-of (ref registered 7)))))
(check-pred "…and what the law asks of it HERE, in the same list"
            (memq 'obtain-entity (kinds-of (ref registered 7))))
(check-pred "a requirement is a fact about the WORK — recorded whether or not it is met"
            (= (length (ref registered 7)) (length (ref unregistered 7))))
(check-pred "unregistered, the EU permits are marked missing inside it"
            (let ((m (map req-name (filter (lambda (r) (eq? #f (req-met? r)))
                                           (ref unregistered 7)))))
              (and (member %eu-registration m) (member %eu-traceability m))))
(check-pred "holding them, nothing in the list is missing"
            (null? (filter (lambda (r) (eq? #f (req-met? r))) (ref registered 7))))

(display "\n── what is NOT asked, and should be ──\n")
;;; No French rule fires. The habilitation de l'aide alimentaire (L.266-2 code de
;;; l'action sociale), the DDPP registration, the loi Garot donation regime —
;;; none of it is in any pack, because none of it is published as a dataset and
;;; nobody has read the prose. The plan is lawful as far as the packs go, and the
;;; packs go as far as the EU baseline.
(check-pred "no rule from any FRENCH pack fires on this work — the gap, shown rather than assumed"
            (not (any (lambda (d) (or (string-contains d "SAFER")
                                      (string-contains d "Permis")
                                      (string-contains d "publicité foncière")))
                      (ref registered 3))))
(test-summary!)
