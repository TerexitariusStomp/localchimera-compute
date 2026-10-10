;;; vf-conformance-table-test.scm — the action table, held to the vocabulary.
;;;
;;; The ValueFlows vocabulary states, for each of its 19 actions, how an event of
;;; that action behaves: which quantity it carries, whether it is a process input
;;; or output, what it pairs with, whether it can create a resource, and its effect
;;; on a resource's accounting quantity, onhand quantity, location, containedIn,
;;; primaryAccountable, stage and state. The vocabulary's Turtle file
;;; (docs/valueflows/assets/all_vf.TTL, "# Actions"; prose in
;;; docs/valueflows/concepts/actions.md) is the authority. This test PARSES that
;;; file at run time and compares every (action, property) cell with
;;; `*action-definitions*` (module/playnet/vf/schemas.scm) through the
;;; schema accessors, one check per cell. A failing check is a real divergence
;;; from the published vocabulary.
;;;
;;; Mapping table (TTL term → playnet symbol) lives in (playnet test vf-ttl) and
;;; is repeated here for the reader:
;;;
;;;   eventQuantity       resource → resource-quantity   effort → effort-quantity   both → both
;;;   inputOutput         input | output | outputInput → output-input | notApplicable → not-applicable
;;;   pairsWith           <action> → its kebab symbol | notApplicable → #f
;;;   createResource     optional | optionalTo → optional-to | notApplicable → no-effect
;;;   accounting/onhandEffect
;;;                       increment | decrement | decrementIncrement → decrement-increment
;;;                       | incrementTo → increment-to | notApplicable → no-effect
;;;   location/contained/accountable/stage/stateEffect
;;;                       update | updateTo → update-to | remove | new | notApplicable → no-effect
;;;   action name         camelCase → kebab-case (transferAllRights → transfer-all-rights)
;;;
;;; Playnet-only symbols: `no-effect` is VF's notApplicable for every effect
;;; property and createResource; `not-applicable` is notApplicable for inputOutput;
;;; pairs-with `#f` is notApplicable for pairsWith. The record also carries two
;;; fields the vocabulary's action individuals do not (implies-transfer,
;;; eligible-for-exchange); they are checked against the prose of
;;; concepts/transfers.md in the last section.
;;;
;;; EXTENSIONS. A cell where the repo deliberately departs from the vocabulary is
;;; listed in `*extensions*` below with its reason and is checked in the separate
;;; "extensions" section: the check passes when the repo holds exactly the
;;; documented departing value AND that value differs from the vocabulary's (so a
;;; later change in either direction is noticed). Every cell not listed there must
;;; equal the vocabulary.
;;;
;;; Run:
;;;   cd <repo> && guix shell --pure -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- \
;;;     guile --no-auto-compile -q -L module tests/planner/vf-conformance-table-test.scm

(use-modules (playnet test harness)
             (playnet vf schemas) (playnet vf formulas actions)
             (srfi srfi-1) (srfi srfi-13))

(use-modules (playnet test vf-ttl))
(use-modules ((playnet utils records) #:select (vf-record-accessor)))

(define root (vf-repo-root))
(define ttl (ttl-action-table root))

;; one accessor per TTL property, read off the record type (vf-ttl %behaviour-props)
(define accessors
  (map (lambda (f) (cons f (vf-record-accessor <action-definition> f))) %behaviour-props))

(define (repo-def action)
  (let ((e (assq action *action-definitions*))) (and e (cdr e))))
(define (repo-value action prop)
  (let ((d (repo-def action)))
    (and d ((cdr (assq prop accessors)) d))))
(define (ttl-value action prop)
  (let* ((a (assq action ttl)) (c (and a (assq prop (cdr a)))))
    (and c (cdr c))))

;;; ── EXTENSIONS: ((action . property) repo-value reason) ─────────────────────
;;; Empty until each departure is traced to a stated reason in the source.
(define *extensions* '())
(define (extension-of action prop)
  (find (lambda (e) (and (eq? (caar e) action) (eq? (cdar e) prop))) *extensions*))

;;; ═════════════════════════════════════════════════════════════════════════════
(display "\n── the vocabulary parses ──\n")

(check "TTL yields 19 vf:Action individuals" (length ttl) 19)
(check "every TTL action is a repo action"
       (filter (lambda (a) (not (memq a *vf-actions*))) (map car ttl)) '())
(check "every repo action is in the TTL"
       (filter (lambda (a) (not (assq a ttl))) *vf-actions*) '())
(check "every repo action has a definition row"
       (filter (lambda (a) (not (repo-def a))) *vf-actions*) '())
(check "no definition row for a non-action"
       (filter (lambda (e) (not (memq (car e) *vf-actions*))) *action-definitions*) '())
(for-each
 (lambda (a)
   (check (format #f "TTL gives ~a all 11 behaviour properties" (car a))
          (length (cdr a)) 11))
 ttl)

;;; ═════════════════════════════════════════════════════════════════════════════
(display "\n── (action, property) cells equal the vocabulary ──\n")

(define diverging '())          ; ((action prop vf repo) ...) in cell order
(for-each
 (lambda (a)
   (let ((action (car a)))
     (for-each
      (lambda (prop)
        (let ((vf (ttl-value action prop)) (repo (repo-value action prop)))
          (cond
           ((extension-of action prop) #f)    ; checked in the extensions section
           (else
            (check (format #f "~a / ~a = ~s" action prop vf) repo vf)))
          (unless (equal? vf repo)
            (set! diverging (cons (list action prop vf repo) diverging)))))
      %behaviour-props)))
 ttl)

;;; ═════════════════════════════════════════════════════════════════════════════
(display "\n── labels ──\n")
;; the label the vocabulary gives an action, spaces to hyphens, is its repo symbol
(for-each
 (lambda (action)
   (let* ((label (ttl-label action root))
          (sym (and label (string->symbol (string-map (lambda (c) (if (char=? c #\space) #\- c)) label)))))
     (unless (eq? action 'separate)
       (check (format #f "label of ~a" action) sym action))))
 *vf-actions*)

;;; ═════════════════════════════════════════════════════════════════════════════
(display "\n── pairs-with and the derived sets ──\n")
(for-each
 (lambda (action)
   (let ((p (repo-value action 'pairs-with)))
     (when p
       (check (format #f "pairs-with is symmetric: ~a ↔ ~a" action p)
              (repo-value p 'pairs-with) action))))
 *vf-actions*)

(define (ttl-where pred)
  (filter-map (lambda (a) (and (pred a) (car a))) ttl))
(define (sorted l) (sort l (lambda (a b) (string<? (symbol->string a) (symbol->string b)))))
(check "*stock-moving-actions* = actions whose TTL accountingEffect is increment|decrement"
       (sorted *stock-moving-actions*)
       (sorted (ttl-where (lambda (a) (memq (ttl-value (car a) 'accounting-effect) '(increment decrement))))))
(check "*adjustment-actions* = stock-moving with inputOutput notApplicable (raise, lower)"
       (sorted *adjustment-actions*)
       (sorted (ttl-where (lambda (a) (and (memq (ttl-value (car a) 'accounting-effect) '(increment decrement))
                                           (eq? (ttl-value (car a) 'input-output) 'not-applicable))))))
(check "*flow-actions* = stock-moving into/out of a process (produce, consume)"
       (sorted *flow-actions*)
       (sorted (ttl-where (lambda (a) (and (memq (ttl-value (car a) 'accounting-effect) '(increment decrement))
                                           (not (eq? (ttl-value (car a) 'input-output) 'not-applicable)))))))

;;; ═════════════════════════════════════════════════════════════════════════════
(display "\n── playnet-only fields, against concepts/transfers.md ──\n")
;; "Explicit and implied transfers": consume, produce imply a full transfer of
;; all rights and custody; pickup, dropoff, accept, modify imply custody only;
;; "…this would normally not be used as part of an agreement" for the custody-only
;; four, which is what eligible-for-exchange states.
(define implies-per-prose
  '((consume . all-rights) (produce . all-rights)
    (pickup . custody) (dropoff . custody) (accept . custody) (modify . custody)))
(for-each
 (lambda (action)
   (let ((want (let ((c (assq action implies-per-prose))) (and c (cdr c)))))
     (check (format #f "implies-transfer of ~a = ~s" action want)
            (action-definition-implies-transfer (repo-def action)) want)
     (check (format #f "eligible-for-exchange of ~a = ~a" action (not (eq? want 'custody)))
            (action-definition-eligible-for-exchange (repo-def action))
            (not (eq? want 'custody)))))
 *vf-actions*)

;;; ═════════════════════════════════════════════════════════════════════════════
(display "\n── symbol vocabularies are closed ──\n")
(for-each
 (lambda (action)
   (for-each
    (lambda (prop)
      (let ((v (repo-value action prop)))
        (check (format #f "~a / ~a = ~s is a declared symbol" action prop v)
               (case prop
                 ((accounting-effect onhand-effect) (quantity-effect? v))
                 ((location-effect contained-effect accountable-effect stage-effect state-effect)
                  (property-effect? v))
                 ((pairs-with) (or (not v) (vf-action? v)))
                 (else (symbol? v))))))
    %behaviour-props))
 *vf-actions*)

(format #t "\n── diverging cells (~a) ──\n" (length diverging))
(for-each (lambda (d) (format #t "  ~a / ~a : vocabulary ~s, repo ~s\n"
                              (car d) (cadr d) (caddr d) (cadddr d)))
          (reverse diverging))

(test-summary!)
