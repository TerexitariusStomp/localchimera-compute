;;; law/lint.scm — the check that catches the class of bug this layer keeps
;;; producing: a fact that goes missing, where the failure looks like legality.
;;;
;;; Three times running, the same shape. A jurisdiction chain that stopped short,
;;; so no guard matched. A place a pack named but never placed, so no guard
;;; matched. A place's `within` clobbered by another pack, so no guard matched.
;;; Every one of them was invisible to a test that arranged things by hand, and
;;; every one made the law quietly NOT apply — under-regulation that reads
;;; exactly like permission.
;;;
;;; What makes it lintable is that a guard says which jurisdictions it keys on,
;;; and a pack says which places it places. If the first names something the
;;; second never placed, that rule can never fire, and no run will ever say so.
;;;
;;; The folder is linted as a SELF-CONTAINED unit: the place ids declared by all
;;; its packs, plus whatever ids the caller says are already known (the built-in
;;; roots, or a live tree). Nothing here registers anything, so a lint run has no
;;; effect on the tree it is checking — and its answer does not depend on the
;;; order the files happen to sort in, which is exactly what one of the bugs did.
;;;
;;; Run: guile --no-auto-compile -L module tools/lint/lint-law-packs.scm [DIR …]

(define-module (playnet knowledge law lint)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:use-module (playnet legal registry)
  #:use-module (playnet legal crossings)
  #:use-module (playnet knowledge law context-pack)
  #:use-module (playnet knowledge law incumbent-readings)
  #:use-module (playnet knowledge law structural-demands)
  #:use-module (playnet knowledge law aspects)
  #:use-module (playnet knowledge law protections)
  #:use-module (playnet knowledge dsl findings)
  #:use-module ((playnet knowledge law activities) #:select (*activities* activity-modes))
  #:use-module ((playnet knowledge worlds free-food-distribution) #:select (*ffd-arc-crossings*))
  #:use-module (playnet knowledge law product)
  #:use-module ((playnet legal gate) #:select (legal-proc-flows))
  #:use-module ((playnet vf schemas) #:select (recipe-id recipe-process-id))
  #:use-module (goblins)
  #:re-export (finding-severity finding-kind finding-subject finding-detail format-findings)
  #:export (guard-jurisdictions pack-declarations lint-law-packs
            pack-crossings federation-crossings law-coverage crossing-sources
            known-demand-names lint-demand-records))

;;; ─── reading a pack without registering anything ─────────────────────────
(define (pack-declarations path)
  "(values place-rows rules) for PATH — a context pack or a bare rule list."
  (let ((pack (read-pack path)))
    (values (pack-section pack 'places) (sexp->rules (pack-section pack 'rules)))))

;;; Every place a guard FORM names, at any depth — under a `negate` too, since a
;;; negated jurisdiction nobody places is a misspelling all the same — and the
;;; level a border rule names, which is a place as well.
(define (guard-jurisdictions form)
  (append (guard-places form #:negated? #t)
          (guard-atoms 'border-level-is form #:negated? #t)))
(define (rule-crossings r) (guard-crossings (legal-rule-guard-form r) #:negated? #t))

;;; ─── findings ────────────────────────────────────────────────────────────
;; the finding shape is (playnet knowledge dsl findings)

;; a place row is (id name parent kind extra lat long)
(define (row-id r) (car r))
(define (row-parent r) (and (> (length r) 2) (caddr r)))
(define (row-extra r) (if (> (length r) 4) (list-ref r 4) '()))
;; A pack's rules are read as the registry reads them (`sexp->rule`), so the
;; lint and the fold agree on what a rule is; these name what the checks ask.
(define (rule-label r) (or (legal-rule-label r) "(unlabelled)"))
(define (rule-demand-names r) (map demand-name (legal-rule-demands r)))

(define (digits s) (and (string? s) (string-filter char-numeric? s)))

(define* (lint-law-packs source #:key (known '()))
  "Check every pack in SOURCE (a directory or an explicit path list). KNOWN names
   place ids that already exist outside these packs — the built-in roots, or the
   ids of a live tree. Returns a list of findings, empty when clean."
  (let* ((paths (pack-paths source))
         (decls (map (lambda (p)
                       (call-with-values (lambda () (pack-declarations p))
                         (lambda (rows rules) (list p rows rules))))
                     paths))
         (all-rows  (append-map cadr decls))
         (placed    (lset-union equal? (map row-id all-rows) known))
         (findings '()))
    (define (add! f) (set! findings (cons f findings)))
    ;; 1. a guard that names a place nobody places — the rule can never fire
    (for-each
     (lambda (d)
       (let ((path (car d)) (rules (caddr d)))
         (for-each
          (lambda (r)
            (let ((label (rule-label r)) (from (legal-rule-as-of r)) (until (legal-rule-until r))
                  (confidence (legal-rule-confidence r)))
              (for-each
               (lambda (j)
                 (unless (member j placed)
                   (add! (finding 'error 'ungrounded-jurisdiction label
                                  (format #f "~a: guard keys on ~s, which no pack places"
                                          (basename path) j)))))
               (guard-jurisdictions (legal-rule-guard-form r)))
              (unless (memq confidence %confidences)
                (add! (finding 'error 'unknown-confidence label
                               (format #f "~a: confidence ~s is none of ~s"
                                       (basename path) confidence %confidences))))
              ;; 3. a window that can never be in force
              (let ((f (digits from)) (u (digits until)))
                (when (and f u (string<= u f))
                  (add! (finding 'error 'empty-window label
                                 (format #f "~a: in force from ~a until ~a — never"
                                         (basename path) from until)))))
              ;; 3b. a measure nobody can take: a levy's base or a threshold's key
              ;;     outside `%measure-keys` reads as unknown forever
              (for-each
               (lambda (k)
                 (unless (memq k %measure-keys)
                   (add! (finding 'error 'measure-unregistered label
                                  (format #f "~a: names the measure ~s, which is none of ~s"
                                          (basename path) k %measure-keys)))))
               (append (guard-measures (legal-rule-guard-form r))
                       (filter-map (lambda (d) (demand-ref d 'base)) (legal-rule-demands r))))))
          rules)))
     decls)
    ;; The crossing catalogue is OPEN by construction — `crossing-kind` answers
    ;; `mirrored` for anything it does not know, and a pack naming its own
    ;; crossings is the design working, not a defect. So this is an INFO line and
    ;; one per distinct crossing, not a warning per rule: it tells a reader what
    ;; vocabulary these packs introduce, which is also where a typo would show.
    (let ((unknown (delete-duplicates
                    (filter (lambda (c) (not (known-crossing? c)))
                            (append-map (lambda (d)
                                          (append-map rule-crossings (caddr d)))
                                        decls)))))
      (for-each (lambda (c)
                  (add! (finding 'info 'crossing-beyond-catalogue c
                                 "named by a pack; folds as `mirrored`")))
                (sort unknown (lambda (a b) (string< (symbol->string a) (symbol->string b))))))
    ;; A derogation that names a demand NO pack demands cancels nothing, and
    ;; nothing at runtime says so — the same silence as a guard on an unplaced
    ;; jurisdiction, one level down. Usually a spelling difference: the name is
    ;; prose, and it is also the id a held permit conforms to, so a pack that
    ;; spells it differently has already broken custody.
    (let ((demanded (delete-duplicates
                     (append-map (lambda (d)
                                   (append-map rule-demand-names (caddr d)))
                                 decls))))
      (for-each
       (lambda (d)
         (for-each
          (lambda (r)
            (for-each
             (lambda (c)
               (unless (member c demanded)
                 (add! (finding 'warning 'cancels-nothing (rule-label r)
                                (format #f "~a: derogates from ~s, which no pack demands"
                                        (basename (car d)) c)))))
             (legal-rule-cancels r)))
          (caddr d)))
       decls))
    ;; A reading of a structural demand is a fact about a place, so it fails the
    ;; way a guard does: on a place nobody places, on a demand nobody states, or
    ;; on a clause the demand's incumbent never had — and then it reads nothing,
    ;; and the place shows as unread with no one the wiser.
    (for-each
     (lambda (d)
       (for-each
        (lambda (reading)
          (for-each
           (lambda (problem)
             (add! (finding 'error 'unreadable-reading (reading-demand reading)
                            (format #f "~a: ~a" (basename (car d)) problem))))
           (reading-problems reading *structural-demands*
                             #:known-place? (lambda (id) (and (member id placed) #t)))))
        (pack-readings (car d))))
     decls)
    ;; A pack's word for an aspect maps onto an aspect the federation states. A
    ;; target nobody states maps the clause onto nothing, and the demand then
    ;; reads as if the federation had an answer it never gave.
    ;; A protection is a fact about a place too, and fails the same way.
    (for-each
     (lambda (d)
       (for-each
        (lambda (protection)
          (for-each
           (lambda (problem)
             (add! (finding 'error 'unreadable-protection (protection-name protection)
                            (format #f "~a: ~a" (basename (car d)) problem))))
           (protection-problems protection
                                #:known-place? (lambda (id) (and (member id placed) #t)))))
        (pack-protections (car d))))
     decls)
    ;; The words are one vocabulary: a word two packs map onto different
    ;; aspects, or an aspect's own id mapped onto another, would mean whichever
    ;; pack loaded first — and the diff would read the other pack's demands by it.
    (let ((seen (make-hash-table)))           ; clause → (aspect . pack)
      (for-each
       (lambda (d)
         (for-each
          (lambda (kv)
            (let ((clause (car kv)) (aspect (cdr kv)) (pack (basename (car d))))
              (unless (memq aspect *food-housing-ids*)
                (add! (finding 'error 'unknown-aspect clause
                               (format #f "~a: maps onto ~a, which is no federation aspect"
                                       pack aspect))))
              (when (and (memq clause *food-housing-ids*) (not (eq? clause aspect)))
                (add! (finding 'error 'remapped-aspect clause
                               (format #f "~a: ~a is an aspect itself and names nothing else"
                                       pack clause))))
              (let ((prior (hash-ref seen clause #f)))
                (cond ((not prior) (hash-set! seen clause (cons aspect pack)))
                      ((not (eq? (car prior) aspect))
                       (add! (finding 'error 'conflicting-aspect clause
                                      (format #f "~a maps it onto ~a, ~a onto ~a"
                                              (cdr prior) (car prior) pack aspect))))))))
          (pack-aspects (car d))))
       decls))
    ;; 4. a place whose parent nobody places — the climb stops there, and every
    ;;    guard above it is unreachable from anything below
    (for-each
     (lambda (r)
       (let ((p (row-parent r)))
         (when (and p (not (member p placed)))
           (add! (finding 'error 'orphan-place (row-id r)
                          (format #f "contained-in ~s, which no pack places" p))))))
     all-rows)
    ;; 5. a `within` regime nobody places — the endpoint is never built
    (for-each
     (lambda (r)
       (for-each
        (lambda (w)
          (unless (member w placed)
            (add! (finding 'error 'dangling-within (row-id r)
                           (format #f "stands within ~s, which no pack places" w)))))
        (or (assq-ref (row-extra r) 'within) '())))
     all-rows)
    ;; A check this file deliberately does NOT make: "a regime nothing stands
    ;; within". It looks like the same silence the rest of these catch, and it is
    ;; unsound — a law folder is partial by design (that is what `known` is for),
    ;; and a zone's members can live anywhere: a commune's parcels sit in
    ;; data/law/, so every one of its 23 zones would be reported empty. A signal
    ;; that fires 25 times wrongly teaches a reader to skip the ones that matter,
    ;; which costs more than the check is worth.
    ;; 6. a containment cycle: the climb would never terminate on its own
    (let ((parent (map (lambda (r) (cons (row-id r) (row-parent r))) all-rows)))
      (for-each
       (lambda (r)
         (let loop ((id (row-parent r)) (seen (list (row-id r))))
           (cond ((not id) #t)
                 ((member id seen)
                  (add! (finding 'error 'containment-cycle (row-id r)
                                 (format #f "contained-in closes a cycle at ~s" id))))
                 (else (loop (assoc-ref parent id) (cons id seen))))))
       all-rows))
    (reverse findings)))

;;; ─── coverage: the silence, said out loud ────────────────────────────────
;;; A rule only fires when a recipe trips its crossing. So a pack can be correct,
;;; linted, in force — and still say NOTHING about everything a federation
;;; actually does, because its rules guard on crossings no recipe trips. Nothing
;;; at runtime distinguishes that from lawfulness: the plan runs, no demand
;;; appears, and you cannot tell whether the act is permitted or merely
;;; unlegislated here.
;;;
;;; This is the same failure the rest of this file exists for, one layer out — a
;;; fact missing where its absence looks like an answer. It cannot be fixed by
;;; writing more rules, only by SAYING which side of the gap you are on.
;;;
;;;   uncovered — something trips this; no rule speaks of it. Not necessarily a
;;;               defect: the act may genuinely be unregulated, or the packs may
;;;               not cover that domain yet. Reported so it is a known unknown.
;;;   inert     — a rule guards this; nothing trips it. The law is loaded and
;;;               cannot fire.
;;; "Speaks of" is the registry's (`rule-speaks-of`), the reading `bill-unread`
;;; makes at one place: this is that question asked of the packs as a whole.
;;; What is tripped is the caller's to state — a scope's recipes
;;; (`store-crossings`, legal/gate.scm), or everything the federation does
;;; outside a solve (`federation-crossings`).
(define (law-coverage tripped-crossings rule-crossings)
  (let* ((rx (delete-duplicates tripped-crossings))
         (gx (delete-duplicates rule-crossings))
         (sym< (lambda (a b) (string< (symbol->string a) (symbol->string b)))))
    (append
     (map (lambda (c)
            (finding 'warning 'uncovered-crossing c
                     "tripped; no rule speaks of it"))
          (sort (lset-difference eq? rx gx) sym<))
     (map (lambda (c)
            (finding 'info 'inert-crossing c
                     "a rule guards this; nothing trips it — the law cannot fire"))
          (sort (lset-difference eq? gx rx) sym<)))))

;;; ─── sources : which crossings the records say, and which a tag says ─────
;;; A process trips a crossing because its records show the pattern (derived,
;;; legal/crossings.scm `*crossing-patterns*`) or because a steward tagged it
;;; (declared). Per process this says which, so a tag the records already say can
;;; go, and a tag that carries a fact the records lack names the fact:
;;;
;;;   restated-crossing      info     derived AND declared — the tag adds nothing
;;;   declared-crossing      info     declared only; the detail says what the
;;;                                   records would have to carry to derive it
;;;   unregistered-crossing  warning  tripped, and absent from the catalogue
;;;   unstated-fact          warning  a rule in force on a crossing the process
;;;                                   trips reads the act (or the channel), and
;;;                                   the process states none: the rule stands
;;;                                   in doubt until the recipe says
;;;
;;; Call inside a vat: RECIPE-STORE is a ^recipe-store.
(define* (crossing-sources recipe-store #:key (rules (current-legal-rules)))
  (let ((resolve  (lambda (id) ($ recipe-store 'get-resource-spec id)))
        (xflows   (lambda (id) ($ recipe-store 'flows-for-exchange id)))
        (reasons  '((where . "where it happens") (whose . "who held the thing before")
                    (state . "the state the thing is in") (shown . "how it is presented")
                    (food . "what kind of food it is, beyond its class")
                    (handover . "to whom it goes and what comes back")
                    (no-flow . "an act that is no flow"))))
    (append-map
     (lambda (r)
       (append-map
        (lambda (rp)
          (let* ((pid      (recipe-process-id rp))
                 (flows    (legal-proc-flows recipe-store pid))
                 (derived  (recipe-crossings/derived flows resolve #:exchange-flows xflows))
                 (declared (recipe-crossings/declared flows resolve))
                 (tripped  (lset-union eq? declared derived))
                 (stated   `((act . ,(recipe-act flows resolve))
                             (channel . ,(recipe-channel flows resolve))))
                 ;; the rules that could bear on this process, and the facts
                 ;; they read that it leaves unstated
                 (owed     (delete-duplicates
                            (append-map
                             (lambda (r)
                               (let ((spoken (rule-speaks-of r)))
                                 (if (and (pair? tripped)
                                          (or (null? spoken)
                                              (pair? (lset-intersection eq? spoken tripped))))
                                     (filter-map
                                      (lambda (fact)
                                        (and (not (assq-ref stated fact))
                                             (cons fact (legal-rule-label r))))
                                      (guard-asks (legal-rule-guard-form r)))
                                     '())))
                             rules))))
            (append
             (map (lambda (fact)
                    (let ((labels (filter-map (lambda (o) (and (eq? fact (car o)) (cdr o))) owed)))
                      (finding 'warning 'unstated-fact fact
                               (format #f "~a: states no ~a, and ~a rule~a read~a it (~a~a) — each stands in doubt"
                                       pid fact (length labels)
                                       (if (= 1 (length labels)) "" "s")
                                       (if (= 1 (length labels)) "s" "")
                                       (car labels)
                                       (if (pair? (cdr labels)) ", …" "")))))
                  (delete-duplicates (map car owed)))
             (map (lambda (c) (finding 'info 'restated-crossing c
                                       (format #f "~a: the records already say it; the tag can go" pid)))
                  (lset-intersection eq? declared derived))
             (map (lambda (c)
                    (let ((why (crossing-lacks c)))
                      (finding 'info 'declared-crossing c
                               (format #f "~a: declared by tag~a" pid
                                       (if why (string-append " — the records lack "
                                                              (assq-ref reasons why))
                                           "")))))
                  (lset-difference eq? declared derived))
             (map (lambda (c) (finding 'warning 'unregistered-crossing c
                                       (format #f "~a: tripped, and no catalogue names it" pid)))
                  (remove known-crossing? (lset-union eq? declared derived))))))
        ($ recipe-store 'get-process-chain (recipe-id r))))
     ($ recipe-store 'all-recipes))))

;;; every crossing the federation trips outside a solve: the ways of its
;;; activities, the arcs it moves goods along, the product's own features
(define (federation-crossings)
  (delete-duplicates
   (append (append-map (lambda (a) (append-map (lambda (m) (assq-ref m 'crossings))
                                               (activity-modes a)))
                       *activities*)
           *ffd-arc-crossings*
           (append-map (lambda (id) (feature-crossings (product-feature id)))
                       (product-feature-ids)))))

;;; every crossing the packs in SOURCE speak of
(define (pack-crossings source)
  (delete-duplicates
   (append-map (lambda (path)
                 (call-with-values (lambda () (pack-declarations path))
                   (lambda (rows rules)
                     (append-map rule-speaks-of rules))))
               (pack-paths source))))

;;; ─── the extractor's records, before they become a pack ──────────────────
;;; A statute extractor (planner/knowledge/law/scrape.scm) hands over records — kind, name,
;;; crossing, rides — that `records->rule` will fold into a pack. Two things a
;;; pack lint would only see afterwards are decidable here, and a model can act
;;; on them when told: a demand named twice, and a name the packs already
;;; spell another way. The name is also the id a held permit conforms to
;;; (compliance.scm), so a second spelling is a second permit nobody holds.
(define (norm-name s)
  (string-downcase (string-filter (lambda (c) (or (char-alphabetic? c) (char-numeric? c)))
                                  (format #f "~a" s))))

(define (known-demand-names source)
  "Every demand name the packs in SOURCE demand, once each."
  (delete-duplicates
   (append-map (lambda (path)
                 (call-with-values (lambda () (pack-declarations path))
                   (lambda (rows rules) (append-map rule-demand-names rules))))
               (pack-paths source))))

(define (rec-ref r k) (let ((p (assq k r))) (and p (cdr p))))

(define* (lint-demand-records records #:key (known '()))
  "Findings over the extractor's RECORDS ((kind . K) (name . N) …), numbered
from 1 as the extractor numbers them for the model."
  (let ((findings '()) (by-norm (map (lambda (n) (cons (norm-name n) n)) known)))
    (define (add! severity kind subject fmt . args)
      (set! findings (cons (finding severity kind subject (apply format #f fmt args)) findings)))
    (let loop ((rs records) (i 1) (seen '()))
      (when (pair? rs)
        (let* ((r (car rs)) (name (rec-ref r 'name)) (kind (rec-ref r 'kind))
               (subject (format #f "record ~a" i))
               (key (and (string? name) (cons kind (norm-name name)))))
          (cond
           ((and key (assoc key seen))
            (add! 'error 'duplicate-demand subject "repeats record ~a (~a ~s); state each demand once"
                  (cdr (assoc key seen)) kind name))
           ((and key (assoc (cdr key) by-norm)
                 (not (string=? name (cdr (assoc (cdr key) by-norm)))))
            (add! 'error 'demand-name-spelling subject
                  "names ~s where the packs spell it ~s; use that spelling, it is the id a held permit conforms to"
                  name (cdr (assoc (cdr key) by-norm)))))
          (loop (cdr rs) (+ i 1) (if key (cons (cons key i) seen) seen)))))
    (findings-by-severity (reverse findings))))
