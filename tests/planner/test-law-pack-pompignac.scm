;;; test-law-pack-pompignac.scm — a real French PLU, folded by the real gate.
;;;
;;; `docs/legal/contexts/fr-33330.sexp` is a CONTEXT PACK generated from the open
;;; national services by tools/law/fetch-fr-gpu.py — the Plan Local d'Urbanisme
;;; of Pompignac (Gironde), document 33330_PLU_20241212, in force since
;;; 17 Dec 2024. Nothing in it is hand-written for this test.
;;;
;;; It exercises the whole seam on real law:
;;;   the pack's PLACES become the scope's contained-in tree (zone ⊂ commune ⊂
;;;   EPCI ⊂ département ⊂ région ⊂ France), so `jurisdiction-path` walks a real
;;;   French administrative chain; the pack's RULES become the scope's
;;;   ^legal-registry; a recipe tagged `crossing:built-structure` then meets them.
;;;
;;; What the PLU actually says, and what the gate must reproduce:
;;;   zone A  — building is forbidden UNLESS necessary to farming
;;;   zone N  — building is forbidden, full stop
;;;   zone U  — building needs a permis de construire
;;;   EBC     — clearing classified woodland is forbidden, commune-wide
;;;
;;; Run: guile -L module tests/planner/test-law-pack-pompignac.scm

(use-modules (playnet test harness) (playnet planner knowledge recipes store) (playnet planner scope spatial-things) (playnet planner legal crossings) (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1)
             (playnet planner legal registry) (playnet planner legal registry-actor)
             (playnet planner legal gate) (playnet planner legal crossings)
             (playnet planner knowledge law context-pack)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (ice-9 format))

(define pack "docs/legal/contexts/fr-33330.sexp")

;; a dwelling: building one trips `built-structure`, the intrinsic crossing the
;; PLU's rules are guarded on. Clearing woodland trips `clear-woodland`.
(define dwelling-spec
  (make-resource-specification #:id "spec-dwelling" #:name "Logement"
    #:resource-classified-as '("shelter" "crossing:built-structure") #:default-unit-of-resource "m2"))
(define timber-spec
  (make-resource-specification #:id "spec-timber" #:name "Bois d'œuvre" #:resource-classified-as '()
                               #:default-unit-of-resource "m3"))
(define barn-spec
  (make-resource-specification #:id "spec-barn" #:name "Bâtiment agricole"
    ;; the same crossing as a house — and its own act
    #:resource-classified-as '("shelter" "crossing:built-structure" "act:agriculture") #:default-unit-of-resource "m2"))
(define clearing-spec
  (make-resource-specification #:id "spec-clearing" #:name "Défrichement"
    #:resource-classified-as '("crossing:clear-woodland") #:default-unit-of-resource "ha"))

(define (seed-build! rs)
  (for-each (lambda (s) ($ rs 'add-resource-spec s))
            (list dwelling-spec timber-spec clearing-spec barn-spec))
  ($ rs 'add-recipe-process (make-recipe-process #:id "rp-build" #:name "Construire un logement"
                                                 #:has-duration (make-duration 200 "hours")))
  ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-timber" #:action 'consume #:resource-conforms-to "spec-timber"
                            #:resource-quantity (make-measure 20 "m3") #:recipe-input-of "rp-build"))
  ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-dwelling" #:action 'produce #:resource-conforms-to "spec-dwelling"
                            #:resource-quantity (make-measure 100 "m2") #:recipe-output-of "rp-build" #:is-primary #t))
  ($ rs 'add-recipe-process (make-recipe-process #:id "rp-barn" #:name "Construire une grange"
                                                 #:has-duration (make-duration 120 "hours")))
  ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-barn-timber" #:action 'consume #:resource-conforms-to "spec-timber"
                            #:resource-quantity (make-measure 12 "m3") #:recipe-input-of "rp-barn"))
  ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-barn" #:action 'produce #:resource-conforms-to "spec-barn"
                            #:resource-quantity (make-measure 300 "m2") #:recipe-output-of "rp-barn" #:is-primary #t))
  ($ rs 'add-recipe-process (make-recipe-process #:id "rp-clear" #:name "Défricher"
                                                 #:has-duration (make-duration 8 "hours")))
  ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-clear" #:action 'produce #:resource-conforms-to "spec-clearing"
                            #:resource-quantity (make-measure 1 "ha") #:recipe-output-of "rp-clear" #:is-primary #t)))

(define vat (spawn-vat))
(define out
  (with-vat vat
    (let* ((rs  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))
           (sts (spawn ^spatial-thing-store (hashmap)))
           (rows (pack-place-rows pack))
           (rules (load-context-pack pack))
           (reg (spawn ^legal-registry rules)))
      (seed-build! rs)
      ($ sts 'add-location (make-spatial-thing #:id "world" #:name "World"))
      (let ((n (seed-pack-places! sts rows)))
        ;; the gate told the act is housing — the act a process has unless its
        ;; own recipe says otherwise (the barn's does)
        (let* ((gate (make-legal-gate #:recipe-store rs #:spatial-thing-store sts
                                      #:registry reg #:act 'habitation))
               ;; the same gate told the act IS farming
               (farm-gate (make-legal-gate #:recipe-store rs #:spatial-thing-store sts
                                           #:registry reg #:act 'agriculture))
               (dec (make-legal-decorate #:recipe-store rs #:spatial-thing-store sts
                                         #:registry reg))
               (bill (lambda (cell)
                       (call-with-values (lambda () (dec "rp-build" cell)) list))))
          (list n (length rows) (length rules)
                (map spatial-thing-id ($ sts 'resolve-chain "fr-33330-A2"))
                (gate "rp-build" "fr-33330-A2@0")       ; farmland, generic act
                (farm-gate "rp-build" "fr-33330-A2@0")  ; farmland, farming act
                (gate "rp-build" "fr-33330-N@0")        ; natural zone
                (gate "rp-build" "fr-33330-Ud1@0")      ; residential zone
                (bill "fr-33330-Ud1@0")                 ; …and what it asks there
                (gate "rp-clear" "fr-33330-Ud1@0")      ; EBC, commune-wide
                (gate "rp-barn" "fr-33330-A2@0")        ; a BARN on the same farmland
                (recipe-crossings (legal-proc-flows rs "rp-build")
                                  (lambda (id) ($ rs 'get-resource-spec id)))
                (recipe-act (legal-proc-flows rs "rp-barn")
                            (lambda (id) ($ rs 'get-resource-spec id)))))))))

(define (ref n) (list-ref out n))
(display "\n── the pack: a real PLU becomes places + rules ──\n")
(format #t "  place rows ~a → seeded ~a · rules ~a\n" (ref 1) (ref 0) (ref 2))
(format #t "  jurisdiction path of zone A2: ~a\n" (ref 3))
(check-pred "the pack seeds every place row it carries" (= (ref 0) (ref 1)))
(check-pred "a real French administrative chain, zone → commune → EPCI → dept → région → France → EU"
            (equal? (ref 3) '("fr-33330-A2" "fr-33330" "fr-epci-243301355"
                              "fr-dep-33" "fr-reg-75" "france" "eu" "world")))
(check-pred "the recipe trips built-structure off its own spec tag"
            (memq 'built-structure (ref 11)))

(display "\n── what the PLU forbids, as the planner sees it ──\n")
(format #t "  zone A2 generic act: ~a · as farming: ~a · zone N: ~a · zone Ud1: ~a\n"
        (ref 4) (ref 5) (ref 6) (ref 7))
(check-pred "zone A: building is FORBIDDEN when the act is not farming" (ref 4))
(check-pred "zone A: the same build as an AGRICULTURAL act is not forbidden" (not (ref 5)))
(check-pred "zone N: building is forbidden outright" (ref 6))
(check-pred "zone Ud1: building is not forbidden — it is permitted, with a permit"
            (not (ref 7)))

(display "\n── what it asks in the buildable zone ──\n")
(let* ((b (ref 8)) (prune? (car b)) (cost (cadr b)) (skills (caddr b)))
  (format #t "  prune ~a · cost ~,1f · skills ~a\n" prune? cost skills)
  (check-pred "a permis de construire is an ENTITY obtain — a cost, not a competence"
              (and (not prune?) (> cost 0.0) (null? skills))))

(display "\n── the commune-wide prescription ──\n")
(check-pred "clearing an Espace Boisé Classé is forbidden anywhere in the commune"
            (ref 9))

;;; ─── the autosetup: a root born under a folder of packs ──────────────────
;;; This is the whole deployment story in one call. `spawn-scope-root
;;; #:law-packs DIR` reads every pack in DIR: its rules become the root's own
;;; ^legal-registry (persisted with the root), its places become the root's own
;;; contained-in tree. Nothing else is wired, and the same DIR is what the
;;; gateway passes from PLAYNET_LAW_PACKS.
(use-modules (playnet planner legal compliance) (playnet planner facts places) (ice-9 ftw))
(define dir (string-append (or (getenv "TMPDIR") "/tmp") "/pompignac-law-" (number->string (getpid))))
(mkdir dir)
(copy-file pack (string-append dir "/fr-33330.sexp"))

(define born
  (with-vat (spawn-vat)
    (let ((root (spawn-scope-root "Pompignac" #:law-packs dir)))
      (seed-build! ($ root 'recipe-store))
      ($ ($ root 'spatial-thing-store) 'add-location
         (make-spatial-thing #:id "world" #:name "World"))
      (let* ((dec (scope-legal-decorate root))
             (before (and dec (call-with-values
                                  (lambda () (dec "rp-build" "fr-33330-Ud1@0")) list))))
        ;; the commune obtains the permis: a resource conforming to the demand's
        ;; own name (compliance.scm demand->spec-id), standing in its own stores
        ;; BOTH obtains the fold unions at that cell: the zone's permis, and the
        ;; commune-wide étude de sol the carrières-souterraines prescription asks
        ;; for anywhere in Pompignac. Two rules, two levels of the same chain.
        (for-each
         (lambda (nm)
           ($ ($ root 'observer) 'seed-resource
              (make-economic-resource #:id (string-append "res:" nm) #:name nm
                #:conforms-to nm #:classified-as '("credential") #:accounting-quantity (make-measure 1 "cert") #:onhand-quantity (make-measure 1 "cert")
                #:current-location "fr-33330-Ud1" #:primary-accountable "fr-33330" #:custodian-scope "fr-33330" #:state "active")))
         (list "Permis de construire"
               "Étude de sol — périmètre d'effondrement (carrières souterraines)"))
        (list (length ($ ($ root 'legal-registry) 'rules))
              (map spatial-thing-id
                   ($ ($ root 'spatial-thing-store) 'resolve-chain "fr-33330-N"))
              (and dec (call-with-values (lambda () (dec "rp-build" "fr-33330-N@0")) list))
              before
              (and dec (call-with-values
                           (lambda () (dec "rp-build" "fr-33330-Ud1@0")) list)))))))

(display "\n── a scope root born under the pack folder ──\n")
(format #t "  rules on the root: ~a · chain of zone N: ~a\n" (car born) (cadr born))
(check-pred "the root carries the pack's rules on its own ^legal-registry"
            (= (car born) (ref 2)))
(check-pred "…and the pack's places in its own contained-in tree"
            (equal? (cadr born) '("fr-33330-N" "fr-33330" "fr-epci-243301355"
                                  "fr-dep-33" "fr-reg-75" "france" "eu" "world")))
(check-pred "a house in zone N is pruned at the born root's own solve door"
            (car (caddr born)))
(check-pred "in Ud1 the permis de construire is an entity permit the commune does NOT hold ⇒ pruned"
            (car (cadddr born)))
(check-pred "…and once BOTH obtains (zone permis + commune-wide étude de sol) are held, it survives"
            (let ((after (list-ref born 4)))
              (and (not (car after)) (> (cadr after) 0.0))))

;;; ─── one climb, two sources ──────────────────────────────────────────────
;;; A scope whose OWN store never heard of Pompignac still stands under its law:
;;; the pack taught the shared jurisdiction tree, and the gate's climb continues
;;; there when the scope's own tree runs out. Without the fall-through the chain
;;; stops at the cell, no guard matches, and the law silently does not apply —
;;; which is also the disagreement that let the law FACE (which walks the shared
;;; tree) show demands the SOLVE (which walks the store) never enforced.
(define bare
  (with-vat (spawn-vat)
    (let ((rs  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                      (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))
          (sts (spawn ^spatial-thing-store (hashmap)))     ; EMPTY: knows no place
          (reg (spawn ^legal-registry (load-context-pack pack))))
      (seed-build! rs)
      (let ((gate (make-legal-gate #:recipe-store rs #:spatial-thing-store sts
                                   #:registry reg)))
        (list (gate "rp-build" "fr-33330-N@0")
              (gate "rp-build" "fr-33330-Ud1@0"))))))

(display "\n── the act rides the recipe ──\n")
;;; The house and the barn trip the SAME crossing at the SAME cell through the
;;; SAME gate — the one the planner builds, told nothing about either. What
;;; separates them is the barn's own `act:agriculture` tag, which is exactly what
;;; zone A's rule turns on. Before the act came off the recipe, one gate could
;;; carry one act for every process it would ever decorate, so this distinction —
;;; 63% of the commune's surface — could not be made at all.
(format #t "  house in zone A2: ~a · barn in zone A2: ~a · barn's act: ~a\n"
        (ref 4) (ref 10) (ref 12))
(check-pred "the barn declares its own act off its spec tag" (eq? 'agriculture (ref 12)))
(check-pred "the SAME gate forbids the house and allows the barn on the same farmland"
            (and (ref 4) (not (ref 10))))

(display "\n── one climb, two sources ──\n")
(check-pred "a scope whose own store knows no place still meets the commune's law"
            (car bare))
(check-pred "…and the same climb still says Ud1 is buildable" (not (cadr bare)))

;;; ─── the regimes that do not nest ────────────────────────────────────────
;;; A second pack, `fr-33330-regimes.sexp`, declares what Pompignac stands in
;;; besides its jurisdiction chain: three SAGE water perimeters that overlap EACH
;;; OTHER, an appellation, and a biosphere transition zone. They ride `within`,
;;; so each is another endpoint climbed by the same containment walk. The test
;;; that matters: a rule guarded on `bassin-adour-garonne` — two levels up the
;;; WATER tree — must reach an activity sitting two levels down the
;;; ADMINISTRATIVE tree, with no guard form, record field or fold change.
(define regimes "docs/legal/contexts/fr-33330-regimes.sexp")

(define (draw-spec)
  (make-resource-specification #:id "spec-borehole" #:name "Prélèvement en nappe"
    #:resource-classified-as '("crossing:eco-draw") #:default-unit-of-resource "m3"))

(define both
  (with-vat (spawn-vat)
    (let* ((rs  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))
           (sts (spawn ^spatial-thing-store (hashmap)))
           ;; BOTH packs, as a law folder holds them
           (rules (append (load-context-pack pack) (load-context-pack regimes)))
           (reg (spawn ^legal-registry rules)))
      (seed-build! rs)
      ($ rs 'add-resource-spec (draw-spec))
      ($ rs 'add-recipe-process (make-recipe-process #:id "rp-draw" #:name "Forer"
                                                     #:has-duration (make-duration 4 "hours")))
      ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-draw" #:action 'produce #:resource-conforms-to "spec-borehole"
                                #:resource-quantity (make-measure 500 "m3") #:recipe-output-of "rp-draw" #:is-primary #t))
      ($ sts 'add-location (make-spatial-thing #:id "world" #:name "World"))
      (seed-pack-places! sts (pack-place-rows pack))
      (let* ((dec (make-legal-decorate #:recipe-store rs #:spatial-thing-store sts
                                       #:registry reg))
             (bill (lambda (proc cell)
                     (call-with-values (lambda () (dec proc cell)) list))))
        (list (length rules)
              ;; the water demand, asked of an activity sitting in a PLU zone
              (bill "rp-draw" "fr-33330-Ud1@0")
              ;; the PLU still applies to building at the same cell
              (bill "rp-build" "fr-33330-N@0"))))))

(display "\n── regimes that do not nest ──\n")
(format #t "  rules from both packs: ~a\n" (car both))
(let ((water (cadr both)))
  (format #t "  drawing water in zone Ud1 → prune ~a · cost ~,1f\n" (car water) (cadr water)))
(check-pred "a rule two levels up the WATER tree reaches a cell two levels down the ADMIN tree"
            (> (cadr (cadr both)) 0.0))
(check-pred "the PLU still forbids building in zone N — the trees do not interfere"
            (car (caddr both)))

;;; ─── packs compose in any order ──────────────────────────────────────────
;;; The production path loads a FOLDER, and a folder is read in name order —
;;; which is an accident of what the files are called. Both packs name Pompignac
;;; and each has different facts about it: one gives its INSEE code and
;;; population, the other the regimes it stands `within`. If a re-registration
;;; replaced a place's extras instead of merging them, whichever file sorted last
;;; would erase the other's — silently, and the whole `within` mechanism would
;;; quietly do nothing in production while passing every test that loaded the
;;; packs by hand in a lucky order.
(define dir2 (string-append (or (getenv "TMPDIR") "/tmp") "/pompignac-both-" (number->string (getpid))))
(mkdir dir2)
(copy-file pack    (string-append dir2 "/fr-33330.sexp"))
(copy-file regimes (string-append dir2 "/fr-33330-regimes.sexp"))

(define folder
  (with-vat (spawn-vat)
    (let* ((rs  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))
           (sts (spawn ^spatial-thing-store (hashmap)))
           (rules (load-context-packs dir2))          ; the folder, name-ordered
           (reg (spawn ^legal-registry rules)))
      (seed-build! rs)
      ($ rs 'add-resource-spec (draw-spec))
      ($ rs 'add-recipe-process (make-recipe-process #:id "rp-draw" #:name "Forer"
                                                     #:has-duration (make-duration 4 "hours")))
      ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-draw" #:action 'produce #:resource-conforms-to "spec-borehole"
                                #:resource-quantity (make-measure 500 "m3") #:recipe-output-of "rp-draw" #:is-primary #t))
      (let ((dec (make-legal-decorate #:recipe-store rs #:spatial-thing-store sts
                                      #:registry reg)))
        (list (place-extra-ref "fr-33330" 'within)
              (place-extra-ref "fr-33330" 'insee)
              (call-with-values (lambda () (dec "rp-draw" "fr-33330-Ud1@0")) list))))))

(display "\n── packs compose in any order ──\n")
(format #t "  within survives a folder load: ~a regimes · insee still there: ~a\n"
        (length (or (car folder) '())) (cadr folder))
;;; The PROPERTY: every regime the regimes pack declares survived, and the
;;; generated pack's own facts about the same place survived too. Counting to a
;;; literal 5 would break the moment a pack learned one more regime — a test
;;; failing because the data got better measures the wrong thing.
(define declared-regimes
  (or (assq-ref (assq-ref (call-with-input-file regimes
                            (lambda (port) (set-port-encoding! port "UTF-8") (read port)))
                          'places)
                #f)
      ;; the regimes pack's own `within` list, read straight from the file
      (let ((rows (pack-place-rows regimes)))
        (or (assq-ref (list-ref (or (find (lambda (r) (equal? "fr-33330" (car r))) rows)
                                    '("" "" "" locality ())) 4)
                      'within)
            '()))))
(check-pred "each pack's facts about the same place survive the other"
            (and (lset<= equal? declared-regimes (or (car folder) '()))
                 (cadr folder)))
(check-pred "…so the water regime still reaches a cell, loaded the way production loads"
            (> (cadr (caddr folder)) 0.0))

(for-each (lambda (f) (delete-file (string-append dir2 "/" f)))
          (filter (lambda (f) (string-suffix? ".sexp" f)) (scandir dir2)))
(rmdir dir2)

(delete-file (string-append dir "/fr-33330.sexp"))
(rmdir dir)
(test-summary!)
