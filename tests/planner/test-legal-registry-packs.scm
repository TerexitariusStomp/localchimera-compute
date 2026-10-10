;;; test-legal-registry-packs.scm — "add a jurisdiction = drop a signed file."
;;;
;;; The engine is jurisdiction-blind; the CONTENT is per-country data. Because a
;;; legal rule is fully serializable (guard FORM + demand data + provenance), a
;;; jurisdiction's laws live as a plain-data rule-pack on disk. This test proves
;;; the loader closes the loop:
;;;   (1) write two per-jurisdiction packs, load the whole directory → one merged
;;;       rule set — the fold's library ASSEMBLED FROM DISK, not hard-coded;
;;;   (2) a loaded rule still FIRES (its guard fold works) and its data survives
;;;       (the permit's #:retain window, its confidence/steward provenance);
;;;   (3) the packs round-trip (write→read identity);
;;;   (4) `load-legal-registry` spawns the governance ACTOR straight from the
;;;       folder — the possibility-tension query (forbids?) runs off disk-loaded law.
;;;
;;; Run: guile -L module tests/planner/test-legal-registry-packs.scm

(use-modules (playnet test harness) (goblins) (goblins vat) (srfi srfi-1) (ice-9 format))

(use-modules (playnet legal crossings))
(use-modules (playnet legal registry))
(use-modules (playnet legal registry-actor))
(use-modules ((playnet knowledge law context-pack) #:select (load-legal-registry)))

;; two jurisdictions' laws, authored as ordinary rules.
(define rule-foodville
  (rule (all-of (in-jurisdiction "foodville") (on-crossing 'food-vending))
        (list (obtain #:rides 'entity #:name "Food Establishment Permit"
                      #:issuer "foodville-health" #:per 'each-site #:retain 3))
        #:label "foodville/food-vending" #:source "foodville Health Code §4"
        #:as-of "2026-01-01" #:confidence 'verified #:steward "scope:food.foodville"))
(define rule-banville
  (rule (all-of (in-jurisdiction "banville") (on-crossing 'food-vending))
        (list (forbid #:reason "public food ordinance"))
        #:label "banville/ban" #:source "(example ordinance)"
        #:confidence 'verified #:steward "scope:test"))

;; a scratch directory of per-jurisdiction packs.
(define dir (string-append (or (getenv "TMPDIR") "/tmp") "/legalpacks-" (number->string (getpid))))
(catch #t (lambda () (mkdir dir)) (lambda _ #t))    ; fresh scratch dir for the packs
(save-rule-pack (in-vicinity dir "foodville.sexp") (list rule-foodville))
(save-rule-pack (in-vicinity dir "banville.sexp")  (list rule-banville))

;; jurisdiction geometry + a food-vending context at a place.
(define (parent-of id) (if (member id '("foodville" "banville")) "world" #f))
(define (ctx-at place) (legal-context #:crossings '(food-vending)
                                      #:place-path (jurisdiction-path place parent-of) #:act 'activity))

;;; ─── (1) load the directory → one merged rule set ─────────────────────────
(define loaded (load-rule-packs dir))
(display "\n── (1) the fold's library, assembled from a folder of signed files ──\n")
(format #t "  packs → ~a rules: ~s\n" (length loaded) (sort (map legal-rule-label loaded) string<?))
(check "loading the directory merges every pack's rules"
       (sort (map legal-rule-label loaded) string<?) '("banville/ban" "foodville/food-vending"))

;;; ─── (2) a disk-loaded rule still FIRES, and its data survived ────────────
(define permit
  (call-with-values (lambda () (legal-demands (ctx-at "foodville") #:rules loaded))
    (lambda (bill hits) (car (assq-ref bill 'obtain-entity)))))
(display "\n── (2) a loaded rule fires; its demand data + provenance survive ──\n")
(format #t "  foodville food-vending → obtain ~s (retain ~a yr)\n" (demand-name permit) (demand-retain permit))
(check "the loaded foodville rule's guard fires and yields its permit"
       (demand-name permit) "Food Establishment Permit")
(check "the permit's retention window (a rule datum) survived serialization"
       (demand-retain permit) 3)
(check-pred "the rule's provenance survived (confidence + steward)"
            (let ((r (find (lambda (r) (equal? (legal-rule-label r) "foodville/food-vending")) loaded)))
              (and (eq? (legal-rule-confidence r) 'verified)
                   (equal? (legal-rule-steward r) "scope:food.foodville"))))
(check-pred "banville's ban fires as a possibility-tension (forbid) off disk"
            (call-with-values (lambda () (legal-demands (ctx-at "banville") #:rules loaded))
              (lambda (bill hits) (pair? (assq-ref bill 'forbid)))))

;;; ─── (3) packs round-trip (write → read identity) ─────────────────────────
(define merged-path (string-append dir "-merged.sexp"))   ; OUTSIDE dir (not re-scanned in (4))
(save-rule-pack merged-path loaded)
(define reloaded (load-rule-pack merged-path))
(check "a saved pack reloads to the same laws (write→read identity)"
       (sort (map legal-rule-label reloaded) string<?)
       (sort (map legal-rule-label loaded) string<?))

;;; ─── (4) spawn the governance actor straight from the folder ──────────────
(define vat (spawn-vat))
(define from-disk
  (with-vat vat
    (let ((reg (load-legal-registry dir)))          ; the actor, loaded from *.sexp on disk
      (list ($ reg 'labels)
            ($ reg 'forbids? (ctx-at "banville"))
            ($ reg 'forbids? (ctx-at "foodville"))))))
(display "\n── (4) the registry ACTOR spawned from the folder of laws ──\n")
(format #t "  actor labels: ~s\n" (sort (first from-disk) string<?))
(check-pred "the actor loaded every jurisdiction from disk"
            (equal? (sort (first from-disk) string<?) '("banville/ban" "foodville/food-vending")))
(check "the actor answers the possibility-tension query off disk-loaded law: banville forbids"
       (second from-disk) #t)
(check "…and foodville does NOT forbid (a permit, not a ban)" (third from-disk) #f)

(display "\n")
(test-summary!)
