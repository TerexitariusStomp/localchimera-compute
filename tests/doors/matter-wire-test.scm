;;; matter-wire-test.scm — matter-results->wire as pure ValueFlows: a solve's
;;; substance flows are produce/consume events over substance EconomicResources.
;;; `produce` links a process → a resource (raising it); `consume` links a
;;; resource → a process (lowering it). Nodes are just {process, resource}; the
;;; RIFT is the environment resources (soil, air, water) whose quantity DRIFTS.
;;; No pools, sinks, sources, or matching — only produce, consume, and balance.
;;;
;;; Run:  guile --no-auto-compile -q -L module -l tests/doors/matter-wire-test.scm
;;; (via the blake3 dev-test shell — see [[reference_blake3_test_profile]])

(use-modules (playnet test harness)
             (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (playnet doors service) (playnet doors plan-wire)
             (playnet knowledge catalogues substances)
             (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1))

(define mem-store (make-memory-store))
(define-values (vat1 scope1)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Matter Wire Test")) mem-store))
(define (~= a b) (and a b (< (abs (- a b)) 1e-6)))

;; ── a worked grow recipe ────────────────────────────────────────────────────
;; The crop is the real carrot, whose composition is the food release's, so the
;; nitrogen it embodies is read off the composition table and the soil's draw is
;; that plus the 74 the runoff carries away: the books close by construction.
(define crop-n (assoc-ref (substance-content "carrot" 1000) "N"))
(define drawn-n (+ crop-n 74))
;; fixation produces N; grow consumes N + co2 and produces carrot + crop-runoff;
;; eat consumes carrot and produces co2 (respiration); compost is not present so
;; the soil isn't fed here. carrot/N are the economy's resources; co2 and
;; crop-runoff are ENVIRONMENT resources whose drift is the rift.
(define grow-solve
  `((material .
     (((action . produce) (conforms-to . "N")           (quantity . ,drawn-n) (output-of . "fixation") (input-of . #f))
      ((action . consume) (conforms-to . "N")           (quantity . ,drawn-n) (output-of . #f)         (input-of . "grow"))
      ((action . produce) (conforms-to . "carrot")      (quantity . 1000) (output-of . "grow")     (input-of . #f))
      ((action . consume) (conforms-to . "carrot")      (quantity . 1000) (output-of . #f)         (input-of . "eat"))
      ((action . produce) (conforms-to . "crop-runoff") (quantity . 1480) (output-of . "grow")     (input-of . #f))
      ((action . consume) (conforms-to . "co2")         (quantity . 440)  (output-of . #f)         (input-of . "grow"))   ; photosynthesis
      ((action . produce) (conforms-to . "co2")         (quantity . 440)  (output-of . "eat")      (input-of . #f))))))   ; respiration
(define wire   (with-vat vat1 (matter-results->wire scope1 grow-solve)))
(check-pred "wire produced" (and wire #t))

;;; ── substances ───────────────────────────────────────────────────────────
(check "every tracked element is on the wire: carbon, nitrogen, phosphorus, potassium, hydrogen, oxygen"
       (sort (map car (assq-ref wire 'substances)) string<?) (sort (list-copy *element-ids*) string<?))
(check "carbon first, with a colour" (car (car (assq-ref wire 'substances))) "C")

;;; ── nodes are just {process, resource} ─────────────────────────────────────
(define nodes (assq-ref wire 'nodes))
(define (node id) (find (lambda (n) (equal? (assq-ref n 'id) id)) nodes))
(define (kind id) (assq-ref (node id) 'kind))
(define (env? id) (assq-ref (node id) 'env))
(define (ndrift id s) (or (assq-ref (assq-ref (node id) 'drift) s) 0))
(check "only two node kinds exist"
       (delete-duplicates (sort (map (lambda (n) (assq-ref n 'kind)) nodes) string<?)) '("process" "resource"))
(check "grow is a process" (kind "grow") "process")
(check "carrot is a resource" (kind "res:carrot") "resource")
(check-pred "co2 is an ENVIRONMENT resource"       (env? "res:co2"))
(check-pred "crop-runoff is an ENVIRONMENT resource" (env? "res:crop-runoff"))
(check-pred "carrot is NOT an environment resource (economy's own)" (not (env? "res:carrot")))

;;; ── links are produce (process→resource) and consume (resource→process) ─────
(define links (assq-ref wire 'links))
(define (link from to) (find (lambda (l) (and (equal? (assq-ref l 'from) from)
                                             (equal? (assq-ref l 'to) to))) links))
(define (lN l) (and l (or (assq-ref (assq-ref l 'flows) 'N) 0)))
(define (lC l) (and l (or (assq-ref (assq-ref l 'flows) 'C) 0)))
(check-pred "consume: soil N drawn into grow (res:N → grow = what the crop holds plus the runoff)" (~= (lN (link "res:N" "grow")) drawn-n))
(check-pred "produce: N embodied in the crop (grow → res:carrot = what a thousand kilograms of carrot hold)" (~= (lN (link "grow" "res:carrot")) crop-n))
(check-pred "consume: the crop is eaten (res:carrot → eat)" (and (link "res:carrot" "eat") #t))
(check-pred "produce: N bled to runoff (grow → res:crop-runoff = 74)" (~= (lN (link "grow" "res:crop-runoff")) 74))
(check-pred "conservation through grow: embodied + lost = drawn"
            (~= (+ (lN (link "grow" "res:carrot")) (lN (link "grow" "res:crop-runoff"))) drawn-n))
(define co2-cfrac (/ (atomic-weight "C") (molar-mass "co2")))   ; derived, not 0.273
(check-pred "respiration deposits carbon (eat → res:co2, derived from CO₂ formula)"
            (~= (lC (link "eat" "res:co2")) (* 440 co2-cfrac)))
(check-pred "photosynthesis withdraws carbon (res:co2 → grow)"
            (~= (lC (link "res:co2" "grow")) (* 440 co2-cfrac)))
(check "no link is a self-loop"
       (length (filter (lambda (l) (equal? (assq-ref l 'from) (assq-ref l 'to))) links)) 0)

;;; ── the RIFT is resource DRIFT (produced − consumed) ───────────────────────
;; runoff only produced → it accumulates (+74 N): matter lost to the environment.
(check-pred "crop-runoff DRIFTS UP — the rift (drift N = +74)" (~= (ndrift "res:crop-runoff" 'N) 74))
;; carbon cycles: respired in = photosynthesised out → the stock stays flat.
(check-pred "carbon stock BALANCED — the loop closes (drift C = 0)" (~= (ndrift "res:co2" 'C) 0))
;; the economy's own resource cycles balanced (produced = consumed → drift 0),
;; and isn't flagged environment, so it contributes nothing to the rift.
(check-pred "carrot (economy resource) cycles balanced (drift 0)" (~= (ndrift "res:carrot" 'N) 0))

;;; ── the DEPLETION side: a stock drawn down faster than it's replenished ─────
;; compost returns 40 N to the soil; grow withdraws 100 → soil drifts DOWN 60.
(define soil-solve
  `((material .
     (((action . produce) (conforms-to . "soil-n") (quantity . 40)  (output-of . "compost") (input-of . #f))
      ((action . consume) (conforms-to . "soil-n") (quantity . 100) (output-of . #f)        (input-of . "grow"))))))
(define sw (with-vat vat1 (matter-results->wire scope1 soil-solve)))
(define (snode id) (find (lambda (n) (equal? (assq-ref n 'id) id)) (assq-ref sw 'nodes)))
(check-pred "soil is an environment resource" (assq-ref (snode "res:soil-n") 'env))
(check-pred "soil DRIFTS DOWN — the rift as depletion (drift N = −60)"
            (~= (or (assq-ref (assq-ref (snode "res:soil-n") 'drift) 'N) 0) -60))

;;; ── conservation: the keystone (element-level; molecules free; boundary exempt) ─
(define co2-q (/ 100 co2-cfrac))   ; mol of CO₂ carrying 100 kg of carbon (formula-derived)
(check-pred "lossy recipe balances — the loss is a named output"
            (eq? #t (check-conservation (bare-flows '((consume "N" 100) (produce "N" 70) (produce "N" 30))))))
(check-pred "molecule forms — carbon conserved as fuel→CO₂, the oxygen drawn from the air"
            (eq? #t (check-conservation (bare-flows `((consume "C" 100) (consume "O" ,(- co2-q 100)) (produce "co2" ,co2-q))))))
(check-pred "…and carbon alone does not make it: the oxygen would come from nowhere"
            (let ((bad (check-conservation (bare-flows `((consume "C" 100) (produce "co2" ,co2-q))))))
              (and (pair? bad) (equal? (caar bad) "O"))))
(check-pred "unbalanced recipe REJECTED — 30 N cannot vanish"
            (pair? (check-conservation (bare-flows '((consume "N" 100) (produce "N" 70))))))
(let ((bad (check-conservation (bare-flows '((consume "N" 100) (produce "N" 70))))))
  (check "rejection names the missing element" (caar bad) "N")
  (check-pred "rejection reports consumed vs produced" (and (~= (cadar bad) 100) (~= (caddar bad) 70))))
(check-pred "boundary recipe (fixation imports N) is exempt"
            (eq? #t (check-conservation (bare-flows '((produce "N" 100))) #:boundary? #t)))

;;; ── substances are first-class ResourceSpecifications ──────────────────────
(check-pred "substance-specs are provided" (pair? substance-specs))
(check-pred "carbon is a registered substance spec" (and (member "C" substance-spec-ids) #t))
(check "a substance spec carries its name"
       (resource-specification-name (find (lambda (s) (equal? (resource-specification-id s) "C")) substance-specs))
       "carbon")

(test-summary!)
