;;; test-comms.scm — the deterministic communications core (NO AI).
;;;
;;; Proves comms is a fold over the plan's own diagnostics: an under-satisfied
;;; ValueFlows <intent> (total-satisfied < total-desired) becomes a citable,
;;; factual post skeleton, and a Stage-3 entailment fence rejects any AI restyle
;;; that invents a fact. No new schema — just <intent> + <satisfaction-state>.
;;;
;;; Run: guile -L module tests/planner/test-comms.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness) (playnet vf schemas) (playnet observation states) (srfi srfi-1) (srfi srfi-13))

(define here (dirname (current-filename)))
(define root (dirname (dirname here)))
(use-modules (playnet comms plan))

;; ─── helpers : build real <intent> + <satisfaction-state> records ───────────
;; make-intent is a 28-field positional constructor; wrap it with keywords.
(define* (mk-intent id #:key (action 'produce) (name #f) (conforms #f)
                    (classified '()) (receiver #f) (scope '()))
  (make-intent
   #:id id #:action action #:name name          ; id action name note image
                          ; input-of output-of
 #:resource-conforms-to conforms #:resource-classified-as classified         ; resource-inventoried-as conforms classified-as
                    ; resource-qty effort-qty available-qty minimum-qty
 #:receiver receiver                    ; provider receiver
                 ; has-beginning has-end has-point-in-time due at-location
                          ; stage state
 #:in-scope-of scope))            ; planned-within satisfies in-scope-of finished avail-window

(define* (mk-sat iid desired satisfied #:key (unit "kg") (finished #f) (plan "plan-1"))
  (make-satisfaction-state iid
                           (make-measure desired unit)
                           (make-measure satisfied unit)
                           '() '() finished plan))

;; A plan snapshot: three needs — a short good, a MET good, a short labour need,
;; plus a below-floor need (tagged) to exercise kind classification.
(define i-food (mk-intent "intent-food" #:action 'produce
                          #:name "Community Meal" #:conforms "spec:meal"))
(define i-water (mk-intent "intent-water" #:action 'produce #:name "Water"))
(define i-cook (mk-intent "intent-cook" #:action 'work #:name "cook-hours"))
(define i-floor (mk-intent "intent-floor" #:action 'produce #:name "Calories"
                           #:classified '("reproduction-floor")))

(define s-food (mk-sat "intent-food" 52 40))              ; short 12
(define s-water (mk-sat "intent-water" 10 10))            ; satisfied
(define s-cook (mk-sat "intent-cook" 8 6 #:unit %effort-unit)) ; short 2
(define s-floor (mk-sat "intent-floor" 2000 1500 #:unit "kcal")) ; short 500

(define all-intents (list i-food i-water i-cook i-floor))
(define all-sats     (list s-food s-water s-cook s-floor))

;;; ─── 1. derivation is deterministic — only the short needs, correctly kinded
(display "\n── Stage 0: plan->comm-intents folds only the under-satisfied ──\n")
(define derived (plan->comm-intents all-intents all-sats))
(check "the satisfied need (water) is dropped; the three short ones remain"
       (map intent-id derived)
       '("intent-food" "intent-cook" "intent-floor"))
(check "a produced-good shortfall is a call-to-action" (comm-kind i-food) 'call-to-action)
(check "an unfilled labour need is recruitment"        (comm-kind i-cook) 'recruitment)
(check "a below-floor need mobilizes (tag wins over action)"
       (comm-kind i-floor) 'mobilization)
(check "the gap is desired − satisfied, in the desired unit"
       (list (measure-has-numerical-value (intent-gap i-food s-food))
             (measure-has-unit (intent-gap i-food s-food)))
       '(12 "kg"))
(check "a met need has no gap" (intent-gap i-water s-water) #f)

;;; ─── 1b. derived selection — rank by shadow price, gated by recruitability ──
(display "\n── Stage 1: rank-comm-intents sorts by the solver's dual, gated ──\n")
;; a hard physical cap (a `use` of an aquifer no volunteer can refill) — high dual
;; but NOT recruitable, so it must be dropped however valuable relieving it is.
(define i-hard (mk-intent "intent-hard" #:action 'use #:name "Aquifer"
                          #:classified '("hard-constraint")))
;; the solver's dual vector, as a lookup (below-floor is worth most to relieve):
(define duals '(("intent-floor" . 10.0) ("intent-food" . 5.0)
                ("intent-cook" . 2.0) ("intent-hard" . 100.0)))
(define (dual-of id) (let ((p (assoc id duals))) (and p (cdr p))))
(define ranked (rank-comm-intents (list i-food i-cook i-floor i-hard) dual-of))
(check "ranked most-valuable-first by dual; the hard cap is gated out"
       (map (lambda (p) (intent-id (car p))) ranked)
       '("intent-floor" "intent-food" "intent-cook"))
(check "the top pick is the below-floor need (highest marginal reproduction value)"
       (cdr (car ranked)) 10.0)
(check "a recruitable labour gap counts" (intent-recruitable? i-cook) #t)
(check "a hard physical cap is NOT recruitable (dropped despite dual 100)"
       (intent-recruitable? i-hard) #f)
(check "the hard cap's posting priority is 0, not its dual"
       (intent-priority i-hard dual-of) 0.0)

;;; ─── 2. the skeleton is factual + citable (deterministic, no AI) ────────────
(display "\n── Stage 2: render-skeleton carries the number and the citation ──\n")
(define sk (render-skeleton i-food s-food))
(check "the skeleton states the shortfall number" (and (string-contains sk "12") #t) #t)
(check "the skeleton carries the provenance citation"
       (and (string-contains sk "[cite:intent-food]") #t) #t)
(check "the skeleton names the subject" (and (string-contains sk "Community Meal") #t) #t)
(check "a recruitment skeleton reads as a labour ask"
       (and (string-contains (render-skeleton i-cook s-cook) "We need 2 hours") #t) #t)

;;; ─── 3. the entailment fence bites (Stage 3 guard, still no AI) ─────────────
(display "\n── Stage 3 fence: entails-skeleton? rejects invented facts ──\n")
(define faithful   "🥕 We're 12 kg short of the Community Meal this week — bring what you can! [cite:intent-food]")
(define fabricated "🚨 We're 25 kg short — a huge crisis! [cite:intent-food]")
(define dropped    "We're 12 kg short of the meal, please help!")   ; citation dropped
(check "a faithful restyle (same number, citation kept) passes"
       (entails-skeleton? sk faithful) #t)
(check "a restyle that invents a new number is rejected"
       (entails-skeleton? sk fabricated) #f)
(check "a restyle that drops the citation is rejected"
       (entails-skeleton? sk dropped) #f)
(check "the dry skeleton trivially entails itself (the always-valid fallback)"
       (entails-skeleton? sk sk) #t)

;;; ─── 4. Stage 0→2 as one fold — the whole deterministic pipeline ────────────
(display "\n── plan->skeletons: the campaign falls out of the plan in one call ──\n")
(define skels (plan->skeletons all-intents all-sats))
(check "one skeleton per under-satisfied intent (water dropped)" (length skels) 3)
(check "the food skeleton leads and carries its number + citation"
       (and (string-contains (car skels) "12")
            (string-contains (car skels) "[cite:intent-food]") #t) #t)
(check "the labour skeleton reads as recruitment"
       (and (string-contains (cadr skels) "We need 2 hours") #t) #t)
(check "the below-floor skeleton mobilizes"
       (and (string-contains (caddr skels) "under the floor") #t) #t)

;;; ─── 5. extension kinds (broadcast) + injectable recruitability ────────────
(display "\n── broadcast kinds: offer / proof / celebration / education ──\n")
(define an-offer (broadcast-intent "recipe:biochar" 'offer "Biochar (sequesters carbon)"))
(check "a broadcast intent classifies by its kind tag" (comm-kind an-offer) 'offer)
(check "an offer renders without a shortfall number, citably"
       (and (string-contains (render-skeleton an-offer #f) "Biochar")
            (string-contains (render-skeleton an-offer #f) "[cite:recipe:biochar]") #t) #t)
(check "a proof renders as a done deed"
       (and (string-contains (render-skeleton (broadcast-intent "e:1" 'proof "composted 50 kg") #f) "Done:") #t) #t)
(check "injectable recruitable? can veto (a strict predicate drops everything)"
       (rank-comm-intents (list i-food) (lambda (_) 5.0) #:recruitable? (lambda (_) #f)) '())

;;; ─── 6. the IG card renderer (skeleton → SVG) ──────────────────────────────
(use-modules (playnet comms card))
(display "\n── render-post-card: a deterministic SVG card ──\n")
(define card (render-post-card "Short 12 kg for Saturday's share! [cite:intent-food]"))
(check "the card is an SVG" (and (string-prefix? "<svg" card) #t) #t)
(check "it embeds the (wrapped) post text" (and (string-contains card "Saturday") #t) #t)
(check "it xml-escapes special chars"
       (and (string-contains (render-post-card "a & b < c") "&amp;") #t) #t)

(display "\n")
(test-summary!)
