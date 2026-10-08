;;; federation-a/config.scm — <federation-a-config> record
;;;
;;; Structurally parallel to Base's <federation-config> in
;;; module/playnet/planner/relational/federation.scm:131-137, with two
;;; A-specific additions (resilient?, attenuate?) and one field elided
;;; (plan-actor? — always #t in A, kept implicit).
;;;
;;; Included fragment — imports come from (playnet deprecated federation-a).

(define-module (playnet deprecated federation-a config)
  #:use-module (srfi srfi-9)
  #:use-module (playnet deprecated planner)
  #:export (<federation-a-config> %make-federation-a-config federation-a-config?
            federation-a-config-weight-fn federation-a-config-max-steps
            federation-a-config-max-leaf-results federation-a-config-resilient?
            federation-a-config-attenuate? federation-a-config-leaf-planner
            make-federation-a-config))

(define-record-type <federation-a-config>
  (%make-federation-a-config weight-fn max-steps max-leaf-results
                             resilient? attenuate? leaf-planner)
  federation-a-config?
  (weight-fn         federation-a-config-weight-fn)
  (max-steps         federation-a-config-max-steps)
  (max-leaf-results  federation-a-config-max-leaf-results)
  (resilient?        federation-a-config-resilient?)
  (attenuate?        federation-a-config-attenuate?)
  (leaf-planner      federation-a-config-leaf-planner))

(define* (make-federation-a-config #:key
                                   (weight-fn #f)
                                   (level-fn #f)
                                   (max-steps 50)
                                   (max-leaf-results *default-leaf-result-count*)
                                   (resilient? #f)
                                   (attenuate? #f)
                                   (leaf-planner #f))
  "Build a <federation-a-config>. Either WEIGHT-FN or LEVEL-FN may be
   supplied (not both). LEVEL-FN is exponentiated via make-weight-fn
   from harmony.scm — same convention as Base's make-federation-config."
  (when (and weight-fn level-fn)
    (error "make-federation-a-config: pass weight-fn OR level-fn, not both"))
  (%make-federation-a-config
    (or weight-fn (and level-fn (make-weight-fn level-fn)))
    max-steps
    max-leaf-results
    resilient?
    attenuate?
    leaf-planner))
