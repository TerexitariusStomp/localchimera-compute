;;; folksonomy/seed.scm — seed a scope's folksonomy from its own classifications.
;;;
;;; The gateway wires; it should not compute. This is the one piece of domain
;;; logic behind the boot seed: gather a scope's resource-spec classifications
;;; and hand them to categories->seed-doc (which filters the NON_CATEGORY
;;; denylist and turns legacy slash-paths into flat terms + broader edges), then
;;; contribute the result as the commons' first cut. Kept out of the actor (so
;;; the actor stays free of the planner dependency) and out of gateway.scm (so
;;; that file wires a one-liner, not a let*/catch block).

(define-module (playnet planner folksonomy seed)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (playnet planner vf schemas)
  #:use-module (srfi srfi-1); resource-specification-resource-classified-as
  #:use-module (playnet planner folksonomy graph)   ; categories->seed-doc
  #:export (seed-folksonomy!))

(define* (seed-folksonomy! folksonomy-ref scope-root #:key (aid "seed:commons"))
  "Seed FOLKSONOMY-REF from SCOPE-ROOT's specs' resource-classified-as, as AID.
   Legacy slash-paths become flat terms + edges; the commons boots with a
   humane starting cut instead of an empty spine, and users drift it by
   publishing their own. Best-effort: a scope with no specs (or a mock store)
   leaves the aggregate empty. Returns #t if it contributed, else #f."
  (catch #t
    (lambda ()
      (let* ((rs    ($ scope-root 'recipe-store))
             (specs (or (false-if-exception ($ rs 'all-resource-specs)) '()))
             (cats  (append-map
                     (lambda (s)
                       (or (resource-specification-resource-classified-as s) '()))
                     specs)))
        (and (pair? cats)
             (begin
               ($ folksonomy-ref 'contribute aid (categories->seed-doc cats))
               #t))))
    (lambda (k . a)
      (format (current-error-port) "[folksonomy] seed skipped: ~a ~a~%" k a)
      #f)))
