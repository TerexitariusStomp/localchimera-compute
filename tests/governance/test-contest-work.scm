;;; test-contest-work.scm — the absence claim, given its door.
;;;
;;; Hours count the moment they are worked against a declared need; the spec's
;;; remedy is "a labour-voice-weighted decision to revoke accrued hours"
;;; (docs/playnet.typ §Matching as validation). This pins that door end to end
;;; through ^governance-service: a member contests a recorded work event, the
;;; ballot opens in the event's own scope under producer voice there with the
;;; worker left out, the scope casts and closes, and at half the voice or more
;;; the work is corrected to nothing — the kernel's correction, so hours,
;;; credit, the skill's standing and the portable record all follow. Below
;;; half, the work stands and nothing is written.

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet scope root) (playnet vf schemas))
(use-modules (playnet observation credentials) (playnet governance scope) (playnet governance service) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri said-portable))
(use-modules ((playnet observation credentials)
              #:select (make-credentialing-on-event skill-attestation-standing)))
(use-modules ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid sign-said))
             (goblins) (goblins utils hashmap) (srfi srfi-1))

(define (preimage-fields pre) (lambda (k) (let ((p (assq k pre))) (and p (cdr p)))))
(define (said-of ar) (compute-said (ar 'issuer) (ar 'holder) (ar 'schema) (ar 'claims) (or (ar 'edges) '())))
(define (cast! svc aid kp pid position)
  (let* ((ar (preimage-fields (cadr ($ svc 'stance-preimage aid pid position))))
         (ts (let ((p (assq 'timestamp (ar 'claims)))) (and p (cdr p))))
         (u  (let ((p (assq 'u (ar 'claims)))) (and p (cdr p)))))
    ($ svc 'cast-signed aid pid position ts (sign-said (said-of ar) kp) u)))

(define (intent! obs aid skill hours iid)
  ($ obs 'register-intent
     (make-intent #:id iid #:action 'work #:resource-conforms-to skill
                  #:effort-quantity (make-measure hours %effort-unit) #:provider aid)))
(define (work! obs aid skill hours eid iid)
  ($ obs 'record-event
     (make-economic-event #:id eid #:action 'work #:resource-conforms-to skill #:provider aid
                          #:effort-quantity (make-measure hours %effort-unit)
                          #:has-point-in-time "2026-03-01T08:00:00Z" #:satisfies iid)))

(define vat (spawn-vat))
(define gross-before #f)   ; ada's credit before the second contest — it carries unskilled contribution too

(with-vat vat
  (let* ((commune-id (make-keri-identity)) (commune-aid (keri-identity-aid commune-id))
         (root  (spawn-scope-root "Granary"))
         (store (spawn-acdc-store))
         (scope (spawn-scope "Granary" #:kind 'commune #:scope-root-ref root
                             #:scope-aid commune-aid #:keypair (keri-identity-keypair commune-id)
                             #:acdc-store store))
         (ada (make-keri-identity)) (ada-aid (keri-identity-aid ada))      ; the worker
         (bo  (make-keri-identity)) (bo-aid  (keri-identity-aid bo))
         (cy  (make-keri-identity)) (cy-aid  (keri-identity-aid cy))
         (svc (spawn-governance-service (list root) ($ root 'ballot-store)
                                        #:acdc-store store #:home-scope scope
                                        #:scope-root-of (lambda (sid) (and (equal? sid "Granary") root))
                                        #:governor? (lambda (a) (equal? a commune-aid)))))
    ;; the scope's roster, and producer voice in it: ada 30, bo 10, cy 20
    (for-each (lambda (aid name h)
                ($ ($ root 'agent-store) 'add-agent (make-agent #:id aid #:type 'person #:name name
                                                                #:note "" #:image ""
                                                                #:classified-as '()))
                ($ ($ root 'account-store) 'add-contribution aid h))
              (list ada-aid bo-aid cy-aid) '("Ada" "Bo" "Cy") '(30 10 20))
    ;; the work-event records ride the observer's on-event, as on a gateway
    ($ ($ root 'observer) 'set-callback 'on-event (make-credentialing-on-event store commune-aid))
    (let ((obs ($ root 'observer)))
      (intent! obs ada-aid "skill-bake" 6 "in-1")
      (work! obs ada-aid "skill-bake" 6 "ev-1" "in-1")
      (intent! obs ada-aid "skill-bake" 4 "in-2")
      (work! obs ada-aid "skill-bake" 4 "ev-2" "in-2")
      (check "before: ada's baking stands at ten validated hours"
             ($ obs 'practiced-hours ada-aid "skill-bake") 10)

      (display "\n── who may contest what ──\n")
      (check "the worker cannot contest their own record"
             (car ($ svc 'contest-work ada-aid "Granary" "ev-1" "")) 'error)
      (check "nor can someone outside the scope"
             (car ($ svc 'contest-work "EStranger" "Granary" "ev-1" "")) 'error)
      (check "nor is an unknown event contested"
             (car ($ svc 'contest-work bo-aid "Granary" "ev-nowhere" "")) 'error)
      (check "a member contests: the ballot contest:<event> opens"
             ($ svc 'contest-work bo-aid "Granary" "ev-1" "nobody saw a loaf")
             '(ok "contest:ev-1"))
      (check "one contest per event"
             (car ($ svc 'contest-work cy-aid "Granary" "ev-1" "")) 'error)
      (let ((snap ($ ($ ($ root 'ballot-store) 'get "contest:ev-1") 'voice-snapshot)))
        (check "the franchise is the roster with the worker left out"
               (sort (hashmap-fold (lambda (k _ acc) (cons k acc)) '() snap) string<?)
               (sort (list bo-aid cy-aid) string<?)))
      (check-pred "the forum can resolve what it is about"
                  (equal? "event:ev-1" (assq-ref ($ ($ root 'ballot-store) 'meta "contest:ev-1") 'subject)))

      (display "\n── below half the voice, the work stands ──\n")
      ;; bo (10) says void, cy (20) says stands: void carries a third
      (check "bo casts void"   (cast! svc bo-aid (keri-identity-keypair bo) "contest:ev-1" 'void) 'ok)
      (check "cy casts stands" (cast! svc cy-aid (keri-identity-keypair cy) "contest:ev-1" 'stands) 'ok)
      (check "the scope closes the ballot" (car ($ svc 'close commune-aid "contest:ev-1")) 'ok)
      (check "ada's hours are untouched" ($ obs 'practiced-hours ada-aid "skill-bake") 10)
      (check-pred "the event still stands" ($ obs 'event-standing? "ev-1"))
      (check "a settled contest is not reopened"
             (car ($ svc 'contest-work cy-aid "Granary" "ev-1" "")) 'error)

      (display "\n── at half or more, the work is corrected to nothing ──\n")
      (set! gross-before ($ obs 'validated-gross ada-aid))
      (check "cy contests the second event" (car ($ svc 'contest-work cy-aid "Granary" "ev-2" "")) 'ok)
      (check "bo casts void" (cast! svc bo-aid (keri-identity-keypair bo) "contest:ev-2" 'void) 'ok)
      (check "cy casts void" (cast! svc cy-aid (keri-identity-keypair cy) "contest:ev-2" 'void) 'ok)
      (check "the scope closes it" (car ($ svc 'close commune-aid "contest:ev-2")) 'ok)
      (check "the four voided hours leave ada's baking; the six that stood remain"
             ($ obs 'practiced-hours ada-aid "skill-bake") 6)
      (check "and her credit drops by exactly those four" ($ obs 'validated-gross ada-aid) (- gross-before 4))
      (check-pred "the event no longer stands" (not ($ obs 'event-standing? "ev-2")))
      (let ((fix ($ obs 'get-event "contest:ev-2:void")))
        (check-pred "the correction is a record, naming the ballot"
                    (and fix (equal? "ev-2" (economic-event-corrects fix))
                         (equal? ada-aid (economic-event-provider fix))
                         (string-contains (economic-event-note fix) "contest:ev-2"))))
      (check "the portable records agree: one baking event stands in ada's live credentials"
             (assq-ref (assoc-ref (skill-attestation-standing store ada-aid) "skill-bake") 'events) 1)
      (check "a corrected event is not contested again"
             (car ($ svc 'contest-work bo-aid "Granary" "ev-2" "")) 'error))))

(display "\n")
(test-summary!)
