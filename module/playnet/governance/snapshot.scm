;;; snapshot.scm — build a real voice-snapshot from the economic substrate
;;;
;;; The ballot's voice-snapshot is `hashmap citizen-id → (voice-share .
;;; delegation-map-ref)`. Tests build this by hand. Production callers
;;; should derive the voice-share from `voice-share` in
;;; (playnet planner) — it walks the supplied scope-roots and divides
;;; the citizen's gross-credited contribution by the federation total.
;;;
;;; This helper is deliberately small and pure: it knows nothing about
;;; KERI, sealers, or franchise. Callers pass in the citizen records and
;;; the scope-roots that constitute the franchise's economic universe.
;;;
;;; A "citizen record" here is a 4-tuple:
;;;   (citizen-id keri-aid delegation-map-actor [opaque])
;;; The fourth slot is ignored; this lets callers reuse richer record
;;; types without remapping.
;;;
;;; A module of (playnet governance); the umbrella re-exports it.


(define-module (playnet governance snapshot)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet pools credit-fold)
  #:use-module (srfi srfi-1)
  #:export (citizen-record-id citizen-record-keri-aid citizen-record-delegation-map
            build-voice-snapshot build-citizen-registry))

(define (citizen-record-id rec)        (list-ref rec 0))
(define (citizen-record-keri-aid rec)  (list-ref rec 1))
(define (citizen-record-delegation-map rec) (list-ref rec 2))


(define (build-voice-snapshot citizens scope-roots)
  "Return a hashmap citizen-id → (voice-share . delegation-map-ref)
   suitable for passing as `citizen-voice-data` to `open-ballot`.

   citizens:    list of records (citizen-id keri-aid delegation-map-actor . _)
   scope-roots: list of ^scope-root actor refs whose account-stores
                contribute to this franchise's voice computation.

   Citizens with zero voice-share are still included (their entry is
   (0 . delegation-map)) so that delegation chains terminating on them
   resolve consistently. The pure-tally treats zero-voice entries as
   no-ops without distortion."
  (fold
    (lambda (rec acc)
      (let* ((cid (citizen-record-id rec))
             (dm  (citizen-record-delegation-map rec))
             (vs  (voice-share cid scope-roots)))
        (hashmap-set acc cid (cons vs dm))))
    (hashmap)
    citizens))


(define (build-citizen-registry citizen-sealed-pairs)
  "Return a hashmap citizen-id → sealed?-actor.
   citizen-sealed-pairs: list of (citizen-id . sealed?-actor)."
  (fold (lambda (p acc) (hashmap-set acc (car p) (cdr p)))
        (hashmap) citizen-sealed-pairs))
