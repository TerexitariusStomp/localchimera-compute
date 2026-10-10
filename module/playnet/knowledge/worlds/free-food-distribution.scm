;;; worlds/free-food-distribution.scm — a REAL scope federation: free food distribution
;;; across jurisdictions, each member commune running the locally-compliant
;;; recipe, with the legal exterior DERIVED (not authored) by the legal fold.
;;;
;;; This is content, not engine. The LAW is not here: every jurisdiction's
;;; places, rules, protections and words for aspects live in a context pack
;;; (docs/legal/contexts/*.sexp — the US, Mexico and Canada written by
;;; tools/emit-na-context.scm, Germany by tools/emit-de-context.scm, France by
;;; hand and by the GPU adapter). This file loads them and supplies what is the
;;; federation's own:
;;;
;;;   • crossings   — the placeless facts free food distribution can trip
;;;   • recipes     — the compliant PATHWAYS, one per operating model
;;;   • federation  — REAL member communes: (scope, place, recipe) triples
;;;   • arcs        — who supplies whom, and the border each arc crosses
;;;
;;; The same ACTIVITY (free food distribution) yields a DIFFERENT bill in
;;; Wyoming than in California — not because the recipe differs, but because
;;; each jurisdiction answers the activity's crossings with its own demands.
;;; Some differences are paperwork (a fold); one (a forbid) prunes a recipe
;;; column and forces a structurally different pathway. Both are shown.
;;;
;;; Loaded by tools/emit-law-snapshot.scm (emits browser/data/snapshots/law-snapshot.json)
;;; and, in the live engine, by the planner-service legal-snapshot method.

;;; ─── crossings : what free food distribution can trip (placeless) ─────────
;;; Registered into the OPEN catalogue (legal/crossings.scm), so one symbol serves
;;; three readers: a recipe's `crossing:<x>` classification tag, a rule guard's
;;; `on-crossing`, and the law face's gloss. A jurisdiction that has said nothing
;;; about one of these still meets the catalogue's safe 'mirrored default.
;;; A way here states them; where a recipe for the way exists (its `process`)
;;; its records trip them too (legal/crossings.scm).
;;; (symbol          kind       gloss  [what the records lack, when a tag must say it])
(define-module (playnet knowledge worlds free-food-distribution)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:use-module (playnet vf schemas)
  #:use-module (playnet legal crossings)
  #:use-module (playnet legal registry)
  #:use-module (playnet vf facts places)
  #:use-module (playnet knowledge law context-pack)
  #:use-module (playnet knowledge law aspects)
  #:use-module ((playnet knowledge law way-recipes) #:select (way-recipe-crossings way-recipe-channel))
  #:export (*ffd-crossings*
            *ffd-recipes* ffd-recipe-ref *ffd-federation*
            ffd-member-list ffd-federation-name ffd-federation-aid *ffd-arcs*
            *ffd-arc-crossings* bill-union ffd-point-bill
            demand-direction bill-filter ffd-border-bill ffd-arc-components
            ffd-arc-bill *ffd-activity-crossings* ffd-bill-at))

(define *ffd-crossings*
  '((share-food      mirrored   "gives food to the public for free (a transfer, never a sale)" handover)
    (congregate-meal mirrored   "prepares and serves meals for on-site consumption" handover)
    (feed-in-public  by-choice  "distributes in a public space — park, sidewalk, plaza" where)
    (home-kitchen    by-choice  "food prepared in a private / home kitchen (cottage)" where)
    (recover-surplus mirrored   "food recovered or donated from another food operation" whose)
    (public-fridge   mirrored   "operates a publicly accessible fridge or shelf others take from" where)

    ;; ── WHAT THE FOOD IS. The crossings above are things an operation DOES;
    ;; these are properties the GOOD carries — the intrinsic facts a Stage-1 list
    ;; is written against. All 'mirrored: raw chicken is raw chicken wherever it
    ;; goes, and no arrangement of the operation makes it otherwise.
    ;;
    ;; They are placeless, like every crossing. That a jurisdiction keeps these
    ;; out of an unattended cabinet is Berlin's answer (contexts/de.sexp), not
    ;; part of the vocabulary; somewhere else may say nothing and the same good
    ;; passes. The fold is what makes the difference, so the recipe stays silent.
    (raw-meat         mirrored  "raw meat or raw sausage" food)
    (raw-fish         mirrored  "raw fish or raw seafood" food)
    (raw-eggs         mirrored  "raw eggs in shell" food)
    (raw-milk         mirrored  "raw, unpasteurised milk" food)
    (opened-packaging mirrored  "packaging or bottles already opened" state)
    (bloated-packs    mirrored  "packaging bloated with gas (soured dairy excepted)" state)
    (open-sandwich    mirrored  "belegte Brötchen — filled rolls not originally packaged and labelled" shown)
    (open-buffet      by-choice "food set out so takers can touch it — an open buffet" shown)
    (foraged-fungi    mirrored  "self-collected mushrooms, identified by the forager" food)
    (alcohol          mirrored  "alcohol, including inside confectionery" food)
    (past-use-by      mirrored  "past its Verbrauchsdatum / use-by date (NOT the advisory MHD)" state)))
(for-each (lambda (row) (apply register-crossing! row)) *ffd-crossings*)

;;; ─── recipes : the compliant PATHWAYS (operating models) ──────────────────
;;; Each pathway names the crossings it trips, the scope-model that runs it, and
;;; the aspects it PERFORMS — read off its own steps: a kitchen that is permitted
;;; and staffed by a certified handler performs the hygiene and the training; a
;;; site secured by the owner's consent and the city's registration performs the
;;; site approval a law asks for. The fold prices the crossings in the member's
;;; jurisdiction; what the members' pathways perform is the federation's ACTUAL
;;; practice in the reform diff (law/aspects.scm `register-practice!`).
;;; Each pathway names the RECIPE that is it (recipes/ways.scm, recipes/
;;; food-surplus.scm). What it trips and the channel it hands its food on by are
;;; read off that recipe (way-recipes.scm) and set beside its own words here.
(define (of-its-recipe pathway)
  (let ((id (assq-ref pathway 'recipe)))
    (append `((crossings . ,(way-recipe-crossings id))
              (channel   . ,(way-recipe-channel id)))
            pathway)))
(define *ffd-recipes*
  (map of-its-recipe
  (list
   `((id . "recipe-ffd-home-share")
     (name . "Home-kitchen direct share")
     (model . "neighbourhood mutual aid")
     (recipe . "recipe-way-home-share")
     (steps . ("cook at home" "label as homemade / uninspected" "hand directly to a neighbour"))
     (performs . (labeling))
     (note . "Lightest pathway. Legal only where a food-freedom / cottage law permits it."))
   `((id . "recipe-ffd-recovery")
     (name . "Surplus recovery & delivery")
     (model . "food-recovery network")
     (recipe . "recipe-collect-produce")            ; recipes/food-surplus.scm
     (steps . ("recover surplus from a permitted source" "sort & inspect (90% yield)" "deliver to recipient kitchens"))
     (performs . (supplier-approval safe-food-handling))
     (note . "Donation is shielded (Emerson / AB-1219). Reuses the food-surplus recipe."))
   `((id . "recipe-ffd-permitted-meal")
     (name . "Permitted congregate meal")
     (model . "community kitchen")
     (recipe . "recipe-way-permitted-meal")
     (steps . ("prep in a permitted kitchen (certified handler)" "cook" "serve on-site to all comers"))
     (performs . (handwashing temperature-control sanitation safe-food-handling hygiene-training))
     (note . "Heaviest paperwork; the model where a permit + food-handler card is unavoidable."))
   `((id . "recipe-ffd-consented-site")
     (name . "Consented-site distribution")
     (model . "registered charitable feeding")
     (recipe . "recipe-way-consented-site")
     (steps . ("secure property-owner consent" "register with the city" "distribute at the consented site"))
     (performs . (site-approval))
     (note . "For jurisdictions that gate PUBLIC feeding on consent/registration (Houston)."))
   `((id . "recipe-ffd-indoor-congregate")
     (name . "Indoor congregate meal")
     (model . "host-venue meal")
     (recipe . "recipe-way-indoor-congregate")
     (steps . ("move indoors to a host venue" "serve a sit-down meal" "no public-space distribution"))
     (performs . (overhead-protection))
     (note . "Side-steps a feed-in-public FORBID/permit by dropping the public-space crossing — a structurally different pathway.")))))

(define (ffd-recipe-ref id)
  (find (lambda (r) (equal? id (assq-ref r 'id))) *ffd-recipes*))

;;; ─── the REAL federation : member communes (scope, place, recipe) ─────────
;;; Each member is a commune of the free-food federation, located in a real
;;; jurisdiction, running the pathway that is compliant THERE. This is the
;;; scope tree (custody) — orthogonal to the place tree (geography).
(define *ffd-federation*
  `((name . "Free Food Distribution Federation")
    (aid  . "scope:ffd")           ; the federation root
    (members
     . (((scope . "Laramie Mutual Aid")        (aid . "scope:ffd.wy")
         (place . "us-56-laramie")  (recipe . "recipe-ffd-home-share"))
        ((scope . "East Bay Food Recovery")     (aid . "scope:ffd.ca")
         (place . "us-06-alameda")  (recipe . "recipe-ffd-recovery"))
        ((scope . "Bayview Community Kitchen")  (aid . "scope:ffd.ca2")
         (place . "us-06-alameda")  (recipe . "recipe-ffd-permitted-meal"))
        ((scope . "Houston Free Tables")        (aid . "scope:ffd.tx")
         (place . "us-48-houston")  (recipe . "recipe-ffd-consented-site"))
        ((scope . "Broward Food Share")         (aid . "scope:ffd.fl")
         (place . "us-12-ftlauderdale") (recipe . "recipe-ffd-indoor-congregate"))
        ((scope . "Lower East Side Kitchen")    (aid . "scope:ffd.ny")
         (place . "us-36-nyc")      (recipe . "recipe-ffd-permitted-meal"))))))

(define (ffd-member-list) (assq-ref *ffd-federation* 'members))
(define (ffd-federation-name) (assq-ref *ffd-federation* 'name))
(define (ffd-federation-aid)  (assq-ref *ffd-federation* 'aid))

;;; what the federation DOES: the aspects performed by the pathways its members
;;; run. A pathway nobody runs performs nothing yet.
(for-each (lambda (m)
            (register-practice! (or (assq-ref (ffd-recipe-ref (assq-ref m 'recipe)) 'performs) '())))
          (ffd-member-list))

;;; ─── supply ARCS : the federation moves recovered surplus across space ────
;;; Each arc is a transport activity — a column of the technology matrix that
;;; consumes a good here and produces it there. An arc whose endpoints lie in
;;; different jurisdictions trips a `border` crossing, and its bill is the
;;; UNION of both endpoints' rules plus the border demand (§2.6). These show
;;; the plan routing recovered food between member communes.
(define *ffd-arcs*
  ;; (from-place        to-place        good                 by)
  '(("us-06-alameda"   "us-32"          "recovered surplus"  "East Bay Food Recovery")   ; CA → NV  (interstate)
    ("us-56-laramie"   "us-08"          "garden surplus"     "Laramie Mutual Aid")       ; WY → CO  (interstate)
    ("us-48-houston"   "us-48"          "restaurant surplus" "Houston Free Tables")      ; TX → TX  (no border)
    ("us-06-alameda"   "mx-tijuana"     "rescued produce"    "East Bay Food Recovery")   ; US → MX  (international)
    ("us-36-nyc"       "ca-toronto"     "surplus staples"    "Lower East Side Kitchen"))); US → CA  (international)

;;; crossings a transport arc trips: it recovers surplus and shares it. The
;;; `border` crossing is added by the context constructor when endpoints diverge.
;; an arc carries recovered surplus: it trips what the recovery recipe trips
(define *ffd-arc-crossings* (way-recipe-crossings "recipe-collect-produce"))

;;; an arc's legal exterior is the UNION over its cells of each cell's own
;;; point-bill, PLUS the border crossing folded with both endpoints visible
;;; (§2.6: "union over both rule-sets"). Folding each endpoint separately keeps
;;; one side's preemptions from leaking onto the other — Nevada still owes its
;;; own permit even when the arc starts in California.
(define (bill-union . bills)
  (map (lambda (k)
         (cons k (delete-duplicates
                  (append-map (lambda (b) (bill-ref b k)) bills) demand=?)))
       %bill-keys))

;;; a point of an arc: the activity's bill there, over the arc's own crossings
(define (ffd-point-bill place-id)
  (ffd-bill-at place-id #:crossings *ffd-arc-crossings*))

(define (demand-direction d) (assq-ref (demand-detail d) 'direction))
;;; keep only the demands in a bill whose direction satisfies PRED.
(define (bill-filter bill pred)
  (map (lambda (kv) (cons (car kv) (filter (lambda (d) (pred (demand-direction d))) (cdr kv)))) bill))

(define (ffd-border-bill from-id to-id)
  (legal-demands              ; the border alone — the constructor trips `border`
   (legal-context #:crossings '()   ; ONLY when the endpoints actually cross
                  #:endpoints (list (place-chain from-id)
                                    (place-chain to-id))
                  #:act 'free-food-distribution)
   #:rules (current-legal-rules)))

;;; An arc's legal exterior, split by SIDE (§2.6 import/export):
;;;   export   — what the ORIGIN must satisfy to send (its internal bill +
;;;              export-tagged border demands: a phytosanitary certificate)
;;;   crossing — direction-neutral border demands (an interstate record)
;;;   import   — what the DESTINATION must satisfy to receive (its internal
;;;              bill + import-tagged border demands: prior notice, a duty)
;;; → (values export-bill crossing-bill import-bill hits)
(define (ffd-arc-components from-id to-id)
  (call-with-values (lambda () (ffd-point-bill from-id))
    (lambda (bf hf)
      (call-with-values (lambda () (ffd-point-bill to-id))
        (lambda (bt ht)
          (call-with-values (lambda () (ffd-border-bill from-id to-id))
            (lambda (bb hb)
              (values (bill-union bf (bill-filter bb (lambda (x) (eq? x 'export))))
                      (bill-filter bb (lambda (x) (not x)))            ; direction-neutral
                      (bill-union bt (bill-filter bb (lambda (x) (eq? x 'import))))
                      (delete-duplicates
                       (append hf ht hb)
                       (lambda (a b) (equal? (legal-rule-label a) (legal-rule-label b))))))))))))

;;; the whole arc as one union (for a single burden number).
(define (ffd-arc-bill from-id to-id)
  (call-with-values (lambda () (ffd-point-bill from-id))
    (lambda (bf hf)
      (call-with-values (lambda () (ffd-point-bill to-id))
        (lambda (bt ht)
          (call-with-values (lambda () (ffd-border-bill from-id to-id))
            (lambda (bb hb)
              (values (bill-union bf bt bb)
                      (delete-duplicates (append hf ht hb)
                        (lambda (a b) (equal? (legal-rule-label a) (legal-rule-label b))))))))))))

;;; ─── the bill for free food distribution AT a place ───────────────────────
;;; Build the legal context (jurisdiction path from the real place tree +
;;; the crossings this activity trips) and FOLD. The crossings tripped are
;;; the union of every member-recipe's crossings — the activity, fully
;;; general; a specific member's pathway trips only its own subset.
;; the activity trips what its pathways trip, each once
(define *ffd-activity-crossings*
  (delete-duplicates (append-map (lambda (r) (assq-ref r 'crossings)) *ffd-recipes*)))

(define* (ffd-bill-at place-id #:key (crossings *ffd-activity-crossings*))
  "→ (values bill hits) : the derived legal exterior of free food distribution
   at PLACE-ID, folded over the law in force (`current-legal-rules`). CROSSINGS
   defaults to the full activity (every pathway's crossings); a pathway's own
   crossings give its bill."
  (bill-at place-id crossings #:act 'free-food-distribution #:regimes? #f))
