;;; test-one-citizen.scm — the communes of one solve partition the economy.
;;;
;;; A decomposed solve equals the pooled solve of the real economy only if each
;;; person and record sits in exactly one program (planner/facts/partition.scm;
;;; docs/planning/federation/federation-identity-and-folds.md §The criterion). The solver
;;; cannot see a duplicate — it converges, correctly, to the answer for a
;;; different economy — so the entry of federated-plan reads the structure:
;;;   • a scope named beside its own member is refused (its bodies would stand
;;;     in the parent's program and the child's);
;;;   • a body declared in two communes' stores or pools is refused;
;;;   • disjoint communes solve as before.
;;; And a scope's record carries its OWN labour entries, never the subtree total.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-one-citizen.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness)
             (playnet knowledge recipes federation-demo) (playnet scope root) (playnet vf schemas) (playnet vf beyond schedules) (srfi srfi-1)
             (playnet doors service)
             (playnet vf facts partition)
             (playnet pools availability-pool)
             ((playnet pools labour-fold) #:select (skill-specs-for-agent))
             ((playnet scope live) #:select (scope-labour?))
             (playnet knowledge recipes federation-demo)
             (goblins)
             (goblins utils hashmap)
             (srfi srfi-1)
             (srfi srfi-13))
(use-modules ((playnet wire rows) #:select (plain-reply)))   ; a door's rows, read back as alists

(display "\n── held-twice: the pure count ──\n")
(check "disjoint holders partition" (held-twice '(("a" 1 2) ("b" 3))) '())
(check "a key under two owners is named with both"
       (held-twice '(("a" 1 2) ("b" 2 3))) '((2 "a" "b")))
(check "an owner listing a key twice holds it once"
       (held-twice '(("a" 1 1) ("b" 2))) '())
(check "keys can be pairs (kind . id)"
       (held-twice '(("a" (agent . "x")) ("b" (resource . "x") (agent . "x"))))
       '(((agent . "x") "a" "b")))

(define vat (spawn-vat))

(define (fresh-world)
  (let ((a (spawn-scope-root "Granary")) (b (spawn-scope-root "Table"))
        (svc (spawn ^planner-service (hashmap))))
    (seed-fed-commune! a "fed" "commune-granary" "Granary" "venue-granary" 42.70 23.32 300.0)
    (seed-fed-commune! b "fed" "commune-table"   "Table"   "venue-table"   42.75 23.40 0.0)
    ($ svc 'add-scope! "Granary" a)
    ($ svc 'add-scope! "Table"   b)
    (values svc a b)))

(define (plan svc)
  ($ svc 'federated-plan "flour"
     (list (list "Granary" (cons "bread#venue-granary@0" 5.0))
           (list "Table"   (cons "bread#venue-table@0" 40.0)))))

(define (message-of env) (if (eq? (car env) 'error) (format #f "~a" (cdr env)) ""))

(with-vat vat
  (call-with-values fresh-world
    (lambda (svc a b)
      (display "\n── disjoint communes solve ──\n")
      (check "two communes with their own bakers: ok" (car (plan svc)) 'ok)

      (display "\n── a scope beside its own member is refused ──\n")
      ($ svc 'move-scope! "Table" "Granary")
      (let ((r (plan svc)))
        (check "parent and child in one call: refused" (car r) 'error)
        (check "and the refusal names the overlap"
               (and (string-contains (message-of r) "overlap") #t) #t)
        (check "the scope held twice is the parent"
               (and (string-contains (message-of r) "scope Granary") #t) #t))
      ($ svc 'move-scope! "Table" #f)
      (check "unnested again: ok" (car (plan svc)) 'ok)

      (display "\n── sibling communes under one parent are two programs ──\n")
      ($ svc 'add-scope! "Region" (spawn-scope-root "Region"))
      ($ svc 'move-scope! "Granary" "Region")
      ($ svc 'move-scope! "Table" "Region")
      (let ((r (plan svc)))
        (check "two members of one parent: ok" (list (car r) (message-of r)) '(ok "")))
      ($ svc 'move-scope! "Granary" #f)
      ($ svc 'move-scope! "Table" #f)

      (display "\n── a body in two communes is refused ──\n")
      ;; Table's store also holds Granary's baker: one body, two programs
      (let* ((as-a ($ a 'agent-store)) (as-b ($ b 'agent-store))
             (baker (find (lambda (x) (equal? (agent-id x) "w-venue-granary"))
                          ($ as-a 'all-agents))))
        ($ as-b 'add-agent baker)
        (let ((r (plan svc)))
          (check "a shared baker: refused" (car r) 'error)
          (check "naming the body"
                 (and (string-contains (message-of r) "agent w-venue-granary") #t) #t))))))

;; a world of its own: the sections above leave a baker in two stores
(display "\n── a scope's record carries its own labour ──\n")
(with-vat vat
  (call-with-values fresh-world
    (lambda (svc a b)
      ($ svc 'move-scope! "Table" "Granary")
      (let* ((own   (lambda (sid) (length (pool-entries ($ ($ svc 'labour-pool sid) 'fold-own)))))
             (total (lambda (sid) (length ($ ($ svc 'labour-pool sid) 'entries)))))
        (check "the parent's total holds the child's bodies too"
               (> (total "Granary") (own "Granary")) #t)))))

;; ── one home per person ──────────────────────────────────────────────────────
;; A person connects through whichever scope; their facts are written at one.
;; Declared twice (through two scopes) a need was a keyed sum counted twice:
;; the UC's demand read twice what the person asked for.
(display "\n── a person's need in two communes is refused, though she has no profile ──\n")
(with-vat vat
  (call-with-values fresh-world
    (lambda (svc a b)
      (for-each (lambda (root)
                  ($ ($ root 'plan-store) 'add-intent
                     (make-intent #:id "need:cleo:spec-soap" #:action 'consume #:name "soap" #:resource-conforms-to "spec-soap"
                                  #:resource-quantity (make-measure 2 "bar") #:receiver "cleo" #:in-scope-of '())))
                (list a b))
      (let ((r (plan svc)))
        (check "she holds no agent record anywhere" 
               (or ($ ($ a 'agent-store) 'get-agent "cleo") ($ ($ b 'agent-store) 'get-agent "cleo")) #f)
        (check "her need held by both: refused" (car r) 'error)
        (check "naming the need"
               (and (string-contains (message-of r) "need need:cleo:spec-soap") #t) #t)))))

(display "\n── a person's facts land at one home, whichever scope they connect through ──\n")
(with-vat vat
  (let* ((svc (spawn ^planner-service (hashmap)))
         (a (spawn-scope-root "Granary")) (b (spawn-scope-root "Table")))
    ($ svc 'add-scope! "Granary" a)
    ($ svc 'add-scope! "Table" b)
    (define (declare! scope qty)
      ($ svc 'declare-need scope "alice" "spec-bread" qty "loaf" "loc-pantry" "" "" "🍞" #f #f "bread"))
    (check "the first scope alice writes through is her home" (car (declare! "Granary" 3)) 'ok)
    (check "the home is that scope" ($ svc 'home-of "alice") "Granary")
    (check "the same need declared through the other scope lands at the home"
           (car (declare! "Table" 5)) 'ok)
    (define (need-rows root)
      (filter (lambda (i) (string-prefix? "need:alice:" (intent-id i))) ($ ($ root 'plan-store) 'all-intents)))
    (check "the other scope holds no need of hers" (length (need-rows b)) 0)
    (check "the home holds it once" (length (need-rows a)) 1)
    (check "the need is the later declaration (an edit), not a second one"
           (map (lambda (n) (assq-ref n 'qty)) (assq-ref (cdr (plain-reply ($ svc 'my-slots "Granary" "alice"))) 'needs)) '(5))
    (check "read through the other scope, she sees the same needs"
           (map (lambda (n) (assq-ref n 'qty)) (assq-ref (cdr (plain-reply ($ svc 'my-slots "Table" "alice"))) 'needs)) '(5))
    (check "the UC reads her need once"
           (apply + (map cdr ($ svc 'demand-total '(0)))) 5)
    (display "\n── the doors that state where she is and what she named land at the home too ──\n")
    (define (places-of root)
      (filter (lambda (l) (string-prefix? "place:alice:" (spatial-thing-id l)))
              ($ ($ root 'spatial-thing-store) 'all-locations)))
    (define (pos-row root) ($ ($ root 'plan-store) 'get-meta "pos|alice|0"))
    ($ svc 'declare-place "Table" "alice" "Corner" 42.7 23.3)
    ($ svc 'set-position-latlon "Table" "alice" 0 52.5 13.4)
    (check "a place she named through the other scope stands at the home"
           (list (length (places-of b)) (> (length (places-of a)) 0)) '(0 #t))
    (check "and so does her position"
           (list (and (pos-row b) #t) (and (pos-row a) #t)) '(#f #t))
    (check "a person nowhere yet has no home" ($ svc 'home-of "bob") #f)))

;; ── moving ───────────────────────────────────────────────────────────────────
(display "\n── a person moves: what they wrote goes with them, once ──\n")
(with-vat vat
  (let* ((svc (spawn ^planner-service (hashmap)))
         (a (spawn-scope-root "Granary")) (b (spawn-scope-root "Table")))
    ($ svc 'add-scope! "Granary" a)
    ($ svc 'add-scope! "Table" b)
    (define (rows root prefix)
      (filter (lambda (i) (string-prefix? prefix (intent-id i))) ($ ($ root 'plan-store) 'all-intents)))
    (define (means-at root)
      (filter (lambda (r) (string-prefix? "means:bob:" (economic-resource-id r)))
              ($ ($ root 'observer) 'inventory)))
    (define (held-at root) (length (filter (lambda (r) (> (measure-has-numerical-value (economic-resource-onhand-quantity r)) 0))
                                           (means-at root))))
    ($ svc 'declare-need "Granary" "bob" "spec-bread" 4 "loaf" "loc-pantry" "" "" "🍞" #f #f "bread")
    ($ svc 'declare-means "Granary" "bob" "spec-bike-repair" 3 %effort-unit "loc-yard" "" "I fix bikes" "🚲" "bike repair")
    ($ svc 'set-profile "Granary" "bob" "[]")         ; stating who you are is becoming a person here
    ($ svc 'declare-skill "Granary" "bob" "baking")
    ($ svc 'set-availability "Granary" "bob"
       (make-availability-window #f #f #f (list (make-time-range "09:00" "17:00"))))
    (check "bob is at home in Granary" ($ svc 'home-of "bob") "Granary")
    (check "his labour stands in Granary's pool"
           (> ($ svc 'labour-total-hours) 0) #t)
    (define hours-before ($ svc 'labour-total-hours))

    (define r ($ svc 'move-home "bob" "Table"))
    (check "the move answers ok" (car r) 'ok)
    (check "his home is Table" ($ svc 'home-of "bob") "Table")
    (check "Granary holds no need of his" (length (rows a "need:bob:")) 0)
    (check "Table holds it once" (length (rows b "need:bob:")) 1)
    (check "Granary's means of his are lowered away" (held-at a) 0)
    (check "Table holds them" (held-at b) 1)
    (check "his skills are held at Table, and not at Granary"
           (list (and (member "baking" (assq-ref (cdr ($ svc 'my-skills "Table" "bob")) 'skills)) #t)
                 (skill-specs-for-agent ($ a 'observer) "bob" (scope-labour? a)))
           '(#t ()))
    (check "his agent record is at Table only"
           (list (and ($ ($ b 'agent-store) 'get-agent "bob") #t)
                 (and ($ ($ a 'agent-store) 'get-agent "bob") #t))
           '(#t #f))
    (check "his hours are counted once, at Table" ($ svc 'labour-total-hours) hours-before)
    (check "the UC reads his need once" (apply + (map cdr ($ svc 'demand-total '(0)))) 4)
    (check "asking again carries nothing" (assq-ref (cdr ($ svc 'move-home "bob" "Table")) 'carried) 0)

    (display "\n── a person declared in two scopes before there was a home is gathered ──\n")
    ;; written straight into two stores, as the dialed-scope doors used to
    (for-each (lambda (root)
                ($ ($ root 'plan-store) 'add-intent
                   (make-intent #:id "need:cleo:spec-soap" #:action 'consume #:name "soap" #:resource-conforms-to "spec-soap"
                                #:resource-quantity (make-measure 2 "bar") #:receiver "cleo" #:in-scope-of '())))
              (list a b))
    (define total-before (apply + (map cdr ($ svc 'demand-total '(0)))))
    ($ svc 'move-home "cleo" "Table")
    (check "gathered, the fold reads her need once: the total falls by exactly the copy she held twice"
           (- total-before (apply + (map cdr ($ svc 'demand-total '(0))))) 2)
    (check "and the total is bob's need and hers, each once"
           (apply + (map cdr ($ svc 'demand-total '(0)))) 6)
    (check "gathered at Table: one need of hers" (length (rows b "need:cleo:")) 1)
    (check "and none at Granary" (length (rows a "need:cleo:")) 0)))

;; ── the rest of the person-doors reach the home; the home is found by rule ──
(display "\n── every door that states a person's standing reaches the home ──\n")
(with-vat vat
  (call-with-values fresh-world
    (lambda (svc a b)
      (define (needs-at root) (filter (lambda (i) (string-prefix? "need:fay:" (intent-id i))) ($ ($ root 'plan-store) 'all-intents)))
      (define (means-held root)
        (filter (lambda (r) (and (string-prefix? "means:fay:" (economic-resource-id r))
                                 (> (measure-has-numerical-value (economic-resource-onhand-quantity r)) 0)))
                ($ ($ root 'observer) 'inventory)))
      ($ svc 'set-profile "Granary" "fay" "[]")
      ($ svc 'declare-need "Granary" "fay" "spec-bread" 3 "loaf" "loc-pantry" "" "" "🍞" #f #f "bread")
      ($ svc 'declare-means "Granary" "fay" "spec-bike-repair" 2 %effort-unit "loc-yard" "" "I fix bikes" "🚲" "bike repair")
      ($ svc 'declare-skill "Granary" "fay" "baking")
      (check "her home is the scope she first wrote through" ($ svc 'home-of "fay") "Granary")
      (check "her need, read through the parent scope that sees it, is hers wherever the asker says home is"
             (map (lambda (n) (> (assq-ref n 'mine) 0))
                  (assq-ref (cdr (plain-reply ($ svc 'our-slots "Granary" "Table" "fay"))) 'needs))
             '(#t))
      ($ svc 'retire-means "Table" "fay" "spec-bike-repair")
      (check "retiring a means through the other scope lowers it at the home" (length (means-held a)) 0)
      ($ svc 'revoke-skill "Table" "fay" "baking")
      (check "revoking a skill through the other scope reaches the home"
             (and (member "baking" (skill-specs-for-agent ($ a 'observer) "fay" (scope-labour? a))) #t) #f)
      ($ svc 'set-home "Table" "fay" "" 42.7 23.3)
      (check "a home place stated through the other scope is made at the home"
             (list (and ($ ($ a 'spatial-thing-store) 'get-location "place:fay:home") #t)
                   (and ($ ($ b 'spatial-thing-store) 'get-location "place:fay:home") #t))
             '(#t #f))
      ($ svc 'set-availability-ranges "Table" "fay" "[{\"start\":\"09:00\",\"end\":\"12:00\"}]")
      (check "an offer of time through the other scope makes the agent at the home, and only there"
             (list (and ($ ($ a 'agent-store) 'get-agent "fay") #t) (and ($ ($ b 'agent-store) 'get-agent "fay") #t))
             '(#t #f))
      ($ svc 'retire-need "Table" "fay" "spec-bread")
      (check "retiring a need through the other scope retires it at the home" (length (needs-at a)) 0))))

(display "\n── a row at two scopes: the smallest scope id is the home ──\n")
(with-vat vat
  (call-with-values fresh-world
    (lambda (svc a b)
      (for-each (lambda (root) ($ ($ root 'plan-store) 'set-meta "home:eve" '((home . #t)))) (list b a))
      (check "two scopes state her home: the same pick whichever order they were written" ($ svc 'home-of "eve") "Granary"))))

(display "\n── a move interrupted is finished by asking again ──\n")
(with-vat vat
  (call-with-values fresh-world
    (lambda (svc a b)
      ($ svc 'declare-need "Granary" "gus" "spec-bread" 3 "loaf" "loc-pantry" "" "" "🍞" #f #f "bread")
      ;; the copy reached Table and the withdrawal did not
      (for-each (lambda (i) ($ ($ b 'plan-store) 'add-intent i))
                (filter (lambda (i) (string-prefix? "need:gus:" (intent-id i))) ($ ($ a 'plan-store) 'all-intents)))
      (define (at root) (length (filter (lambda (i) (string-prefix? "need:gus:" (intent-id i))) ($ ($ root 'plan-store) 'all-intents))))
      (check "both scopes hold it" (list (at a) (at b)) '(1 1))
      ($ svc 'move-home "gus" "Table")
      (check "asked again, the move finishes: at Table once, at Granary not at all" (list (at a) (at b)) '(0 1))
      (check "and the fold reads it once" (apply + (map cdr ($ svc 'demand-total '(0)))) 3))))

(display "\n── a resource in two communes' stores is refused ──\n")
(with-vat vat
  (call-with-values fresh-world
    (lambda (svc a b)
      (let ((r (car ($ ($ a 'observer) 'all-resources))))
        ($ ($ b 'observer) 'seed-resource r)
        (let ((res (plan svc)))
          (check "the same resource held by both: refused, naming it"
                 (list (car res) (and (string-contains (message-of res) (string-append "resource " (economic-resource-id r))) #t))
                 '(error #t)))))))

;; ── a relationship between two people follows whichever of them moves ──
(display "\n── relationships travel with the person ──\n")
(with-vat vat
  (call-with-values fresh-world
    (lambda (svc a b)
      (define (rels root) (map agent-relationship-id ($ ($ root 'agent-store) 'all-relationships)))
      ($ svc 'set-profile "Granary" "bob" "[]")
      ($ svc 'set-profile "Granary" "cleo" "[]")
      ($ svc 'set-profile "Granary" "dan" "[]")
      ($ ($ a 'agent-store) 'add-relationship (make-agent-relationship #:id "rel-knows"
                                                                       #:subject "bob"
                                                                       #:object "cleo"
                                                                       #:relationship "knows"))
      ($ ($ a 'agent-store) 'add-relationship (make-agent-relationship #:id "rel-employs"
                                                                       #:subject "dan"
                                                                       #:object "bob"
                                                                       #:relationship "employs"))
      ($ ($ a 'agent-store) 'add-relationship (make-agent-relationship #:id "rel-other"
                                                                       #:subject "cleo"
                                                                       #:object "dan"
                                                                       #:relationship "knows"))
      (check "the Granary holds all three" (sort (rels a) string<?) '("rel-employs" "rel-knows" "rel-other"))
      (let ((r ($ svc 'move-home "bob" "Table")))
        (check "the move answers ok" (car r) 'ok)
        (check "bob's two relationships stand at the Table, the third stays with the people who stayed"
               (list (sort (rels b) string<?) (rels a)) '(("rel-employs" "rel-knows") ("rel-other"))))
      (check "asking again carries nothing and adds nothing"
             (list (assq-ref (cdr ($ svc 'move-home "bob" "Table")) 'carried) (sort (rels b) string<?))
             '(0 ("rel-employs" "rel-knows"))))))

;; ── where a person is, the places they named and their dwelling go with them ──
(display "\n── a person's position, home place and dwelling move with them ──\n")
(with-vat vat
  (call-with-values fresh-world
   (lambda (svc a b)
    (define (place-at root id) ($ ($ root 'spatial-thing-store) 'get-location id))
    (define (position-at root period)
      (let ((m ($ ($ root 'plan-store) 'get-meta (string-append "pos|eli|" (number->string period)))))
        (and m (assq-ref m 'place))))
    (define (dwelling-held root)
      (let ((r ($ ($ root 'observer) 'get-resource "dwelling:eli")))
        (and r (> (measure-has-numerical-value (economic-resource-onhand-quantity r)) 0))))
    (define known (spatial-thing-id (car ($ ($ a 'spatial-thing-store) 'all-locations))))
    ($ svc 'set-profile "Granary" "eli" "[]")
    ($ svc 'set-home "Granary" "eli" "" 42.70 23.32)
    ($ svc 'set-position-latlon "Granary" "eli" 0 52.5 13.4)
    ($ svc 'set-position "Granary" "eli" 1 known)
    ($ svc 'declare-dwelling "Granary" "eli" "" 40 2 18 24 2 "[]" #f 0 "own")
    (check "at Granary: her home, her fix, her expected place and her dwelling"
           (list (and (place-at a "place:eli:home") #t) (and (place-at a "place:eli:here") #t)
                 (and (position-at a 0) #t) (position-at a 1) (dwelling-held a))
           (list #t #t #t known #t))
    (define r ($ svc 'move-home "eli" "Table"))
    (check "the move answers ok" (car r) 'ok)
    (check "at Table: the same"
           (list (and (place-at b "place:eli:home") #t) (and (place-at b "place:eli:here") #t)
                 (and (position-at b 0) #t) (position-at b 1) (dwelling-held b))
           (list #t #t #t known #t))
    (check "at Granary: none of it stands"
           (list (place-at a "place:eli:home") (place-at a "place:eli:here")
                 (position-at a 0) (position-at a 1) (dwelling-held a))
           (list #f #f #f #f #f))
    (check "her registered home is the place she carried"
           (agent-primary-location ($ ($ b 'agent-store) 'get-agent "eli")) "place:eli:home")
    (check "asking again carries nothing"
           (assq-ref (cdr ($ svc 'move-home "eli" "Table")) 'carried) 0))))

;; ── a person whose first act was offering time holds the generic labour skill ──
(display "\n── a person born by offering time carries their generic skill with them ──\n")
(with-vat vat
  (let* ((svc (spawn ^planner-service (hashmap)))
         (a (spawn-scope-root "Granary")) (b (spawn-scope-root "Table")))
    ($ svc 'add-scope! "Granary" a)
    ($ svc 'add-scope! "Table" b)
    ($ svc 'set-availability-ranges "Granary" "dana" "[{\"start\":\"09:00\",\"end\":\"17:00\"}]")
    (check "dana holds the generic labour skill at Granary"
           (skill-specs-for-agent ($ a 'observer) "dana" (scope-labour? a)) '("spec-labor"))
    (define r ($ svc 'move-home "dana" "Table"))
    (check "the skill is carried" (assq-ref (cdr r) 'carried) 2)       ; the record and the skill
    (check "Granary no longer lists her as holding any skill"
           (skill-specs-for-agent ($ a 'observer) "dana" (scope-labour? a)) '())
    (check "Table holds it" (skill-specs-for-agent ($ b 'observer) "dana" (scope-labour? b)) '("spec-labor"))
    (check "asking again carries nothing"
           (assq-ref (cdr ($ svc 'move-home "dana" "Table")) 'carried) 0)))

;; ── a parent holds its children's cells once ─────────────────────────────────
;; A scope's solve answers for the demand of its whole subtree, so its cached
;; rows also name its members' places; the slack cells it climbs with are its
;; own places'.
(display "\n── a scope's own slack is its own places' ──\n")
(define slack-svc #f)
(with-vat vat
  (let* ((svc (spawn ^planner-service (hashmap)))
         (a (spawn-scope-root "Granary")) (b (spawn-scope-root "Table")))
    ;; both hold flour: each is solved alone below, and a draw with nothing to
    ;; draw on is the raw lint's to refuse
    (seed-fed-commune! a "fed" "commune-granary" "Granary" "venue-granary" 42.70 23.32 300.0)
    (seed-fed-commune! b "fed" "commune-table" "Table" "venue-table" 42.75 23.40 100.0)
    ($ svc 'add-scope! "Granary" a)
    ($ svc 'add-scope! "Table" b)
    ($ svc 'move-scope! "Table" "Granary")
    ($ svc 'plan "Table" (list (list "bread" "venue-table" 0 40.0)))
    ($ svc 'plan "Granary" (list (list "bread" "venue-granary" 0 5.0) (list "bread" "venue-table" 0 40.0)))
    (set! slack-svc svc)))
(with-vat vat
  (check "the parent's own cells name its own venue only"
         (delete-duplicates (map cdar ($ ($ slack-svc 'slack "Granary") 'fold-own))) '("venue-granary"))
  (check "the child's name its own"
         (delete-duplicates (map cdar ($ ($ slack-svc 'slack "Table") 'fold-own))) '("venue-table"))
  (check "and the federation reads both, once each"
         (sort (map car ($ slack-svc 'slack-read 'slacks)) string<?) '("venue-granary" "venue-table")))

(test-summary!)
