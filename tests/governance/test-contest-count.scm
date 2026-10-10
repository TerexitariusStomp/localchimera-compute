;;; test-contest-count.scm — a count is contested the way work is, and its
;;; whole family goes with it.
;;;
;;; A count lands an adjustment on a stock, a record and the counter's hours,
;;; and a count of a container carries a cascade onto its contents. A member
;;; who says the count was not done contests it through the one door work is
;;; contested through (docs/observation/capture.md §8): the ballot is
;;; contest:<adjustment's id>, whichever part is named, the franchise is the
;;; roster less the counter, and at half the voice or more every part of the
;;; count is corrected to nothing, the stock reads what it read before, and the
;;; count stops being the stock's last. Pinned here:
;;;
;;;   • who may contest a count, and that one contest stands for the count;
;;;   • what a member may do about a contest: the counter attaches a picture,
;;;     the franchise reads it, no one else does either;
;;;   • a void settles the adjustment, its record and its hours, the observer
;;;     takes the adjustment's cascade back with it, and the stock and what is
;;;     in it read what they read before; a count that stands is left;
;;;   • the settled hook is told either way, so a held picture can be let go.
;;;
;;; Run from project root:
;;;   tools/own-ccache.sh guile --no-auto-compile -q -L module tests/governance/test-contest-count.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)
(add-to-load-path "module")

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules ((playnet wire rows) #:select (plain-reply)))   ; a door's rows, read back as alists
(use-modules (playnet test harness)
             (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (playnet boot scope) (playnet boot governance) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri said-portable)
             ((playnet observation evidence) #:select (evidence-tag))
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid sign-said))
             (goblins) (goblins utils hashmap) (srfi srfi-1))

(define (preimage-fields pre) (lambda (k) (let ((p (assq k pre))) (and p (cdr p)))))
(define (said-of ar) (compute-said (ar 'issuer) (ar 'holder) (ar 'schema) (ar 'claims) (or (ar 'edges) '())))
(define (cast! svc aid kp pid position)
  (let* ((ar (preimage-fields (cadr ($ svc 'stance-preimage aid pid position))))
         (ts (let ((p (assq 'timestamp (ar 'claims)))) (and p (cdr p))))
         (u  (let ((p (assq 'u (ar 'claims)))) (and p (cdr p)))))
    ($ svc 'cast-signed aid pid position ts (sign-said (said-of ar) kp) u)))

(define pic (string-append "sha256:" (make-string 64 #\c)))
(define (onhand obs rid) (measure-qty (economic-resource-onhand-quantity ($ obs 'get-resource rid))))

(define (seed! obs rid qty in)
  ($ obs 'seed-resource
     (make-economic-resource #:id rid #:name rid #:conforms-to "rice" #:classified-as '()
                             #:accounting-quantity (make-measure qty "kg") #:onhand-quantity (make-measure qty "kg") #:primary-accountable "ada" #:contained-in in)))

;; a count by ada of RID, found DELTA below the ledger: the adjustment, the
;; record and the hours, as do-count-stock lands them
(define (count! obs who eid rid delta)
  ($ obs 'record-event
     (make-economic-event #:id eid #:action 'lower #:output-of "count:stated" #:resource-inventoried-as rid #:resource-conforms-to "rice" #:resource-classified-as (list (evidence-tag pic))
                          #:provider who #:receiver who #:resource-quantity (make-measure delta "kg") #:has-point-in-time "2026-10-01T10:00:00Z" #:created "2026-10-01T10:00:00Z" #:note "a count" #:in-scope-of '("Granary")))
  ($ obs 'record-event
     (make-economic-event #:id (string-append eid "-record") #:action 'produce #:output-of "count:stated" #:resource-conforms-to "count-record"
                          #:resource-classified-as (list (string-append "count-of:" rid))
                          #:provider who #:receiver who #:resource-quantity (make-measure 1.0 %count-unit) #:has-point-in-time "2026-10-01T10:00:00Z" #:created "2026-10-01T10:00:00Z" #:note "a record" #:in-scope-of '("Granary")))
  ($ obs 'record-event
     (make-economic-event #:id (string-append eid "-hours") #:action 'work #:input-of "count~announced~rice" #:resource-conforms-to "skill-counting"
                          #:provider who #:effort-quantity (make-measure 0.15 %effort-unit) #:has-point-in-time "2026-10-01T10:00:00Z" #:note "a visit" #:in-scope-of '("Granary"))))

(define settled '())

(define vat (spawn-vat))
(with-vat vat
  (let* ((commune-id (make-keri-identity)) (commune-aid (keri-identity-aid commune-id))
         (root  (spawn-scope-root "Granary"))
         (store (spawn-acdc-store))
         (scope (spawn-scope "Granary" #:kind 'commune #:scope-root-ref root
                             #:scope-aid commune-aid #:keypair (keri-identity-keypair commune-id)
                             #:acdc-store store))
         (ada (make-keri-identity)) (ada-aid (keri-identity-aid ada))      ; the counter
         (bo  (make-keri-identity)) (bo-aid  (keri-identity-aid bo))
         (cy  (make-keri-identity)) (cy-aid  (keri-identity-aid cy))
         (svc (spawn-governance-service (list root) ($ root 'ballot-store)
                                        #:acdc-store store #:home-scope scope
                                        #:scope-root-of (lambda (sid) (and (equal? sid "Granary") root))
                                        #:governor? (lambda (a) (equal? a commune-aid))))
         (obs ($ root 'observer)))
    (for-each (lambda (aid name h)
                ($ ($ root 'agent-store) 'add-agent (make-agent #:id aid #:type 'person #:name name
                                                                #:note "" #:image ""
                                                                #:classified-as '()))
                ($ ($ root 'account-store) 'add-contribution aid h))
              (list ada-aid bo-aid cy-aid) '("Ada" "Bo" "Cy") '(30 10 20))
    ($ svc 'set-contest-settled! (lambda (id) (set! settled (cons id settled))))

    ;; rice 10 kg in a crate; a jar of 4 kg inside it. Ada counts the crate 2 kg
    ;; short, so the crate's contents are drawn down with it.
    (seed! obs "crate" 10.0 #f)
    (seed! obs "jar" 4.0 "crate")
    (count! obs ada-aid "evt-count-1" "crate" 2.0)
    (check "before: the crate reads 8 kg" (onhand obs "crate") 8.0)
    (check-pred "before: the count's parts all stand"
                (every (lambda (id) ($ obs 'event-standing? id))
                       '("evt-count-1" "evt-count-1-record" "evt-count-1-hours")))

    (display "\n── who may contest a count ──\n")
    (check "the counter cannot contest their own count"
           (car ($ svc 'contest-work ada-aid "Granary" "evt-count-1" "")) 'error)
    (check "nor can someone outside the scope"
           (car ($ svc 'contest-work "EStranger" "Granary" "evt-count-1" "")) 'error)
    (check "an event that is no work and no count is refused"
           (begin
             ($ obs 'record-event
                (make-economic-event #:id "evt-prod" #:action 'produce #:output-of "bake" #:resource-inventoried-as "loaf" #:resource-conforms-to "bread"
                                     #:provider ada-aid #:receiver ada-aid #:resource-quantity (make-measure 1.0 %count-unit) #:has-point-in-time "2026-10-01T10:00:00Z" #:note "baked" #:in-scope-of '("Granary")))
             (car ($ svc 'contest-work bo-aid "Granary" "evt-prod" "")))
           'error)
    (check "a member contests the count by naming its record"
           ($ svc 'contest-work bo-aid "Granary" "evt-count-1-record" "she never opened the crate")
           '(ok "contest:evt-count-1"))
    (check "the ballot is the count's, so naming the adjustment is the same contest"
           (car ($ svc 'contest-work cy-aid "Granary" "evt-count-1" "")) 'error)
    (check "…and so is naming the hours"
           (car ($ svc 'contest-work cy-aid "Granary" "evt-count-1-hours" "")) 'error)
    (let ((snap ($ ($ ($ root 'ballot-store) 'get "contest:evt-count-1") 'voice-snapshot)))
      (check "the franchise is the roster with the counter left out"
             (sort (hashmap-fold (lambda (k _ acc) (cons k acc)) '() snap) string<?)
             (sort (list bo-aid cy-aid) string<?)))

    (display "\n── what a member may do about it ──\n")
    (define (role-of aid)
      (let ((r (plain-reply ($ svc 'contests aid "Granary"))))
        (and (eq? 'ok (car r))
             (let ((c (find (lambda (c) (equal? "contest:evt-count-1" (assq-ref c 'id))) (assq-ref (cdr r) 'rows))))
               (and c (assq-ref c 'role))))))
    (check "a contest names the stock the count is of, though the record was named"
           (assq-ref (find (lambda (c) (equal? "contest:evt-count-1" (assq-ref c 'id))) (assq-ref (cdr (plain-reply ($ svc 'contests bo-aid "Granary"))) 'rows))
                     'resource)
           "crate")
    (check "the counter may attach a picture" (role-of ada-aid) "attach")
    (check "a member of the franchise may vote" (role-of bo-aid) "vote")
    (check "someone outside may do neither" (role-of "EStranger") "none")
    (define (terms aid) ($ svc 'contest-terms aid "contest:evt-count-1"))
    (check "the counter's terms name the role and the hash the count carries"
           (list (assq-ref (cadr (terms ada-aid)) 'role) (assq-ref (cadr (terms ada-aid)) 'hash))
           (list 'attach pic))
    (check "a member of the franchise reads the same picture"
           (list (assq-ref (cadr (terms bo-aid)) 'role) (assq-ref (cadr (terms bo-aid)) 'hash))
           (list 'vote pic))
    (check "no one else is given terms" (car (terms "EStranger")) 'error)
    (check "a contest that does not exist has none" (car ($ svc 'contest-terms bo-aid "contest:nowhere")) 'error)

    (display "\n── a void settles the whole count ──\n")
    (check "bo casts void" (cast! svc bo-aid (keri-identity-keypair bo) "contest:evt-count-1" 'void) 'ok)
    (check "cy casts void" (cast! svc cy-aid (keri-identity-keypair cy) "contest:evt-count-1" 'void) 'ok)
    (check "the scope closes it" (car ($ svc 'close commune-aid "contest:evt-count-1")) 'ok)
    (check "the crate reads what it read before the count" (onhand obs "crate") 10.0)
    (check-pred "the adjustment, the record and the hours no longer stand"
                (every (lambda (id) (not ($ obs 'event-standing? id)))
                       '("evt-count-1" "evt-count-1-record" "evt-count-1-hours")))
    (check-pred "the contested part is corrected by a record naming the ballot"
                (let ((fix ($ obs 'get-event "contest:evt-count-1:void")))
                  (and fix (equal? "evt-count-1-record" (economic-event-corrects fix))
                       (string-contains (economic-event-note fix) "contest:evt-count-1"))))
    (check-pred "…and every other part by one of its own"
                (and ($ obs 'get-event "contest:evt-count-1:void~evt-count-1")
                     ($ obs 'get-event "contest:evt-count-1:void~evt-count-1-hours")))
    (check "what the count did to the crate's contents goes back with the adjustment"
           (onhand obs "jar") 4.0)
    (check-pred "…and leaves the standing log"
                (not (any (lambda (e) (string-prefix? "evt-count-1~contains~" (economic-event-id e)))
                          ($ obs 'standing-log))))
    (check-pred "the corrections are events of the same scope, as a list"
                (equal? '("Granary") (economic-event-in-scope-of ($ obs 'get-event "contest:evt-count-1:void"))))
    (check-pred "the standing events hold none of the count"
                (not (any (lambda (e) (string-prefix? "evt-count-1" (economic-event-id e)))
                          ($ obs 'standing-log))))
    (check "the hook was told the ballot had settled" settled '("contest:evt-count-1"))
    (check "a settled contest gives no terms" (car (terms ada-aid)) 'error)
    (check "…and is not reopened" (car ($ svc 'contest-work cy-aid "Granary" "evt-count-1" "")) 'error)

    (display "\n── a count that stands is left ──\n")
    (count! obs ada-aid "evt-count-2" "crate" 1.0)
    (check "before: the crate reads 9 kg" (onhand obs "crate") 9.0)
    (check "cy contests the second count" (car ($ svc 'contest-work cy-aid "Granary" "evt-count-2" "")) 'ok)
    (check "bo says it stands" (cast! svc bo-aid (keri-identity-keypair bo) "contest:evt-count-2" 'stands) 'ok)
    (check "cy says it stands" (cast! svc cy-aid (keri-identity-keypair cy) "contest:evt-count-2" 'stands) 'ok)
    (check "the scope closes it" (car ($ svc 'close commune-aid "contest:evt-count-2")) 'ok)
    (check "the crate still reads 9 kg" (onhand obs "crate") 9.0)
    (check-pred "the count still stands" ($ obs 'event-standing? "evt-count-2"))
    (check "the hook is told all the same" (car settled) "contest:evt-count-2")))

(display "\n")
(test-summary!)
