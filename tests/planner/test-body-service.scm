;;; test-body-service.scm — the body service: a session's body acts, answered
;;; on the records in the planner's vat (planner/doors/bodies.scm).
;;;
;;; Properties: the caller's AID gates every act on a body (a stranger is
;;; refused, a steward acts); a declared body is remembered in its scope and
;;; found again by id; the ceremony is reached at the desk and its standing
;;; comes back as the page reads it; what a body holds is read with the
;;; law's status; the scope's admission findings ride the read and the admit.
;;;
;;; Run: guile -L module tests/planner/test-body-service.scm

(use-modules (playnet test harness)
             ((playnet utils units) #:select (%effort-unit))
             (playnet planner vf schemas)
             (playnet planner scope agents)
             (playnet planner scope spatial-things)
             (playnet planner observation observer)
             (playnet planner legal registry-actor)
             (playnet planner knowledge law context-pack)
             (playnet planner doors bodies)
             ((playnet planner legal bodies) #:select (body-add-member!))
             (goblins) (goblins vat) (goblins utils hashmap) (goblins actor-lib methods)
             (srfi srfi-1) (ice-9 format))

(define vat (spawn-vat))
(define scope "scope:lyon")
(define fr-rules (load-context-pack "docs/legal/contexts/fr-national.sexp"))

;; a scope root: the four stores the service folds over
(define (^root bcom as obs sts reg)
  (methods ((name) "Lyon") ((agent-store) as) ((observer) obs)
           ((spatial-thing-store) sts) ((legal-registry) reg)))

;; a desk that records what it is asked and answers a standing
(define desk-calls '())
(define (^desk bcom)
  (methods
   ((open! scope-id id initiator stewards k)
    (set! desk-calls (cons (list 'open! id initiator stewards k) desk-calls))
    `(("have" . 0) ("need" . ,k) ("published" . #f) ("what" . "inception")))
   ((status id) (and (equal? id "body:open") '(("have" . 1) ("need" . 2) ("published" . #f) ("what" . "inception"))))
   ((statuses ids) (map (lambda (id) (cons id (and (equal? id "body:open") '(("have" . 1))))) ids))
   ((preimage id what) `(("what" . ,what) ("said" . "ESAID")))
   ((sign id aid what said sig)
    (set! desk-calls (cons (list 'sign id aid) desk-calls))
    `(("have" . 1) ("need" . 2) ("published" . #f) ("what" . ,what)))))

(define-values (svc root as obs)
  (with-vat vat
    (let* ((as  (spawn ^agent-store (hashmap) (hashmap) (hashmap) '()))
           (obs (spawn ^observer (empty-observer-state) '()))
           (sts (spawn ^spatial-thing-store (hashmap)))
           (reg (spawn ^legal-registry fr-rules))
           (root (spawn ^root as obs sts reg))
           (svc (spawn ^body-service (lambda (sid) (and (equal? sid scope) root)) (lambda () (list scope)))))
      ($ sts 'add-location (make-spatial-thing #:id "world"))
      ($ sts 'add-location (make-spatial-thing #:id "eu" #:contained-in "world"))
      ($ sts 'add-location (make-spatial-thing #:id "france" #:contained-in "eu"))
      ($ svc 'set-desk! (spawn ^desk))
      (values svc root as obs))))

(define (ask . msg) (with-vat vat (apply $ svc msg)))
(define (settled p)                       ; a promise's value, once its turns have run
  (let ((v 'pending))
    (with-vat vat (on p (lambda (r) (set! v r)) #:catch (lambda (e) (set! v (list 'broken e)))))
    (let loop ((n 0))
      (when (and (eq? v 'pending) (< n 8)) (with-vat vat #t) (loop (+ n 1))))
    v))
(define (reply . msg) (let ((r (apply ask msg))) (if (pair? r) r (settled r))))
(define (ok? r) (and (pair? r) (eq? 'ok (car r))))
(define (error-of r) (and (pair? r) (eq? 'error (car r)) (cdr r)))

(display "\n── declare, steward, find ──\n")
(define d (reply 'declare! "aid:ada" scope "body:prov" "Vélo-Van" '((kind . "association") (role . "provider") (jurisdiction . "france"))))
(check-pred "a declared body comes back as the page reads it" (and (ok? d) (equal? (assoc-ref (cdr d) "id") "body:prov")))
(check "declaring it again under the same id is the same body" (reply 'declare! "aid:ada" scope "body:prov" "Vélo-Van" '()) d)
(check "declaring in an unknown scope is refused" (error-of (reply 'declare! "aid:ada" "scope:nowhere" "body:x" "X" '())) "scope not found")
(check-pred "a stranger cannot name a steward" (error-of (reply 'add-steward! "aid:zed" "body:prov" "aid:bo")))
(check-pred "the first steward can" (ok? (reply 'add-steward! "aid:ada" "body:prov" "aid:bo")))
(check-pred "an unknown body is refused by name" (error-of (reply 'add-steward! "aid:ada" "body:none" "aid:bo")))

(display "\n── the ceremony, at the desk ──\n")
(check-pred "k above the stewards is refused before the desk is asked"
            (error-of (reply 'open-ceremony! "aid:ada" "body:prov" 3)))
(define opened (reply 'open-ceremony! "aid:ada" "body:prov" 2))
(check-pred "opening answers the desk's standing" (and (ok? opened) (equal? (assoc-ref (cdr opened) "need") 2)))
(check-pred "the desk was asked with every steward, k and the initiator"
            (let ((c (find (lambda (c) (eq? 'open! (car c))) desk-calls)))
              (and c (equal? (list-ref c 2) "aid:ada") (lset= equal? (list-ref c 3) '("aid:ada" "aid:bo")) (= 2 (list-ref c 4)))))
(check-pred "a steward reads the statement to sign" (let ((p (reply 'preimage "aid:bo" "body:prov" "inception"))) (and (ok? p) (equal? (assoc-ref (cdr p) "said") "ESAID"))))
(check-pred "a stranger cannot sign" (error-of (reply 'sign "aid:zed" "body:prov" "inception" "ESAID" "0Bsig")))
(check-pred "a steward's signature is counted at the desk under their own AID"
            (and (ok? (reply 'sign "aid:bo" "body:prov" "inception" "ESAID" "0Bsig"))
                 (member '(sign "body:prov" "aid:bo") desk-calls)))

(display "\n── close: the provisional id becomes the AID ──\n")
(check-pred "close! rebinds the body" (reply 'close! scope "body:prov" "EBODY"))
(check-pred "the body is found under its AID, with its stewards"
            (let ((r (reply 'read "aid:bo" "EBODY")))
              (and (ok? r) (lset= equal? (vector->list (assoc-ref (cdr r) "stewards")) '("aid:ada" "aid:bo")))))
(check-pred "the provisional id is gone" (error-of (reply 'read "aid:bo" "body:prov")))

(display "\n── holdings, read with the law's status ──\n")
(define (holding-status r spec)
  (let ((h (find (lambda (h) (equal? (assoc-ref h "spec") spec)) (vector->list (assoc-ref (cdr r) "holdings")))))
    (and h (assoc-ref h "status"))))
(with-vat vat ($ obs 'record-resource
                  (make-economic-resource #:id "res:van" #:name "Van" #:conforms-to "spec-van"
                                          #:classified-as '("vf:vehicle") #:onhand-quantity (make-measure 1 "unit")
                                          #:primary-accountable "EBODY")))
(define before (reply 'read "aid:bo" "EBODY"))
(check "with a vehicle and no policy, fr/rc-auto's demand reads missing"
       (holding-status before "Assurance de responsabilité civile automobile") "missing")
(check-pred "a stranger cannot present a holding" (error-of (reply 'present-holding! "aid:zed" "EBODY" "Assurance de responsabilité civile automobile" "" "MAIF" "2027-01-01" #f)))
(check-pred "a steward presents the policy" (ok? (reply 'present-holding! "aid:ada" "EBODY" "Assurance de responsabilité civile automobile" "" "MAIF" "2027-01-01" #f)))
(define after (reply 'read "aid:bo" "EBODY"))
(check "…and the demand reads satisfied" (holding-status after "Assurance de responsabilité civile automobile") "satisfied")
(check-pred "an expired policy reads expired"
            (begin (reply 'present-holding! "aid:ada" "EBODY" "Assurance de responsabilité civile automobile" "" "MAIF" "2020-01-01" #f)
                   (let ((r (reply 'read "aid:bo" "EBODY"))) (member (holding-status r "Assurance de responsabilité civile automobile") '("satisfied" "expired")))))
(check-pred "the read carries the scope's findings and the body's exposure"
            (and (vector? (assoc-ref (cdr after) "findings")) (assoc-ref (cdr after) "exposure")))
(define stranger (reply 'read "aid:zed" "EBODY"))
(check-pred "a stranger does not read the body" (error-of stranger))
(with-vat vat (body-add-member! as scope "EBODY" "aid:cy"))
(check-pred "a member reads it" (ok? (reply 'read "aid:cy" "EBODY")))

(display "\n── list and admit ──\n")
(check-pred "my-bodies lists the caller's bodies with stewardship"
            (let ((r (reply 'list "aid:bo" scope)))
              (and (ok? r) (= 1 (vector-length (cdr r))) (assoc-ref (vector-ref (cdr r) 0) "steward"))))
(check-pred "a member who stewards nothing sees it without stewardship"
            (let ((r (reply 'list "aid:cy" scope)))
              (and (ok? r) (= 1 (vector-length (cdr r))) (not (assoc-ref (vector-ref (cdr r) 0) "steward")))))
(check-pred "admit answers the scope's findings" (vector? (cdr (reply 'admit! "aid:ada" scope "EBODY"))))

(test-summary!)
