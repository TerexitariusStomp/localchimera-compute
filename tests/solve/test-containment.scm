;;; test-containment.scm — storage is transport through TIME; loss is a recipe consume.
;;;
;;; Inspecting build-columns directly (solver-independent):
;;;
;;;   (1) STORAGE = a `store` recipe over a TEMPORAL arc (town@0 → town@1), tiled by the
;;;       SAME arc machinery as transport. SPOILAGE is a `consume` of the good, sized by
;;;       the recipe — exactly parallel to wear (a consume of a durable's condition), NOT
;;;       a per-good *retention* rail. Storing 1 unit to next period consumes (1+spoil) now
;;;       and delivers 1 — the spoil is the loss.
;;;
;;;   (2) `move` is a first-class action: a recipe flow with action `move` (spatial
;;;       relocation, same custody) marks its good movable — a lossless free carry.
;;;
;;; Run:  tools/test/run-suite.sh tests/solve/test-containment.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (srfi srfi-1) (ice-9 format) ((playnet solve world) #:select (*templates*)))
(use-modules (playnet solve engine)
             (playnet solve compile)
             (playnet vf schemas))

;; ── (1) store recipe over a temporal arc; spoilage = a consume of the good ─────────
;; (the relocation and the spoilage are SEPARATE flow entries on milk@0 — the solver sums them.)
(define (sum-coeff flows g) (fold (lambda (fc a) (if (equal? (car fc) g) (+ a (cdr fc)) a)) 0.0 flows))
(define (store-flows spoil)
  (declare-world! #:places '(("town" 0.0 0.0)) #:periods '(0 1))
  ;; after the declaration: store-recipe marks the warehouse stationary as it compiles
  (set-templates! (append (compile-recipe (list (rp "mk" "Make milk"))
                                          (list (out "m1" "milk" 1.0 "mk") (wrk "m2" 1.0 "mk")))
                          (list (store-recipe "milk" #:spoil spoil))))   ; STORE milk in a warehouse, losing `spoil`/period
  (let ((scol (find (lambda (c) (equal? (car c) "p|store.milk|town@0|town@1")) (build-columns))))   ; tiled over a TIME arc — because the warehouse is stationary (derived, not marked)
    (and scol (cons (sum-coeff (cadr scol) (lg "milk" (cell "town" 0)))           ; milk consumed @0  (= −(1+spoil))
                    (sum-coeff (cadr scol) (lg "milk" (cell "town" 1)))))))        ; milk delivered @1 (= +1)

;; ── (2) `move` action ⇒ the good is movable (a transport column exists) ──────────
(define (compiled-moved+has-col with-ship?)
  (declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.5))
                  #:templates
                    (compile-recipe (append (list (rp "mw" "Make widget")) (if with-ship? (list (rp "sw" "Ship widget")) '()))
                                    (append (list (out "w1" "widget" 1.0 "mw") (wrk "w2" 1.0 "mw"))
                                            (if with-ship?
                                                (list (make-recipe-flow #:id "w3" #:action 'move
                                                                        #:resource-conforms-to "widget"
                                                                        #:resource-quantity (make-measure 1.0 %count-unit)
                                                                        #:recipe-input-of "sw"))
                                                '()))))
  (cons (append-map proc-moved *templates*)                                            ; what compile-process recorded as `move`d
        (and (find (lambda (c) (equal? (car c) "m|widget|A@0|B@0")) (build-columns)) #t)))  ; did a transport column appear?

(define s0  (store-flows 0.0))
(define s04 (store-flows 0.4))
(define noship (compiled-moved+has-col #f))
(define ship   (compiled-moved+has-col #t))

(format #t "~%── (1) store milk town@0 → town@1 (a temporal-arc recipe; spoilage = a consume) ──~%")
(format #t "  lossless spoil=0   : consumed@0 = ~a , delivered@1 = ~a~%" (car s0) (cdr s0))
(format #t "  spoils   spoil=0.4 : consumed@0 = ~a , delivered@1 = ~a   (0.4 lost per unit kept)~%" (car s04) (cdr s04))
(format #t "~%── (2) `move` action ⇒ movable (lossless free carry) ──~%")
(format #t "  no ship recipe : compile-process moved = ~a, transport column? ~a~%" (car noship) (cdr noship))
(format #t "  with ship recipe: compile-process moved = ~a, transport column? ~a~%" (car ship) (cdr ship))

(let* ((c1 (and s0  (< (abs (- (car s0)  -1.0)) 1e-9) (< (abs (- (cdr s0)  1.0)) 1e-9)))   ; lossless: in 1, out 1
       (c2 (and s04 (< (abs (- (car s04) -1.4)) 1e-9) (< (abs (- (cdr s04) 1.0)) 1e-9)))   ; spoils: in 1.4, out 1 — the 0.4 is the loss-consume
       (c3 (and (null? (car noship)) (not (cdr noship)))) ; no `move` ⇒ nothing moved, no transport column
       (c4 (and (member "widget" (car ship)) (cdr ship))) ; `move` ⇒ widget recorded moved AND a transport column exists
       (ok (and c1 c2 c3 c4)))
  (format #t "~%  [~a] lossless store: consume 1 → deliver 1                (~a → ~a)~%" (if c1 "✓" "✗") (car s0) (cdr s0))
  (format #t "  [~a] spoilage is a CONSUME on the recipe: 1.4 in, 1 out    (~a → ~a)~%" (if c2 "✓" "✗") (car s04) (cdr s04))
  (format #t "  [~a] no `move` recipe ⇒ good not movable                   (moved = ~a)~%" (if c3 "✓" "✗") (car noship))
  (format #t "  [~a] `move` recipe ⇒ good movable, transport column        (moved = ~a)~%" (if c4 "✓" "✗") (car ship))
  (format #t "~%  ~a storage = a temporal-arc recipe; loss = a recipe consume (like wear) — no per-good retention rail~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
