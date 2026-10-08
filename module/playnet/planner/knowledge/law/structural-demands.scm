;;; law/structural-demands.scm — the DEEP program: the structural demands.
;;;
;;; The regulatory program (law/reform-mirrors.scm) withers the state's redundant
;;; INSPECTION — the easy tier, ripe now. This is the other end of the SAME
;;; ladder, through the SAME logic: each abolition is a `<spec-mirror>` (L,I,D)
;;; and what to do about it is a MOVE read off the cells, not a score
;;; (legal-crossings.md §8). L = the social functions the state's monopoly serves;
;;; I = what the commons already reproduces of them; D = what it wants (the
;;; function minus the coercive shell). Then reform.scm computes the regions:
;;;   redundant  (L∩D∩I) — we already provide it → demand the state's version wither
;;;   absorb-first ((L∩D)−I) — we want it, must BUILD it (the I that makes the
;;;                            demand a capacity claim, not a wish)
;;;   transform  (L−D)   — the coercive shell we reject outright
;;; The coercive core comes out all absorb-first — honestly: we have not yet
;;; reproduced defense or public safety, so the work there is to build.
;;; Stewardable. `class` ∈ force | value | border | property.
;;; Loads after reform.scm + legal-aspects (for `grounded-mirror`).
(define-module (playnet planner knowledge law structural-demands)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner legal registry)
  #:use-module (playnet planner legal reform)
  #:use-module (playnet planner knowledge law aspects)
  #:use-module (playnet planner knowledge law incumbent-readings)
  #:export (*structural-demands* *program-budget*))

(define *structural-demands*
  (list
   `((name . "Recognize social property") (class . "property")
     (withers . "the deed regime that knows only a named owner")
     (becomes . "a social-property title class — purpose-owned, asset-locked, no beneficial owner")
     (mirror . ,(grounded-mirror "Recognize social property" #:kind 'permit
                  #:incumbent '(custody transfer asset-protection dispute-title named-owner)
                  #:actual '(custody transfer asset-protection)
                  #:desired  '(custody transfer asset-protection dispute-title))))
   `((name . "Hold the means of life in common") (class . "property")
     (withers . "the title that lets a few hold the land, tools, housing, and food the many must live by")
     (becomes . "social stewardship of the means of life — held in common, allocated by use, no beneficial owner")
     (mirror . ,(grounded-mirror "Hold the means of life in common" #:kind 'permit
                  #:incumbent '(allocate-use steward transfer-stewardship exclude-others accumulate command-labour gate-subsistence)
                  #:actual '(allocate-use)
                  #:desired  '(allocate-use steward transfer-stewardship))))
   `((name . "Retire rent") (class . "property")
     (withers . "the levy on shelter — payment for access to housing someone else holds title to")
     (becomes . "housing as a commons: maintained and coordinated by those who live there — no rent, no eviction")
     (mirror . ,(grounded-mirror "Retire rent" #:kind 'permit
                  #:incumbent '(house-access maintain coordinate-tenancy extract-rent gate-by-payment evict)
                  #:actual '(maintain coordinate-tenancy)
                  #:desired  '(house-access maintain coordinate-tenancy))))
   `((name . "Retire debt") (class . "value")
     (withers . "credit as an enforceable claim on the future — interest, seniority, the obligation to pay")
     (becomes . "mutual credit: resources advanced and obligations recorded by the commons, without interest or coercion")
     (mirror . ,(grounded-mirror "Retire debt" #:kind 'permit
                  #:incumbent '(advance-resources record-obligation risk-share extract-interest creditor-seniority enforce-claim)
                  #:actual '(record-obligation risk-share)
                  #:desired  '(advance-resources record-obligation risk-share))))
   `((name . "Withdraw extractive taxation") (class . "value")
     (withers . "the levy on a self-provisioning commons")
     (becomes . "the commons funds its own metabolism; the levy is duress, not contribution")
     (mirror . ,(grounded-mirror "Withdraw extractive taxation" #:kind 'permit
                  #:incumbent '(fund-provision fund-infrastructure redistribute extract-from-self)
                  #:actual '(fund-provision fund-infrastructure)
                  #:desired  '(fund-provision fund-infrastructure redistribute))))
   `((name . "End state money") (class . "value")
     (withers . "the monetary monopoly")
     (becomes . "the commons transacts in its own unit — credit and socially-necessary labour-time")
     (mirror . ,(grounded-mirror "End state money" #:kind 'permit
                  #:incumbent '(unit-of-account internal-settlement store-of-value external-extraction)
                  #:actual '(unit-of-account internal-settlement)
                  #:desired  '(unit-of-account internal-settlement))))
   `((name . "Pull the border inside") (class . "border")
     (withers . "the jurisdiction levy on people and goods")
     (becomes . "free association across the line — international solidarity as a setting, not a sentiment")
     (mirror . ,(grounded-mirror "Pull the border inside" #:kind 'permit
                  #:incumbent '(coordinate-movement safety-screen levy-crossing restrict-people)
                  #:actual '(coordinate-movement)
                  #:desired  '(coordinate-movement safety-screen))))
   `((name . "Retire prisons") (class . "force")
     (withers . "punishment and caging")
     (becomes . "transformative justice — repair priced as an economic option, not vengeance")
     (mirror . ,(grounded-mirror "Retire prisons" #:kind 'permit
                  #:incumbent '(harm-response accountability deterrence punishment caging)
                  #:actual '(accountability)
                  #:desired  '(harm-response accountability repair))))
   `((name . "Reform the courts") (class . "force")
     (withers . "the adjudication monopoly")
     (becomes . "elective, revocable arbiters; standing (the suable party) kept as the residual interface")
     (mirror . ,(grounded-mirror "Reform the courts" #:kind 'permit
                  #:incumbent '(resolve-disputes interpret-rules suable-party coercive-enforcement)
                  #:actual '(resolve-disputes)
                  #:desired  '(resolve-disputes interpret-rules suable-party))))
   `((name . "Retire the police") (class . "force")
     (withers . "the monopoly on public safety and dispute-force")
     (becomes . "safety as a commons function — the police a revocable agent, then superfluous")
     (mirror . ,(grounded-mirror "Retire the police" #:kind 'permit
                  #:incumbent '(public-safety dispute-response harm-response armed-patrol)
                  #:actual '(dispute-response)
                  #:desired  '(public-safety dispute-response harm-response))))
   `((name . "Retire the standing army") (class . "force")
     (withers . "the professional military monopoly")
     (becomes . "defense as a commons function — the people in arms, no standing army to turn on them")
     (mirror . ,(grounded-mirror "Retire the standing army" #:kind 'permit
                  #:incumbent '(defense deterrence force-projection)
                  #:actual '()
                  #:desired  '(defense))))
   ;; ── civic / rights demands ─────────────────────────────────────────────
   `((name . "Make rights material") (class . "civic")
     (withers . "formal permission without the means to use it")
     (becomes . "the means placed at the people's disposal — presses, halls, airtime, the time to take part")
     (mirror . ,(grounded-mirror "Make rights material" #:kind 'permit
                  #:incumbent '(expression press assembly association permission-without-means)
                  #:actual '(expression press)
                  #:desired  '(expression press assembly association))))
   `((name . "Self-determination & decolonisation") (class . "border")
     (withers . "imperial extraction, occupation, and imposed administration")
     (becomes . "peoples govern themselves; voluntary federation, not colonial control")
     (mirror . ,(grounded-mirror "Self-determination & decolonisation" #:kind 'permit
                  #:incumbent '(self-governance federated-coordination resource-extraction military-occupation imposed-administration)
                  #:actual '(self-governance)
                  #:desired  '(self-governance federated-coordination))))
   `((name . "Repudiate odious debt") (class . "value")
     (withers . "the obligation to service extractive and inherited debt")
     (becomes . "the commons keeps its own books; legitimate mutual obligations honored, odious ones annulled")
     (mirror . ,(grounded-mirror "Repudiate odious debt" #:kind 'permit
                  #:incumbent '(fiscal-accounting debt-service creditor-seniority)
                  #:actual '(fiscal-accounting)
                  #:desired  '(fiscal-accounting))))
   `((name . "Separate church from state") (class . "civic")
     (withers . "the established creed and church-run schooling")
     (becomes . "secular provision + freedom of conscience — no state religion, no church-run school")
     (mirror . ,(grounded-mirror "Separate church from state" #:kind 'permit
                  #:incumbent '(public-education civil-registry established-worship religious-schooling)
                  #:actual '(public-education civil-registry)
                  #:desired  '(public-education civil-registry))))))

;;; The general case IS a reading: each demand's whole incumbent, registered on
;;; the root. A place's own reading (law/incumbent-readings.scm) stands nearer on its
;;; chain and is found first; everywhere else the walk ends here.
(for-each
 (lambda (d)
   (register-incumbent-reading!
    `((place . "world") (demand . ,(assq-ref d 'name))
      (in-force . ,(spec-mirror-legal (assq-ref d 'mirror)))
      (source . "the general case — knowledge/structural-demands.scm")
      (confidence . reported))))
 *structural-demands*)

;;; ─── the premium is a BUDGET; the program is the BUNDLE ──────────────────
;;; The extractable premium is NOT priced per demand — it is ONE budget of
;;; credible coercion the federation has built (its leverage: a budget, not a cash flow;
;;; the premium manifests as state concessions). The
;;; whole program is the standing ask; each cycle we extract as much of it —
;;; readiest first — as the budget affords. The cheap, ripe demands
;;; clear now; the dear structural ones (social property, the standing army) wait
;;; until leverage grows the budget. The figure is stewarded until the budget is
;;; read off a real composed plan (option-composition.scm).
(define *program-budget* 20000)                  ; the federation's extractable premium, $B
