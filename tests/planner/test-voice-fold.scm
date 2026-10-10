;;; test-voice-fold.scm — ^voice-pool: the scope fold of producer voice.
;;;
;;; pools/voice-fold.scm is `^fold-node` with voice's three pieces; its
;;; OWN is the pure function scope-own-voice over the observer's events and the
;;; rail's hands. What this suite pins:
;;;   • node = fold: the node's pushes and hours are the pure function's;
;;;   • anonymity: no cell above the scope names a person;
;;;   • theorem 10 scope_key_is_voice_share: a stance on the scope's own part
;;;     weighs as producer voice does today — two workers, shares a and b,
;;;     opposite full stances ⇒ push a − b;
;;;   • theorem 8 no_carried_hours: a hand on a part one never worked moves
;;;     nothing; a person with no hours at all moves nothing;
;;;   • the planner service's door: hands! parses rows, refolds, and the
;;;     solve's standing keywords carry the pushes only when τ > 0;
;;;   • two scopes under the UC: the parent's total is the anonymous sum.
;;;
;;; Run:  guile -q -L module tests/planner/test-voice-fold.scm

(use-modules (playnet test harness) (playnet pools credit-fold) (playnet scope root) (srfi srfi-1) (playnet doors service)
             (playnet vf facts parts) (playnet solve voice-field)
             (playnet pools voice-fold)
             ((playnet pools credit-fold) #:select (voice-share))
             ((playnet test scope) #:select (record-work! push-on))
             ((playnet knowledge dsl shorthand) #:select (rp*))
             (goblins) (goblins utils hashmap) (srfi srfi-1))

(define (approx= a b) (< (abs (- a b)) 1e-9))
(define* (work! obs aid hours eid iid #:key (process "bake") (place "town") (skill "baker") (scope "bakery"))
  (record-work! obs aid hours eid iid #:process process #:place place #:skill skill #:scope scope))

(define P-SCOPE (make-part))
(define P-BAKE  (make-part #:process "bake"))
(define P-MILL  (make-part #:process "mill"))
(define P-TOWN  (make-part #:place "town"))

(define vat (spawn-vat))
(with-vat vat
  (let* ((root (spawn-scope-root "bakery")) (obs ($ root 'observer)))
    ;; ada 10h baking, bob 30h baking, cy 20h milling at the farm
    (work! obs "ada" 10 "e1" "i1")
    (work! obs "bob" 30 "e2" "i2")
    (work! obs "cy"  20 "e3" "i3" #:process "mill" #:place "farm" #:skill "miller")

    (display "\n── node = fold ──\n")
    (let* ((hands (lambda (r) `(("ada" ,P-SCOPE 1.0) ("bob" ,P-SCOPE -1.0) ("cy" ,P-BAKE -1.0) ("cy" ,P-MILL 0.5))))
           (own (scope-own-voice root hands))
           (node (spawn ^voice-pool '() '() "bakery")))
      (wire-voice-node! root node #:scope-id "bakery" #:hands-of hands)
      (check "the node's total is the pure fold's own" (equal? ($ node 'cells) own))
      (check "pushes agree" (equal? ($ node 'pushes) (voice-pushes own)))
      (check "hours agree, and the total's reader ignores an owner (anonymous)"
             (and (approx= ($ node 'hours P-BAKE) ((voice-hours-of own) P-BAKE))
                  (approx= ((voice-hours-of own) P-BAKE "ada") ((voice-hours-of own) P-BAKE))))
      (check "no cell names a person"
             (every (lambda (c) (not (member (if (string? (cdar c)) (cdar c) "") '("ada" "bob" "cy")))) own))
      (check "h cells carry the event's terms, not its provider"
             (every (lambda (c) (or (not (eq? (caar c) 'h)) (not (assq 'provider (cdar c))))) own))
      (let ((pushes ($ node 'pushes)))
        (check "theorem 10: on the scope's own part, push = ada's share − bob's share = (10 − 30)/60"
               (approx= (push-on pushes P-SCOPE) (- (voice-share "ada" (list root)) (voice-share "bob" (list root)))))
        (check "theorem 8: cy never baked — cy's dislike of baking moves nothing" (approx= (push-on pushes P-BAKE) 0.0))
        (check "cy alone mills: half a hand, whole share" (approx= (push-on pushes P-MILL) 0.5))
        (check "hours of a part are the covered cells' validated hours" (approx= ($ node 'hours P-TOWN) 40.0))))

    (display "\n── the hand held hour by hour, in the fold ──\n")
    (let* ((hands (lambda (r) `(("ada" ,P-SCOPE 1.0) ("ada" ,P-BAKE 1.0) ("ada" ,P-TOWN 1.0))))
           (own (scope-own-voice root hands)))
      (check "three full stances on ada's one cell fold to one hand: a third each, times her share"
             (and (approx= (push-on (voice-pushes own) P-BAKE) (* (/ 1.0 3) (/ 10.0 40.0)))
                  (approx= (push-on (voice-pushes own) P-TOWN) (* (/ 1.0 3) (/ 10.0 40.0)))
                  (approx= (push-on (voice-pushes own) P-SCOPE) (* (/ 1.0 3) (/ 10.0 60.0))))))

    (display "\n── nobody's hours move nothing ──\n")
    (let ((own (scope-own-voice root (lambda (r) `(("dee" ,P-SCOPE 1.0))))))
      (check "a person with no validated hours pushes nothing" (null? (voice-pushes own))))))

(display "\n── the service door ──\n")
(with-vat vat
  (let* ((a (spawn-scope-root "A")) (b (spawn-scope-root "B"))
         ;; the rail: the only store of a hand; hands! rereads it
         (rail-rows '())
         (rail (lambda (sid) (if (equal? sid "A") rail-rows '())))
         (svc (spawn ^planner-service (hashmap) plain-plan-fn #f (list (cons 'hands rail))))
         (cast! (lambda (rows) (set! rail-rows rows) ($ svc 'hands! "A")))
         (oa ($ a 'observer)) (ob ($ b 'observer)))
    (work! oa "ada" 10 "ea" "ia" #:scope "A")
    (work! ob "bob" 30 "eb" "ib" #:scope "B" #:process "mill" #:place "farm")
    ($ svc 'add-scope! "A" a)
    ($ svc 'add-scope! "B" b)
    (check "hands! rereads the rail, parses its rows and refolds"
           (equal? '(ok . 1) (let ((r (cast! '(("ada" "process=bake" -1.0))))) (if (pair? r) (cons (car r) (cdr r)) r))))
    (check "the scope's node pushes ada's full dislike of baking"
           (approx= (push-on ($ ($ svc 'voice "A") 'pushes) P-BAKE) -1.0))
    (check "the UC total is the anonymous sum: bake hours from A, mill hours from B"
           (and (approx= ($ ($ svc 'voice-uc) 'hours P-BAKE) 10.0)
                (approx= ($ ($ svc 'voice-uc) 'hours P-MILL) 30.0)))
    (check "a hand on a part this scope never worked is refused nowhere and bends nothing"
           (and (pair? (cast! '(("ada" "process=mill" 1.0))))
                (null? ($ ($ svc 'voice "A") 'pushes))))
    (check "an unparsable hand on the rail is a failure, not a crash"
           (let ((r (cast! '(("ada" "colour=red" 1.0))))) (and (pair? r) (not (eq? (car r) 'ok)))))
    (check "a planner with no rail reader holds no hand: the rail is the only store"
           (let ((svc0 (spawn ^planner-service (hashmap))))
             ($ svc0 'add-scope! "A" (spawn-scope-root "A0"))
             (and (equal? '(ok . 0) ($ svc0 'hands! "A")) (null? ($ svc0 'hands "A")))))))

(display "\n── a tag is a kind the fold reads too ──\n")
;; the process's tags (its recipe-process classification in the scope's
;; recipe-store) are a term of the event, as they are of the column, so a
;; stance on the tag weighs by the hours of the acts under it
(with-vat vat
  (let* ((root (spawn-scope-root "T")) (obs ($ root 'observer)))
    ($ ($ root 'recipe-store) 'add-recipe-process (rp* "bake" "Bake" #:tags '("tag:wood-oven-way")))
    ($ ($ root 'recipe-store) 'add-recipe-process (rp* "mill" "Mill"))
    (work! obs "ada" 10 "et1" "it1" #:scope "T")
    (work! obs "bob" 30 "et2" "it2" #:scope "T" #:process "mill" #:place "farm")
    (let* ((P-WAY (make-part #:tag "tag:wood-oven-way"))
           (own (scope-own-voice root (lambda (r) `(("ada" ,P-WAY -1.0) ("bob" ,P-WAY -1.0))))))
      (check "the tagged act's hours are the tag's hours" (approx= ((voice-hours-of own) P-WAY) 10.0))
      (check "ada, who worked the way, pushes her whole dislike of it; bob, who milled, moves nothing"
             (approx= (push-on (voice-pushes own) P-WAY) -1.0)))))

(display "\n── the rail seeds the fold at wiring ──\n")
;; HANDS-OF, the injected reader over the credential store (server/gateway.scm
;; passes governance's plan-part-hands-of): a scope's voice node stands on
;; the rail's hands from its first fold, so a restart reads them as a cast did.
(with-vat vat
  (let* ((a (spawn-scope-root "A"))
         (rail (lambda (sid) (if (equal? sid "A") '(("ada" "process=bake" -1.0)) '())))
         (svc (spawn ^planner-service (hashmap) plain-plan-fn #f (list (cons 'hands rail))))
         (oa ($ a 'observer)))
    (work! oa "ada" 10 "ea" "ia" #:scope "A")
    ($ svc 'add-scope! "A" a)
    (check "the seeded hand stands as rows" (equal? '(("ada" "process=bake" -1.0)) ($ svc 'hands "A")))
    (check "the node's first fold already carries it" (approx= (push-on ($ ($ svc 'voice "A") 'pushes) P-BAKE) -1.0))))

(test-summary!)
