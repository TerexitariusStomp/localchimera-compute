;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; playnet/matching/filter-rule.scm — the slot's ELIGIBILITY rule,
;;; and the criteria sidecar it rides in on the wire.
;;;
;;; free-association's `filter_rule` (protocol/filters + filters/eligibility):
;;; a JSON-logic expression on a slot that says who the slot may be paired
;;; with, evaluated BILATERALLY — the need's rule over the offer's side and the
;;; offer's rule over the need's — before any allocation. Ours is the same
;;; idea in the commons' own vocabulary, kept as an s-expression written in
;;; JSON arrays (so the dial writes it and the gateway carries it verbatim):
;;;
;;;   true | false                     allow all | deny all ("deny-all" inside;
;;;                                    #f is the ABSENT rule, which allows)
;;;   ["aid", A, …]                    the other side IS one of these AIDs
;;;   ["not-aid", A, …]                … is not
;;;   ["min-recognition", r]           my recognition of them ≥ r  (0..1)
;;;   ["in-scope", S, …]               they stand in one of these scopes
;;;   ["has-skill", SPEC, …]           they hold one of these skills
;;;   ["in-group", REL, …]             they hold one of these rels in MY
;;;                                    contact book ("friends", "family", …)
;;;   ["vouched"]                      I hold a live signed vouch for them
;;;   ["within-km", d]                 they are within d km (unknown → passes)
;;;   ["and", …] ["or", …] ["not", x]  the connectives
;;;
;;; The rule is evaluated over a CONTEXT alist describing the other side —
;;; ((aid . str) (recognition . num|#f) (scopes . (str …)) (skills . (str …))
;;; (groups . (str …)) (vouched . bool) (distance-km . num|#f)) — built by whoever pairs slots: match-slots,
;;; feasibility, deferred-acceptance. A rule the evaluator does not understand
;;; is a rule that DENIES (a typo in a lock must not open the door).
;;;
;;; The sidecar: `criteria` on the declare wire is one JSON object holding the
;;; rule and the other matcher-only fields <intent-matching-criteria> already
;;; names — min-atomic-size, max-participation, max-concurrency, online-link,
;;; priority — parsed here into an alist and handed back to the dial as it
;;; came, so both sides read one shape.

(define-module (playnet matching filter-rule)
  #:use-module (srfi srfi-1)
  #:use-module ((json parser) #:select (json-string->scm))
  #:use-module ((playnet social relationship-kinds) #:select (rel=?))
  #:export (criteria-json->alist
            criteria-ref
            context
            priority-for
            rule-passes?
            rule-preset))

;; JSON arrays arrive as vectors; nested rules are read as vectors too, and
;; are kept that way so the alist round-trips through scm->json as arrays.
(define (->list x)
  (cond ((vector? x) (vector->list x)) ((list? x) x) (else '())))

(define %criteria-keys
  '("filter-rule" "min-atomic-size" "max-participation" "max-concurrency"
    "online-link" "priority" "priority-distribution" "search-radius-km"))

(define (priority-for criteria aid)
  "The weight CRITERIA's priority-distribution gives AID (0..1), else its flat
   priority, else #f (no say). free-association's SlotPriorityDistribution:
   per-person priorities on a capacity that override the global recognition
   for this one slot."
  (let* ((dist (criteria-ref criteria 'priority-distribution))
         (p (and dist (list? dist) aid (assoc aid dist))))
    (cond ((and p (number? (cdr p))) (cdr p))
          ((number? (criteria-ref criteria 'priority)) (criteria-ref criteria 'priority))
          (else #f))))

(define (criteria-json->alist json)
  "Parse the declare wire's criteria JSON object into an alist keyed by
   symbol — only the known keys, only when set (a null or empty value is a
   field the citizen left blank). #f when absent/unparseable."
  (and (string? json) (not (string-null? json))
       (let ((parsed (catch #t (lambda () (json-string->scm json)) (lambda _ #f))))
         (and (list? parsed) (pair? parsed)
              (let ((kept
                     (filter-map
                      (lambda (k)
                        (let ((p (assoc k parsed)))
                          (and p
                               (let ((v (cdr p)))
                                 (and (not (eq? v 'null))
                                      (not (and (string? v) (string-null? v)))
                                      ;; JSON false on the rule is "nobody" — kept
                                      ;; as the word, since #f is the absent rule
                                      (cons (string->symbol k)
                                            (if (and (equal? k "filter-rule") (eq? v #f))
                                                "deny-all" v)))))))
                      %criteria-keys)))
                (and (pair? kept) kept))))))

(define (criteria-ref criteria key)
  "One field of a criteria alist, or #f."
  (and criteria (assq-ref criteria key)))

;; ── the context a rule reads ────────────────────────────────────────────────
;; The one shape every side of an eligibility check is built into, whatever
;; the source: feasibility.scm reads it off an <intent-binding>'s weights and
;; location, service.scm's match-slots off the agent-store's contact book and
;; the scope's spatial-things. Naming it here — beside the vocabulary that
;; reads it — means a new key is one signature change, not two hand-edited
;; alist literals drifting apart. KNOWS is how the rule's owner knows the other
;; side — the alist a `knows` reading answers, ((recognition . r) (groups .
;; rels) (vouched . bool)), governance's make-knows over the owner's contact
;; book and signed vouches — so every pairing door hands the rule the same
;; social facts; a key the caller states itself wins.
(define* (context #:key aid recognition scopes skills groups vouched distance-km knows)
  (define (known key) (and (pair? knows) (assq-ref knows key)))
  `((aid . ,aid) (recognition . ,(or recognition (known 'recognition)))
    (scopes . ,(or scopes '())) (skills . ,(or skills '()))
    (groups . ,(or groups (known 'groups) '()))
    (vouched . ,(and (or vouched (known 'vouched)) #t))
    (distance-km . ,distance-km)))

;; ── the evaluator ──────────────────────────────────────────────────────────
(define (rule-passes? rule ctx)
  "Does RULE admit the other side CTX describes? Absent rule = allow."
  (define (get k) (assq-ref ctx k))
  (define (num? x) (and (number? x) (not (nan? x))))
  (define (eval-rule r) (if (eval-rule* r) #t #f))
  (define (eval-rule* r)
    (cond
     ((eq? r #t) #t)
     ((eq? r #f) #f)
     ((eq? r 'null) #t)
     ((equal? r "allow-all") #t)
     ((equal? r "deny-all") #f)
     ((or (vector? r) (pair? r))
      (let* ((l (->list r)) (op (and (pair? l) (car l))) (args (if (pair? l) (cdr l) '())))
        (cond
         ((equal? op "and") (every eval-rule args))
         ((equal? op "or")  (any eval-rule args))
         ((equal? op "not") (and (pair? args) (not (eval-rule (car args)))))
         ((equal? op "aid")     (and (get 'aid) (member (get 'aid) args) #t))
         ((equal? op "not-aid") (not (and (get 'aid) (member (get 'aid) args))))
         ((equal? op "min-recognition")
          (let ((r (and (pair? args) (car args))) (mine (get 'recognition)))
            (and (num? r) (num? mine) (>= mine r))))
         ((equal? op "in-scope")
          (any (lambda (s) (member s (or (get 'scopes) '()))) args))
         ((equal? op "has-skill")
          (any (lambda (s) (member s (or (get 'skills) '()))) args))
         ((equal? op "in-group")
          (any (lambda (g) (member g (or (get 'groups) '()) rel=?)) args))
         ((equal? op "vouched") (and (get 'vouched) #t))
         ((equal? op "within-km")
          (let ((d (and (pair? args) (car args))) (have (get 'distance-km)))
            (or (not (num? have)) (and (num? d) (<= have d)))))
         (else #f))))                       ; an unknown clause denies
     (else #f)))
  (if (or (not rule) (eq? rule 'null)) #t
      (catch #t (lambda () (eval-rule rule)) (lambda _ #f))))

;; the presets the 🔒 section offers, by name — the same six free-association's
;; FilterRuleEditor ships, in our vocabulary (allow_all · deny_all · trust · …)
(define (rule-preset name)
  (cond ((equal? name "allow-all") #t)
        ((equal? name "deny-all") "deny-all")
        ((equal? name "trusted") (vector "min-recognition" 0.5))
        ((equal? name "known") (vector "min-recognition" 0.01))
        ((equal? name "nearby") (vector "within-km" 10))
        (else #t)))
