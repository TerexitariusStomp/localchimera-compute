;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; legal/adapters.scm — the adapter is a FOLD, not an artifact: spawn, retire, rotate.
;;;
;;; Design: docs/legal/legal-compliance-lifecycle.md §12, and localchimera.typ
;;; §"Standing: held by key, a mask at the door" (the per-door adapters,
;;; "dissolve it and register another"). Once compliance is a fold over the VF event log
;;; (compliance.scm) and filings are a deterministic Process (legal/filings.scm), a
;;; adapter's whole posture — which permits it holds, what it owes, what it
;;; holds worth keeping — is a QUERY over data the federation already has. So an
;;; adapter is cheap to stand up, cheap to administer and cheap to replace when
;;; it becomes a liability, and its stewards rotate by governance. Three verbs:
;;;
;;;   spawn-adapter  — a new Agent + the demand bill for the doors it opens +
;;;                    every application rendered from canonical data. Seeding,
;;;                    not bespoke setup.
;;;   retire-adapter — the dissolution check: it holds nothing substantive, and
;;;                    its credentials are held-but-not-required — safe to let
;;;                    lapse.
;;;   rotate-adapter — regenerate the SAME filings against a fresh Agent and
;;;                    re-point the decorate's custody check; the planner runs on.
;;;
;;; An adapter is per-DOOR, not per-asset (localchimera.typ): each carries exactly one
;;; door's exposure, so adapters are thin and single-purpose.
;;;
;;; Composes: legal-demands (the bill), render-filing (the applications),
;;; holding-status (custody). Load compliance.scm + legal/filings.scm first (the
;;; umbrella / a test's planner-load chain does).
;;;
;;; Run the demo:  guile -L module module/localchimera/legal/adapters.scm

(define-module (localchimera legal adapters)
  #:use-module ((localchimera legal bodies) #:select (masks-subject-of))
  #:use-module ((localchimera vf facts agent-tags) #:select (agent-tag-value))
  #:use-module (localchimera legal registry)
  #:use-module (localchimera vf schemas)
  #:use-module (localchimera legal compliance)
  #:use-module (localchimera legal filings)
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:export (%ad-dir adapter-class make-adapter adapter? adapter-bill spawn-adapter
            adapter-spawn-agent adapter-spawn-applications adapter-spawn-entity-needs
            %classed? adapter-credentials adapter-substance held-but-not-required
            retire-adapter rotate-adapter adapter-exposure mask-jurisdiction
            adapter-covers? resolve-mask mask-subject-of adapters-demo))

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (localchimera legal filings))
(use-modules (localchimera legal compliance))

(define %ad-dir (or (and=> (current-filename) (lambda (f) (dirname (dirname f)))) "module/localchimera"))

;;; ─── a mask is an organization <agent>, tagged per door/jurisdiction ─────
(define adapter-class "adapter")
(define* (make-adapter id name jurisdiction #:optional (extra '()))
  (make-agent #:id id #:type 'organization #:name name
              #:classified-as (append (list adapter-class
                            (string-append "jurisdiction:" (format #f "~a" jurisdiction)))
                      extra)))
(define (adapter? a)
  (and (agent? a) (let ((c (agent-classified-as a))) (and (list? c) (member adapter-class c) #t))))

;;; ─── the bill for the doors a mask opens (a thin wrapper on legal-demands) ─
;;; ACTOR / MEASURES: the body behind the doors and its counts, when the caller
;;; names them — a form's own consequences read them (registry.scm `actor-has`).
(define* (adapter-bill #:key (crossings '()) (place-path '()) (act #f) (rules #f)
                       (actor #f) (measures #f))
  (call-with-values
      (lambda ()
        (legal-demands (legal-context #:crossings crossings #:place-path place-path #:act act
                                      #:actor actor #:measures measures)
                       #:rules (or rules (current-legal-rules))))
    list))                                              ; (bill hits)

;;; ─── SPAWN : Agent + rendered applications for every door, from canonical ─
;;; templates : alist (demand-name . <filing-template>). Every entity `obtain`
;;; with a template is rendered from `canonical` (augmented with the adapter's
;;; name); the rest surface as unmet `entity-needs`/`person-needs` — you see
;;; exactly what a door still requires. Nothing is re-keyed.
(define* (spawn-adapter #:key id name jurisdiction (crossings '()) (place-path '())
                        (act #f) (rules #f) (templates '()) (canonical '()))
  (let* ((agent (make-adapter id name jurisdiction))
         (bh    (adapter-bill #:crossings crossings #:place-path place-path #:act act #:rules rules))
         (bill  (car bh))
         (ents  (bill-ref bill 'obtain-entity))
         (pers  (bill-ref bill 'obtain-person))
         (canon (cons (cons 'adapter-name name) canonical))
         (apps  (filter-map
                 (lambda (d)
                   (let ((tmpl (assoc-ref templates (demand-name d))))
                     (and tmpl
                          (call-with-values (lambda () (render-filing tmpl canon #:filer id))
                            (lambda (r f s) (cons (demand-name d) r))))))
                 ents)))
    `((agent        . ,agent)
      (entity-needs . ,(map demand-name ents))          ; the entity doors this mask must clear
      (person-needs . ,(map demand-name pers))          ; competences that ride named people
      (applications . ,apps))))                          ; ((demand-name . <filing resource>) …)

(define (adapter-spawn-agent s)        (assq-ref s 'agent))
(define (adapter-spawn-applications s) (assq-ref s 'applications))
(define (adapter-spawn-entity-needs s) (assq-ref s 'entity-needs))

;;; ─── RETIRE : the hollow check + the held-but-not-required audit ──────────
;;; A credential is a resource classed "credential"; a filing is classed
;;; "filing"; everything else the subject is primary-accountable for is
;;; SUBSTANCE (means of production, stock, credit) — the stuff an adapter must
;;; NOT hold if it is to be dissolved with nothing left behind.
(define (%classed? r tag)
  (let ((c (economic-resource-classified-as r))) (and (list? c) (member tag c) #t)))
(define (adapter-credentials observer subject)
  (filter (lambda (r) (%classed? r "credential")) ($ observer 'inventory-for-agent subject)))
(define (adapter-substance observer subject)
  (filter (lambda (r) (not (or (%classed? r "credential") (%classed? r "filing"))))
          ($ observer 'inventory-for-agent subject)))

;; held-but-not-required : credentials the subject holds that conform to NO
;; currently-required spec — exactly what to let lapse when a door is retired.
(define (held-but-not-required observer subject required-spec-ids)
  (filter (lambda (r) (not (member (economic-resource-conforms-to r) required-spec-ids)))
          (adapter-credentials observer subject)))

;; retire-adapter : → (values hollow? stale-credentials substance). `hollow?`
;; is the dissolution check — the adapter holds nothing substantive, so
;; dissolving it loses nothing the federation keeps (membership/hours/credit
;; live in the social ledger, not here). Pass the doors still open as
;; `required-spec-ids` so a partial retirement names only the freed credentials.
(define* (retire-adapter observer subject #:key (required-spec-ids '()))
  (values (null? (adapter-substance observer subject))
          (held-but-not-required observer subject required-spec-ids)
          (adapter-substance observer subject)))

;;; ─── ROTATE : same filings, fresh Agent, re-pointed custody ──────────────
;;; The appendix's "dissolve it and register another", as a pipeline. Because a
;;; filing is f(template, canonical), regenerating against a new subject is a
;;; re-render, not a rebuild; the returned `subject-at` re-points
;;; make-legal-decorate/observer's custody check at the new mask, and the planner
;;; keeps running. → (values fresh-spawn subject-at).
(define* (rotate-adapter #:key old-id new-id new-name jurisdiction (crossings '())
                         (place-path '()) (act #f) (rules #f)
                         (templates '()) (canonical '()))
  (let ((fresh (spawn-adapter #:id new-id #:name (or new-name new-id) #:jurisdiction jurisdiction
                              #:crossings crossings #:place-path place-path #:act act
                              #:rules rules #:templates templates #:canonical canonical)))
    (values fresh (lambda (proc cell) new-id))))         ; the decorate's new #:subject-at

;;; ─── EXPOSURE : the per-door posture of one mask (a query) ────────────────
;;; What doors it opens, what entity credentials it holds (folded as-of), what it
;;; owes (levies/disclosures), what is forbidden and what is only doubted, and
;;; the stance of the whole — one mask's legal surface.
;;; BILL+HITS, when the caller folded the bill already, spares a second fold.
;;; MEASURES, when the caller counted the subject, price each levy (`amounts`);
;;; what the law OFFERS the subject stands under `offered`, held or unclaimed.
(define* (adapter-exposure observer subject #:key (crossings '()) (place-path '())
                           (act #f) (rules #f) (as-of #f) (bill+hits #f) (measures #f))
  (let* ((bh   (or bill+hits
                   (adapter-bill #:crossings crossings #:place-path place-path #:act act #:rules rules)))
         (bill (car bh)) (hits (cadr bh))
         (sure? (lambda (d) (forbid-sure? d hits)))
         (status (lambda (d) (holding-status observer subject (demand-name d) as-of))))
    `((doors     . ,crossings)
      (stance    . ,(bill-stance bill hits #:crossings crossings))
      (holds     . ,(map (lambda (d) (cons (demand-name d) (status d)))
                         (bill-ref bill 'obtain-entity)))
      (owes      . ,(map demand-name (append (bill-ref bill 'pay)
                                             (bill-ref bill 'tell))))
      (amounts   . ,(filter-map (lambda (d) (let ((a (demand-amount d measures)))
                                              (and a (cons (demand-name d) a))))
                                (bill-ref bill 'pay)))
      (offered   . ,(map (lambda (d) (cons (demand-name d)
                                           (let ((s (status d))) (if (eq? s 'missing) 'unclaimed s))))
                         (bill-ref bill 'grant)))
      (forbidden . ,(map demand-name (filter sure? (bill-ref bill 'forbid))))
      (doubted   . ,(map demand-name (remove sure? (bill-ref bill 'forbid)))))))

;;; ─── subject-across-masks : a demand → the mask holding its door ──────────
;;; A mask is per-DOOR (localchimera.typ): each holds only the credentials of the
;;; doors it opens (its `entity-needs`). So a demand binds to WHICHEVER mask
;;; covers its spec — resolved here, not hard-coded by the caller. `mask-subject-of`
;;; builds exactly the `subject-of` reconcile/holding-status already take, so the
;;; compliance fold needs no change: an entity demand routes to its covering mask,
;;; a person (competence) demand to the named practitioner. An optional jurisdiction
;;; disambiguates the SAME spec held by different masks in different places.
(define (mask-jurisdiction agent)                 ; read the "jurisdiction:X" tag → X
  (agent-tag-value agent "jurisdiction"))
(define (adapter-covers? spawn spec)              ; this mask's door covers the credential?
  (and (member spec (adapter-spawn-entity-needs spawn)) #t))
(define* (resolve-mask masks spec #:optional (jurisdiction #f))
  (find (lambda (s) (and (adapter-covers? s spec)
                         (or (not jurisdiction)
                             (equal? (format #f "~a" jurisdiction)
                                     (mask-jurisdiction (adapter-spawn-agent s))))))
        masks))
;; → a reconcile/holding-status `subject-of`: entity demands to their mask,
;; person demands to the named practitioner (`person-of`), else `fallback`.
;; MASKS are spawns by default; COVERS? (mask spec) and ID-OF (mask) read any
;; other thing that answers for a demand — a body holding the spec
;; (legal/bodies.scm `body-reconcile-subject`).
(define* (mask-subject-of masks #:key (person-of (lambda (d) 'person)) (fallback 'scope)
                          (covers? adapter-covers?)
                          (id-of (lambda (m) (agent-id (adapter-spawn-agent m)))))
  "A `subject-of` over the adapters MASKS: the generic builder (legal/bodies.scm
   masks-subject-of) with an adapter's own reading of what a mask covers and
   whose agent it is."
  (masks-subject-of masks #:person-of person-of #:fallback fallback #:covers? covers? #:id-of id-of))

;;; ─── demo (only when run as a script) ────────────────────────────────────
(define (adapters-demo)
  (format #t "~%legal/adapters.scm — the mask as a fold:~%")
  (format #t "  make-adapter → an org <agent> tagged ~s, per door/jurisdiction~%" adapter-class)
  (format #t "  spawn-adapter  = Agent + legal-demands + render-filing (seed, don't build)~%")
  (format #t "  retire-adapter = hollow? check + held-but-not-required (dissolve clean)~%")
  (format #t "  rotate-adapter = re-render filings on a fresh Agent + re-point custody~%")
  (format #t "  see tests/observation/test-adapters.scm for spawn → retire → rotate.~%"))

(when (and (pair? (command-line))
           (string-suffix? "legal/adapters.scm" (car (command-line))))
  (adapters-demo))
