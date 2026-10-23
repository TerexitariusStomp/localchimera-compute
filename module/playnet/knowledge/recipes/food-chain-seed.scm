;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; food-chain-seed.scm — ONE generic seeder for a food chain: reclaim → store →
;;; distribute, as VF records the convex planner solves directly.
;;;
;;; The structural twin of farm-commune-seed.scm. A chain is DATA — its stages,
;;; their durations and yields, the vehicles and containers they draw on, and the
;;; crossings each end trips — and the mechanism (specs, processes, flows, the
;;; recipe that ties them together) is shared. food-surplus.scm and cold-chain.scm
;;; are the SF-derived configurations; a Berlin one is another data file.
;;;
;;; ── WHAT THE PLANNER SEES ────────────────────────────────────────────────
;;; Each stage is one <recipe-process> — one column of the technology matrix —
;;; consuming the previous good and producing the next at its yield. Two kinds:
;;;
;;;   'transform  consume good_i (qty) → produce good_{i+1} (qty × yield),
;;;               `use`ing whatever it draws on and `work`ing the chain's skill.
;;;               The ordinary space-tiled column.
;;;   'store      `move` the good through a keep-in-place container it `use`s.
;;;               planner.scm's proc-temporal? reads the arc off the CONTAINER,
;;;               so the engine tiles this column along the TIME edge — a real
;;;               storage column that carries its own costs, with no #:storable
;;;               keyword anywhere (test-store-recipe.scm proves the mechanism).
;;;
;;; ── WHAT THE LEGAL FOLD SEES ─────────────────────────────────────────────
;;; Nothing here names a jurisdiction. A chain declares the CROSSINGS it trips —
;;; intrinsic, placeless facts — as `crossing:<x>` classification tags, on the
;;; intake and outlet goods (`#:intake-crossings` / `#:outlet-crossings`) or on a
;;; single stage's own flow (`#:crossings`). legal/crossings.scm reads them off the real
;;; records, legal/gate.scm folds them against the place the cell sits in, and the
;;; bill comes out per jurisdiction. The same chain therefore meets Wyoming's
;;; food-freedom notice and Berlin's §43 IfSG Belehrung without one line of law
;;; living in the recipe.
;;;
;;; Loaded before the per-context configurations. Every
;;; `$` is a near-call, so call within the recipe-store's vat.

;;; ─── a STAGE, as data ─────────────────────────────────────────────────────
;;; uses : ((spec-id qty unit label) …) — what the stage draws on for a batch.
;;;        A 'store stage's uses are its CONTAINERS (registered keep-in-place).
;;; crossings : symbols this stage itself trips (a public-space handout, a meal
;;;        served on site) — tagged on the stage's own flow, not on a good.
(define-module (playnet knowledge recipes food-chain-seed)
  #:use-module (srfi srfi-1)
  #:use-module (playnet vf schemas)
  #:use-module ((playnet knowledge recipes transport) #:select (pickup-flow dropoff-flow))
  #:use-module ((playnet utils units) #:select (time-unit? %effort-unit))
  #:use-module (goblins)
  #:use-module ((playnet knowledge recipes handover) #:select (state-exchange!))
  #:export (food-stage stage-ref crossing-tags food-spec! seed-food-chain!))

(define* (food-stage id label #:key (kind 'transform) (hours #f) (yield 1.0)
                                    (uses '()) (crossings '()) (channel #f)
                                    (good #f) (good-name #f))
  `((id . ,id) (label . ,label) (kind . ,kind) (hours . ,hours) (yield . ,yield)
    (uses . ,uses) (crossings . ,crossings) (channel . ,channel)
    (good . ,good) (good-name . ,good-name)))

(define (stage-ref s k) (assq-ref s k))

;;; ─── helpers ──────────────────────────────────────────────────────────────
(define (crossing-tags crossings)
  (map (lambda (c) (string-append "crossing:" (if (symbol? c) (symbol->string c) c)))
       crossings))

(define* (food-spec! rs id name unit #:key (classes '()) (keep-in-place #f))
  ($ rs 'add-resource-spec
     (make-resource-specification #:id id #:name name #:resource-classified-as (if (null? classes) #f classes)
                                  #:default-unit-of-resource unit #:keep-in-place keep-in-place))
  id)

;;; ─── the seeder ───────────────────────────────────────────────────────────
;;; intake/outlet are (spec-id name) pairs — the good that enters the chain and
;;; the good that leaves it. Stages between them name their own intermediate
;;; goods, or take a generated one.
(define* (seed-food-chain! rs
          #:key (id "food-chain") (name "Food chain")
                (intake "spec-intake") (intake-name "Intake good")
                (outlet "spec-outlet") (outlet-name "Outlet good")
                (unit "kg") (batch 100.0)
                (classes '("food"))
                (intake-crossings '()) (outlet-crossings '())
                ;; the chain's two ends, as exchanges: RECEIVED says how the
                ;; intake comes in, HANDED-OVER how the outlet goes out —
                ;; 'gift (nothing passes the other way), 'sale (money does;
                ;; MONEY names the spec), or #f (the chain states neither)
                (received #f) (handed-over #f) (money "spec-eur")
                (work #f) (work-name "Chain labour")
                (stages '()))
  "Seed a reclaim → store → distribute chain into RS. Returns the recipe id."
  (when (null? stages) (error "seed-food-chain!: a chain needs at least one stage" id))

  ;; the two ends: the goods that carry the chain's crossings
  (food-spec! rs intake intake-name unit
              #:classes (append classes (crossing-tags intake-crossings)))
  (food-spec! rs outlet outlet-name unit
              #:classes (append classes (crossing-tags outlet-crossings)))
  (when work (food-spec! rs work work-name %effort-unit))
  (when received
    (state-exchange! rs (string-append id "/received") (string-append intake-name ", received")
                     #:money (and (eq? received 'sale) money)))
  (when handed-over
    (state-exchange! rs (string-append id "/handed-over") (string-append outlet-name ", handed over")
                     #:money (and (eq? handed-over 'sale) money)))

  ;; every `use` spec a stage draws on, registered once. A 'store stage's
  ;; containers are stationary — that is what makes its column tile through time.
  ;; A DRAW'S UNIT IS NOT A STOCK'S UNIT, and a stage knows only the first. The
  ;; row `("spec-bt-cargo-bike" 0.75 "hours" …)` says a pickup OCCUPIES the bike
  ;; for three quarters of an hour; it says nothing about the bike being counted
  ;; in hours, and a Lastenrad is one Lastenrad. Claiming otherwise here is how
  ;; the same spec id came to be denominated `hours` by this chain and `each` by
  ;; the transit shed — one object, two catalogues, two answers.
  ;;
  ;; So a means gets a spec only when nobody has declared one, and even then this
  ;; states no unit: the chain registers that the thing EXISTS, and leaves what it
  ;; is counted in to whoever owns the means. A scope that declares its own specs
  ;; keeps them.
  (for-each
   (lambda (s)
     (for-each (lambda (u)
                 (unless ($ rs 'get-resource-spec (car u))
                   (food-spec! rs (car u) (or (list-ref u 3) (car u)) #f
                               #:keep-in-place (eq? 'store (stage-ref s 'kind)))))
               (map (lambda (u) (list (car u) (cadr u)
                                      (if (> (length u) 2) (list-ref u 2) %effort-unit)
                                      (if (> (length u) 3) (list-ref u 3) #f)))
                    (stage-ref s 'uses))))
   stages)

  ;; walk the stages, threading the good: each transform hands its output on as
  ;; the next stage's input; the last transform lands on `outlet`.
  (let* ((n (length stages))
         (transforms (filter (lambda (s) (eq? 'transform (stage-ref s 'kind))) stages))
         (last-transform (and (pair? transforms) (last transforms)))
         (first-transform (and (pair? transforms) (car transforms))))
    (let loop ((rest stages) (i 0) (in-good intake) (pids '()))
      (if (null? rest)
          (begin
            ($ rs 'add-recipe
               (make-recipe #:id id #:name name #:primary-output outlet #:recipe-processes (reverse pids)
                            #:recipe-exchanges (let ((rxs (append (if received (list (string-append id "/received")) '())
                                               (if handed-over (list (string-append id "/handed-over")) '()))))
                              (and (pair? rxs) rxs))))
            id)
          (let* ((s (car rest))
                 (pid (string-append id "/" (stage-ref s 'id)))
                 (store? (eq? 'store (stage-ref s 'kind)))
                 (hours (stage-ref s 'hours))
                 ;; the stage's own declarations, on its own flow: the crossings it
                 ;; trips and the CHANNEL it hands the good on by. Both are read by
                 ;; legal/crossings.scm off the real record; neither names a jurisdiction.
                 (tags (let* ((c (crossing-tags (stage-ref s 'crossings)))
                              (ch (stage-ref s 'channel))
                              (all (if ch
                                       (cons (string-append "channel:" (symbol->string ch)) c)
                                       c)))
                         (if (null? all) #f all)))
                 ;; a store stage keeps the good it holds; a transform hands on a
                 ;; new one — the outlet for the last transform, else its own.
                 (out-good (cond (store? in-good)
                                 ((eq? s last-transform) outlet)
                                 (else (or (stage-ref s 'good)
                                           (string-append id "/good-" (stage-ref s 'id))))))
                 (out-qty (* batch (or (stage-ref s 'yield) 1.0))))

            ;; the intermediate good, when this stage invents one
            (unless (or store? (member out-good (list outlet intake)))
              (food-spec! rs out-good
                          (or (stage-ref s 'good-name) (stage-ref s 'label)) unit
                          #:classes classes))

            ($ rs 'add-recipe-process
               (make-recipe-process #:id pid #:name (stage-ref s 'label)
                                    #:has-duration (and hours (make-duration hours %effort-unit))))

            (if store?
                ;; PICK UP the good here and DROP IT OFF there — the pair that
                ;; builds a real relocation arc. Through a keep-in-place container
                ;; that arc runs along the TIME edge, so the good arrives in the
                ;; next period. (A bare `move` flow only marks the good movable and
                ;; builds no arc at all — compile-process routes `move` to `moved`
                ;; and only pickup/dropoff to `relocated`, which is the slot the
                ;; transport branch reads. A store stage written with `move` runs a
                ;; free column and carries nothing.) The pair itself is
                ;; transport.scm's own pickup-flow/dropoff-flow — the shape
                ;; `recipe-hold` composes from — so this is the one place either
                ;; is spelled out, not a second derivation of it. `#:primary #f`
                ;; because a mid-chain store stage hands its good on, unlike
                ;; `recipe-hold`'s own dropoff, which is always the whole
                ;; recipe's output.
                (begin
                  ($ rs 'add-recipe-flow
                     (pickup-flow  (string-append pid "-pickup")  in-good batch unit pid #:tags tags))
                  ($ rs 'add-recipe-flow
                     (dropoff-flow (string-append pid "-dropoff") in-good batch unit pid #:primary #f)))
                (begin
                  ($ rs 'add-recipe-flow
                     ;; the first transform takes the intake in: the receipt
                     (make-recipe-flow #:id (string-append pid "-in") #:action 'consume #:resource-conforms-to in-good
                                       #:resource-quantity (make-measure batch unit) #:recipe-input-of pid
                                       #:recipe-clause-of (and received (eq? s first-transform)
                                            (string-append id "/received"))))
                  ($ rs 'add-recipe-flow
                     ;; the last transform makes the outlet: the handover
                     (make-recipe-flow #:id (string-append pid "-out") #:action 'produce #:resource-conforms-to out-good #:resource-classified-as tags
                                       #:resource-quantity (make-measure out-qty unit) #:recipe-output-of pid
                                       #:recipe-clause-of (and handed-over (eq? s last-transform)
                                            (string-append id "/handed-over"))))))

            ;; What the stage draws on, said the way a `use` has to be said:
            ;; occupy COUNT of the thing for HOURS. A row already denominated in
            ;; time IS the duration and stays in the effort slot; a row counting
            ;; things — four containers, one pair of gloves — is a COUNT, and the
            ;; hours it occupies them for are the stage's own.
            ;;
            ;; The distinction is not cosmetic. An effort in a non-time unit reads
            ;; as a plain multiplier and the run is taken to hold the thing for the
            ;; WHOLE PERIOD, so four containers borrowed for a 45-minute Abholung
            ;; and handed back were charged as four containers standing idle all
            ;; day — 32 times their real occupancy, and enough to make a shared kit
            ;; the binding constraint on a 60 kg handout.
            (for-each
             (lambda (u)
               (let* ((qty  (cadr u))
                      (unit (if (> (length u) 2) (list-ref u 2) %effort-unit))
                      (duration? (time-unit? unit)))
                 ($ rs 'add-recipe-flow
                    (make-recipe-flow #:id (string-append pid "-use-" (car u)) #:action 'use #:resource-conforms-to (car u)
                                      #:resource-quantity (and (not duration?) (make-measure qty unit))
                                      #:effort-quantity (if duration?
                                          (make-measure qty unit)
                                          (and hours (make-measure hours %effort-unit)))
                                      #:recipe-input-of pid))))
             (stage-ref s 'uses))
            (when (and work hours)
              ($ rs 'add-recipe-flow
                 (make-recipe-flow #:id (string-append pid "-work") #:action 'work
                                   #:resource-conforms-to work
                                   #:effort-quantity (make-measure hours %effort-unit)
                                   #:recipe-input-of pid)))

            (loop (cdr rest) (+ i 1) out-good (cons pid pids)))))))
