;;; flow-graph.scm — Scope-level value flow analysis
;;;
;;; Builds directed flow graph between scopes, computes coherence,
;;; interdependence, and merge/split candidates.
;;;
;;; Flow weights are denominated in SNLT (socially-necessary labour-time,
;;; hours) per §3 of the commons spec. Work flows contribute their
;;; effort-quantity directly; resource flows contribute qty × SNLT(spec).

(define-module (playnet deprecated planner algorithms flow-graph)
  #:use-module (playnet vf schemas)
  #:use-module (playnet algorithms propagation)
  #:export (build-flow-graph internal-flow external-flow total-flow bilateral-flow
            coherence interdependence merge-candidates split-candidates
            boundary-objective)
  #:use-module (srfi srfi-1)
  #:use-module (goblins utils hashmap))


(define (build-flow-graph events scope-of-agent recipe-store)
  "Build value-flow graph from economic events.
   scope-of-agent: procedure (agent-id) -> scope-id.
   recipe-store: actor reference for SNLT computation via min-snlt-for-spec.
   Returns alist: ((edges . hashmap) (scopes . list)
                    (internal . hashmap) (external . hashmap)).
   Edge weights are SNLT hours (work effort-quantity or qty × SNLT(spec))."
  (let ((edges (hashmap))  ;; "src->tgt" -> weight (SNLT hours)
        (scopes '()))
    ;; Process each event
    (for-each
      (lambda (e)
        (let ((prov (economic-event-provider e))
              (recv (economic-event-receiver e)))
          (when (and prov recv (not (equal? prov recv)))
            (let* ((src-scope (scope-of-agent prov))
                   (tgt-scope (scope-of-agent recv))
                   (action (economic-event-action e))
                   (spec (economic-event-resource-conforms-to e))
                   (rq (economic-event-resource-quantity e))
                   (eq (economic-event-effort-quantity e))
                   ;; SNLT cost: work flows use effort-qty; others use qty × SNLT(spec)
                   (value (cond
                            ((and (eq? action 'work) eq)
                             (measure-has-numerical-value eq))
                            ((and spec rq)
                             (let ((snlt (min-snlt-for-spec recipe-store spec)))
                               (if (= snlt +inf.0) 0
                                   (* (measure-has-numerical-value rq) snlt))))
                            (else 0)))
                   (key (string-append src-scope "->" tgt-scope)))
              (when (and src-scope tgt-scope (> value 0))
                (set! edges (hashmap-set edges key
                              (+ (hashmap-ref edges key 0) value)))
                (unless (member src-scope scopes) (set! scopes (cons src-scope scopes)))
                (unless (member tgt-scope scopes) (set! scopes (cons tgt-scope scopes))))))))
      events)
    ;; Pre-compute internal and external flows
    (let ((internal (hashmap))
          (external (hashmap)))
      (hashmap-fold
        (lambda (key weight _)
          (let* ((parts (string-split key #\>))
                 (src (substring (car parts) 0 (- (string-length (car parts)) 1)))
                 (tgt (cadr parts)))
            (if (equal? src tgt)
                (set! internal (hashmap-set internal src
                                 (+ (hashmap-ref internal src 0) weight)))
                (begin
                  (set! external (hashmap-set external src
                                   (+ (hashmap-ref external src 0) weight)))
                  (set! external (hashmap-set external tgt
                                   (+ (hashmap-ref external tgt 0) weight)))))))
        #f edges)
      `((edges . ,edges) (scopes . ,scopes)
        (internal . ,internal) (external . ,external)))))

(define (internal-flow scope-id graph)
  (hashmap-ref (assq-ref graph 'internal) scope-id 0))

(define (external-flow scope-id graph)
  (hashmap-ref (assq-ref graph 'external) scope-id 0))

(define (total-flow scope-id graph)
  (+ (internal-flow scope-id graph) (external-flow scope-id graph)))

(define (bilateral-flow scope-a scope-b graph)
  (let ((edges (assq-ref graph 'edges)))
    (+ (hashmap-ref edges (string-append scope-a "->" scope-b) 0)
       (hashmap-ref edges (string-append scope-b "->" scope-a) 0))))

(define (coherence scope-id graph)
  "internal / total. Range [0,1]. 0 when total=0."
  (let ((total (total-flow scope-id graph)))
    (if (= total 0) 0 (/ (internal-flow scope-id graph) total))))

(define (interdependence scope-a scope-b graph)
  "bilateral / (ext_a + ext_b). 0 when denominator=0."
  (let ((denom (+ (external-flow scope-a graph) (external-flow scope-b graph))))
    (if (= denom 0) 0 (/ (bilateral-flow scope-a scope-b graph) denom))))

(define (merge-candidates graph theta-merge)
  "Scope pairs where interdependence > theta-merge."
  (let ((scopes (assq-ref graph 'scopes)) (results '()))
    (let loop-a ((sa scopes))
      (when (pair? sa)
        (let loop-b ((sb (cdr sa)))
          (when (pair? sb)
            (when (> (interdependence (car sa) (car sb) graph) theta-merge)
              (set! results (cons (list (car sa) (car sb)) results)))
            (loop-b (cdr sb))))
        (loop-a (cdr sa))))
    results))

(define (split-candidates graph theta-split)
  "Scopes where coherence < theta-split."
  (filter (lambda (s) (< (coherence s graph) theta-split))
          (assq-ref graph 'scopes)))

(define (boundary-objective graph)
  "Weighted objective: sum(coherence[k] * total[k]) / sum(total)."
  (let* ((scopes (assq-ref graph 'scopes))
         (total-all (fold (lambda (s acc) (+ acc (total-flow s graph))) 0 scopes)))
    (if (= total-all 0) 0
        (/ (fold (lambda (s acc)
                   (+ acc (* (coherence s graph) (total-flow s graph))))
                 0 scopes)
           total-all))))
