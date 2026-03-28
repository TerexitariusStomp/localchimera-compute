;;; positioning.scm — DDMRP strategic inventory positioning (Ch 6)
;;;
;;; Analyzes recipe structures for decoupling point and control point candidates.

(use-modules (srfi srfi-1))

(define (routing-geometry recipe-id recipe-store)
  "Analyze each process: upstream/downstream path counts, convergent/divergent flags.
   Returns list of alists per process."
  (let* ((chain ($ recipe-store 'get-process-chain recipe-id)))
    (map (lambda (rp)
           (let* ((pid (recipe-process-id rp))
                  (flows ($ recipe-store 'flows-for-process pid))
                  (inputs (car flows))
                  (outputs (cdr flows))
                  (n-inputs (length inputs))
                  (n-outputs (length outputs)))
             `((process-id . ,pid)
               (name . ,(recipe-process-name rp))
               (upstream-path-count . ,n-inputs)
               (downstream-path-count . ,n-outputs)
               (is-convergent . ,(> n-inputs 1))
               (is-divergent . ,(> n-outputs 1))
               (is-gating-point . ,(and (> n-inputs 1) (= n-outputs 1))))))
         chain)))

(define (rank-decoupling-candidates recipe-id recipe-store . rest)
  "Score each intermediate output as stock-buffer candidate.
   Higher score = better candidate. Returns sorted list of alists."
  (let* ((chain ($ recipe-store 'get-process-chain recipe-id))
         (full-lt (fold (lambda (rp acc) (+ acc (rp-duration-days rp))) 0 chain))
         (geometry (routing-geometry recipe-id recipe-store)))
    (let ((candidates
            (filter-map
              (lambda (geo)
                (let* ((pid (assq-ref geo 'process-id))
                       (n-down (assq-ref geo 'downstream-path-count))
                       ;; Compression: how much DLT is reduced by buffering here
                       (procs-after (length (take-right chain
                                     (- (length chain)
                                        (+ 1 (list-index (lambda (rp) (equal? (recipe-process-id rp) pid)) chain))))))
                       (lt-after (fold (lambda (rp acc) (+ acc (rp-duration-days rp)))
                                       0 (take-right chain procs-after)))
                       (compression (if (> full-lt 0) (/ lt-after full-lt) 0))
                       ;; Leverage: how many downstream paths benefit
                       (leverage (max 1 n-down))
                       ;; Score
                       (score (+ (* compression 50)
                                 (min (* leverage 10) 30)
                                 (if (assq-ref geo 'is-divergent) 10 0)
                                 (if (assq-ref geo 'is-convergent) 5 0))))
                  `((process-id . ,pid)
                    (score . ,score)
                    (compression . ,compression)
                    (leverage . ,leverage)
                    (geometry . ,geo))))
              geometry)))
      (sort candidates (lambda (a b) (> (assq-ref a 'score) (assq-ref b 'score)))))))

(define (rank-control-point-candidates recipe-id recipe-store)
  "Score each process for time-buffer control point. Returns sorted list."
  (let ((geometry (routing-geometry recipe-id recipe-store)))
    (sort
      (map (lambda (geo)
             (let ((score (+ (if (assq-ref geo 'is-convergent) 3 0)
                             (if (assq-ref geo 'is-gating-point) 2 0)
                             (if (assq-ref geo 'is-divergent) 1 0))))
               `((process-id . ,(assq-ref geo 'process-id))
                 (score . ,score)
                 (geometry . ,geo))))
           geometry)
      (lambda (a b) (> (assq-ref a 'score) (assq-ref b 'score))))))
