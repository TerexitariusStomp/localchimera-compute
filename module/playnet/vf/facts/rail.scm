;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; rail.scm — the rail a good is on, read off the recipes that touch it.
;;;
;;; A good is on the INDIVIDUAL rail because a claim recipe consumes it for
;;; someone (live.scm claim-recipes: `consume spec` + `consume credit|aid` →
;;; `produce spec~aid`); COMMUNAL because only the scope's own recipes consume
;;; it; a MEANS because `use` flows touch it — what a process uses, no person
;;; claims. The plan publishes the whole classification here, the way it
;;; publishes social free time, and every reader — the pool, a claim's
;;; admissibility, the credit identity K, the custody invariant, the legal
;;; channel — reads this one table. The resource record's distribution-mode is
;;; import vocabulary (classifiedAs, normalised in schemas.scm) and provenance
;;; on the events a claim writes; it decides nothing.
;;;
;;; A leaf: it imports nothing of the planner, so the accounting, the custody
;;; rule and the crossings all read it without a cycle.
(define-module (playnet vf facts rail)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet vf facts barred-specs) #:select (barred-individual?))
  #:export (rails-of spec-rail publish-rails! declare-rail! rails
            spec-claimable? declare-claimable! claimable-specs
            publish-social-portion! declare-social-portion! spec-social-portion social-portions
            set-rails! set-social-portions!))

(define* (rails-of #:key (used '()) (consumed '()) (made '()) (claimed '()))
  "The rail of every spec the verbs name, from the verbs alone: USED (a `use`
   flow touches it) ⇒ means; CLAIMED (a claim recipe consumes it for someone)
   ⇒ individual; CONSUMED (a scope recipe's own input) ⇒ communal; MADE or
   stocked and none of those — a final good, nobody's input — ⇒ individual,
   since what a process uses is the only thing no person claims. A word on a
   record never enters: the rail is read off the recipes and nothing else."
  ;; USED/CLAIMED/CONSUMED as hash-sets, the union deduplicated by one pass
  ;; (same first-occurrence order as delete-duplicates) instead of
  ;; `delete-duplicates` (SRFI-1, O(n²)) over the whole union followed by
  ;; `member` (O(n)) three times per element: a crowd's flows make USED/
  ;; CONSUMED/MADE all O(population), so this was O(population²).
  (define (as-set l) (let ((h (make-hash-table))) (for-each (lambda (x) (hash-set! h x #t)) l) h))
  (let ((used-set (as-set used)) (claimed-set (as-set claimed)) (consumed-set (as-set consumed))
        (seen (make-hash-table)) (acc '()))
    (for-each (lambda (sp) (unless (hash-ref seen sp #f) (hash-set! seen sp #t) (set! acc (cons sp acc))))
              (append used claimed consumed made))
    (map (lambda (sp)
           (cons sp (cond ((hash-ref used-set sp #f)     'means)
                          ((hash-ref claimed-set sp #f)  'individual)
                          ((hash-ref consumed-set sp #f) 'communal)
                          (else                          'individual))))
         (reverse acc))))

(define *spec-rail* (make-hash-table))          ; spec → individual | communal | means

;; A SCOPE's own rail, never another's: keyed by the scope's recipe-store
;; (a Goblins near-ref, one per scope, stable for its whole life — the same
;; identity *met-memo*/*slot-criteria* key by elsewhere in this sweep).
;; store → (hash-table: spec → rail), replaced WHOLE on every solve of that
;; store, so a spec this solve no longer mentions doesn't linger from the
;; last one. A caller with no store, or whose store has never solved, falls
;; through to the single legacy table below — never the other way around:
;; once a store HAS its own table, an absent spec there means "this scope's
;; own recipes don't name it", not "ask someone else's".
(define *rail-by-store* (make-hash-table))
(define (store-rail-table store) (and store (hash-ref *rail-by-store* store #f)))

(define (set-rails! store rails)
  "THIS scope's word alone: RAILS ((spec . rail) …) replaces STORE's own
   table — no other store's entries move. A false STORE is a no-op: a
   solve off no real scope (a bare `plan-from-records` run) has nothing of
   its own to keep, and leaves the legacy table as the only answer."
  (when store
    (let ((t (make-hash-table)))
      (for-each (lambda (p) (hash-set! t (car p) (cdr p))) rails)
      (hash-set! *rail-by-store* store t))))

(define* (spec-rail spec #:optional (store #f))
  "The rail SPEC is on, as STORE's own last solve classified it — never a
   different scope's, once STORE has solved at all. With no STORE, or
   before STORE has ever solved, the legacy single-plan table (declared or
   published there); #f when nothing has spoken at all. The one exception:
   a spec on the bar list (vf/facts/barred-specs.scm) answers 'communal always,
   whatever any solve, `declare-rail!`, or future caller ever wrote for it —
   not a record's word, read before the table is."
  (and spec
       (or (and (barred-individual? spec) 'communal)
           (let ((t (store-rail-table store)))
             (if t (hash-ref t spec #f)
                 (hash-ref *spec-rail* spec #f))))))

(define (publish-rails! rails)
  "The plan's word, legacy/no-store layer: RAILS ((spec . rail) …) replaces
   the one shared table — test fixtures still declare into this, and a
   caller that never names its own store still reads it."
  (hash-clear! *spec-rail*)
  (for-each (lambda (p) (hash-set! *spec-rail* (car p) (cdr p))) rails))

(define (declare-rail! spec rail)
  "A test fixture's stand-in for the plan, for one spec. Production code
   publishes through the plan (live.scm) and declares nothing."
  (hash-set! *spec-rail* spec rail))

(define (rails) (hash-map->list cons *spec-rail*))

;; ── the portion that remains social, read off the plan ──────────────────────
;; One portion serves as fresh means of production and stays social; another
;; portion is consumed by members as means of subsistence. The
;; rail says WHETHER a good is on the individual rail; this table says HOW MUCH
;; of its stock the plan keeps back — what the scope's own processes consume
;; this horizon plus the reserve it defends (the three deductions: replacement,
;; expansion, insurance). The pool K is valued over what stands above it, so
;; the certificate's exchange rate counts only the distributable portion. The
;; plan publishes it after each solve, the way it publishes the rail; no reader
;; subtracts anything of its own.
(define *social-portion* (make-hash-table))     ; spec → quantity kept back, in the spec's unit

;; the scope-keyed twin of *rail-by-store* above, same reasoning: a store
;; that has solved answers for itself alone.
(define *social-portion-by-store* (make-hash-table))
(define (store-social-table store) (and store (hash-ref *social-portion-by-store* store #f)))

(define (set-social-portions! store portions)
  "THIS scope's word alone: PORTIONS ((spec . qty) …) replaces STORE's own
   table. A false STORE is a no-op, same as set-rails!."
  (when store
    (let ((t (make-hash-table)))
      (for-each (lambda (p) (hash-set! t (car p) (cdr p))) portions)
      (hash-set! *social-portion-by-store* store t))))

(define (publish-social-portion! portions)
  "The plan's word, legacy/no-store layer: PORTIONS ((spec . qty) …)
   replaces the one shared table."
  (hash-clear! *social-portion*)
  (for-each (lambda (p) (hash-set! *social-portion* (car p) (cdr p))) portions))

(define (declare-social-portion! spec qty)
  "A test fixture's stand-in for the plan, for one spec."
  (hash-set! *social-portion* spec qty))

(define* (spec-social-portion spec #:optional (store #f))
  "How much of SPEC the plan keeps back, as STORE's own last solve said —
   never another scope's, once STORE has solved at all; 0 when no plan has
   spoken, there or in the legacy table."
  (or (and spec
           (let ((t (store-social-table store)))
             (if t (hash-ref t spec #f)
                 (hash-ref *social-portion* spec #f))))
      0))

(define* (social-portions #:optional (store #f))
  "Every spec STORE's own last solve kept back — never another scope's,
   once STORE has solved at all; the legacy shared table with no STORE, or
   before STORE has ever solved."
  (let ((t (store-social-table store)))
    (if t (hash-map->list cons t)
        (hash-map->list cons *social-portion*))))

(define* (spec-claimable? spec #:optional (store #f)) (eq? (spec-rail spec store) 'individual))
(define (declare-claimable! . specs) (for-each (lambda (s) (declare-rail! s 'individual)) specs))
(define* (claimable-specs #:optional (store #f))
  "Every spec a citizen may claim: the individual rail, read through spec-rail so
   the bar list holds here as it does for each spec asked alone."
  (filter (lambda (spec) (spec-claimable? spec store))
          (map car (let ((t (store-rail-table store))) (if t (hash-map->list cons t) (rails))))))
