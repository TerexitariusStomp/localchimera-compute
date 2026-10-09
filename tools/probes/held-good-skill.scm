;;; held-good-skill.scm — a good a person holds is read as a skill they have.
;;;
;;;   guix shell --pure -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- \
;;;     guile --no-auto-compile -q -L module tools/probes/held-good-skill.scm
;;;
;;; vf-agent-skills (solve/engine.scm) takes every resource an agent holds with an
;;; on-hand quantity as one of their skills. A work flow asking for skill WATER is then
;;; met by a person whose only link to water is a stock of it. Expected (the second and
;;; third cases): work asking for a skill is met by a person holding that skill's
;;; resource, and by nobody else.
(use-modules (playnet test harness) (playnet test scope)
             (playnet planner vf schemas) (playnet planner scope live)
             (goblins) (goblins utils hashmap) (srfi srfi-1) (ice-9 format))
(setvbuf (current-output-port) 'none)
(define PLACE "town")
(define vat (spawn-vat #:name "p45"))
(define win (all-week-window "00:00" "23:59"))
(define* (run people orgs skills-of-person goods-held #:optional (work-skill #f))
  (let* ((procs (list (make-recipe-process #:id "bake" #:name "Bake")))
         (flows (list
                 ;; labour with NO skill named: the engine reads it as "general" labour
                 (make-recipe-flow #:id "bw" #:action 'work #:resource-conforms-to work-skill #:effort-quantity (make-measure 1.0 "hours") #:recipe-input-of "bake")
                 (make-recipe-flow #:id "bi" #:action 'consume #:resource-conforms-to "wheat" #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of "bake")
                 (make-recipe-flow #:id "bo" #:action 'produce #:resource-conforms-to "bread" #:resource-quantity (make-measure 10.0 "kg") #:recipe-output-of "bake" #:is-primary #t)))
         (recipes (list (make-recipe #:id "r" #:name "Bread" #:primary-output "bread" #:recipe-processes (list "bake"))))
         (agents (append (map (lambda (id) (make-agent #:id id #:type 'person #:name id #:primary-location PLACE #:classified-as '() #:availability-window win)) people)
                         (map (lambda (id) (make-agent #:id id #:type 'organization #:name id #:primary-location PLACE #:classified-as '() #:availability-window #f)) orgs)))
         (resources (append
                     (append-map (lambda (p) (map (lambda (g) (make-economic-resource #:id (format #f "~a-~a" p g) #:conforms-to g #:classified-as '()
                                                      #:accounting-quantity (make-measure 5.0 "kg") #:onhand-quantity (make-measure 5.0 "kg")
                                                      #:current-location PLACE #:primary-accountable p))
                                                  (append skills-of-person goods-held)))
                                 people)))
         (spatials (list (make-spatial-thing #:id PLACE #:lat 40.0 #:long -74.0))))
    (with-vat vat
      (let* ((obs (spawn ^mock `((all-resources . ,(lambda () resources)) (record-event . ,(lambda (e) "ok")))))
             (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
             (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
             (rs  (spawn ^mock `((all-recipes . ,(lambda () recipes)) (get-process-chain . ,(lambda (rid) procs))
                                 (flows-for-process . ,(lambda (pid) (cons (filter (lambda (f) (equal? (recipe-flow-recipe-input-of f) pid)) flows)
                                                                           (filter (lambda (f) (equal? (recipe-flow-recipe-output-of f) pid)) flows)))))))
             (root (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs)))
        (plan-scope->alist root #:demand '(("bread#town@0" . 40.0)) #:eco-caps (list (cons "wheat#town@0" 100.0)) #:backend 'native-c #:reproduce? #f)))))
(define (by-provider r) (let ((t '())) (for-each (lambda (w) (let ((p (assq-ref w 'provider)) (h (or (assq-ref w 'effort) 0))) (set! t (cons (cons p (+ h (or (assoc-ref t p) 0))) (alist-delete p t))))) (or (assq-ref r 'work) '())) t))
(define (skills r) (delete-duplicates (map (lambda (w) (assq-ref w 'conforms-to)) (or (assq-ref r 'work) '()))))

(format #t "~%A person holds a stock of WATER and no skill; the work in the recipe asks for skill WATER.~%")
(let ((r (run '("ann") '() '() '("water") "water")))
  (format #t "  met ~,3f, labour by provider ~s~%" (assq-ref r 'met) (by-provider r)))
(format #t "~%The same recipe asking for a skill she does not hold, and holds no such good:~%")
(let ((r (run '("ann") '() '() '("water") "welding")))
  (format #t "  met ~,3f, labour by provider ~s~%" (assq-ref r 'met) (by-provider r)))
(format #t "~%A person holding the skill resource itself:~%")
(let ((r (run '("ann") '() '("welding") '() "welding")))
  (format #t "  met ~,3f, labour by provider ~s~%" (assq-ref r 'met) (by-provider r)))
