;;; plan-for-unit.scm — Complete DDMRP multi-pass planning pipeline
;;;
;;; Architecture: The planner is a compiler.
;;;
;;;   Demands (source)
;;;     → Normalize (deduplicate IDs)
;;;     → Extract (demand/supply slots from stores)
;;;     → Classify (locally-satisfiable / transport / producible / external)
;;;     → Formulate (multi-pass fold with buffer guards)
;;;         Block A (Pass 0): Buffer evaluation + capacity reservation
;;;         Block B (Pass 1): Primary demand explosion (with TOY guard → deferred)
;;;         Block C (Pass 2): Derived replenishment from consumed specs
;;;         Pass 1b: Retry deferred demands (replenishment increased capacity)
;;;         Backtracking: Sacrifice low-priority to resolve metabolic debts
;;;     → Supply phase: Forward-schedule supply, route surplus to buffers
;;;     → Collect: Emit deficit/surplus/conservation signals
;;;
;;; Each pass is a pure function: (netter-state, context) → (netter-state, results)
;;; The netter is a pure state monad. Fork = identity. Retract = restore.

(use-modules (srfi srfi-1)
             (srfi srfi-11)
             (goblins utils hashmap))

(define *epsilon-pu* 1e-9)
(define *class-order*
  '((locally-satisfiable . 0) (transport-candidate . 1)
    (producible-with-imports . 2) (external-dependency . 3)))


;; ═════════════════════════════════════════════════════════════════════════
;; Extract + Classify (same as before, compact)
;; ═════════════════════════════════════════════════════════════════════════

(define (extract-demands plan-store)
  (filter-map
    (lambda (i)
      (let ((rq (intent-resource-quantity i)))
        (and rq (> (measure-has-numerical-value rq) *epsilon-pu*)
             `((intent-id . ,(intent-id i))
               (spec-id . ,(intent-resource-conforms-to i))
               (action . ,(intent-action i))
               (remaining-quantity . ,(measure-has-numerical-value rq))
               (unit . ,(measure-has-unit rq))
               (due . ,(intent-due i))
               (at-location . ,(intent-at-location i))
               (provider . ,(intent-provider i))
               (receiver . ,(intent-receiver i))))))
    ($ plan-store 'open-intents)))

(define (extract-supply observer)
  (filter-map
    (lambda (r)
      (let ((qty (measure-qty (economic-resource-onhand-quantity r))))
        (and (> qty *epsilon-pu*)
             `((id . ,(string-append "inv:" (economic-resource-id r)))
               (spec-id . ,(economic-resource-conforms-to r))
               (quantity . ,qty)
               (at-location . ,(economic-resource-current-location r))))))
    ($ observer 'all-resources)))

(define (classify-demand slot supply recipe-store)
  (let ((spec (assq-ref slot 'spec-id)))
    (cond
      ((any (lambda (s) (equal? (assq-ref s 'spec-id) spec)) supply) 'locally-satisfiable)
      ((and spec (pair? ($ recipe-store 'recipes-for-output spec))) 'producible-with-imports)
      (else 'external-dependency))))

(define (sort-classified classified)
  (sort classified
    (lambda (a b)
      (let ((ca (or (assq-ref *class-order* (assq-ref a 'class)) 3))
            (cb (or (assq-ref *class-order* (assq-ref b 'class)) 3)))
        (if (= ca cb)
            (string<? (or (assq-ref (assq-ref a 'slot) 'due) "9999")
                      (or (assq-ref (assq-ref b 'slot) 'due) "9999"))
            (< ca cb))))))


;; ═════════════════════════════════════════════════════════════════════════
;; Block A (Pass 0): Buffer evaluation + capacity reservation
;; ═════════════════════════════════════════════════════════════════════════

(define (block-a ns ctx)
  "Returns (values ns alerts reservations)."
  (let ((bzs (assq-ref ctx 'buffer-zone-store))
        (obs (assq-ref ctx 'observer))
        (ps  (assq-ref ctx 'plan-store))
        (profiles (assq-ref ctx 'buffer-profiles)))
    (if (not (and bzs profiles))
        (values ns '() '())
        (let* ((zones ($ bzs 'all-zones))
               (alerts
                 (filter-map
                   (lambda (bz)
                     (let* ((spec (buffer-zone-spec-id bz))
                            (resources ($ obs 'conforming-resources spec))
                            (onhand (fold (lambda (r a) (+ a (measure-qty (economic-resource-onhand-quantity r)))) 0 resources)))
                       (cons spec `((zone . ,(assq-ref (buffer-status onhand bz) 'zone))
                                    (onhand . ,onhand)
                                    (tor . ,(buffer-zone-tor bz))
                                    (toy . ,(buffer-zone-toy bz))
                                    (tog . ,(buffer-zone-tog bz))))))
                   zones))
               (reservations
                 (filter-map
                   (lambda (a)
                     (let ((z (assq-ref (cdr a) 'zone)))
                       (and (memq z '(red yellow))
                            (cons (car a)
                                  `((reserved . ,(max 0 (- (assq-ref (cdr a) 'tog) (assq-ref (cdr a) 'onhand))))
                                    (toy . ,(assq-ref (cdr a) 'toy)))))))
                   alerts))
               (final-ns
                 (fold (lambda (r ns-acc)
                         (let ((qty (assq-ref (cdr r) 'reserved)))
                           (if (> qty *epsilon-pu*)
                               (let-values (((new-ns _) (netter-reserve ns-acc ps obs (car r) qty)))
                                 new-ns)
                               ns-acc)))
                       ns reservations)))
          (values final-ns alerts reservations)))))


;; ═════════════════════════════════════════════════════════════════════════
;; Block B (Pass 1): Primary demands with buffer guard
;; ═════════════════════════════════════════════════════════════════════════

(define (block-b ns classified alerts reservations ctx)
  "Returns (values ns records deferred purchases)."
  (let ((rs (assq-ref ctx 'recipe-store)) (ps (assq-ref ctx 'plan-store))
        (obs (assq-ref ctx 'observer)) (agents (assq-ref ctx 'agents))
        (plan-id (assq-ref ctx 'plan-id)) (bf? (assq-ref ctx 'buffer-first?)))
    (let loop ((slots classified) (ns ns) (recs '()) (defer '()) (purch '()))
      (if (null? slots)
          (values ns (reverse recs) (reverse defer) (reverse purch))
          (let* ((e (car slots)) (slot (assq-ref e 'slot)) (cls (assq-ref e 'class))
                 (spec (assq-ref slot 'spec-id)) (qty (assq-ref slot 'remaining-quantity))
                 (due (or (assq-ref slot 'due) (number->string (current-time))))
                 (due-ep (if (number? due) due (iso-datetime->epoch due)))
                 (res-info (assoc spec reservations))
                 (toy (and res-info (assq-ref (cdr res-info) 'toy)))
                 (guard? (and bf? toy
                              (< (- (netter-net-available ns ps obs spec) qty) toy))))
            (if guard?
                (loop (cdr slots) ns recs (cons e defer) purch)
                (let-values (((ns2 result) (dependent-demand plan-id spec qty due-ep rs ps obs ns #:agents agents)))
                  (loop (cdr slots) ns2
                        (cons `((slot . ,slot) (class . ,cls) (result . ,result)) recs)
                        defer
                        (append (or (assq-ref result 'purchase-intents) '()) purch)))))))))


;; ═════════════════════════════════════════════════════════════════════════
;; Block C (Pass 2): Derived replenishment
;; ═════════════════════════════════════════════════════════════════════════

(define (block-c ns records alerts ctx)
  "Returns (values ns debts conservation)."
  (let ((rs (assq-ref ctx 'recipe-store)) (ps (assq-ref ctx 'plan-store))
        (obs (assq-ref ctx 'observer)) (agents (assq-ref ctx 'agents))
        (plan-id (assq-ref ctx 'plan-id))
        (buffered (or (assq-ref ctx 'buffered-specs) '())))
    (let* ((consumed
             (fold (lambda (rec acc)
                     (fold (lambda (a m)
                             (let* ((sp (cadr a)) (q (caddr a))
                                    (ex (or (assoc-ref m sp) 0)))
                               (cons (cons sp (+ ex q))
                                     (filter (lambda (p) (not (equal? (car p) sp))) m))))
                           acc (or (assq-ref (assq-ref rec 'result) 'allocated) '())))
                   '() records))
           (replen
             (filter-map
               (lambda (cp)
                 (let* ((sp (car cp)) (ai (assoc sp alerts)))
                   (and ai (memq (assq-ref (cdr ai) 'zone) '(red yellow))
                        (member sp buffered)
                        `((spec-id . ,sp)
                          (qty . ,(max 0 (- (assq-ref (cdr ai) 'tog) (assq-ref (cdr ai) 'onhand))))))))
               consumed))
           (rns (netter-fork ns)))
      (let loop ((ds replen) (rns rns) (debts '()))
        (if (null? ds)
            (values ns debts '())
            (let* ((d (car ds)) (sp (assq-ref d 'spec-id)) (q (assq-ref d 'qty)))
              (if (<= q *epsilon-pu*)
                  (loop (cdr ds) rns debts)
                  (let-values (((rns2 result)
                                (dependent-demand (string-append plan-id "-r") sp q (current-time)
                                  rs ps obs rns #:agents agents)))
                    (let ((short (fold (lambda (pi a)
                                         (+ a (if (and (intent-resource-quantity pi)
                                                       (equal? (intent-resource-conforms-to pi) sp))
                                                  (measure-has-numerical-value (intent-resource-quantity pi)) 0)))
                                       0 (or (assq-ref result 'purchase-intents) '()))))
                      (loop (cdr ds) rns2
                            (if (> short *epsilon-pu*)
                                (cons `((spec-id . ,sp) (shortfall . ,short)) debts)
                                debts)))))))))))


;; ═════════════════════════════════════════════════════════════════════════
;; Pass 1b: Retry deferred demands
;; ═════════════════════════════════════════════════════════════════════════

(define (pass-1b ns deferred ctx)
  "Returns (values ns records purchases)."
  (let ((rs (assq-ref ctx 'recipe-store)) (ps (assq-ref ctx 'plan-store))
        (obs (assq-ref ctx 'observer)) (agents (assq-ref ctx 'agents))
        (plan-id (assq-ref ctx 'plan-id)))
    (let loop ((slots deferred) (ns ns) (recs '()) (purch '()))
      (if (null? slots) (values ns (reverse recs) (reverse purch))
          (let* ((e (car slots)) (slot (assq-ref e 'slot)) (cls (assq-ref e 'class))
                 (spec (assq-ref slot 'spec-id)) (qty (assq-ref slot 'remaining-quantity))
                 (due-ep (iso-datetime->epoch (or (assq-ref slot 'due) "2099-01-01T00:00:00Z"))))
            (let-values (((ns2 result) (dependent-demand plan-id spec qty due-ep rs ps obs ns #:agents agents)))
              (loop (cdr slots) ns2
                    (cons `((slot . ,slot) (class . ,cls) (result . ,result)) recs)
                    (append (or (assq-ref result 'purchase-intents) '()) purch))))))))


;; ═════════════════════════════════════════════════════════════════════════
;; Backtracking: Sacrifice to resolve metabolic debts
;; ═════════════════════════════════════════════════════════════════════════

(define (backtrack ns debts all-records ctx)
  "Returns (values ns final-records deficits)."
  (if (null? debts)
      (values ns all-records '())
      (let ((rs (assq-ref ctx 'recipe-store)) (ps (assq-ref ctx 'plan-store))
            (obs (assq-ref ctx 'observer)) (agents (assq-ref ctx 'agents))
            (plan-id (assq-ref ctx 'plan-id)))
        ;; Sort: lowest priority first (highest class order, latest due)
        (let ((candidates
                (sort all-records
                  (lambda (a b)
                    (let ((ca (or (assq-ref *class-order* (assq-ref a 'class)) 3))
                          (cb (or (assq-ref *class-order* (assq-ref b 'class)) 3)))
                      (if (not (= ca cb)) (> ca cb)
                          (string>? (or (assq-ref (assq-ref a 'slot) 'due) "")
                                    (or (assq-ref (assq-ref b 'slot) 'due) ""))))))))
          (let loop ((cands candidates) (ns ns) (debts debts)
                     (kept all-records) (defs '()))
            (if (or (null? debts) (null? cands))
                (values ns kept
                        (append defs (map (lambda (d)
                                            `((kind . deficit) (spec-id . ,(assq-ref d 'spec-id))
                                              (qty . ,(assq-ref d 'shortfall))
                                              (source . metabolic-debt)))
                                          debts)))
                (let* ((cand (car cands))
                       (ns-ret (netter-retract ns (or (assq-ref (assq-ref cand 'result) 'plan-id) "?")))
                       ;; Re-explode candidate on retracted state
                       (slot (assq-ref cand 'slot))
                       (spec (assq-ref slot 'spec-id))
                       (qty (assq-ref slot 'remaining-quantity))
                       (due-ep (iso-datetime->epoch (or (assq-ref slot 'due) "2099-01-01T00:00:00Z"))))
                  (let-values (((ns3 re-result) (dependent-demand plan-id spec qty due-ep rs ps obs ns-ret #:agents agents)))
                    (if (> (length (or (assq-ref re-result 'processes) '())) 0)
                        ;; Re-explosion succeeded → sacrifice accepted, debts may resolve
                        (loop (cdr cands) ns3 '()
                              (cons `((slot . ,slot) (class . ,(assq-ref cand 'class)) (result . ,re-result))
                                    (delete cand kept))
                              defs)
                        ;; Failed → permanent sacrifice
                        (loop (cdr cands) ns-ret debts
                              (delete cand kept)
                              (cons `((kind . deficit) (spec-id . ,spec) (qty . ,qty)
                                      (source . unmet-demand))
                                    defs)))))))))))


;; ═════════════════════════════════════════════════════════════════════════
;; Supply phase + Collect
;; ═════════════════════════════════════════════════════════════════════════

(define (supply-phase ns supply alerts ctx)
  "Returns (values ns surpluses purchases)."
  (let ((rs (assq-ref ctx 'recipe-store)) (ps (assq-ref ctx 'plan-store))
        (obs (assq-ref ctx 'observer)) (agents (assq-ref ctx 'agents))
        (plan-id (assq-ref ctx 'plan-id)))
    (let loop ((slots supply) (ns ns) (surp '()) (purch '()))
      (if (null? slots) (values ns (reverse surp) (reverse purch))
          (let* ((s (car slots)) (spec (assq-ref s 'spec-id)) (qty (assq-ref s 'quantity)))
            (if (or (not spec) (<= qty *epsilon-pu*))
                (loop (cdr slots) ns surp purch)
                (let-values (((ns2 result) (dependent-supply plan-id spec qty (current-time)
                                             rs ps obs ns #:agents agents)))
                  (let sloop ((rem (or (assq-ref result 'surplus) '())) (acc surp))
                    (if (null? rem)
                        (loop (cdr slots) ns2 acc
                              (append (or (assq-ref result 'purchase-intents) '()) purch))
                        (let* ((sr (car rem)) (sp (assq-ref sr 'spec-id)) (sq (assq-ref sr 'quantity))
                               (ai (assoc sp alerts)) (z (and ai (assq-ref (cdr ai) 'zone))))
                          (if (and z (memq z '(red yellow)))
                              (let* ((need (max 0 (- (assq-ref (cdr ai) 'tog) (assq-ref (cdr ai) 'onhand))))
                                     (routed (min sq need)) (left (- sq routed)))
                                (sloop (cdr rem)
                                       (if (> left *epsilon-pu*)
                                           (cons `((kind . surplus) (spec-id . ,sp) (qty . ,left)) acc)
                                           acc)))
                              (sloop (cdr rem)
                                     (cons `((kind . surplus) (spec-id . ,sp) (qty . ,sq)) acc)))))))))))))


;; ═════════════════════════════════════════════════════════════════════════
;; plan-for-unit — the complete DDMRP planner
;; ═════════════════════════════════════════════════════════════════════════

(define* (plan-for-unit ids horizon
                        recipe-store plan-store observer
                        #:key (agents #f) (normalize-fn identity)
                              (plan-name "Plan")
                              (buffer-zone-store #f) (buffer-profiles #f)
                              (buffered-specs '()))
  "Complete DDMRP multi-pass planning algorithm."
  (let* ((canonical (normalize-fn ids))
         (plan-id (generate-id "plan-"))
         (_ ($ plan-store 'add-plan (make-plan plan-id plan-name #f #f #f #f #f #f)))
         (ctx `((recipe-store . ,recipe-store) (plan-store . ,plan-store)
                (observer . ,observer) (agents . ,agents) (plan-id . ,plan-id)
                (buffer-zone-store . ,buffer-zone-store)
                (buffer-profiles . ,buffer-profiles)
                (buffered-specs . ,buffered-specs)
                (buffer-first? . ,(and buffer-zone-store buffer-profiles #t))))
         (demands (extract-demands plan-store))
         (supply (extract-supply observer))
         (classified (sort-classified
                       (map (lambda (d) `((slot . ,d) (class . ,(classify-demand d supply recipe-store))))
                            demands)))
         (ns0 (empty-netter-state)))
    ;; The pipeline: Block A → B → C → 1b → Backtrack → Supply → Collect
    (call-with-values (lambda () (block-a ns0 ctx))
      (lambda (ns1 alerts reservations)
        (call-with-values (lambda () (block-b ns1 classified alerts reservations ctx))
          (lambda (ns2 p1-recs deferred p1-purch)
            (call-with-values (lambda () (block-c ns2 p1-recs alerts ctx))
              (lambda (ns3 debts conservation)
                (call-with-values (lambda () (pass-1b ns3 deferred ctx))
                  (lambda (ns4 d-recs d-purch)
                    (let ((all-recs (append p1-recs d-recs))
                          (all-purch (append p1-purch d-purch)))
                      (call-with-values (lambda () (backtrack ns4 debts all-recs ctx))
                        (lambda (ns5 final-recs deficit-sigs)
                          (call-with-values (lambda () (supply-phase ns5 supply alerts ctx))
                            (lambda (ns6 surplus-sigs supply-purch)
                              ;; Collect: emit signals
                              (for-each
                                (lambda (sig)
                                  (let-values (((intent meta) (signal->intent sig plan-id)))
                                    ($ plan-store 'add-intent intent)
                                    ($ plan-store 'set-meta (intent-id intent) meta)))
                                (append deficit-sigs surplus-sigs))
                              ;; Return
                              `((plan-id . ,plan-id)
                                (processes . ,(append-map
                                                (lambda (r) (or (assq-ref (assq-ref r 'result) 'processes) '()))
                                                final-recs))
                                (purchase-intents . ,(append all-purch supply-purch))
                                (deficit-signals . ,deficit-sigs)
                                (surplus-signals . ,surplus-sigs)))))))))))))))))
