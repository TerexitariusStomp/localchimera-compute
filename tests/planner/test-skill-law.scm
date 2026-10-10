;;; test-skill-law.scm — one law for a skill, on the record and in the plan.
;;;
;;; The engine's competence law (engine.scm SKILL DYNAMICS) says how a skill
;;; decays when idle, renews through practice and grows through training. This
;;; pins the same law read off the RECORD (planner/formulas/skill-law.scm):
;;;   • a skill's law is typed tags on its spec — `skill:decay:0.4` — and a
;;;     spec with none has the identity;
;;;   • under the identity the fold IS the validated ledger (practiced-hours),
;;;     so nothing changes for a skill that declares no law;
;;;   • with a law, idle periods wear competence and satisfied practice renews
;;;     it — the fold reads the observer's dated, satisfaction-weighted practice;
;;;   • the profile's standing carries where competence stands, in hours;
;;;   • the live solve opens each worker's competence at the record's figure
;;;     (engine set-competence!), never below the endowment.
;;;
;;; Run: guile -L module tests/planner/test-skill-law.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1))
(use-modules (playnet planner doors service))
(use-modules ((playnet planner formulas skill-law)
              #:select (skill-law-of *skill-law-identity* law-ref competence-fold)))
(use-modules ((playnet planner solve engine) #:select (set-competence! apply-skill-dynamics! iso->epoch)))
(use-modules (goblins) (goblins utils hashmap) (srfi srfi-1))

(define (approx= a b) (< (abs (- a b)) 1e-6))
(define DAY 86400)
(define (day n) (+ (iso->epoch "2026-03-01T08:00:00Z") (* n DAY)))

(display "\n── the law off a spec's tags ──\n")
(check "no tag, no law" (skill-law-of '("vf:skill" "colour:blue")) #f)
(let ((law (skill-law-of '("skill:decay:0.4" "skill:regen:0.6" "skill:lag:2" "skill:oops:1" "skill:decay:x"))))
  (check "decay, regen and lag read as numbers; an unknown key and a non-number are passed over"
         (sort (map car law) (lambda (a b) (string<? (symbol->string a) (symbol->string b))))
         '(decay lag regen))
  (check-pred "lag is whole" (= 2 (law-ref law 'lag)))
  (check-pred "a key the spec left out reads the identity's" (= 1.0 (law-ref law 'yield))))

(display "\n── the identity is the ledger ──\n")
(let ((practice `((,(day 0) . 6) (,(day 3) . 4) (,(day 40) . 2))))
  (check-pred "under no law, competence is Σ validated practice, however long ago"
              (approx= (competence-fold practice #f #:today (day 100)) 12))
  (check "no practice reads the endowment" (competence-fold '() #f #:today (day 1)) 0.0))

(display "\n── with a law, idle time wears it and practice renews it ──\n")
(let ((law '((decay . 0.5) (regen . 1.0))))
  ;; 6 h on day 0: by day 1 C = 0.5·0 + 1·6 = 6; day 2: 3; day 3: 1.5
  (check-pred "one practice, three idle days: halved each day"
              (approx= (competence-fold `((,(day 0) . 6)) law #:today (day 3)) 1.5))
  ;; practice today stands beside the competence it has not yet become
  (check-pred "today's own practice stands beside what the past leaves"
              (approx= (competence-fold `((,(day 0) . 6) (,(day 3) . 4)) law #:today (day 3)) 5.5))
  (check-pred "an ISO instant reads the same as its epoch"
              (approx= (competence-fold '(("2026-03-01T08:00:00Z" . 6)) law #:today "2026-03-04T08:00:00Z") 1.5))
  (check-pred "with nothing practiced the endowment stands"
              (approx= (competence-fold '() '((endow . 3.0)) #:today (day 9)) 3.0))
  ;; the week's practice becomes the next week's competence (6 at day 13), and
  ;; only the week after that wears it (3 at day 20)
  (check-pred "a period a week long wears once a week"
              (and (approx= (competence-fold `((,(day 0) . 6)) law #:today (day 13) #:period-days 7) 6.0)
                   (approx= (competence-fold `((,(day 0) . 6)) law #:today (day 20) #:period-days 7) 3.0))))

(display "\n── the record, through the standing ──\n")
(define vat (spawn-vat))
(with-vat vat
  (let* ((root  (spawn-scope-root "Granary"))
         (rs    ($ root 'recipe-store))
         (obs   ($ root 'observer))
         (svc   (spawn ^planner-service (hashmap))))
    ($ ($ root 'agent-store) 'add-agent (make-agent #:id "ada" #:type 'person #:name "Ada" #:note ""
                                                    #:image "" #:classified-as '()))
    ($ svc 'add-scope! "Granary" root)
    ;; one skill with a law — a day's idleness halves it — and one without
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "skill-bake" #:name "baking"
                                    #:resource-classified-as '("skill:decay:0.5" "skill:regen:1") #:default-unit-of-effort %effort-unit))
    ($ rs 'add-resource-spec (make-resource-specification #:id "skill-plumb" #:name "plumbing"
                                                          #:resource-classified-as '()
                                                          #:default-unit-of-effort %effort-unit))
    (define (work! skill hours eid iid when)
      ($ obs 'register-intent
         (make-intent #:id iid #:action 'work #:resource-conforms-to skill
                      #:effort-quantity (make-measure hours %effort-unit) #:provider "ada"))
      ($ obs 'record-event
         (make-economic-event #:id eid #:action 'work #:resource-conforms-to skill #:provider "ada"
                              #:effort-quantity (make-measure hours %effort-unit) #:has-point-in-time when
                              #:satisfies iid)))
    ;; both skills: 6 h a year ago, 4 h a month ago
    (work! "skill-bake" 6 "b1" "i1" "2025-09-01T08:00:00Z")
    (work! "skill-bake" 4 "b2" "i2" "2026-08-23T08:00:00Z")
    (work! "skill-plumb" 6 "p1" "i3" "2025-09-01T08:00:00Z")
    (work! "skill-plumb" 4 "p2" "i4" "2026-08-23T08:00:00Z")
    (check "the observer hands the dated, validated practice"
           (sort (map cdr ($ obs 'skill-practice "ada" "skill-bake")) <) '(4 6))
    (let* ((rows (assq-ref (cdr ($ svc 'skill-standing "Granary" "ada")) 'standing))
           (bake (find (lambda (r) (equal? (assq-ref r 'skill) "skill-bake")) rows))
           (plmb (find (lambda (r) (equal? (assq-ref r 'skill) "skill-plumb")) rows)))
      (check "the ledger keeps every validated hour of both" (list (assq-ref bake 'hours) (assq-ref plmb 'hours)) '(10 10))
      (check-pred "no law: competence is the ledger" (approx= (assq-ref plmb 'competence) 10))
      (check-pred "a law: a month of idleness has worn the baking to nearly nothing"
                  (< (assq-ref bake 'competence) 0.01)))

    (display "\n── the plan opens where the record leaves it ──\n")
    ;; the engine's door, as live.scm drives it: laws declared, competence set
    (apply-skill-dynamics! `(("ada" "skill-bake" ((decay . 0.5) (regen . 1.0) (endow . 2.0)) 7.5)))
    (check-pred "the skill's law stands in the engine" (and ((@@ (playnet planner solve engine) skill-spec) "skill-bake") #t))
    (check-pred "the worker's competence opens at the record's figure"
                (approx= ((@@ (playnet planner solve engine) competence-p0) "ada" "skill-bake") 7.5))))

(display "\n")
(test-summary!)
