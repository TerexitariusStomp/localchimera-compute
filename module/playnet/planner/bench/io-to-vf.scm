;;; io-to-vf.scm — turn a preprocessed input-output table into REAL ValueFlows records.
;;;
;;; This is the bridge the WIOD benchmark was missing. `bench-real.scm` proved the
;;; SOLVER on real data, but it built the convex forms (mk-bar/mk-des) straight off
;;; the A-matrix — bypassing the VF schema entirely. That is not the product. The
;;; product is: real economic records → the engine's own ingest → solve.
;;;
;;; So this emitter maps an I-O table onto the same record types the live observer
;;; uses (schemas.scm), one-for-one with the recipe contract in planner.scm:
;;;
;;;   sector j (column)         → a ResourceSpecification  (the commodity)
;;;                             + a RecipeProcess "prod|j"
;;;   its reference output      → a `produce` RecipeFlow   (qty 1 per unit run)
;;;   each input i (a_ij>0)     → a `consume` RecipeFlow   (qty a_ij)   [(out)/(in)]
;;;   its labour content ℓ_j    → a `work`    RecipeFlow   (ℓ_j hours)  [(wrk)]
;;;   on-hand inventory cushion → an EconomicResource      (onhand STOCK_j)
;;;   the aggregate labour pool → ONE Agent "economy" (general skill, Σhours)
;;;                             at ONE SpatialThing "world"
;;;   final demand              → the #:demand alist (located good keys)
;;;
;;; Running process prod|j at level x_j then produces x_j of good j, consumes
;;; a_ij·x_j of every input i, and draws ℓ_j·x_j hours from the economy agent —
;;; exactly the I-O column, now expressed as records `plan-from-records` ingests.
;;;
;;; `io->vf` returns everything `plan-from-records` needs as an alist; the driver
;;; (bench-real-vf.scm) just unpacks and calls it. REGION (e.g. "AUS") keeps only
;;; that country's sectors (an open sub-economy) for a fast pipeline smoke test.

(define-module (playnet planner bench io-to-vf)
  #:use-module (playnet planner scope live)
  #:use-module (playnet planner vf schemas)
  #:use-module (ice-9 match)
  #:export (io->vf))

(use-modules (srfi srfi-1) (ice-9 match))

;; Build the VF records from a parsed I-O sexp (the structure bench-real.scm reads).
;; `region` #f ⇒ the whole closed world; a string ⇒ keep only "<region>|…" sectors.
(define* (io->vf IO #:key (region #f) (place "world"))
  (let* ((body   (cdr IO))
         (fld    (lambda (k) (cdr (or (assq k body) (error "missing field" k)))))
         (N      (car (fld 'n)))
         (LABELS (car (fld 'labels)))
         (GO     (car (fld 'gross-output)))
         (FDR    (car (fld 'final-demand-raw)))   ; net final demand, WITH negatives
         (HOURS  (car (fld 'hours)))
         (ATRIP  (fld 'a-triples))                ; (i j a) … : input i into sector j
         ;; region mask: which sectors survive
         (keep   (make-vector N #t)))
    (when region
      (do ((g 0 (+ g 1))) ((= g N))
        (vector-set! keep g (string-prefix? (string-append region "|")
                                            (vector-ref LABELS g)))))
    ;; `|` `#` `@` `.` are engine key delimiters (p|proc|cell, good#cell, place@t),
    ;; so a WIOD label like "AUS|A01" would corrupt every column split. Map `|`→`_`
    ;; (already a safe char in labels such as "C31_C32"); the rest never appear.
    (let* ((sane (lambda (s) (string-map (lambda (c) (if (char=? c #\|) #\_ c)) s)))
           (spec (lambda (g) (sane (vector-ref LABELS g))))    ; commodity id = the (sane) label
           (pid  (lambda (g) (string-append "prod_" (spec g))))   ; no `|`: it is a column-key delimiter
           (kept (filter (lambda (g) (vector-ref keep g)) (iota N)))
           ;; the I-O column AS VF records — local shorthands so the body reads like
           ;; the mapping table it is (units are cosmetic to the engine; it reads the
           ;; numbers). produce 1 unit/run, consume a_ij/run, work ℓ hours/run.
           (rspec   (lambda (id)        (make-resource-specification #:id id #:name id
                                                                     #:default-unit-of-resource "USD"
                                                                     #:default-unit-of-effort "hours")))
           (rproc   (lambda (id)        (make-recipe-process #:id id #:name id)))
           (produce (lambda (id sp p)   (make-recipe-flow #:id id #:action 'produce
                                                          #:resource-conforms-to sp
                                                          #:resource-quantity (make-measure 1.0 "USD")
                                                          #:recipe-output-of p #:is-primary #t)))
           (consume (lambda (id sp q p) (make-recipe-flow #:id id #:action 'consume
                                                          #:resource-conforms-to sp
                                                          #:resource-quantity (make-measure q "USD")
                                                          #:recipe-input-of p)))
           (work    (lambda (id hrs p)  (make-recipe-flow #:id id #:action 'work
                                                          #:effort-quantity (make-measure hrs "hours")
                                                          #:recipe-input-of p)))
           (stock   (lambda (id sp q)   (make-economic-resource #:id id #:name sp #:conforms-to sp
                                                                #:onhand-quantity (make-measure q "USD")
                                                                #:current-location place
                                                                #:primary-accountable "economy")))
           ;; consumers[j] = ((i . a) …) inputs of sector j, both ends kept
           (cons-by (make-vector N '())))
      (for-each (match-lambda ((i j a)
                  (when (and (vector-ref keep i) (vector-ref keep j) (> a 0.0))
                    (vector-set! cons-by j (cons (cons i a) (vector-ref cons-by j))))))
                ATRIP)
      (let ((specs '()) (procs '()) (flows '()) (ress '()) (demand '()))
        (for-each
         (lambda (g)
           (let ((sid (spec g)) (p (pid g)) (go (vector-ref GO g))
                 (h (vector-ref HOURS g)) (f (vector-ref FDR g)))
             (set! specs (cons (rspec sid) specs))                                       ; the commodity
             (set! procs (cons (rproc p) procs))                                         ; its production process
             (set! flows (cons (produce (string-append "o|" sid) sid p) flows))          ; reference output
             (for-each (lambda (ia)                                                       ; one consume per nonzero a_ig
                         (set! flows (cons (consume (string-append "c|" sid "|" (spec (car ia)))
                                                    (spec (car ia)) (cdr ia) p)
                                           flows)))
                       (vector-ref cons-by g))
             (when (and (> go 0.0) (> h 0.0))                                             ; labour content ℓ_g = hours/output
               (set! flows (cons (work (string-append "w|" sid) (/ h go) p) flows)))
             (when (< f 0.0)                                                              ; inventory cushion = |net drawdown|
               (set! ress (cons (stock (string-append "er|" sid) sid (- f)) ress)))
             (when (> f 0.0)                                                              ; final demand → located good key
               (set! demand (cons (cons (lg sid (cell place 0)) f) demand)))))
         kept)
        ;; the aggregate labour pool: one economy agent at one world location
        (let* ((tot-hours (fold (lambda (g a) (+ a (vector-ref HOURS g))) 0.0 kept))
               (agent  (make-agent #:id "economy" #:type 'person #:name "Economy"
                                   #:primary-location place #:classified-as '("general")))
               (world  (make-spatial-thing #:id place #:name "World" #:lat 0.0 #:long 0.0)))
          (list (cons 'resources   ress)
                (cons 'agents      (list agent))
                (cons 'spatials    (list world))
                (cons 'recipe-procs procs)
                (cons 'recipe-flows flows)
                (cons 'demand      demand)
                (cons 'tot-hours   tot-hours)
                (cons 'n-kept      (length kept))
                (cons 'n-flows     (length flows))))))))
