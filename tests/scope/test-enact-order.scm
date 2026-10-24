;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-enact-order.scm — a plan enacts in an order the books can serve, cycles included.
;;;
;;; A plan's material rows depend on one another: a good is made before it is used, a move
;;; lands the good where a consume needs it. A closed loop (a farm and a compost heap: scraps
;;; make soil, soil makes food and scraps) is a real cycle in those dependencies, and no
;;; order read off the graph exists. The books are the schedule: a row whose stock the books
;;; hold is enacted, a row they cannot yet serve waits for the rows that make its stock, and
;;; when nothing more can be served the rest are reported, never recorded against stock that
;;; is not there. So enacting the rows in ANY order conserves every spec: what is on hand
;;; afterwards is what was held, plus what was produced, less what was consumed.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/scope/test-enact-order.scm

(use-modules (localchimera solve report))
(use-modules ((localchimera vf formulas flows) #:select (row-figure))
             (localchimera test harness)
             (localchimera test books)
             (localchimera vf schemas) (srfi srfi-1) (srfi srfi-11)
             (localchimera scope live)
             (localchimera solve engine) (localchimera solve world) (localchimera solve compile) (localchimera solve solver)
             (goblins) (goblins vat) (goblins persistence-store memory) (goblins utils hashmap)
             (srfi srfi-1))

;; the loop world: ore → gizmo (move A→B) → meal; soil ↔ food/scraps
(declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.05))
                #:templates (list (list "mk"  '(("gizmo" . 1.0)) '(("ore" . 1.0)) 0.1)
                                  (list "eat" '(("meal" . 1.0))  '(("gizmo" . 1.0) ("salt" . 1.0)) 0.1)
                                  (list "farm" '(("food" . 1.0) ("scraps" . 1.0)) '(("soil" . 1.0)) 0.1)
                                  (list "compost" '(("soil" . 1.0)) '(("scraps" . 1.0)) 0.1))
                #:workers (list (list "w" '("sk") (cell "A" 0) 100.0) (list "w2" '("sk") (cell "B" 0) 100.0))
                #:movable '("gizmo") #:tau 0.5 #:neighbours '(("A" "B") ("B")))
(for-each (lambda (t) (hash-set! *proc-skill* (car t) "sk")) *templates*)
(hash-set! *init* (lg "ore" (cell "A" 0)) 100.0)
(hash-set! *init* (lg "salt" (cell "B" 0)) 100.0)
(hash-set! *demand* (lg "meal" (cell "B" 0)) 10.0)
(hash-set! *init* (lg "soil" (cell "A" 0)) 5.0)
(hash-set! *demand* (lg "food" (cell "A" 0)) 20.0)
(define E (resolve-module '(localchimera solve engine)))
(define planned
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x0 ((module-ref E 'located-warm) cols ncol idx))
             (x (call-with-values (lambda () (solve-native forms labform x0)) (lambda (x . _) x))))
        ((@ (localchimera solve report) plan->material) x cols idx)))))
(define (row m)
  `((id . ,(commitment-id m)) (action . ,(commitment-action m)) (conforms-to . ,(commitment-resource-conforms-to m))
    (quantity . ,(row-figure m))
    (at-location . ,(commitment-at-location m)) (input-of . ,(commitment-input-of m)) (output-of . ,(commitment-output-of m))
    (note . ,(commitment-note m))))
(define rows (map row planned))

(define seeds '(("ore" . 100.0) ("salt" . 100.0) ("soil" . 5.0)))
(define (expected spec)
  (+ (or (assoc-ref seeds spec) 0.0)
     (fold (lambda (r a)
             (if (equal? (assq-ref r 'conforms-to) spec)
                 (case (assq-ref r 'action) ((produce) (+ a (assq-ref r 'quantity))) ((consume) (- a (assq-ref r 'quantity))) (else a))
                 a))
           0.0 rows)))
(define (enact-in order)
  (let-values (((vat scope) (fresh-scope)))
    (with-vat vat
      (let ((obs ($ scope 'observer)))
        ($ obs 'seed-resource (res "ore1" "ore" 100.0 "A"))
        ($ obs 'seed-resource (res "salt1" "salt" 100.0 "B"))
        ($ obs 'seed-resource (res "soil1" "soil" 5.0 "A"))
        (let ((r (enact-rows scope order)))
          (list r (map (lambda (spec) (cons spec (spec-total obs spec))) '("ore" "salt" "soil" "gizmo" "meal" "food" "scraps"))))))))

(check "the loop plan emits material rows" (> (length rows) 4) #t)
(for-each
 (lambda (label order)
   (let* ((out (enact-in order)) (r (car out)) (totals (cadr out)))
     (check (format #f "~a: every row is enacted" label) (length (car r)) (length order))
     (check (format #f "~a: no row is left unserved" label) (cdr r) '())
     (check (format #f "~a: every spec is conserved (held + produced - consumed)" label)
            (every (lambda (t) (< (abs (- (cdr t) (expected (car t)))) 0.01)) totals) #t)))
 '("in the emitted order" "in reverse order")
 (list rows (reverse rows)))

;; the emitted order is itself a good schedule: the books serve each row as it comes
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      ($ obs 'seed-resource (res "ore1" "ore" 100.0 "A"))
      ($ obs 'seed-resource (res "salt1" "salt" 100.0 "B"))
      ($ obs 'seed-resource (res "soil1" "soil" 5.0 "A"))
      (check "the rows as emitted record one after another, with none refused"
             (catch #t (lambda () (for-each (lambda (r) (record-flow-done scope r)) rows) #t) (lambda _ #f)) #t))))

(let* ((ghost '((id . "g1") (action . consume) (conforms-to . "unobtanium") (quantity . 5.0)
                (at-location . "A") (input-of . "mk") (output-of . #f) (note . #f)))
       (out (car (enact-in (list ghost)))))
  (check "a row no stock can serve is not recorded, and is returned with its id"
         (list (car out) (map car (cdr out))) '(() ("g1"))))

;; a flow that leaves the stock as it was is an event naming no stock: a service
;; delivered is in the books as delivered, fulfilling its commitment
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let* ((obs ($ scope 'observer))
           (night '((id . "s1") (action . deliver-service) (conforms-to . "shelter-night") (quantity . 3.0)
                    (at-location . "A") (input-of . #f) (output-of . "host") (note . #f)))
           (r   (enact-rows scope (list night)))
           (evs (filter (lambda (e) (equal? (economic-event-fulfills e) "s1")) ($ obs 'all-events))))
      (check "a delivered service is enacted" (list (length (car r)) (cdr r)) '(1 ()))
      (check "…as one deliver-service event of its quantity, naming no stock"
             (map (lambda (e) (list (economic-event-action e) (economic-event-resource-inventoried-as e)
                                    (measure-has-numerical-value (economic-event-resource-quantity e))))
                  evs)
             '((deliver-service #f 3.0))))))

;; an action with no reading as a done flow is refused, and nothing is recorded
(let* ((odd '((id . "m1") (action . modify) (conforms-to . "gizmo") (quantity . 1.0)
              (at-location . "A") (input-of . #f) (output-of . "fix") (note . #f)))
       (out (car (enact-in (list odd)))))
  (check "a row whose action has no reading is returned, not ended in silence"
         (list (car out) (map car (cdr out))) '(() ("m1"))))

(test-summary!)
