;;; test-steward-gate.scm — the steward gate, end to end.
;;;
;;; Alice lends her oven into the Hearth under a rule naming who may cook on
;;; it. The solve keeps the oven anonymous capacity; every door that chooses a
;;; PERSON asks the gate — the UC matching's candidate filter, the directed
;;; offer, the accept door — through the one predicate make-may-steward
;;; builds off the grant's `eligible` claim and Alice's contact book. Recall
;;; the grant and the gate is moot: no rule stands, anyone may.
;;;
;;; Run:  guile --no-auto-compile -L module -L tests tests/planner/test-steward-gate.scm

(setenv "PLAYNET_DATA_DIR"
        (string-append (or (getenv "TMPDIR") "/tmp") "/pn-steward-gate-test"))

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness)
             (playnet planner scope root) (playnet planner vf schemas) (playnet planner beyond schedules) (srfi srfi-1)
             (playnet planner doors service)
             (playnet planner doors offers)
             (playnet planner federation plan-bundle)
             (playnet planner facts availability)
             (playnet governance socialization) (playnet keri acdc) (playnet keri acdc-store) (playnet keri first-person credentials)
             ((playnet governance socialization) #:select (lent-to))
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))
(use-modules ((playnet wire rows) #:select (plain-reply)))   ; a door's rows, read back as alists

(define ALICE  "aid:alice")
(define TIA    "aid:tia")            ; Alice's friend
(define SAM    "aid:sam")            ; nobody to Alice
(define HEARTH "Hearth")             ; the scope id IS the commune AID the grant names
(define FUTURE "2099-12-31T00:00:00Z")

(define ONLY-TIA  "{\"filter-rule\":[\"aid\",\"aid:tia\"]}")
(define ONLY-SAM  "{\"filter-rule\":[\"aid\",\"aid:sam\"]}")
(define FRIENDS   "{\"filter-rule\":[\"in-group\",\"friends\"]}")
(define VOUCHED   "{\"filter-rule\":[\"vouched\"]}")

(define (window from to)
  (make-availability-window #f #f #f (list (make-time-range from to))))

;; a work intent on process PROC — input-of carries the process, as every
;; work-intent the solve or an offer lays does
(define (cook-intent id proc)
  (make-intent #:id id #:action 'work #:input-of proc #:resource-conforms-to "spec-cook"
               #:effort-quantity (make-measure 4.0 %effort-unit) #:planned-within "plan-1"))

;; Alice's contact book, as the lobby syncs it: Tia is a friend
(define (contacts-of aid)
  (if (equal? aid ALICE) `(((aid . ,TIA) (rel . "friends") (alias . "Tia"))) '()))

;; one fresh world: the Hearth with two cooks on the roster, a `cook` process
;; that USES an oven, and Alice's oven lent under ELIGIBLE. Returns
;; (values svc root store grant may-steward).
(define (world eligible)
  (let* ((root  (spawn-scope-root HEARTH))
         (store (spawn-acdc-store))
         (may   (make-may-steward store #:contacts-of contacts-of))
         ;; the injection: plan-fn, earth, debts×3, standing, then the gate
         (svc   (spawn ^planner-service (hashmap) plain-plan-fn #f
                       (cons (cons 'steward may) (socialized-readers store))))
         (rs    ($ root 'recipe-store))
         (as    ($ root 'agent-store)))
    ($ rs 'add-recipe-process (make-recipe-process #:id "cook" #:name "Cook"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "cook-oven" #:action 'use #:resource-conforms-to "oven" #:resource-quantity (make-measure 1.0 %count-unit)
                         #:effort-quantity (make-measure 4.0 %effort-unit) #:recipe-input-of "cook"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "cook-work" #:action 'work #:resource-conforms-to "spec-cook"
                         #:effort-quantity (make-measure 4.0 %effort-unit) #:recipe-input-of "cook"))
    ($ as 'add-agent (make-agent #:id TIA #:type 'person #:name "Tia" #:note "" #:image ""
                                 #:classified-as '() #:availability-window (window "09:00" "17:00")))
    ($ as 'add-agent (make-agent #:id SAM #:type 'person #:name "Sam" #:note "" #:image ""
                                 #:classified-as '() #:availability-window (window "09:00" "17:00")))
    ($ svc 'add-scope! HEARTH root)
    ($ svc 'declare-skill HEARTH TIA "spec-cook")
    ($ svc 'declare-skill HEARTH SAM "spec-cook")
    (let ((grant (socialize-private-resource store ALICE HEARTH "oven" 1
                                             #:until FUTURE #:eligible eligible)))
      (values svc root store grant may))))

;; who the UC matching lands the cooking on, under ELIGIBLE
(define (matched-provider eligible)
  (call-with-values (lambda () (world eligible))
    (lambda (svc root store grant may)
      (let ((ps ($ root 'plan-store)))
        ($ ps 'add-intent (cook-intent "wi1" "cook"))
        ($ ps 'add-proposal (make-rising-proposal "prop-1" "plan-1" HEARTH '("wi1")))
        (let ((r ($ svc 'match-labour!)))
          (and (eq? (car r) 'ok)
               (let ((landed (filter (lambda (c) (equal? (commitment-planned-within c) "plan-1"))
                                     ($ ps 'all-commitments))))
                 (and (= 1 (length landed))
                      (commitment-provider (car landed))))))))))

(define vat (spawn-vat))
(define (roster-root svc sid) ($ svc 'scope-root-ref sid))

(with-vat vat
  (display "\n── the predicate: the grant's rule, over Alice's book ──\n")
  (call-with-values (lambda () (world ONLY-TIA))
    (lambda (svc root store grant may)
      (check "the named friend may cook on the oven"   (may HEARTH TIA "oven") #t)
      (check "a stranger may not"                       (may HEARTH SAM "oven") #f)
      (check "a spec nobody lent under a rule is anyone's" (may HEARTH SAM "sink") #t)
      (display "\n── recall: no rule stands, the oven is anyone's again ──\n")
      (desocialize-private-resource! store ALICE (cred-said grant))
      (check "after recall the stranger passes — nothing binds" (may HEARTH SAM "oven") #t)))

  (call-with-values (lambda () (world FRIENDS))
    (lambda (svc root store grant may)
      (check "in-group reads the rel Alice gave Tia"   (may HEARTH TIA "oven") #t)
      (check "…and Sam holds no rel in her book"        (may HEARTH SAM "oven") #f)
      (display "\n── the signed half: a relationship credential is a group too ──\n")
      ;; Alice vouches Sam as a friend — a VRC in the store, no book entry
      (let ((vrc (make-relationship-credential ALICE SAM 'friends "EphcAlice"
                                               "2026-08-30T00:00:00Z")))
        ($ store 'issue vrc)
        (check "a live VRC admits him under in-group" (may HEARTH SAM "oven") #t)
        (check "the gate reads the rel off the credential, by the kind's one name"
               (vrc-groups-of store ALICE SAM) '("friend"))
        ($ store 'revoke (cred-said vrc))
        (check "revoking it closes the gate again" (may HEARTH SAM "oven") #f))))

  (display "\n── vouched: the signed vouch alone, whatever its kind ──\n")
  (call-with-values (lambda () (world VOUCHED))
    (lambda (svc root store grant may)
      (check "a book tag is no vouch: Tia waits"  (may HEARTH TIA "oven") #f)
      (let ((vrc (make-relationship-credential ALICE TIA 'colleague "EphcAlice"
                                               "2026-08-30T00:00:00Z")))
        ($ store 'issue vrc)
        (check "Alice's signed vouch admits her"  (may HEARTH TIA "oven") #t)
        (check "…and admits nobody else"          (may HEARTH SAM "oven") #f)
        ($ store 'revoke (cred-said vrc))
        (check "withdrawn, the gate closes"       (may HEARTH TIA "oven") #f))))

  (display "\n── the slot matcher asks the same reading: a group on a need's own rule ──\n")
  (let* ((root  (spawn-scope-root "Ring"))
         (store (spawn-acdc-store))
         (svc   (spawn ^planner-service (hashmap) plain-plan-fn #f
                       (list (cons 'knows (make-knows store #:contacts-of contacts-of)))))
         (hits  (lambda ()
                  (let* ((v (cdr (plain-reply ($ svc 'match-slots "ring" '()))))
                         (row (find (lambda (m) (equal? (assq-ref m 'need) (string-append "need:" ALICE ":spec-bread")))
                                    (assq-ref v 'matches))))
                    (map (lambda (h) (assq-ref h 'id)) (or (and row (assq-ref row 'hits)) '()))))))
    ($ svc 'add-scope! "ring" root)
    ($ svc 'declare-means "ring" TIA "spec-bread" 4 "loaf" "" "" "" "🍞" "bread")
    ($ svc 'declare-means "ring" SAM "spec-bread" 4 "loaf" "" "" "" "🍞" "bread")
    ($ svc 'declare-need "ring" ALICE "spec-bread" 2 "loaf" "" "" "" "🍞" #f #f "bread" "" FRIENDS)
    (check "her friends' bread meets a need locked to friends"
           (and (member (string-append "means:" TIA ":spec-bread") (hits)) #t) #t)
    (check "…a stranger's does not" (member (string-append "means:" SAM ":spec-bread") (hits)) #f)
    ($ svc 'declare-need "ring" ALICE "spec-bread" 2 "loaf" "" "" "" "🍞" #f #f "bread" "" VOUCHED)
    (check "locked to the vouched, a tagged friend waits" (hits) '())
    ($ store 'issue (make-relationship-credential ALICE SAM 'friends "EphcAlice" "2026-08-30T00:00:00Z"))
    (check "…and her signed vouch for Sam opens it to him"
           (hits) (list (string-append "means:" SAM ":spec-bread"))))

  (display "\n── door B: the UC matching lands only where the rule admits ──\n")
  (check "the rule for Tia lands the cooking on Tia" (matched-provider ONLY-TIA) TIA)
  (check "the rule for Sam lands it on Sam — the gate steers, not the roster order"
         (matched-provider ONLY-SAM) SAM)

  (display "\n── door C: the directed offer refuses, typed ──\n")
  (call-with-values (lambda () (world ONLY-TIA))
    (lambda (svc root store grant may)
      (let* ((row '((input-of . "cook") (effort . 4.0) (conforms-to . "spec-cook")
                    (when . #f) (until . #f) (at-location . #f)))
             (admit (lambda (agent proc) (may HEARTH agent "oven")))
             (refusal (catch 'offer-refused
                        (lambda () (offer-work root row SAM #:admit? admit) #f)
                        (lambda (_ kind . rest) kind))))
        (check "Sam's offer is refused as may-not-steward" refusal 'may-not-steward)
        (check "Tia's offer stands" (string? (offer-work root row TIA #:admit? admit)) #t))))

  (display "\n── door A: the accept door, where every path ends ──\n")
  (call-with-values (lambda () (world ONLY-TIA))
    (lambda (svc root store grant may)
      (let ((ps ($ root 'plan-store)))
        ($ ps 'add-intent (cook-intent "wi-sam" "cook"))
        ($ ps 'add-intent (cook-intent "wi-tia" "cook"))
        (check "Sam cannot accept work drawing on Alice's oven"
               (car ($ svc 'accept-assignment HEARTH "wi-sam" SAM)) 'error)
        (check "Tia can"
               (car ($ svc 'accept-assignment HEARTH "wi-tia" TIA)) 'ok)))))

(display "\n── a visitor's skills are read at their home ──\n")
;; the oven is lent to whoever can weld; Vic's welding is declared at Home, and
;; the Hearth holds no record of them
(define VIC "aid:vic")
(define CAN-WELD "{\"filter-rule\":[\"has-skill\",\"spec-weld\"]}")
(with-vat vat
  (call-with-values (lambda () (world CAN-WELD))
    (lambda (svc root store grant may)
      ($ svc 'add-scope! "Home" (spawn-scope-root "Home"))
      ($ svc 'declare-skill "Home" VIC "spec-weld")
      (check "Vic's home is Home" ($ svc 'home-of VIC) "Home")
      (let ((ps ($ root 'plan-store)))
        ($ ps 'add-intent (cook-intent "wi-vic" "cook"))
        ($ ps 'add-intent (cook-intent "wi-sam2" "cook"))
        (check "the Hearth has no skills of Vic's, and the gate reads them where they are: admitted"
               (car ($ svc 'accept-assignment HEARTH "wi-vic" VIC)) 'ok)
        (check "someone with the skill nowhere is still refused"
               (car ($ svc 'accept-assignment HEARTH "wi-sam2" SAM)) 'error)))))

(display "\n── a lent means is not stranded by a move ──\n")
;; Alice lent her oven to the Hearth under a grant that names the Hearth. A move
;; carries what is hers to carry; the oven's grant names the Hearth and only the
;; Hearth's resource view projects it, so the oven stays and the move says so.
(with-vat vat
  (call-with-values (lambda () (world ONLY-TIA))
    (lambda (svc root store grant may)
      ($ svc 'add-scope! "Home" (spawn-scope-root "Home"))
      ($ svc 'declare-means HEARTH ALICE "oven" 1 %count-unit "" "" "" "🔥" "oven")
      ($ svc 'declare-means HEARTH ALICE "bike" 1 %count-unit "" "" "" "🚲" "bike")
      (check "the governance reader names what the Hearth is lent"
             (map (lambda (g) (assq-ref g 'owner)) (lent-to store HEARTH)) (list ALICE))
      (let ((r ($ svc 'move-home ALICE "Home")))
        (check "the move answers ok" (car r) 'ok)
        (check "the lent oven is kept and reported"
               (assq-ref (cdr r) 'kept) (list (string-append "means:" ALICE ":oven")))
        (check "the unlent bike went home with her"
               (map economic-resource-id
                    (filter (lambda (x) (and (string-prefix? "means:" (economic-resource-id x))
                                             (> (measure-has-numerical-value (economic-resource-onhand-quantity x)) 0)))
                            ($ ($ (roster-root svc "Home") 'observer) 'inventory)))
               (list (string-append "means:" ALICE ":bike"))))
      (check "asking again keeps the oven and carries nothing"
             (let ((r ($ svc 'move-home ALICE "Home")))
               (list (assq-ref (cdr r) 'carried) (assq-ref (cdr r) 'kept)))
             (list 0 (list (string-append "means:" ALICE ":oven")))))))

(test-summary!)
