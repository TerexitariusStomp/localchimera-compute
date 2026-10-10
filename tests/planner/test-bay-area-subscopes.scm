;;; test-bay-area-subscopes.scm — SF + Oakland as DURABLE nested subscopes under earth,
;;; in the Bay Area bioregion. The union of everything built this session:
;;;   • earth (durable per-commune economic roots),
;;;   • the bioregion containment inheritance (a scope in the shed gets its drought
;;;     futures + water limit for free),
;;;   • the live seed → plan path.
;;;
;;; Proves: SF and Oakland are two communes under one earth; each is placed
;;; contained-in its city ⊂ "bay-area" ⊂ biosphere, so each INHERITS the Bay's 4 real
;;; Mediterranean futures (incl. drought) + its EXTREME water limit; each plans food
;;; bounded by its water budget; and BOTH rehydrate from the store with their own state.
;;;
;;; Run: guile --no-auto-compile -q -L module -L tests tests/planner/test-bay-area-subscopes.scm

(use-modules (playnet test harness)
             (playnet knowledge recipes bay-area-commune-seed) (playnet scope earth) (playnet vf schemas) (playnet vf beyond scenario) (srfi srfi-1)
             (playnet scope live)
             (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

(define SF "E_commune_SF")
(define OAK "E_commune_Oakland")
(define live-yields  (@@ (playnet knowledge worlds bay-area) *bay-area-crop-yields*))
(define live-scen-of (@@ (playnet scope live) scope-bioregion-scenarios))
(define live-frag-of (@@ (playnet scope live) scope-bioregion-fragilities))
(define frag-specs-of (@@ (playnet scope live) fragility-specs-of))

;; ── two subscopes born under earth, each seeded in the Bay ──
(define store (make-memory-store))
(define-values (vat earth)
  (spawn-persistent-vat earth-env (lambda () (spawn-earth)) store))

(with-vat vat
  (seed-bay-area-commune! ($ earth 'ensure-commune! SF  "San Francisco")
                          #:place "sf-garden"  #:city "san-francisco" #:city-name "San Francisco")
  (seed-bay-area-commune! ($ earth 'ensure-commune! OAK "Oakland")
                          #:place "oak-garden" #:city "oakland" #:city-name "Oakland"
                          #:land-ha 1.0 #:water 3.0))

;; containment inheritance — read each subscope's own spatial tree, resolve its shed
(define (scope-scen aid) (with-vat vat (live-scen-of ($ ($ ($ earth 'commune aid) 'spatial-thing-store) 'all-locations))))
(define (scope-frag aid) (with-vat vat (live-frag-of ($ ($ ($ earth 'commune aid) 'spatial-thing-store) 'all-locations))))

(display "\n── SF + Oakland: nested subscopes in the Bay Area shed, under earth ──\n")
(check "earth holds BOTH subscopes (SF + Oakland)" (with-vat vat ($ earth 'count)) 2)
(check "SF inherits the Bay's 4 futures by containment (incl. drought)"
       (and (= 4 (length (scope-scen SF)))
            (and (find (lambda (s) (equal? (planning-scenario-id s) "bay-area-drought")) (scope-scen SF)) #t)))
(check "SF inherits the Bay's water + topsoil limits"
       (equal? (sort (frag-specs-of (scope-frag SF)) string<?) '("topsoil" "water")))
(check "Oakland inherits the SAME shed independently (4 futures)"
       (= 4 (length (scope-scen OAK))))
(check "the seeded yields match the vendored *bay-area-crop-yields* (no drift)"
       (every (lambda (cw) (= (cddr cw) (assoc-ref live-yields (car cw))))
              (@@ (playnet knowledge recipes bay-area-commune-seed) *bay-area-commune-crops*)))

;; ── SF plans, bounded by its water budget (the California constraint) ──
(define sf-met
  (with-vat vat
    (assq-ref (plan-scope->alist ($ earth 'commune SF)
                #:demand (list (cons "food#sf-garden@0" 200000.0))
                #:repro-floors (list (cons "food#sf-garden@0" 20000.0))
                #:backend 'native-c)
              'met)))
(display "\n── SF plans in the Bay, water-bounded ──\n")
(check "SF's live plan produces food toward demand"  (> sf-met 0.0))
(check "…and is BOUNDED (its scarce water binds — the California limit)" (< sf-met 0.999))

;; ── durability: both subscopes rehydrate from the store with their state ──
(define-values (vat2 earth2)
  (spawn-persistent-vat earth-env (lambda () (error "thunk ran — not restoring!")) store))
(display "\n── reboot: both subscopes come back durable, independent ──\n")
(with-vat vat2
  (check "REHYDRATED: earth still holds both subscopes" ($ earth2 'count) 2)
  (check "REHYDRATED: SF kept its resources (land+water+labour+ground)"
         (length ($ ($ ($ earth2 'commune SF) 'observer) 'all-resources)) 4)
  (check "REHYDRATED: Oakland kept ITS own resources — separate economy"
         (length ($ ($ ($ earth2 'commune OAK) 'observer) 'all-resources)) 4)
  (check "REHYDRATED: SF's grow-recipes survived (4 crops)"
         (length (filter (lambda (r) (string-prefix? "r-grow-" (recipe-id r)))
                         ($ ($ ($ earth2 'commune SF) 'recipe-store) 'all-recipes)))
         4))

(test-summary!)
