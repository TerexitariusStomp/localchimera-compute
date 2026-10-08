;;; test-distribution-channel.scm — a distribution mode is a recipe, and the
;;; composition of modes is something the solver finds.
;;;
;;; `distribution-mode` is carried today as a declared property of a resource
;;; (schemas.scm), read after the solve by the accounting, the custody rule and
;;; the dial. legal/crossings.scm already says the truer thing about it — "a crossing
;;; says WHAT an act is; a CHANNEL says HOW the good reaches a person" — and a
;;; *how it reaches a person* is a process, with its own labour and its own
;;; means, not an attribute of the thing that reaches them.
;;;
;;; Written as a recipe it needs nothing the engine does not already have. Put a
;;; process between production and the want, and move the want onto the good the
;;; process delivers:
;;;
;;;     make-machine                        →  machine
;;;     machine + household labour          →  clean-laundry     (individual)
;;;     machine + attendant + Svc|laundrette →  clean-laundry     (communal)
;;;
;;; Same terminal good, two ways of reaching it, and the solver chooses.
;;;
;;; ── WHY THE TWO CHANNELS DIFFER, AND WHY THAT IS STILL CONVEX ───────────────
;;; The difference between the rails is not that one is cheaper. It is a change
;;; of DENOMINATION: a private machine is claimed as a thing and stands idle
;;; between loads, while a communal one is drawn on as CAPACITY and is idle for
;;; nobody. So the machines-per-load coefficient differs by the utilisation ratio
;;; — here 1/400 against 1/2000 — and the sharing shows up as a smaller input
;;; coefficient rather than as a return to scale. That is the whole convexity
;;; argument: denominated in capacity, twenty people sharing one machine is a
;;; LINEAR draw on a pool, not an economy of scale, and the column stays a
;;; column. (utils/capacity.scm carries the stock→capacity conversion this
;;; leans on.)
;;;
;;; What communal spends instead is the user's time getting there, and a means
;;; that individual laundry does not need at all: the laundrette itself, whose
;;; service is capped. Those two are what stop the answer being a corner.
;;;
;;; The four checks below are the argument:
;;;   1. with the laundrette roomy, the plan is communal — sharing the machines
;;;      is worth the walk
;;;   2. make the walk long enough and it is individual — no rail is favoured a
;;;      priori, the coefficients decide
;;;   3. cap the laundrette and the answer is a COMPOSITION — communal to the
;;;      capacity, individual for the rest. This is the result the declared-tag
;;;      reading cannot state: the rail is not a property of laundry, it is a
;;;      quantity per channel.
;;;   4. a scope may still DECLARE the rail — by pruning the column, not by
;;;      weighting the objective — and the cost of that declaration is then
;;;      legible as an unmet want rather than hidden in a preference.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-distribution-channel.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner knowledge dsl shorthand))
(use-modules (playnet test planner prelude)
             (playnet planner solve engine)
             (playnet planner solve compile)
             (playnet planner vf schemas))

;;; A barrier method sits INSIDE its feasible set, so a channel that the optimum
;;; would run to zero or to its ceiling is found near zero and near the ceiling.
;;; The checks below therefore read shares, not corners — 2 loads out of 200 on a
;;; channel is that channel switched off.
(define (near? a b) (< (abs (- a b)) 0.5))
(define (share? part whole f) (> (/ part whole) f))
(define PLACE "town")
(define LOADS 200.0)          ; the want: clean laundry, in loads over the period
;;; Room enough that the laundrette never binds — 1000 h ÷ 0.2 h/load = 5000
;;; loads against a want of 200. It is stated rather than omitted because an
;;; UNCAPPED `Svc|` here is unsupplied rather than free (container-pool-test:
;;; "off the line the service is unsupplied, not free"), which would switch the
;;; communal channel off for a reason that has nothing to do with the question.
(define AMPLE 1000.0)

;;; ── the recipes ─────────────────────────────────────────────────────────────
;;; A machine is 25 hours of somebody's work, on either rail. Nothing about the
;;; channel changes what a machine costs to build; the channels differ in how
;;; many of them a load needs, and in what else it spends.
(define (make-machine-tpl)
  (car (compile-recipe (list (rp "mk" "Make machine"))
         (list (out/u "m1" "machine" 1.0 "each" "mk")
               (wrk "m2" 25.0 "mk")))))

;;; INDIVIDUAL-CLAIMABLE — the machine is claimed, kept, and used by one
;;; household. It sits idle between loads, so a load carries 1/400 of a machine.
;;; The labour is the household's own, and there is no journey.
(define (individual-tpl)
  (car (compile-recipe (list (rp "wash-ind" "Wash at home"))
         (list (out/u "i1" "clean-laundry" 1.0 "each" "wash-ind")
               (in/u  "i2" "machine" 0.0025 "each" "wash-ind")
               (wrk   "i3" 0.15 "wash-ind")))))

;;; COMMUNAL — the machine is drawn on as capacity. It is idle for nobody, so a
;;; load carries 1/2000 of a machine; an attendant's work replaces some of the
;;; household's; the laundrette's service is `use`d and returns whole; and TRAVEL
;;; is the household's time, spent, and so stated as work.
(define (communal-tpl travel)
  (car (compile-recipe (list (rp "wash-com" "Wash at the laundrette"))
         (list (out/u "c1" "clean-laundry" 1.0 "each" "wash-com")
               (in/u  "c2" "machine" 0.0005 "each" "wash-com")
               (wrk   "c3" (+ 0.05 travel) "wash-com")
               (use* "c4" "laundrette" "wash-com" 0.2 #:qty 1.0)))))

;;; A SECOND want, competing for the same hours. Nothing to do with laundry —
;;; it is here so that scarcity has somewhere to fall, which is the only
;;; condition under which a floor and a desire behave differently at all.
(define (bake-tpl)
  (car (compile-recipe (list (rp "bake" "Bake"))
         (list (out/u "b1" "bread" 1.0 "each" "bake")
               (wrk "b2" 0.3 "bake")))))
(define LOAVES 100.0)

;;; ── the solve ───────────────────────────────────────────────────────────────
;;; TRAVEL     hours the household spends reaching the laundrette, per load
;;; ROOM       laundrette-hours available
;;; CHANNELS   which columns exist at all — the governance knob (check 4)
;;; LABOUR     the hours the place has
;;; FLOOR      when set, laundry is METERED AS A NEED: a hard minimum instead of
;;;            a soft desire. Applied the way plan-from-records applies
;;;            #:repro-floors — a deficit on the good's on-hand, so the ≥0
;;;            balance every good already carries forces the plan to provision
;;;            it. No new tension kind, and no weight to outbid.
;;; BREAD?     put the competing want in the world
(define* (run #:key (travel 0.05) (room AMPLE) (channels '(individual communal))
              (labour 100000.0) (floor #f) (bread? #f))
  (declare-world! #:places (list (list PLACE 0.0 0.0))
                  #:templates
                    (append (list (make-machine-tpl))
                            (if bread? (list (bake-tpl)) '())
                            (filter-map (lambda (c)
                                          (case c
                                            ((individual) (individual-tpl))
                                            ((communal)   (communal-tpl travel))
                                            (else #f)))
                                        channels)))
  (hash-set! *A* (cell PLACE 0) labour)
  (hash-set! *cap* (lg (svc-good "laundrette") (cell PLACE 0)) room)
  (when bread? (hash-set! *demand* (lg "bread" (cell PLACE 0)) LOAVES))
  ;; laundry is metered EITHER as a want (a desire that can be traded away) OR as
  ;; a need (a floor that cannot). The two are exclusive: a floor already forces
  ;; the quantity, and a desire on top of it would only add a weight to a
  ;; question that no longer has one.
  (if floor
      (hash-set! *init* (lg "clean-laundry" (cell PLACE 0)) (- floor))
      (hash-set! *demand* (lg "clean-laundry" (cell PLACE 0)) LOADS))
  (call-with-values solve-located
    (lambda (x idx)
      (let ((V (Vof x idx)))
        (list (cons 'individual (V (string-append "p|wash-ind|"  PLACE "@0")))
              (cons 'communal   (V (string-append "p|wash-com|"  PLACE "@0")))
              (cons 'machines   (V (string-append "p|mk|"        PLACE "@0")))
              (cons 'bread      (V (string-append "p|bake|"      PLACE "@0"))))))))

(define (chan r k) (or (assq-ref r k) 0.0))
(define (served r) (+ (chan r 'individual) (chan r 'communal)))
(define (report label r)
  (format #t "    ~a~vt individual ~6,1f · communal ~6,1f · machines ~5,2f~%"
          label 22 (chan r 'individual) (chan r 'communal) (chan r 'machines)))

;;; ════════════════════════════════════════════════════════════════════════════
(format #t "~%── 1. a short walk: the plan shares the machines ──~%~%")

;;; Per load, individual spends 0.15 h of the household's own work and 1/400 of a
;;; machine (0.0625 h of embodied work); communal spends 0.05 + the walk, and
;;; 1/2000 of a machine (0.0125 h). At a 0.05 h walk the communal column is
;;; cheaper in total labour, and κ (the free-time weight) is what notices.
(define roomy (run #:travel 0.05))
(report "walk 0.05 h" roomy)
(check "the want is met" (near? LOADS (served roomy)))
(check "…on the communal channel" (share? (chan roomy 'communal) LOADS 0.95))

(format #t "~%── 2. a long walk: the plan hands them out ──~%~%")

;;; Nothing about the rails is preferred a priori. Raise the journey past the
;;; crossing point — the machine labour communal saves is 0.05 h per load, so a
;;; walk over ~0.15 h costs more than it saves — and the same solver, the same
;;; recipes, choose the other rail.
(define far (run #:travel 0.40))
(report "walk 0.40 h" far)
(check "the want is still met" (near? LOADS (served far)))
(check "…now on the individual channel" (share? (chan far 'individual) LOADS 0.95))

;;; And the machines are what the choice is ABOUT. The same 200 loads, reached
;;; the two ways, is the same want costing a different stock of means — which is
;;; the sentence a declared tag on the laundry cannot say.
(format #t "    machines for the same 200 loads: shared ~,3f · claimed ~,3f~%"
        (chan roomy 'machines) (chan far 'machines))
(check "sharing reaches the same want on a fraction of the machines"
       (< (chan roomy 'machines) (* 0.4 (chan far 'machines))))

(format #t "~%── 3. a capped laundrette: the answer is a COMPOSITION ──~%~%")

;;; The laundrette is a means with a capacity, and 0.2 h of it goes into a load.
;;; 20 laundrette-hours therefore reach 100 loads, and the remaining 100 have to
;;; come off the other rail. Neither mode is THE mode for laundry; each is a
;;; quantity, and the split is where the capacity runs out.
(define mixed (run #:travel 0.05 #:room 20.0))
(report "20 laundrette-h" mixed)
(check "the want is met in full"       (near? LOADS (served mixed)))
(check "communal fills to the capacity — 20 h ÷ 0.2 h/load = 100 loads"
       (< (abs (- 100.0 (chan mixed 'communal))) 5.0))
(check "…and the rest is claimed individually"
       (< (abs (- 100.0 (chan mixed 'individual))) 5.0))
(check "both channels carry a real quantity — the rail is not a property of laundry"
       (and (share? (chan mixed 'individual) LOADS 0.25)
            (share? (chan mixed 'communal)   LOADS 0.25)))

(format #t "~%── 4. a scope may still DECLARE the rail — by pruning the column ──~%~%")

;;; The political question is not settled by the solver, and must not be. A scope
;;; that says "laundry is communal here" removes the other column; what it may
;;; NOT do is tell the objective to prefer communal, because a preference hides
;;; the cost inside the optimum. Pruned, the cost surfaces where it belongs — as
;;; a want the capacity cannot reach.
(define declared (run #:travel 0.05 #:room 20.0 #:channels '(communal)))
(report "communal only" declared)
(check "no individual claim is planned at all" (near? 0.0 (chan declared 'individual)))
(check "communal still runs to its capacity"
       (< (abs (- 100.0 (chan declared 'communal))) 5.0))
(check "…and the declaration's price is a legible shortfall, not a hidden preference"
       (< (served declared) (- LOADS 50.0)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; THE SECOND AXIS — how a claim is METERED, which is not how a good TRAVELS
;;; ════════════════════════════════════════════════════════════════════════════
;;; Everything above varies the channel. The channel is a technical question:
;;; utilisation against travel, answered by coefficients. It is NOT the question
;;; The question is by what standard a person's claim is measured — and the
;;; engine answers that one somewhere else entirely, in the KIND of tension a
;;; want carries:
;;;
;;;   `des`         a desire. Priced in Σ w_d g_d² against every other desire,
;;;                 and therefore tradeable — it can be partly abandoned when the
;;;                 hours run short. A want.
;;;   repro-floor   a deficit on the good's on-hand, defended by the ≥0 balance
;;;                 every good already carries. Nothing outbids a balance. A need.
;;;
;;; Those two axes are INDEPENDENT, and the sections below are the demonstration.
;;; A need can be met on the individual rail (drawn to your own hands, and not
;;; rationed by your credit); a want can be served communally. Contribution and
;;; need are a property of the METERING; individual and communal are a property
;;; of the CHANNEL. The lower and higher phases run the diagonal of that square,
;;; which is why they read as one axis until an engine holds both.
;;;
;;; Scarcity is what tells them apart, so from here the hours are short: 40 h
;;; against 52.5 h of fully-served want (22.5 h of communal laundry + 30 h of
;;; bread). Something has to give, and WHICH thing gives is the whole question.

(format #t "~%── 5. laundry as a WANT: it gives way ──~%~%")

(define squeezed 40.0)
(define as-want (run #:labour squeezed #:bread? #t))
(format #t "    soft desire         laundry ~6,1f/~a · bread ~6,1f/~a~%"
        (served as-want) LOADS (chan as-want 'bread) LOAVES)
(check "both wants are trimmed — the hours are shared out by relative gap"
       (and (< (served as-want) (- LOADS 20.0))
            (< (chan as-want 'bread) (- LOAVES 10.0))))

(format #t "~%── 6. laundry as a NEED: it does not ──~%~%")

;;; The same world, the same hours, the same recipes. Only the KIND of the
;;; laundry tension changes — and a floor is not a louder desire, it is a
;;; quantity no desire can bid against. So the trimming falls entirely on bread.
(define as-need (run #:labour squeezed #:bread? #t #:floor LOADS))
(format #t "    repro-floor         laundry ~6,1f/~a · bread ~6,1f/~a~%"
        (served as-need) LOADS (chan as-need 'bread) LOAVES)
(check "the floor is provisioned in full" (share? (served as-need) LOADS 0.99))
(check "…without being given a bigger weight — it is a balance, not a priority"
       (> (served as-need) (served as-want)))
(check "and the shortfall lands entirely on the want beside it"
       (< (chan as-need 'bread) (chan as-want 'bread)))

(format #t "~%── 7. the two axes are independent ──~%~%")

;;; The floor says WHAT is owed. The channel says what meeting it costs. Vary the
;;; channel under a fixed floor and the floor is met every time — on the communal
;;; rail, on the individual rail, at whatever price each exacts. Fifty hours now,
;;; so that the individual rail's 42.5 h is affordable at all.
(define roomier 50.0)
(define need-shared  (run #:labour roomier #:bread? #t #:floor LOADS))
(define need-claimed (run #:labour roomier #:bread? #t #:floor LOADS
                          #:channels '(individual)))
(format #t "    need, shared        laundry ~6,1f · bread ~6,1f~%"
        (served need-shared)  (chan need-shared  'bread))
(format #t "    need, claimed       laundry ~6,1f · bread ~6,1f~%"
        (served need-claimed) (chan need-claimed 'bread))
(check "the need is met on the communal rail"  (share? (served need-shared)  LOADS 0.99))
(check "…and on the individual rail, equally"  (share? (served need-claimed) LOADS 0.99))
(check "what the channel decides is the PRICE — what is left over for the rest"
       (> (chan need-shared 'bread) (* 2.0 (chan need-claimed 'bread))))

;;; Which is the distinction worth keeping. A plan that meters laundry as a need
;;; has settled what the commune owes its members; it has settled nothing about
;;; whether that is reached by a machine in every flat or one on the corner. The
;;; first is the political question and belongs to the scope; the second is a
;;; question about utilisation and walking distance, and the solver can have it.

(check-done
 "  A distribution mode is a recipe: two channels to one want, and the plan is a~%  composition of them — found, not declared. What is OWED is a separate axis~%  from how it TRAVELS, and the engine holds them apart.~%")
