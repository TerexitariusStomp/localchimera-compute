;;; critical-path.scm — Critical Path Method scheduling
;;;
;;; Forward pass (ES/EF) + backward pass (LS/LF). Float = LF - EF.
;;; Processes with float=0 are on the critical path.

(use-modules (srfi srfi-1) (goblins utils hashmap))

(define (critical-path plan-id plan-store process-registry recipe-store
                       . rest)
  "Compute the critical path for processes in a plan.
   Returns alist: ((critical-path . process-ids) (schedule . alist-per-process)
                    (total-duration-ms . number))."
  (let* ((default-dur-ms (if (pair? rest) (car rest) 3600000))
         (procs ($ process-registry 'for-plan plan-id)))
    (if (null? procs) '((critical-path) (schedule) (total-duration-ms . 0))
        ;; Build dependency graph from commitment/intent flow matching
        (let* ((proc-ids (map process-id procs))
               (predecessors (make-hash-table))
               (successors (make-hash-table))
               (durations (make-hash-table)))
          ;; Initialize
          (for-each (lambda (p)
                      (let ((pid (process-id p)))
                        (hash-set! predecessors pid '())
                        (hash-set! successors pid '())
                        (hash-set! durations pid
                          (let ((ps (and (process-based-on p)
                                        ($ recipe-store 'get-process-spec (process-based-on p)))))
                            ;; Use process timestamps if available
                            (if (and (process-has-beginning p) (process-has-end p))
                                (let ((b (iso-datetime->epoch (process-has-beginning p)))
                                      (e (iso-datetime->epoch (process-has-end p))))
                                  (* (- e b) 1000))
                                default-dur-ms)))))
                    procs)
          ;; Build edges: process A → B if A produces what B consumes (via commitments)
          (let ((commitments ($ plan-store 'commitments-for-plan plan-id)))
            (for-each
              (lambda (c)
                (when (and (commitment-output-of c) (commitment-resource-conforms-to c))
                  (let ((out-pid (commitment-output-of c))
                        (spec (commitment-resource-conforms-to c)))
                    ;; Find consuming commitments for same spec
                    (for-each
                      (lambda (c2)
                        (when (and (commitment-input-of c2)
                                   (equal? (commitment-resource-conforms-to c2) spec)
                                   (not (equal? (commitment-input-of c2) out-pid)))
                          (let ((in-pid (commitment-input-of c2)))
                            (when (and (member out-pid proc-ids) (member in-pid proc-ids))
                              (hash-set! successors out-pid
                                (cons in-pid (hash-ref successors out-pid '())))
                              (hash-set! predecessors in-pid
                                (cons out-pid (hash-ref predecessors in-pid '())))))))
                      commitments))))
              commitments))
          ;; Forward pass: ES/EF
          (let ((es (make-hash-table)) (ef (make-hash-table)))
            ;; Topo sort (Kahn's)
            (let* ((in-deg (make-hash-table))
                   (_ (for-each (lambda (pid)
                                  (hash-set! in-deg pid (length (hash-ref predecessors pid '()))))
                                proc-ids))
                   (queue (filter (lambda (pid) (= 0 (hash-ref in-deg pid 0))) proc-ids))
                   (order '()))
              (let topo-loop ((q queue))
                (unless (null? q)
                  (let ((cur (car q)))
                    (set! order (cons cur order))
                    (hash-set! es cur
                      (fold (lambda (pred best)
                              (max best (hash-ref ef pred 0)))
                            0 (hash-ref predecessors cur '())))
                    (hash-set! ef cur (+ (hash-ref es cur 0) (hash-ref durations cur default-dur-ms)))
                    (let ((new-q (cdr q)))
                      (for-each
                        (lambda (succ)
                          (let ((d (- (hash-ref in-deg succ 1) 1)))
                            (hash-set! in-deg succ d)
                            (when (= d 0) (set! new-q (append new-q (list succ))))))
                        (hash-ref successors cur '()))
                      (topo-loop new-q)))))
              (set! order (reverse order))
              ;; Backward pass: LS/LF
              (let* ((total-dur (fold (lambda (pid best) (max best (hash-ref ef pid 0)))
                                      0 proc-ids))
                     (ls (make-hash-table)) (lf (make-hash-table)))
                (for-each (lambda (pid) (hash-set! lf pid total-dur)) proc-ids)
                (for-each
                  (lambda (pid)
                    (for-each
                      (lambda (succ)
                        (hash-set! lf pid (min (hash-ref lf pid total-dur)
                                               (hash-ref ls succ total-dur))))
                      (hash-ref successors pid '()))
                    (hash-set! ls pid (- (hash-ref lf pid total-dur)
                                         (hash-ref durations pid default-dur-ms))))
                  (reverse order))
                ;; Critical path = processes with float = 0
                (let ((critical (filter (lambda (pid)
                                          (< (abs (- (hash-ref lf pid 0) (hash-ref ef pid 0))) 1))
                                        order))
                      (schedule (map (lambda (pid)
                                       `((process-id . ,pid)
                                         (es . ,(hash-ref es pid 0))
                                         (ef . ,(hash-ref ef pid 0))
                                         (ls . ,(hash-ref ls pid 0))
                                         (lf . ,(hash-ref lf pid 0))
                                         (float . ,(- (hash-ref lf pid 0) (hash-ref ef pid 0)))))
                                     order)))
                  `((critical-path . ,critical)
                    (schedule . ,schedule)
                    (total-duration-ms . ,total-dur))))))))))
