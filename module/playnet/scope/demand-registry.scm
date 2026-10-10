;;; scope/demand-registry.scm — per-scope registry of free-form demands
;;;
;;; A "demand" is someone in a scope saying "this place needs X". Each
;;; demand is a *partial intent* — every VF intent field is optional
;;; at propose-time. A proposer can voice "100 points, jacuzzi" with
;;; nothing else, or go all the way: "1 jacuzzi conforming to
;;; spec-hot-tub-v2 in room-302 by Q3". Fields can be filled in later
;;; via `elaborate` as the wish becomes concrete enough for the
;;; planner to solve for.
;;;
;;; Entry shape (alist):
;;;   (citizen               . aid)
;;;   (description           . str)                     ;; always required
;;;   (resource-conforms-to  . spec-id | #f)
;;;   (resource-classified-as . (tag ...))               ;; default: '()
;;;   (quantity-value        . number | #f)
;;;   (quantity-unit         . string | #f)              ;; e.g. "unit", "kg"
;;;   (at-location           . spatial-thing-id | #f)
;;;   (has-beginning         . iso-datetime | #f)
;;;   (has-end               . iso-datetime | #f)
;;;   (promoted-proposal     . proposal-id | #f)
;;;   (no-auto-unify         . bool — default #f)
;;;
;;; A slot's value may be:
;;;   - a ground datum (string/number)
;;;   - #f                           — anonymous hole, auto-identified
;;;                                    by (demand-id, field) coordinate
;;;                                    at unification time so others
;;;                                    can (link) to it
;;;   - (hole NAME)                  — named hole, shared across any
;;;                                    slot that uses the same NAME
;;;   - (link DEMAND-ID FIELD-KEY)   — this slot unifies with the
;;;                                    target slot of another demand
;;;                                    in the same unification session
;;;
;;; Holes and links let a proposer voice partial knowledge ("I want a
;;; jacuzzi at the same location as Alice's beer") in a way the
;;; unifier can resolve structurally.
;;;
;;; Quantity is stored as (value . unit) rather than a <measure>
;;; record so the entry persists cleanly as plain data; <measure> is
;;; rebuilt at intent-construction time by the bridge.

(define-module (playnet scope demand-registry)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:export (^demand-registry spawn-demand-registry demand-registry-env
            proposer-only-elaborate?
            make-demand-entry merge-demand-fields
            demand-entry-citizen demand-entry-description
            demand-entry-resource-conforms-to
            demand-entry-resource-classified-as
            demand-entry-quantity-value demand-entry-quantity-unit
            demand-entry-at-location
            demand-entry-has-beginning demand-entry-has-end
            demand-entry-promoted-proposal
            demand-entry-no-auto-unify
            *demand-entry-keys*
            ;; Slot-value references
            make-hole hole-ref? hole-name
            make-link link-ref? link-demand-id link-field))


;; =========================================================================
;; Slot-value references: named holes and inter-demand links
;; =========================================================================

;; A slot value may be a (hole NAME) tagged list. Any other slot using
;; the same NAME refers to the same underlying unknown. NAME is any
;; value comparable with equal? — symbols work well.
(define (make-hole name) (list 'hole name))
(define (hole-ref? x) (and (pair? x) (eq? (car x) 'hole)
                           (pair? (cdr x)) (null? (cddr x))))
(define (hole-name h) (cadr h))

;; A (link DEMAND-ID FIELD-KEY) tagged list. When the unifier resolves
;; this slot it walks to the target demand's FIELD-KEY slot and unifies
;; with whatever it finds there (ground, hole, another link, or #f).
;; Cycles are broken by falling back to the anonymous var for the
;; originating coordinate.
(define (make-link demand-id field-key) (list 'link demand-id field-key))
(define (link-ref? x) (and (pair? x) (eq? (car x) 'link)
                           (= (length x) 3)))
(define (link-demand-id l) (cadr l))
(define (link-field l)     (caddr l))


;; =========================================================================
;; Demand entry — alist over the partial-intent fields
;; =========================================================================

(define *demand-entry-keys*
  '(citizen description
    resource-conforms-to resource-classified-as
    quantity-value quantity-unit
    at-location has-beginning has-end
    promoted-proposal
    no-auto-unify))

(define (make-demand-entry citizen description fields)
  "Build a demand-entry alist. CITIZEN and DESCRIPTION are required;
   FIELDS is an alist over the optional keys (see header comment).
   Unknown keys in FIELDS are ignored silently."
  (define (field k default)
    (let ((pair (assq k fields)))
      (if pair (cdr pair) default)))
  `((citizen                . ,citizen)
    (description            . ,description)
    (resource-conforms-to   . ,(field 'resource-conforms-to   #f))
    (resource-classified-as . ,(field 'resource-classified-as '()))
    (quantity-value         . ,(field 'quantity-value         #f))
    (quantity-unit          . ,(field 'quantity-unit          #f))
    (at-location            . ,(field 'at-location            #f))
    (has-beginning          . ,(field 'has-beginning          #f))
    (has-end                . ,(field 'has-end                #f))
    (promoted-proposal      . ,(field 'promoted-proposal      #f))
    (no-auto-unify          . ,(field 'no-auto-unify          #f))))

(define (merge-demand-fields entry fields)
  "Return a new entry with each key in FIELDS overwriting the
   corresponding value in ENTRY. Keys in ENTRY not mentioned in FIELDS
   are preserved. Only the known *demand-entry-keys* are considered."
  (map (lambda (k)
         (let ((update (assq k fields))
               (existing (assq k entry)))
           (cond
             (update   update)
             (existing existing)
             (else     (cons k #f)))))
       *demand-entry-keys*))

(define (demand-entry-citizen e)                (assq-ref e 'citizen))
(define (demand-entry-description e)            (assq-ref e 'description))
(define (demand-entry-resource-conforms-to e)   (assq-ref e 'resource-conforms-to))
(define (demand-entry-resource-classified-as e) (assq-ref e 'resource-classified-as))
(define (demand-entry-quantity-value e)         (assq-ref e 'quantity-value))
(define (demand-entry-quantity-unit e)          (assq-ref e 'quantity-unit))
(define (demand-entry-at-location e)            (assq-ref e 'at-location))
(define (demand-entry-has-beginning e)          (assq-ref e 'has-beginning))
(define (demand-entry-has-end e)                (assq-ref e 'has-end))
(define (demand-entry-promoted-proposal e)      (assq-ref e 'promoted-proposal))
(define (demand-entry-no-auto-unify e)           (assq-ref e 'no-auto-unify))


;; =========================================================================
;; ^demand-registry actor
;; =========================================================================

(define-actor (^demand-registry bcom
                                demands   ;; hashmap demand-id → entry-alist
                                next-seq  ;; integer, monotonic id counter
                                #:optional
                                (can-elaborate? (lambda (caller-id entry) #t)))
  ;; CAN-ELABORATE? gates `elaborate` below — a closure, so (matching
  ;; ^governance-service's own governor? convention) it is never part of
  ;; #:portrait and #:restore always falls back to the permissive default,
  ;; the same as a fresh spawn-demand-registry call with no #:can-elaborate?.
  ;; A caller that needs a real policy across restarts re-supplies it via
  ;; spawn-demand-registry at boot, same as governor? is re-supplied fresh
  ;; from founders.txt every boot rather than persisted.

  #:portrait
  (lambda () (list demands next-seq))

  #:version 1

  #:restore
  (lambda (version d n)
    (case version
      ((1) (spawn ^demand-registry d n))
      (else (error "Unknown ^demand-registry version" version))))

  (methods

    ;; --- Reads ---

    ((get demand-id)
     (hashmap-ref demands demand-id #f))

    ((all)
     (hashmap-fold
       (lambda (did entry acc) (cons (cons did entry) acc))
       '() demands))

    ((ids)
     ;; Plain list of demand-ids — ready to feed to open-expression
     ;; (with domain='demand) as its target-ids argument.
     (hashmap-fold (lambda (did _e acc) (cons did acc)) '() demands))

    ;; --- Writes ---

    ((propose citizen-id description fields)
     ;; FIELDS is an alist of optional partial-intent fields (see
     ;; header). Pass '() for a free-form wish carrying only
     ;; description. Returns the new demand-id.
     (let* ((did   (string-append "demand-" (number->string next-seq)))
            (entry (make-demand-entry citizen-id description fields)))
       (bcom (^demand-registry bcom
                               (hashmap-set demands did entry)
                               (+ next-seq 1)
                               can-elaborate?)
             did)))

    ((elaborate demand-id fields caller-id)
     ;; Merge FIELDS into the existing entry, once CAN-ELABORATE? (spawn-
     ;; time predicate, see the actor header) admits CALLER-ID for this
     ;; entry. Missing entry, or a refused caller, → error.
     (let ((existing (hashmap-ref demands demand-id #f)))
       (cond
         ((not existing) (error "Unknown demand-id" demand-id))
         ((not (can-elaborate? caller-id existing))
          (error "not authorized to elaborate this demand" demand-id caller-id))
         (else
          (let ((merged (merge-demand-fields existing fields)))
            (bcom (^demand-registry bcom
                                    (hashmap-set demands demand-id merged)
                                    next-seq
                                    can-elaborate?)
                  'ok))))))

    ((set-policy demand-id key value)
     ;; Update a single policy field on an existing demand. Primary
     ;; use: toggle no-auto-unify per demand. KEY must be in
     ;; *demand-entry-keys*. Returns 'ok.
     (let ((existing (hashmap-ref demands demand-id #f)))
       (cond
         ((not existing) (error "Unknown demand-id" demand-id))
         ((not (memq key *demand-entry-keys*))
          (error "Unknown demand-entry key" key))
         (else
          (let ((updated (merge-demand-fields
                           existing (list (cons key value)))))
            (bcom (^demand-registry bcom
                                    (hashmap-set demands demand-id updated)
                                    next-seq
                                    can-elaborate?)
                  'ok))))))

    ((mark-promoted demand-id proposal-id)
     ;; Idempotent — sets the promoted-proposal-id for demand-id.
     (let ((existing (hashmap-ref demands demand-id #f)))
       (cond
         ((not existing) (error "Unknown demand-id" demand-id))
         (else
          (let ((updated (merge-demand-fields
                           existing
                           (list (cons 'promoted-proposal proposal-id)))))
            (bcom (^demand-registry bcom
                                    (hashmap-set demands demand-id updated)
                                    next-seq
                                    can-elaborate?)))))))))


(define* (spawn-demand-registry #:key
                                (can-elaborate? (lambda (caller-id entry) #t)))
  "Create an empty demand-registry. Must be called within a vat.

   CAN-ELABORATE? is (lambda (caller-id entry) bool) — refused callers get
   `elaborate' refused with an error. Default is permissive, matching
   spawn-governance-service's own governor? convention. proposer-only-
   elaborate? below is a dependency-free reference policy; a PHC-backed
   \"any member may elaborate\" policy lives in (playnet voice demand-bridge) as any-live-phc-holder-elaborate? — first-person.scm
   cannot be imported from this module without a circular dependency
   (first-person → credentials → planner → demand-registry). A full
   scope-steward tier (may-govern?'s fuller kind/members context) is a
   natural next refinement once elaborate has a real gateway door to gate."
  (spawn ^demand-registry (hashmap) 0 can-elaborate?))

(define (proposer-only-elaborate? caller-id entry)
  "Only the demand's own proposer may elaborate it."
  (equal? caller-id (demand-entry-citizen entry)))


(define demand-registry-env
  (make-persistence-env
    `((((playnet scope demand-registry) ^demand-registry)
       ,^demand-registry))))
