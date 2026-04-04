;;; control.scm — Control systems as relations
;;;
;;; Makes the control-theoretic structure of planning loops explicit.
;;; DDMRP buffer zones are bang-bang controllers; the planning cycle
;;; is observe-search-commit. This module generalizes: one relation,
;;; many control questions — forward, inverse, identification.
;;;
;;; Fact schema:
;;;   (control-loop loop-id sensor-id actuator-id law-kind)
;;;   (setpoint sensor-id target-value unit)
;;;   (gain loop-id gain-value)
;;;   (deadband loop-id half-width)
;;;   (observation sensor-id timestamp measured-value)

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))


;;; ── Fact relations ──────────────────────────────────────────────────────────

(define (control-loop-o facts loop-id sensor-id actuator-id law-kind)
  "Relate a control loop to its sensor, actuator, and law. Any direction."
  (in-list-o `(control-loop ,loop-id ,sensor-id ,actuator-id ,law-kind) facts))

(define (setpoint-o facts sensor-id target unit)
  "Relate a sensor to its desired value. Any direction."
  (in-list-o `(setpoint ,sensor-id ,target ,unit) facts))

(define (gain-o facts loop-id gain-value)
  "Relate a control loop to its gain parameter. Any direction."
  (in-list-o `(gain ,loop-id ,gain-value) facts))

(define (deadband-o facts loop-id half-width)
  "Relate a control loop to its deadband half-width. Any direction."
  (in-list-o `(deadband ,loop-id ,half-width) facts))

(define (observation-o facts sensor-id timestamp measured-value)
  "Relate a sensor to a timestamped measurement. Any direction."
  (in-list-o `(observation ,sensor-id ,timestamp ,measured-value) facts))


;;; ── Error (CLP(FD) — bidirectional) ─────────────────────────────────────────
;;; "What error given SP and PV?" AND "What PV gives this error?"

(define (error-o sp pv error)
  "error = sp - pv. Three questions from one relation."
  (-fd sp pv error))


;;; ── Control law (branching via conde) ───────────────────────────────────────
;;; Multiple law kinds explored simultaneously.

(define (control-law-o facts loop-id error action)
  "Relate error to action via the control law for LOOP-ID.
   proportional: action = gain * error
   bang-bang: error > 0 → 1, else → 0
   deadband: |error| > half-width → ±1, else → 0 (hysteresis)"
  (fresh (sensor-id actuator-id law-kind)
    (control-loop-o facts loop-id sensor-id actuator-id law-kind)
    (conde
      ;; Proportional: action = gain * error (CLP(FD) bidirectional)
      ((== law-kind 'proportional)
       (fresh (g)
         (gain-o facts loop-id g)
         (*fd g error action)))
      ;; Bang-bang: binary on/off
      ((== law-kind 'bang-bang)
       (conde
         ((<fd 0 error) (== action 1))
         ((<=fd error 0) (== action 0))))
      ;; Deadband: neutral zone (hysteresis)
      ((== law-kind 'deadband)
       (fresh (hw neg-hw)
         (deadband-o facts loop-id hw)
         (-fd 0 hw neg-hw)
         (conde
           ((<fd hw error) (== action 1))
           ((<fd error neg-hw) (== action -1))
           ((<=fd neg-hw error) (<=fd error hw) (== action 0))))))))


;;; ── Control action (main entry point) ───────────────────────────────────────
;;; Full loop: measurement → error → law → action. Any direction.

(define (control-action-o facts loop-id pv action)
  "Full control loop: PV → error → law → action. Bidirectional.
   Forward: given PV, what action?
   Inverse: given action, what PV?"
  (fresh (sensor-id actuator-id law-kind sp unit error)
    (control-loop-o facts loop-id sensor-id actuator-id law-kind)
    (setpoint-o facts sensor-id sp unit)
    (error-o sp pv error)
    (control-law-o facts loop-id error action)))


;;; ── Control signal bridge ───────────────────────────────────────────────────
;;; Convert control action to a signal fact (signals.scm interop).

(define (control-signal-o facts loop-id pv signal)
  "Bridge control action to signal system. Uses signal-tag-o."
  (fresh (sensor-id actuator-id law-kind action sp unit error)
    (control-loop-o facts loop-id sensor-id actuator-id law-kind)
    (setpoint-o facts sensor-id sp unit)
    (error-o sp pv error)
    (control-law-o facts loop-id error action)
    (project (loop-id sensor-id action error)
      (let* ((kind (cond ((> action 0) 'replenishment)
                         ((< action 0) 'surplus)
                         (else 'conservation)))
             (qty (abs error)))
        (fresh (tag)
          (signal-tag-o kind tag)
          (== signal `((kind . ,kind) (spec-id . ,sensor-id)
                       (qty . ,qty) (source . control)
                       (meta . ((loop-id . ,loop-id)
                                (error . ,error)
                                (action . ,action))))))))))


;;; ── DDMRP as control loop ──────────────────────────────────────────────────
;;; Shows DDMRP IS a control loop — wraps existing relations, doesn't replace.

(define (ddmrp-as-control-o facts spec-id today result)
  "Express DDMRP evaluation as a control loop.
   sensor = spec-id (NFP is the process variable)
   setpoint = tog (top of green)
   law = zone (multi-zone bang-bang)"
  (fresh (ddmrp-result tor toy tog adu dlt)
    (ddmrp-evaluate-o facts spec-id today ddmrp-result)
    (buffer-zone-fact-o facts spec-id tor toy tog adu dlt)
    (project (ddmrp-result tog)
      (let* ((nfp-val (assq-ref ddmrp-result 'nfp))
             (zone-val (assq-ref ddmrp-result 'zone))
             (sig (assq-ref ddmrp-result 'signal))
             (error-val (- tog nfp-val))
             (action-val (if (memq zone-val '(red yellow)) 1 0)))
        (== result `((loop-id . ,(string-append "ddmrp:" spec-id))
                     (sensor-id . ,spec-id) (setpoint . ,tog)
                     (pv . ,nfp-val) (error . ,error-val)
                     (zone . ,zone-val) (action . ,action-val)
                     (signal . ,sig)))))))


;;; ── Gain identification (inverse query) ─────────────────────────────────────
;;; Pure CLP(FD). *fd running backwards.

(define (identify-gain-o facts loop-id pv action gain)
  "Given observed PV and action, what gain explains them?
   gain * (sp - pv) = action. Bidirectional via *fd."
  (fresh (sensor-id actuator-id sp unit error)
    (control-loop-o facts loop-id sensor-id actuator-id 'proportional)
    (setpoint-o facts sensor-id sp unit)
    (error-o sp pv error)
    (*fd gain error action)))


;;; ── Loop trace (depth-bounded) ──────────────────────────────────────────────
;;; Same pattern as provenance-o in trace.scm.

(define *max-trace-depth* 50)

(define (loop-trace-o facts loop-id observations trace)
  "Trace a sequence of observations through a control loop.
   observations = list of (observation sensor-id timestamp pv) tuples
   trace = list of (timestamp pv error action) entries"
  (loop-trace-iter facts loop-id observations trace *max-trace-depth*))

(define (loop-trace-iter facts loop-id observations trace depth)
  (if (or (null? observations) (= depth 0))
      (== trace '())
      (fresh (sensor-id ts pv sp unit error action rest)
        (== (car observations) `(observation ,sensor-id ,ts ,pv))
        (setpoint-o facts sensor-id sp unit)
        (error-o sp pv error)
        (control-law-o facts loop-id error action)
        (loop-trace-iter facts loop-id (cdr observations) rest (- depth 1))
        (== trace (cons `(,ts ,pv ,error ,action) rest)))))


;;; ── Stability classification ────────────────────────────────────────────────
;;; Ground computation via project (honest — observations must be known).

(define (stability-o observations classification)
  "Relate an observation sequence to a stability classification.
   converging | oscillating | diverging | insufficient"
  (project (observations)
    (let* ((vals (map (lambda (obs) (list-ref obs 3)) observations))
           (n (length vals)))
      (if (< n 3)
          (== classification 'insufficient)
          (let* ((diffs (map (lambda (a b) (- b a))
                             vals (cdr vals)))
                 (abs-diffs (map abs diffs))
                 (sign-changes
                   (let loop ((ds diffs) (count 0))
                     (if (< (length ds) 2) count
                         (loop (cdr ds)
                               (if (< (* (car ds) (cadr ds)) 0)
                                   (+ count 1) count))))))
            (cond
              ((> sign-changes (quotient (- n 1) 2))
               (== classification 'oscillating))
              ((> (last abs-diffs) (car abs-diffs))
               (== classification 'diverging))
              (else
               (== classification 'converging))))))))


;;; ── Composition (cascade two loops) ─────────────────────────────────────────
;;; Output of inner feeds error of outer.

(define (compose-o facts outer-loop-id inner-loop-id pv final-action)
  "Cascade two control loops: inner loop's action becomes outer loop's error."
  (fresh (inner-action)
    (control-action-o facts inner-loop-id pv inner-action)
    (control-law-o facts outer-loop-id inner-action final-action)))
