;;; emit-matter-snapshot.scm — run the REAL substance-flow wire over a demo
;;; nutrient-cycle solve and emit browser/data/snapshots/matter-snapshot.json (the matter-face
;;; fallback). What the browser shows is the OUTPUT of matter-results->wire over
;;; the contains relation — not invented, not re-derived in JS. The live planner
;;; service produces the same shape on demand (window.__matterFlow); this
;;; committed file is the offline fallback. Mirrors tools/emit/emit-law-snapshot.scm.
;;;
;;;   guix shell -m deploy/manifests/dev-test-manifest.scm -- \
;;;     guile --no-auto-compile -q -L module tools/emit/emit-matter-snapshot.scm

(use-modules (playnet scope root) (playnet vf schemas)
             (playnet doors service)
             (playnet knowledge catalogues substances)
             (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1)
             (ice-9 format))

(define root (dirname (dirname (current-filename))))
(define (rel p) (string-append root "/" p))

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Matter Demo")) store))

;; spec names so the resource nodes read nicely (compost back to soil etc.)
(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    (for-each (lambda (id nm)
                ($ rs 'add-resource-spec (make-resource-specification #:id id #:name nm
                                                                      #:default-unit-of-resource "kg")))
              '("food"  "excreta"  "crop-runoff"      "co2"               "soil-n")
              '("food"  "excreta"  "runoff → water"   "atmosphere (CO₂)"  "soil nitrogen"))))

;; one nutrient cycle, as a solve's produce/consume events. field withdraws soil
;; nitrogen + CO₂ and grows food (bleeding the rest to runoff); the household
;; eats, respires CO₂, excretes; composting returns some nitrogen to the soil.
(define solve
  `((material .
     (((action . consume) (conforms-to . "soil-n")      (quantity . 100)  (output-of . #f)           (input-of . "field"))
      ((action . consume) (conforms-to . "co2")          (quantity . 440)  (output-of . #f)           (input-of . "field"))
      ((action . produce) (conforms-to . "food")         (quantity . 1000) (output-of . "field")      (input-of . #f))
      ((action . produce) (conforms-to . "crop-runoff")  (quantity . 1480) (output-of . "field")      (input-of . #f))
      ((action . consume) (conforms-to . "food")         (quantity . 1000) (output-of . #f)           (input-of . "household"))
      ((action . produce) (conforms-to . "co2")          (quantity . 440)  (output-of . "household")  (input-of . #f))
      ((action . produce) (conforms-to . "excreta")      (quantity . 580)  (output-of . "household")  (input-of . #f))
      ((action . consume) (conforms-to . "excreta")      (quantity . 580)  (output-of . #f)           (input-of . "composting"))
      ((action . produce) (conforms-to . "soil-n")       (quantity . 60)   (output-of . "composting") (input-of . #f))))))

(define wire (with-vat vat (matter-results->wire scope solve)))

;;; the JSON writer the snapshot emitters share
(use-modules (playnet utils json-emit))

(define (flows->json fl) (J:o (map (lambda (p) (cons (symbol->string (car p)) (J:n (cdr p)))) fl)))
(define (node->json n)
  (J:o (append `(("id" . ,(J:s (assq-ref n 'id))) ("label" . ,(J:s (assq-ref n 'label))) ("kind" . ,(J:s (assq-ref n 'kind))))
               (if (assq 'env n)   `(("env"   . ,(J:b (assq-ref n 'env)))) '())
               (if (assq 'drift n) `(("drift" . ,(flows->json (assq-ref n 'drift)))) '()))))
(define (link->json l)
  (J:o `(("from" . ,(J:s (assq-ref l 'from))) ("to" . ,(J:s (assq-ref l 'to))) ("flows" . ,(flows->json (assq-ref l 'flows))))))

(define json
  (J:o `(("substances" . ,(J:a (map (lambda (s) (J:a (list (J:s (car s)) (J:s (cadr s))))) (assq-ref wire 'substances))))
         ("nodes"      . ,(J:a (map node->json (assq-ref wire 'nodes))))
         ("links"      . ,(J:a (map link->json (assq-ref wire 'links)))))))

(call-with-output-file (rel "browser/data/snapshots/matter-snapshot.json")
  (lambda (port) (set-port-encoding! port "UTF-8") (display json port) (newline port)))
(format #t "wrote browser/data/snapshots/matter-snapshot.json — ~a nodes, ~a links~%"
        (length (assq-ref wire 'nodes)) (length (assq-ref wire 'links)))
