;;; demand-unify.scm — structural unification of partial demand entries
;;;
;;; Slot grammar (from demand-registry.scm):
;;;   ground-value | (hole NAME) | (link DEMAND-ID FIELD) | #f
;;;
;;; Unification proceeds inside a *session* that owns the shared
;;; namespace for holes and anonymous coordinates:
;;;
;;;   - two slots with (hole ?X) share one logic var — across
;;;     different demands and different clusters;
;;;   - a (link d-id field) slot shares the var of its target slot,
;;;     so ground values propagate through links;
;;;   - every #f slot is auto-identified by its (demand-id, field)
;;;     coordinate, so another demand can (link) to a specific #f
;;;     even when the proposer didn't bother to name it.
;;;
;;; Link cycles fall back to the originating coordinate's anon var.
;;;
;;; Because the session's substitution is shared across every pairwise
;;; merge in a clustering pass, a ground binding discovered in one
;;; cluster propagates to every demand (clustered or solo) that
;;; mentions the same hole name.

(define-module (playnet deprecated governance demand-unify)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)                 ;; let*-values
  #:use-module (srfi srfi-13)                 ;; string-join
  #:use-module (playnet lang kanren)
  #:use-module (playnet scope demand-registry)
  #:export (try-unify-entries
            unify-demand-cluster
            *unifiable-keys*))


;; =========================================================================
;; Which fields unify
;; =========================================================================

(define *unifiable-keys*
  '(resource-conforms-to
    at-location
    quantity-unit
    has-beginning
    has-end))


;; =========================================================================
;; Session — shared namespace over a set of demands being unified
;; =========================================================================
;;
;; A session carries three alists:
;;   demands    : (demand-id . entry) ...
;;   hole-vars  : (hole-name . kanren-var) ...
;;   anon-vars  : ((demand-id . field) . kanren-var) ...

(define (make-session demands)
  "Build a session over DEMANDS (a list of (demand-id . entry) pairs).
   Walks each demand's unifiable slots once: a fresh kanren var is
   allocated per distinct (hole NAME), and per (demand-id, field)
   coordinate whose slot is #f."
  (let loop ((rest demands) (counter 0) (holes '()) (anons '()))
    (cond
      ((null? rest)
       (list (cons 'demands   demands)
             (cons 'hole-vars holes)
             (cons 'anon-vars anons)))
      (else
       (let ((did (caar rest)) (entry (cdar rest)))
         (let-values (((counter holes anons)
                       (scan-entry-slots did entry counter holes anons)))
           (loop (cdr rest) counter holes anons)))))))

(define (scan-entry-slots did entry counter holes anons)
  "For each unifiable slot in ENTRY: register a fresh var for a
   (hole NAME) that hasn't been seen yet, or a fresh var for a #f
   slot keyed by (did . field). Returns (values counter holes anons)."
  (let ((result
          (fold (lambda (field acc)
                  (let ((c (list-ref acc 0))
                        (h (list-ref acc 1))
                        (a (list-ref acc 2))
                        (slot (assq-ref entry field)))
                    (cond
                      ((not slot)
                       (list (+ c 1) h
                             (cons (cons (cons did field) (var c)) a)))
                      ((hole-ref? slot)
                       (let ((name (hole-name slot)))
                         (cond
                           ((assoc name h) (list c h a))
                           (else (list (+ c 1)
                                       (cons (cons name (var c)) h)
                                       a)))))
                      (else (list c h a)))))
                (list counter holes anons)
                *unifiable-keys*)))
    (values (list-ref result 0)
            (list-ref result 1)
            (list-ref result 2))))

(define (session-demand session did)   (assoc-ref (assq-ref session 'demands)   did))
(define (session-hole-var s name)      (assoc-ref (assq-ref s 'hole-vars) name))
(define (session-anon-var s did field) (assoc-ref (assq-ref s 'anon-vars)
                                                  (cons did field)))


;; =========================================================================
;; Slot → kanren term
;; =========================================================================

(define (slot-term session did field slot-value visited)
  "Resolve SLOT-VALUE to a kanren term. VISITED is a list of
   (demand-id . field) coordinates on the resolution path; used to
   break link cycles."
  (cond
    ((not slot-value)
     (session-anon-var session did field))
    ((hole-ref? slot-value)
     (session-hole-var session (hole-name slot-value)))
    ((link-ref? slot-value)
     (let ((t-did (link-demand-id slot-value))
           (t-fld (link-field slot-value)))
       (cond
         ((member (cons t-did t-fld) visited)
          (session-anon-var session did field))
         (else
          (let ((target (session-demand session t-did)))
            (cond
              ((not target) (session-anon-var session did field))
              (else
               (slot-term session t-did t-fld
                          (assq-ref target t-fld)
                          (cons (cons did field) visited)))))))))
    (else slot-value)))


;; =========================================================================
;; Pairwise unification within a session
;; =========================================================================

(define (unify-pair session subst did-a entry-a did-b entry-b)
  "Unify all unifiable slots between two demands, extending SUBST.
   Returns the new substitution, or #f on conflict."
  (fold (lambda (key subst)
          (and subst
               (unify (slot-term session did-a key (assq-ref entry-a key) '())
                      (slot-term session did-b key (assq-ref entry-b key) '())
                      subst)))
        subst
        *unifiable-keys*))


;; =========================================================================
;; Reification — walk slots with the final substitution
;; =========================================================================

(define (reify-slot session did field subst slot-value)
  "Walk the slot's term through SUBST. Still-unbound → preserve the
   original slot-value shape (hole / link / #f) so the caller sees
   what was not resolved."
  (let ((w (walk* (slot-term session did field slot-value '()) subst)))
    (if (var? w) slot-value w)))

(define (reify-whole-entry session did entry subst)
  "Walk every unifiable slot of ENTRY through SUBST. Non-unifiable
   fields (citizen, description, promoted-proposal, …) pass through."
  (map (lambda (pair)
         (cond
           ((memq (car pair) *unifiable-keys*)
            (cons (car pair) (reify-slot session did (car pair) subst
                                          (cdr pair))))
           (else pair)))
       entry))

(define (cluster->unified session cluster subst)
  "Turn CLUSTER (a non-empty list of (did . entry) pairs, oldest
   first) into one unified entry. Unifiable slots are reified from the
   primary; classification tags set-union across all members;
   quantity-value sums numeric contributions; description joins with
   ' + '."
  (let* ((primary (car cluster))
         (p-did   (car primary))
         (p-entry (cdr primary))
         (entries (map cdr cluster))
         (tags (fold (lambda (e acc)
                       (lset-union equal? acc
                         (or (demand-entry-resource-classified-as e) '())))
                     '() entries))
         (qv-sum (fold (lambda (e acc)
                         (let ((qv (demand-entry-quantity-value e)))
                           (cond ((and qv acc) (+ acc qv))
                                 (qv qv)
                                 (else acc))))
                       #f entries))
         (desc (string-join (map demand-entry-description entries) " + "))
         (reify-p (lambda (k) (reify-slot session p-did k subst
                                           (assq-ref p-entry k)))))
    `((citizen                . ,(demand-entry-citizen p-entry))
      (description            . ,desc)
      (resource-conforms-to   . ,(reify-p 'resource-conforms-to))
      (resource-classified-as . ,tags)
      (quantity-value         . ,qv-sum)
      (quantity-unit          . ,(reify-p 'quantity-unit))
      (at-location            . ,(reify-p 'at-location))
      (has-beginning          . ,(reify-p 'has-beginning))
      (has-end                . ,(reify-p 'has-end))
      (promoted-proposal      . #f)
      (no-auto-unify          . #f))))


;; =========================================================================
;; Cluster-level sweep
;; =========================================================================
;;
;; Clusters during the sweep are lists of (did . entry) pairs, oldest
;; first. No separate "primary" slot — the primary is always (car c).

(define (unify-demand-cluster demands)
  "Cluster DEMANDS (list of (demand-id . entry)) via session-scoped
   unification. Demands with no-auto-unify=#t pass through as solos.
   Returns (values CLUSTERS SOLOS) where:
     CLUSTERS = list of (UNIFIED-ENTRY MEMBER-ID ...), ≥ 2 members each.
     SOLOS    = list of (demand-id . entry), reified under the final
                session substitution so holes and links benefit from
                any ground bindings discovered elsewhere in the pass.

   Greedy pairwise sweep over a single session-wide substitution."
  (let ((session (make-session demands)))
    (let loop ((rest demands) (clusters '()) (opt-outs '()) (subst empty-subst))
      (cond
        ((null? rest)
         (finalize session subst (reverse clusters) (reverse opt-outs)))
        (else
         (let ((head (car rest)))
           (cond
             ((demand-entry-no-auto-unify (cdr head))
              (loop (cdr rest) clusters (cons head opt-outs) subst))
             (else
              (let-values (((new-clusters new-subst)
                             (join-or-start session subst clusters head)))
                (loop (cdr rest) new-clusters opt-outs new-subst))))))))))

(define (join-or-start session subst clusters new-member)
  "Try to merge NEW-MEMBER (a (did . entry) pair) into the first
   cluster whose primary unifies with it. On success, append it to
   that cluster (preserving order) and return the updated subst. On
   no match, start a new singleton cluster. Returns (values CLUSTERS
   SUBST)."
  (let loop ((acc '()) (rest clusters))
    (cond
      ((null? rest)
       (values (reverse (cons (list new-member) acc)) subst))
      (else
       (let* ((c (car rest))
              (primary (car c))
              (attempt (unify-pair session subst
                                    (car primary) (cdr primary)
                                    (car new-member) (cdr new-member))))
         (cond
           (attempt
            (values (append (reverse acc)
                            (cons (append c (list new-member)) (cdr rest)))
                    attempt))
           (else (loop (cons c acc) (cdr rest)))))))))

(define (finalize session subst clusters opt-outs)
  "Split CLUSTERS into multi-member (→ unified entries) and singletons
   (→ solos). Reify singletons and opt-outs under SUBST."
  (let-values (((multi single) (partition (lambda (c) (> (length c) 1))
                                           clusters)))
    (values
      (map (lambda (c)
             (cons (cluster->unified session c subst) (map car c)))
           multi)
      (append
        (map (lambda (c)
               (let ((p (car c)))
                 (cons (car p) (reify-whole-entry session (car p) (cdr p) subst))))
             single)
        (map (lambda (opt)
               (cons (car opt)
                     (reify-whole-entry session (car opt) (cdr opt) subst)))
             opt-outs)))))


;; =========================================================================
;; Convenience: pairwise API is now a thin wrapper
;; =========================================================================

(define (try-unify-entries a b)
  "Two-entry convenience wrapper around unify-demand-cluster. Returns
   the unified entry, or #f if the pair doesn't unify. For
   cross-demand (link) references to resolve, callers must use
   unify-demand-cluster with demand-ids that match the link targets."
  (call-with-values
    (lambda ()
      (unify-demand-cluster (list (cons 'A a) (cons 'B b))))
    (lambda (clusters _solos)
      (and (pair? clusters) (car (car clusters))))))
