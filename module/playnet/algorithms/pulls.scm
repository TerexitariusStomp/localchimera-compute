;;; algorithms/pulls.scm — Pull: the marginal harmony of one more hour.
;;;
;;; Spec: docs/playnet.typ §"Derived demand and the pull of a bottleneck".
;;;
;;; A *pull* is how hard a tension tugs toward relaxation: the marginal
;;; harmony that one more hour of skill k at time t in cell c would resolve.
;;; Formally the dual variable λ_(k,t,c) of the labour-availability
;;; constraint, updated by subgradient ascent on the Lagrangian dual.
;;;
;;; The word is *pull*: what coordinates here is computed in the open, in
;;; labour-hours, and is carried by no commodity. The literature's name for
;;; the same dual is "shadow price". The tensor holds one pull per
;;; (skill, cell, time bucket); the subgradient step moves them.

(define-module (playnet algorithms pulls)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (goblins utils hashmap)
  #:export (make-pull-tensor pull-tensor?
            tensor-ref tensor-set tensor-update
            compute-subgradient
            subgradient-step
            tensor-norm))


(define-record-type <pull-tensor>
  (%make-pull-tensor data)
  pull-tensor?
  (data st-data))

(define (make-pull-tensor)
  (%make-pull-tensor (hashmap)))


;;; ── Key encoding ────────────────────────────────────────────────────────────
;;; Keys are (skill . cell . time-bucket) triples, encoded as strings
;;; for hashmap storage.

(define (tensor-key skill cell time-bucket)
  (string-append (or skill "") "|" (or cell "") "|" (or time-bucket "")))

(define (tensor-ref tensor skill cell time-bucket)
  (hashmap-ref (st-data tensor) (tensor-key skill cell time-bucket) 0))

(define (tensor-set tensor skill cell time-bucket value)
  (%make-pull-tensor
   (hashmap-set (st-data tensor) (tensor-key skill cell time-bucket) value)))

(define (tensor-update tensor skill cell time-bucket f)
  (let* ((key (tensor-key skill cell time-bucket))
         (old (hashmap-ref (st-data tensor) key 0)))
    (%make-pull-tensor (hashmap-set (st-data tensor) key (f old)))))


;;; ── Subgradient computation ─────────────────────────────────────────────────

(define (compute-subgradient demand-by-key supply-by-key)
  "Compute the subgradient g_(k,t,c) = demand - supply for each key.
   DEMAND-BY-KEY and SUPPLY-BY-KEY are alists of (key . hours).
   Returns an alist of (key . gradient-value)."
  (let ((all-keys (delete-duplicates
                   (append (map car demand-by-key)
                           (map car supply-by-key)))))
    (map (lambda (key)
           (let ((d (or (assoc-ref demand-by-key key) 0))
                 (s (or (assoc-ref supply-by-key key) 0)))
             (cons key (- d s))))
         all-keys)))

(define (assoc-ref alist key)
  (let ((p (assoc key alist))) (if p (cdr p) #f)))

(define* (subgradient-step tensor gradient step-size)
  "Update: λ ← max(0, λ + α·g). Returns new tensor."
  (fold (lambda (entry t)
          (let* ((key (car entry))
                 (g   (cdr entry))
                 (old (hashmap-ref (st-data t) key 0))
                 (new (max 0 (+ old (* step-size g)))))
            (%make-pull-tensor (hashmap-set (st-data t) key new))))
        tensor gradient))

(define (tensor-norm tensor)
  "L2 norm of the tensor (for convergence check)."
  (sqrt (hashmap-fold (lambda (_k v acc) (+ acc (* v v)))
                      0 (st-data tensor))))
