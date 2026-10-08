;;; async.scm — vow-based variants of global-* aggregations + open-ballot
;;;
;;; Cross-vat federation is the use case: scope-roots may be far refs
;;; (held by OCapN to remote vats). Synchronous `$` doesn't work on far
;;; refs — we need `<-` (returns a vow) and `on` to compose.
;;;
;;; Two macros eliminate the boilerplate:
;;;
;;;   (on-> vow handler)        — shorthand for (on vow handler #:promise? #t)
;;;   (vow-let* ((x vow) ...) body)  — sequential vow bind, like let* but async
;;;
;;; A module of (playnet governance); the umbrella re-exports it.

(define-module (playnet governance async)
  #:use-module (playnet governance ballot)
  #:use-module (playnet governance snapshot)
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-11)
  #:use-module (goblins)
  #:export (on-> vow-let* vow-fold-async async-sum-over-scopes
            global-total-social-svc-async global-embodied-labor-in-pool-async
            global-sum-met-capacity-async global-sum-unmet-capacity-async
            global-citizen-gross-async global-citizen-claimed-async
            global-citizen-unmet-async global-citizen-ability-async global-ability-norm-async
            global-effective-balance-async voice-share-async commune-weight-async
            tally-mandated-async open-ballot-async spawn-ballot-from-snapshot))

;; =========================================================================
;; Vow composition primitives
;; =========================================================================

(define-syntax on->
  (syntax-rules ()
    "Like (on vow handler) but always returns a promise (vow).
     Equivalent to (on vow handler #:promise? #t)."
    ((_ vow-expr handler)
     (on vow-expr handler #:promise? #t))))

(define-syntax vow-let*
  (syntax-rules ()
    "Sequential vow binding — each binding's vow is awaited before the
     next is evaluated. The body runs once all bindings have resolved.
     Returns a vow resolving to the body's value.

       (vow-let* ((pool  (fetch-pool-async))
                   (total (fetch-total-async)))
         (/ pool total))

     Expands to nested (on-> ...) forms."
    ((_ () body ...)
     (begin body ...))
    ((_ ((var vow-expr) . rest) body ...)
     (on-> vow-expr
           (lambda (var)
             (vow-let* rest body ...))))))


;; =========================================================================
;; vow-fold — sequential vow composition over a list
;; =========================================================================

(define (vow-fold-async items step seed)
  "Sequentially process ITEMS with STEP : (item, acc) → vow-of-acc.
   Returns a vow resolving to the final accumulator."
  (if (null? items)
      (let-values (((p r) (spawn-promise-and-resolver)))
        (<-np r 'fulfill seed)
        p)
      (on-> (step (car items) seed)
            (lambda (next-acc)
              (if (null? (cdr items))
                  next-acc
                  (vow-fold-async (cdr items) step next-acc))))))


;; =========================================================================
;; Async aggregates over scope-roots
;; =========================================================================

(define (async-sum-over-scopes scope-roots accessor-method . accessor-args)
  "Cross-vat async: for each scope-root, fetch the requested quantity
   from its account-store asynchronously and sum. Returns a vow."
  (vow-fold-async
    scope-roots
    (lambda (scope acc)
      (on-> (<- scope 'account-store)
            (lambda (as)
              (on-> (apply <- as accessor-method accessor-args)
                    (lambda (v) (+ v acc))))))
    0))

(define (global-total-social-svc-async scope-roots)
  (async-sum-over-scopes scope-roots 'total-social-svc))

(define (global-embodied-labor-in-pool-async scope-roots)
  (async-sum-over-scopes scope-roots 'embodied-labor-in-pool))

(define (global-sum-met-capacity-async scope-roots)
  (async-sum-over-scopes scope-roots 'sum-met-capacity))

(define (global-sum-unmet-capacity-async scope-roots)
  (async-sum-over-scopes scope-roots 'sum-unmet-capacity))

(define (global-citizen-gross-async aid scope-roots)
  (async-sum-over-scopes scope-roots 'citizen-gross aid))

(define (global-citizen-claimed-async aid scope-roots)
  (async-sum-over-scopes scope-roots 'citizen-claimed aid))

(define (global-citizen-unmet-async aid scope-roots)
  (async-sum-over-scopes scope-roots 'citizen-unmet aid))


;; =========================================================================
;; Composed: global-effective-balance-async
;; =========================================================================

(define (global-citizen-ability-async aid scope-roots)
  "Vow: the citizen's contribution by ability r_p, summed per scope."
  (async-sum-over-scopes scope-roots 'citizen-ability aid))

(define (global-ability-norm-async scope-roots)
  "Vow: Σ r over every account holder, summed per scope."
  (async-sum-over-scopes scope-roots 'ability-norm))

(define (global-effective-balance-async aid scope-roots)
  "Vow resolving to citizen's effective-balance across scope-roots:
   the pool by ability (contribution r_p / Σ r), less what they claimed.
   Mirrors the sync global-effective-balance but composes via vows for
   cross-vat use; per-scope sums, so a person held in several scopes is
   read per scope (the fold's once-counting is the sync path's)."
  (vow-let* ((pool    (global-embodied-labor-in-pool-async scope-roots))
             (norm    (global-ability-norm-async scope-roots))
             (ability (global-citizen-ability-async aid scope-roots))
             (claimed (global-citizen-claimed-async aid scope-roots)))
    (let ((contribution (if (= 0 norm) 0 (* pool (/ ability norm)))))
      (max 0 (- contribution claimed)))))

(define (voice-share-async aid scope-roots)
  "Vow resolving to citizen's voice-share = gross / total_svc."
  (vow-let* ((gross (global-citizen-gross-async aid scope-roots))
             (total (global-total-social-svc-async scope-roots)))
    (if (= 0 total) 0 (/ gross total))))


;; =========================================================================
;; Cross-server federation: commune-weight + tally (async)
;; =========================================================================

(define (commune-weight-async federation commune-id scope-roots)
  "Vow resolving to a commune's federation weight (its share of total
   labor). Works with remote communes via `<-`."
  (vow-let* ((commune (<- federation 'member-commune commune-id))
             (scope   (<- commune 'scope-root))
             (as      (<- scope 'account-store))
             (local   (<- as 'total-social-svc))
             (total   (global-total-social-svc-async scope-roots)))
    (if (= 0 total) 0 (/ local total))))


(define (tally-mandated-async federation proposal-id scope-roots)
  "Vow resolving to mandated tally across communes. Each commune's
   delegate stance is weighted by its share of federation labor.
   Accumulator is (tally-hashmap . total-weight)."
  (vow-let* ((per-proposal (<- federation 'commune-stances-for proposal-id)))
    (let ((entries (hashmap-fold (lambda (k v acc) (cons (cons k v) acc))
                                '() per-proposal)))
      (on-> (vow-fold-async
              entries
              (lambda (pair acc)
                (let ((commune-id    (car pair))
                      (stance-bundle (cdr pair))
                      (tally         (car acc))
                      (tw            (cdr acc)))
                  (vow-let* ((weight (commune-weight-async
                                       federation commune-id scope-roots)))
                    (let* ((cleartext (if (pair? stance-bundle)
                                         (car stance-bundle) stance-bundle))
                           (position  (and (pair? cleartext) (caddr cleartext))))
                      (if position
                          (cons (hashmap-set tally position
                                            (+ weight (hashmap-ref tally position 0)))
                                (+ tw weight))
                          acc)))))
              (cons (hashmap) 0))
            (lambda (acc)
              (list (cons 'tally (car acc))
                    (cons 'total-mandated-weight (cdr acc))
                    (cons 'mode 'mandated)))))))


;; =========================================================================
;; open-ballot-async — cross-vat snapshot construction
;; =========================================================================

(define* (open-ballot-async domain proposal-id franchise description
                             citizens citizen-registry scope-roots
                             #:key
                             (credential-check (lambda (_aid) #t))
                             (close-authority #f))
  "Async variant of open-ballot. DOMAIN tags the ballot kind. For each citizen:
   - vow: voice-share-async aid scope-roots
   - vow: <- delegation-map 'resolve-for franchise
   Awaits all, builds voice-snapshot, spawns ^ballot in caller's vat.
   Returns a vow resolving to the voice-snapshot hashmap."
  (vow-fold-async
    citizens
    (lambda (rec acc-snapshot)
      (let* ((cid (citizen-record-id rec))
             (dm  (citizen-record-delegation-map rec)))
        (vow-let* ((vs       (voice-share-async cid scope-roots))
                   (resolved (if dm (<- dm 'resolve-for franchise) (hashmap))))
          (hashmap-set acc-snapshot cid
                       (voice-snap vs resolved)))))
    (hashmap)))

(define (spawn-ballot-from-snapshot domain proposal-id franchise description
                                     voice-snapshot citizen-registry
                                     credential-check close-authority)
  "Helper: spawn a ^ballot directly with a pre-built snapshot. Useful
   after open-ballot-async resolves and you want to materialize the
   ballot in the caller's vat. DOMAIN tags the ballot kind."
  (spawn ^ballot domain proposal-id franchise description
         voice-snapshot (hashmap)
         (make-sealer-verifier citizen-registry)
         credential-check close-authority
         (hashmap) (hashmap)
         'open))
