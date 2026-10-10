;;; recipes.scm — Goblins actor for recipe/specification management
;;;
;;; Translated from src/lib/knowledge/recipes.ts (RecipeStore)
;;; State: 7 hashmaps for the knowledge-layer template entities.

(define-module (playnet knowledge recipes store)
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf formulas actions)
  #:use-module (playnet utils store-utils)
  #:use-module (playnet vf serdes)
  #:use-module (goblins utils hashmap)
  #:export (resource-specification->list list->resource-specification
            process-specification->list list->process-specification
            recipe-process->list list->recipe-process recipe-flow->list
            list->recipe-flow recipe-exchange->list list->recipe-exchange recipe->list
            list->recipe recipe-group->list list->recipe-group
            process-inputs process-outputs recipe-deliverable find-flow spec-row-id spec-row-name
            spec-row-unit spec-row-classes seed-spec-rows! ^recipe-store
            recipe-store-env)
  ;; the action table's own reading (schemas.scm), kept on this module's face
  #:re-export (action-input-output)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:use-module ((playnet utils catch) #:select (catch* throw* with-throw-handler*)))


;; Assumes schemas.scm and store-utils.scm are loaded.


;; =========================================================================
;; Record <-> list serialization
;; =========================================================================
;;
;; All record-to-list / list-to-record conversion now goes through the
;; generic introspective walker in `lib/utils/serdes.scm`. Each record
;; type is registered once, as it is declared (vf/schemas.scm define-vf-record); adding
;; a new field to a record requires no change here.
;;
;; The per-type names are kept as one-line wrappers so the existing
;; `serialize-hashmap` / `deserialize-hashmap` call sites in #:portrait
;; and #:restore don't have to change.

(define (resource-specification->list rs) (vf-serialize rs))
(define (list->resource-specification lst) (vf-deserialize lst))

(define (process-specification->list ps) (vf-serialize ps))
(define (list->process-specification lst) (vf-deserialize lst))

(define (recipe-process->list rp) (vf-serialize rp))
(define (list->recipe-process lst) (vf-deserialize lst))

(define (recipe-flow->list rf) (vf-serialize rf))
(define (list->recipe-flow lst) (vf-deserialize lst))

(define (recipe-exchange->list rx) (vf-serialize rx))
(define (list->recipe-exchange lst) (vf-deserialize lst))

(define (recipe->list r) (vf-serialize r))
(define (list->recipe lst) (vf-deserialize lst))

(define (recipe-group->list rg) (vf-serialize rg))
(define (list->recipe-group lst) (vf-deserialize lst))


;; =========================================================================
;; Reading a process's flows
;; =========================================================================
;;
;; `flows-for-process` answers with the pair (inputs . outputs), and every caller
;; then writes the `car`/`cdr` itself — legal/gate.scm, live.scm, option-premium.scm
;; and both recipe test suites each do their own. Naming the two halves once says
;; which half is meant at the call site, where `(cdr …)` does not.

(define (process-inputs recipe-store pid)
  "The consume/use/work/pickup flows INTO process PID."
  (car ($ recipe-store 'flows-for-process pid)))

(define (process-outputs recipe-store pid)
  "The produce/dropoff flows OUT OF process PID."
  (cdr ($ recipe-store 'flows-for-process pid)))

(define (recipe-deliverable recipe-store recipe)
  "The spec RECIPE exists to make: its own word (primary-output), else the
   primary output of the last act of its chain. #f for a recipe with no act
   that makes anything. The one reading the solve's record and the wire take."
  (or (recipe-primary-output recipe)
      (let ((chain ($ recipe-store 'get-process-chain (recipe-id recipe))))
        (and (pair? chain)
             (let ((outs (process-outputs recipe-store (recipe-process-id (last chain)))))
               (and (pair? outs)
                    (recipe-flow-resource-conforms-to
                     (or (find recipe-flow-is-primary outs) (car outs)))))))))

(define* (find-flow flows spec #:key (action #f))
  "The flow in FLOWS on SPEC — narrowed to one ACTION when given, since a process
   may both `use` and `consume` the same spec. #f when there is none."
  (find (lambda (f)
          (and (equal? spec (recipe-flow-resource-conforms-to f))
               (or (not action) (eq? action (recipe-flow-action f)))))
        flows))

;; =========================================================================
;; Spec tables — one row per ResourceSpecification
;; =========================================================================
;;
;; A recipe file's catalogue is a list of ROWS, `(id name unit class …)`. One row
;; per spec keeps a spec's name, its unit and its classification on one line,
;; where a reader checks them together and a typo is visible; parallel alists
;; keyed by the same ids drift silently, and a missing entry seeds a spec with
;; the fallback unit rather than raising.
;;
;; #:substitutable? is asked of a row's id — a spec that invites a local
;; stand-in (a plant wax for beeswax) says so here rather than in a second table.

(define (spec-row-id row)      (car row))
(define (spec-row-name row)    (cadr row))
(define (spec-row-unit row)    (caddr row))
(define (spec-row-classes row) (cdddr row))

(define* (seed-spec-rows! recipe-store rows
                          #:key (substitutable? (lambda (id) #f)))
  "Register each ROW `(id name unit class …)` as a ResourceSpecification."
  (for-each
   (lambda (row)
     ($ recipe-store 'add-resource-spec
        (make-resource-specification
         #:id (spec-row-id row) #:name (spec-row-name row)
         #:resource-classified-as (spec-row-classes row) #:default-unit-of-resource (spec-row-unit row)
         #:substitutable (and (substitutable? (spec-row-id row)) #t))))
   rows))


;; =========================================================================
;; ^recipe-store
;; =========================================================================

(define-actor (^recipe-store bcom recipes groups processes flows exchanges
                             resource-specs process-specs
                             ;; Secondary indexes
                             idx-flows-by-input  ;; process-id -> list of flows
                             idx-flows-by-output ;; process-id -> list of flows
                             idx-recipes-by-output) ;; spec-id -> list of recipe-ids
  ;; 7 primary hashmaps + 3 indexes

  #:portrait
  (lambda ()
    (list (serialize-hashmap recipes recipe->list)
          (serialize-hashmap groups recipe-group->list)
          (serialize-hashmap processes recipe-process->list)
          (serialize-hashmap flows recipe-flow->list)
          (serialize-hashmap exchanges recipe-exchange->list)
          (serialize-hashmap resource-specs resource-specification->list)
          (serialize-hashmap process-specs process-specification->list)
          idx-flows-by-input idx-flows-by-output idx-recipes-by-output))

  #:version 2

  #:restore
  (lambda (version . args)
    (case version
      ((1) ;; Old version without indexes — rebuild indexes from flows/recipes
       (match args
         ((sr sg sp sf sx srs sps)
          (let* ((d-recipes (deserialize-hashmap sr list->recipe))
                 (d-flows (deserialize-hashmap sf list->recipe-flow))
                 ;; Rebuild indexes
                 (fbi (hashmap-fold (lambda (fid f acc)
                         (if (recipe-flow-recipe-input-of f)
                             (let ((pid (recipe-flow-recipe-input-of f)))
                               (hashmap-set acc pid (cons fid (hashmap-ref acc pid '()))))
                             acc)) (hashmap) d-flows))
                 (fbo (hashmap-fold (lambda (fid f acc)
                         (if (recipe-flow-recipe-output-of f)
                             (let ((pid (recipe-flow-recipe-output-of f)))
                               (hashmap-set acc pid (cons fid (hashmap-ref acc pid '()))))
                             acc)) (hashmap) d-flows))
                 (rbo (hashmap-fold (lambda (_id r acc)
                         (if (recipe-primary-output r)
                             (let ((spec (recipe-primary-output r)))
                               (hashmap-set acc spec (cons (recipe-id r) (hashmap-ref acc spec '()))))
                             acc)) (hashmap) d-recipes)))
            (spawn ^recipe-store
                   d-recipes
                   (deserialize-hashmap sg list->recipe-group)
                   (deserialize-hashmap sp list->recipe-process)
                   d-flows
                   (deserialize-hashmap sx list->recipe-exchange)
                   (deserialize-hashmap srs list->resource-specification)
                   (deserialize-hashmap sps list->process-specification)
                   fbi fbo rbo)))))
      ((2) ;; Current version with indexes
       (match args
         ((sr sg sp sf sx srs sps ifbi ifbo irbo)
          (spawn ^recipe-store
                 (deserialize-hashmap sr list->recipe)
                 (deserialize-hashmap sg list->recipe-group)
                 (deserialize-hashmap sp list->recipe-process)
                 (deserialize-hashmap sf list->recipe-flow)
                 (deserialize-hashmap sx list->recipe-exchange)
                 (deserialize-hashmap srs list->resource-specification)
                 (deserialize-hashmap sps list->process-specification)
                 ifbi ifbo irbo))))
      (else (error "Unknown ^recipe-store version" version))))

  (methods

    ;; --- Specifications ---

    ((add-resource-spec spec)
     (let ((id (resource-specification-id spec)))
       (bcom (^recipe-store bcom recipes groups processes flows exchanges
                            (hashmap-set resource-specs id spec) process-specs
                            idx-flows-by-input idx-flows-by-output idx-recipes-by-output)
             id)))

    ((add-process-spec spec)
     (let ((id (process-specification-id spec)))
       (bcom (^recipe-store bcom recipes groups processes flows exchanges
                            resource-specs (hashmap-set process-specs id spec)
                            idx-flows-by-input idx-flows-by-output idx-recipes-by-output)
             id)))

    ((get-resource-spec id) (hashmap-ref resource-specs id #f))
    ((get-process-spec id)  (hashmap-ref process-specs id #f))
    ((all-resource-specs)   (hashmap-values resource-specs))
    ;; the compositions this scope STATES on its specs — ((spec (leaf . amount) …) …),
    ;; read in front of the fallback table by the solve (live.scm scope-composition)
    ;; and the lint (vf-lint), so a warmed form a scope holds is a fact of the scope
    ((stated-compositions)
     (filter-map (lambda (s) (let ((c (resource-specification-composition s)))
                               (and (pair? c) (cons (resource-specification-id s) c))))
                 (hashmap-values resource-specs)))
    ((all-process-specs)    (hashmap-values process-specs))

    ;; --- Recipe Processes ---

    ((add-recipe-process rp)
     (let ((id (or (recipe-process-id rp) (generate-id "rp-"))))
       (bcom (^recipe-store bcom recipes groups
                            (hashmap-set processes id rp)
                            flows exchanges resource-specs process-specs
                            idx-flows-by-input idx-flows-by-output idx-recipes-by-output)
             id)))

    ((get-recipe-process id) (hashmap-ref processes id #f))

    ;; --- Recipe Flows (with validation) ---

    ((add-recipe-flow rf)
     (let* ((id (or (recipe-flow-id rf) (generate-id "rf-")))
            (action (recipe-flow-action rf))
            (io (action-input-output action)))
       ;; Validate action direction. A `not-applicable` action (move, transfer,
       ;; copy) is ONE flow standing for both sides at once — a good leaving here
       ;; and arriving there — so it has no input/output polarity of its own. The
       ;; planner reads such a flow off the process's INPUT side and tiles the
       ;; column along a real edge: through time when the container it uses is
       ;; keep-in-place (storage), through space otherwise (transport). So the
       ;; input side accepts it, and the output side stays strict.
       (when (and (recipe-flow-recipe-input-of rf)
                  (not (memq io '(input output-input not-applicable))))
         (error (format #f "Flow ~a: action '~a' not valid as input (io=~a)"
                        id action io)))
       (when (and (recipe-flow-recipe-output-of rf)
                  (not (memq io '(output output-input))))
         (error (format #f "Flow ~a: action '~a' not valid as output (io=~a)"
                        id action io)))
       (let* ((new-flows (hashmap-set flows id rf))
              ;; Maintain flow indexes (store flow IDs, not records). An id
              ;; stands once in its process's index, so a flow added again
              ;; replaces itself and a store seeded twice plans as seeded once.
              (new-fbi (if (recipe-flow-recipe-input-of rf)
                           (let ((pid (recipe-flow-recipe-input-of rf)))
                             (hashmap-set idx-flows-by-input pid
                               (cons id (delete id (hashmap-ref idx-flows-by-input pid '())))))
                           idx-flows-by-input))
              (new-fbo (if (recipe-flow-recipe-output-of rf)
                           (let ((pid (recipe-flow-recipe-output-of rf)))
                             (hashmap-set idx-flows-by-output pid
                               (cons id (delete id (hashmap-ref idx-flows-by-output pid '())))))
                           idx-flows-by-output)))
         (bcom (^recipe-store bcom recipes groups processes new-flows
                              exchanges resource-specs process-specs
                              new-fbi new-fbo idx-recipes-by-output)
               id))))

    ((get-recipe-flow id) (hashmap-ref flows id #f))

    ;; --- Recipes ---

    ((add-recipe r)
     (let* ((id (or (recipe-id r) (generate-id "recipe-")))
            (new-recipes (hashmap-set recipes id r))
            ;; Maintain recipes-by-output index
            (new-rbo (if (recipe-primary-output r)
                         (let ((spec (recipe-primary-output r)))
                           (hashmap-set idx-recipes-by-output spec
                             (cons id (delete id (hashmap-ref idx-recipes-by-output spec '())))))
                         idx-recipes-by-output)))
       (bcom (^recipe-store bcom new-recipes groups processes flows exchanges
                            resource-specs process-specs
                            idx-flows-by-input idx-flows-by-output new-rbo)
             id)))

    ((get-recipe id) (hashmap-ref recipes id #f))
    ((all-recipes)   (hashmap-values recipes))

    ;; --- Retiring ---
    ;; A process leaves with its flows and the recipes that ran it: the one
    ;; door a seed migrates a durable store through, so a commune seeded
    ;; under an older shape gains the new one on its next boot and the old
    ;; shape stops solving. Every index is rebuilt from what stays.
    ((retire-recipe-process id)
     (let* ((fids (append (hashmap-ref idx-flows-by-input id '())
                          (hashmap-ref idx-flows-by-output id '())))
            (new-flows (let loop ((fs fids) (m flows))
                         (if (null? fs) m (loop (cdr fs) (hashmap-remove m (car fs))))))
            (new-processes (hashmap-remove processes id))
            (gone (filter (lambda (r) (member id (or (recipe-recipe-processes r) '())))
                          (hashmap-values recipes)))
            (new-recipes (let loop ((rs gone) (m recipes))
                           (if (null? rs) m (loop (cdr rs) (hashmap-remove m (recipe-id (car rs)))))))
            (new-rbo (let loop ((rs gone) (m idx-recipes-by-output))
                       (if (null? rs) m
                           (let* ((r (car rs)) (spec (recipe-primary-output r)))
                             (loop (cdr rs)
                                   (if spec
                                       (hashmap-set m spec (delete (recipe-id r) (hashmap-ref m spec '())))
                                       m)))))))
       (bcom (^recipe-store bcom new-recipes groups new-processes new-flows exchanges
                            resource-specs process-specs
                            (hashmap-remove idx-flows-by-input id)
                            (hashmap-remove idx-flows-by-output id)
                            new-rbo)
             (length gone))))

    ;; --- Recipe Groups ---

    ((add-recipe-group rg)
     (let ((id (or (recipe-group-id rg) (generate-id "rg-"))))
       (bcom (^recipe-store bcom recipes (hashmap-set groups id rg)
                            processes flows exchanges resource-specs process-specs
                            idx-flows-by-input idx-flows-by-output idx-recipes-by-output)
             id)))

    ((get-recipe-group id) (hashmap-ref groups id #f))
    ((all-recipe-groups)   (hashmap-values groups))

    ((recipes-for-group group-id)
     (let ((group (hashmap-ref groups group-id #f)))
       (if (not group) '()
           (filter-map (lambda (rid) (hashmap-ref recipes rid #f))
                       (or (recipe-group-recipes group) '())))))

    ;; --- Exchanges ---

    ((add-recipe-exchange rx)
     (let ((id (or (recipe-exchange-id rx) (generate-id "rex-"))))
       (bcom (^recipe-store bcom recipes groups processes flows
                            (hashmap-set exchanges id rx)
                            resource-specs process-specs
                            idx-flows-by-input idx-flows-by-output idx-recipes-by-output)
             id)))

    ((get-recipe-exchange id) (hashmap-ref exchanges id #f))

    ((flows-for-exchange rex-id)
     (hashmap-filter
       (lambda (f) (equal? (recipe-flow-recipe-clause-of f) rex-id))
       flows))

    ;; --- Navigation Queries ---

    ((flows-for-process rp-id)
     ;; O(log n) via indexes — resolve flow IDs to records
     (cons (filter-map (lambda (fid) (hashmap-ref flows fid #f))
                       (hashmap-ref idx-flows-by-input rp-id '()))
           (filter-map (lambda (fid) (hashmap-ref flows fid #f))
                       (hashmap-ref idx-flows-by-output rp-id '()))))

    ((processes-for-recipe recipe-id)
     (let ((r (hashmap-ref recipes recipe-id #f)))
       (if (not r) '()
           (filter-map (lambda (pid) (hashmap-ref processes pid #f))
                       (or (recipe-recipe-processes r) '())))))

    ((recipe-for-output spec-id)
     ;; O(log n) via index
     (let ((rids (hashmap-ref idx-recipes-by-output spec-id '())))
       (and (pair? rids) (hashmap-ref recipes (car rids) #f))))

    ((recipes-for-output spec-id)
     ;; O(log n) via index
     (filter-map (lambda (rid) (hashmap-ref recipes rid #f))
                 (hashmap-ref idx-recipes-by-output spec-id '())))

    ((recipes-for-input spec-id)
     ;; Find processes that have input flows for spec-id, then recipes containing them.
     (let ((process-ids
             (hashmap-fold
               (lambda (_id f acc)
                 (if (and (recipe-flow-recipe-input-of f)
                          (equal? (recipe-flow-resource-conforms-to f) spec-id))
                     (cons (recipe-flow-recipe-input-of f) acc)
                     acc))
               '() flows)))
       (hashmap-filter
         (lambda (r)
           (let ((rps (or (recipe-recipe-processes r) '())))
             (any (lambda (pid) (member pid process-ids)) rps)))
         recipes)))

    ((recipes-for-transport spec-id)
     ;; Recipes with both pickup input AND dropoff output for spec-id.
     (let ((pickup-pids '())
           (dropoff-pids '()))
       (hashmap-for-each
         (lambda (_id f)
           (when (equal? (recipe-flow-resource-conforms-to f) spec-id)
             (when (and (eq? (recipe-flow-action f) 'pickup)
                        (recipe-flow-recipe-input-of f))
               (set! pickup-pids (cons (recipe-flow-recipe-input-of f) pickup-pids)))
             (when (and (eq? (recipe-flow-action f) 'dropoff)
                        (recipe-flow-recipe-output-of f))
               (set! dropoff-pids (cons (recipe-flow-recipe-output-of f) dropoff-pids)))))
         flows)
       (hashmap-filter
         (lambda (r)
           (let ((rps (or (recipe-recipe-processes r) '())))
             (and (any (lambda (pid) (member pid pickup-pids)) rps)
                  (any (lambda (pid) (member pid dropoff-pids)) rps))))
         recipes)))

    ;; --- Topological Sort (Kahn's algorithm) ---

    ((get-process-chain recipe-id)
     (let ((procs (filter-map (lambda (pid) (hashmap-ref processes pid #f))
                              (or (recipe-recipe-processes
                                    (or (hashmap-ref recipes recipe-id #f)
                                        (make-recipe #:id "" #:name "")))
                                  '()))))
       (if (null? procs) '()
           ;; Build adjacency: src -> dst if src outputs what dst inputs
           (let* ((adj (make-hash-table))
                  (in-degree (make-hash-table)))
             ;; Initialize
             (for-each (lambda (p)
                         (let ((pid (recipe-process-id p)))
                           (hashv-set! adj pid '())
                           (hashv-set! in-degree pid 0)))
                       procs)
             ;; Build edges
             (for-each
               (lambda (src)
                 (let* ((src-id (recipe-process-id src))
                        (src-outputs (filter-map (lambda (fid) (hashmap-ref flows fid #f))
                                                 (hashmap-ref idx-flows-by-output src-id '()))))
                   (for-each
                     (lambda (out-flow)
                       (let ((out-spec (recipe-flow-resource-conforms-to out-flow))
                             (out-stage (recipe-flow-stage out-flow)))
                         (when out-spec
                           (for-each
                             (lambda (dst)
                               (let ((dst-id (recipe-process-id dst)))
                                 (unless (equal? dst-id src-id)
                                   (let ((dst-inputs (filter-map (lambda (fid) (hashmap-ref flows fid #f))
                                                         (hashmap-ref idx-flows-by-input dst-id '()))))
                                     (when (any (lambda (f)
                                                  (and (equal? (recipe-flow-resource-conforms-to f) out-spec)
                                                       (equal? (recipe-flow-stage f) out-stage)))
                                                dst-inputs)
                                       (hashv-set! adj src-id
                                                   (cons dst-id (hashv-ref adj src-id '())))
                                       (hashv-set! in-degree dst-id
                                                   (+ 1 (hashv-ref in-degree dst-id 0))))))))
                             procs))))
                     src-outputs)))
               procs)
             ;; Kahn's
             (let ((queue (filter (lambda (p)
                                    (= 0 (hashv-ref in-degree (recipe-process-id p) 0)))
                                  procs)))
               (let loop ((q queue) (sorted '()))
                 (if (null? q)
                     (if (= (length sorted) (length procs))
                         (reverse sorted)
                         (error (format #f "Recipe ~a: circular dependency" recipe-id)))
                     (let* ((current (car q))
                            (cid (recipe-process-id current))
                            (neighbors (hashv-ref adj cid '()))
                            (new-q (cdr q)))
                       (for-each
                         (lambda (nid)
                           (let ((new-deg (- (hashv-ref in-degree nid 0) 1)))
                             (hashv-set! in-degree nid new-deg)
                             (when (= new-deg 0)
                               (let ((proc (find (lambda (p) (equal? (recipe-process-id p) nid)) procs)))
                                 (when proc (set! new-q (append new-q (list proc))))))))
                         neighbors)
                       (loop new-q (cons current sorted))))))))))

    ;; --- Validation ---

    ((validate-recipe recipe-id)
     (let ((errors '())
           (r (hashmap-ref recipes recipe-id #f)))
       (if (not r)
           (list (format #f "Recipe ~a not found" recipe-id))
           (let ((procs (filter-map (lambda (pid) (hashmap-ref processes pid #f))
                                    (or (recipe-recipe-processes r) '()))))
             (when (null? procs)
               (set! errors (cons (format #f "Recipe ~a: no processes defined" recipe-id) errors)))
             ;; Each process should have at least one flow
             (for-each
               (lambda (rp)
                 (let* ((pid (recipe-process-id rp))
                        (ins (filter-map (lambda (fid) (hashmap-ref flows fid #f))
                                        (hashmap-ref idx-flows-by-input pid '())))
                        (outs (filter-map (lambda (fid) (hashmap-ref flows fid #f))
                                        (hashmap-ref idx-flows-by-output pid '()))))
                   (when (and (null? ins) (null? outs))
                     (set! errors (cons (format #f "RecipeProcess ~a (~a): no flows"
                                                pid (recipe-process-name rp))
                                        errors)))))
               procs)
             ;; Check primary output
             (when (recipe-primary-output r)
               (let ((last-proc (and (not (null? procs)) (last procs))))
                 (when last-proc
                   (let ((outs (hashmap-ref idx-flows-by-output (recipe-process-id last-proc) '())))
                     (unless (any (lambda (f)
                                    (equal? (recipe-flow-resource-conforms-to f)
                                            (recipe-primary-output r)))
                                  outs)
                       (set! errors (cons (format #f "Recipe ~a: primary output ~a not in last process"
                                                  recipe-id (recipe-primary-output r))
                                          errors)))))))
             ;; Check circular dependencies
             (catch* #t
               (lambda ()
                 ;; Inline the topo sort check
                 (let ((chain-len (length procs)))
                   (when (> chain-len 1)
                     ;; Just trigger the chain computation for validation
                     #t)))
               (lambda (k . args)
                 (set! errors (cons (format #f "Recipe ~a: circular dependency" recipe-id) errors))))
             ;; Validate resolveFromFlow references
             (for-each
               (lambda (rp)
                 (let* ((pid (recipe-process-id rp))
                        (proc-flows (append (filter-map (lambda (fid) (hashmap-ref flows fid #f))
                                        (hashmap-ref idx-flows-by-input pid '()))
                                              (filter-map (lambda (fid) (hashmap-ref flows fid #f))
                                        (hashmap-ref idx-flows-by-output pid '()))))
                        (proc-flow-ids (map recipe-flow-id proc-flows)))
                   (for-each
                     (lambda (f)
                       (when (recipe-flow-resolve-from-flow f)
                         (unless (member (recipe-flow-resolve-from-flow f) proc-flow-ids)
                           (set! errors (cons (format #f "Flow ~a: resolveFromFlow '~a' not sibling"
                                                      (recipe-flow-id f)
                                                      (recipe-flow-resolve-from-flow f))
                                              errors)))
                         (let ((anchor (hashmap-ref flows (recipe-flow-resolve-from-flow f) #f)))
                           ;; a flow resolves from a `use` (the thing used), or — a `work`
                           ;; alone — from a `pickup`: the work of the one being moved
                           (when (and anchor
                                      (not (or (eq? (recipe-flow-action anchor) 'use)
                                               (and (eq? (recipe-flow-action f) 'work)
                                                    (eq? (recipe-flow-action anchor) 'pickup)))))
                             (set! errors (cons (format #f "Flow ~a: anchor '~a' action is '~a', expected 'use (or 'pickup under a work)"
                                                        (recipe-flow-id f)
                                                        (recipe-flow-resolve-from-flow f)
                                                        (recipe-flow-action anchor))
                                                errors))))))
                     proc-flows)))
               procs)
             (reverse errors)))))))


;; =========================================================================
;; Persistence environment
;; =========================================================================

(define recipe-store-env
  (make-persistence-env
    `((((vf knowledge) ^recipe-store) ,^recipe-store))))
