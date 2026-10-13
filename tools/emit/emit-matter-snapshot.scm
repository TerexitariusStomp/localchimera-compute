;;; emit-matter-snapshot.scm — run the REAL substance-flow wire over a demo
;;; nutrient-cycle solve and emit browser/data/snapshots/matter-snapshot.json (the matter-face
;;; fallback). What the browser shows is the OUTPUT of matter-results->wire over
;;; the contains relation, written by the matter table — not invented, not re-derived in JS. The live planner
;;; service produces the same shape on demand (window.__matterFlow); this
;;; committed file is the offline fallback. Mirrors tools/emit/emit-law-snapshot.scm.
;;;
;;;   guix shell -m deploy/manifests/dev-test-manifest.scm -- \
;;;     guile --no-auto-compile -q -L module tools/emit/emit-matter-snapshot.scm [out]
;;;
;;; `make check-matter-fresh` regenerates and diffs the committed copy.

(use-modules (playnet scope root) (playnet vf schemas)
             (playnet doors service) (playnet doors plan-wire)
             (playnet knowledge catalogues substances)
             (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1)
             (ice-9 format))

(define root (dirname (dirname (dirname (current-filename)))))
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

;;; the page reads the matter table's rows (wire/snapshot.scm matter->wire), so
;;; the fallback is written by that table and the canonical JSON writer: the
;;; same object the live gateway answers with, byte for byte in shape
(use-modules ((playnet wire snapshot) #:select (matter->wire))
             ((playnet utils json-portable) #:select (scm->json-canonical)))
(define json (scm->json-canonical (matter->wire wire)))

(define out-path
  (let ((args (cdr (command-line))))
    (if (pair? args) (car args) (rel "browser/data/snapshots/matter-snapshot.json"))))
(call-with-output-file out-path
  (lambda (port) (set-port-encoding! port "UTF-8") (display json port) (newline port)))
(format #t "wrote ~a — ~a nodes, ~a links~%" out-path
        (length (assq-ref wire 'nodes)) (length (assq-ref wire 'links)))
