;;; test-calendar-willingness.scm — the willingness UI in (playnet ui calendar)
;;;
;;; Pure SXML rendering test (no goblins/vat). Exercises the calendar's
;;; offer-side willingness surface that the live ^planner-service feeds:
;;;   - the "You'd be helpful here" band (intents the acting-as user is a
;;;     candidate for, not yet picked) vs "Awaiting your acceptance" (matched);
;;;   - the Willing / Withdraw toggle and the callback it fires;
;;;   - the candidate 'race chips (who's signalled, with status);
;;;   - back-compat: no on-express-willingness ⇒ no band, old behaviour.
;;;
;;; Run from project root:
;;;   guile -L module tests/ui/test-calendar-willingness.scm

(use-modules (playnet test harness)
             (playnet ui calendar)
             (srfi srfi-1))

;; Flatten an SXML tree to a space-joined string of its text/symbol leaves.
(define (walk x)
  (cond ((pair? x) (string-append (walk (car x)) (walk (cdr x))))
        ((string? x) (string-append x " "))
        ((symbol? x) (string-append (symbol->string x) " "))
        (else "")))
(define (has? sx sub) (and (string-contains (walk sx) sub) #t))

;; Collect the `click` thunks on nodes whose @class contains CLASS-SUBSTR.
(define (clicks-on sx class-substr)
  (let collect ((x sx) (acc '()))
    (cond ((and (pair? x) (pair? (car x)) (eq? (caar x) '@))
           (let ((attrs (cdar x)))
             (collect (cdr x)
               (if (and (assq 'class attrs)
                        (string-contains (cadr (assq 'class attrs)) class-substr)
                        (assq 'click attrs))
                   (cons (cadr (assq 'click attrs)) acc) acc))))
          ((pair? x) (collect (cdr x) (collect (car x) acc)))
          (else acc))))

;; ── Fixtures ────────────────────────────────────────────────────────────────
(define (need id proc spec . extra)        ; a work need; EXTRA overrides defaults
  (append extra                            ; (alist-ref takes the first match ⇒ extra wins)
          (list (cons 'id id) (cons 'proc-name proc) (cons 'spec spec)
                (cons 'effort 0.5) (cons 'effort-unit "hr") (cons 'scope "town")
                (cons 'match 'unassigned))))
(define (race . pairs)                       ; willing-workers list: (id name status)…
  (cons 'willing
        (map (lambda (p) (list (cons 'id (car p)) (cons 'name (cadr p))
                               (cons 'willing-status (caddr p)))) pairs)))

;; A need ada+bob can fill; bob has opted in (willing), ada only invited.
(define bake (need "ni|bake|skill-bake|town@0" "Bake bread" "skill-bake"
                   (cons 'candidates '("ada" "bob"))
                   (race '("bob" "Bob" willing) '("ada" "Ada" invited))))

(display "\n── (playnet ui calendar): willingness offer band ──\n")

;; (1) acting-as=ada is a candidate, not yet willing ⇒ lands in the OFFER band.
(let* ((fired #f)
       (sx (render-intents-sidebar (list bake) (lambda (i) #f) #f
             #:acting-as "ada"
             #:on-express-willingness (lambda (i w?) (set! fired (cons (assq-ref i 'id) w?))))))
  (check "offer band 'You'd be helpful here' present" (has? sx "You'd be helpful here"))
  (check "candidate 'race rendered"                   (has? sx "cal-willing-race"))
  (check "race shows the willing-worker names"        (and (has? sx "Bob") (has? sx "Ada")))
  (check "willing toggle present"                     (has? sx "cal-intent-willing"))
  (check "ada (invited, not willing) sees the opt-in label" (has? sx "I'm willing"))
  (check "no Accept button in the offer band"         (not (has? sx "Accept")))
  ;; clicking the toggle fires on-express-willingness with (id . #t)
  (let ((btns (clicks-on sx "cal-intent-willing")))
    (check "exactly one willing toggle" (length btns) 1)
    ((car btns) #f)
    (check "toggle fires (intent-id . #t) when opting in"
           fired (cons "ni|bake|skill-bake|town@0" #t))))

;; (2) acting-as=bob is already willing ⇒ Withdraw, fires #f.
(let* ((fired 'none)
       (sx (render-intents-sidebar (list bake) (lambda (i) #f) #f
             #:acting-as "bob"
             #:on-express-willingness (lambda (i w?) (set! fired w?)))))
  (check "willing user sees Withdraw label" (has? sx "withdraw"))
  (let ((btns (clicks-on sx "cal-intent-willing")))
    ((car btns) #f)
    (check "Withdraw fires willing?=#f" fired #f)))

;; (3) a need MATCHED to acting-as goes to 'Awaiting your acceptance' (Accept),
;;     NOT the offer band — offer vs commitment stay distinct.
(let* ((mine (need "ni|mill|skill-mill|town@0" "Mill flour" "skill-mill"
                   (cons 'match 'matched)
                   (cons 'suggested "ada")
                   (cons 'suggested-name "Ada")
                   (cons 'candidates '("ada"))))
       (sx (render-intents-sidebar (list mine) (lambda (i) #f) #f
             #:acting-as "ada"
             #:on-accept (lambda (i) #f) #:on-decline (lambda (i) #f)
             #:on-express-willingness (lambda (i w?) #f))))
  (check "matched-to-me need is 'Awaiting your acceptance'" (has? sx "Awaiting your acceptance"))
  (check "matched need shows Accept"                         (has? sx "Accept"))
  (check "matched need is NOT in the offer band"             (not (has? sx "You'd be helpful here"))))

;; (4) back-compat: no on-express-willingness ⇒ no offer band, no willing toggle.
(let ((sx (render-intents-sidebar (list bake) (lambda (i) #f) #f #:acting-as "ada")))
  (check "without callback: no offer band"     (not (has? sx "You'd be helpful here")))
  (check "without callback: no willing toggle"  (not (has? sx "cal-intent-willing"))))

;; (5) a user who is NOT a candidate and hasn't signalled sees no offer for it.
(let ((sx (render-intents-sidebar (list bake) (lambda (i) #f) #f
            #:acting-as "carol"
            #:on-express-willingness (lambda (i w?) #f))))
  (check "non-candidate user gets no offer band" (not (has? sx "You'd be helpful here"))))

;; ── The event detail panel: three-way response on an offered event ──────────
(display "\n── detail panel: willing / commit / reject ──\n")

;; An offered (intent) grid-event suggested to ada; bob is in the race.
(define (offered-event . extra)
  (append extra
          (list (cons 'id "ni|bake|skill-bake|town@0")
                (cons 'title "Bake bread: skill-bake")
                (cons 'date "2026-06-08")
                (cons 'source 'intent) (cons 'status 'open)
                (cons 'match 'matched)
                (cons 'suggested "ada")
                (cons 'suggested-name "Ada")
                (cons 'spec "skill-bake") (cons 'cell "town@0")
                (race '("bob" "Bob" willing)))))

(define (panel evt acting-as . cbs)
  (apply render-event-detail-panel evt
         (lambda (e) #f) (lambda (e) #f) (lambda (e) #f)
         '() '() (lambda (c q) #f) '() '()
         #:acting-as acting-as cbs))

;; (P1) the suggested person sees all three expressions; each fires.
(let* ((got '())
       (sx (panel (offered-event) "ada"
                  #:on-accept-assignment  (lambda (e) (set! got (cons 'commit got)))
                  #:on-decline-assignment (lambda (e) (set! got (cons 'reject got)))
                  #:on-express-willingness (lambda (e w?) (set! got (cons (cons 'willing w?) got))))))
  (check "panel has the response section"  (has? sx "Your response"))
  (check "panel offers Willing"            (has? sx "Willing"))
  (check "panel offers Commit"             (has? sx "Commit"))
  (check "panel offers Reject"             (has? sx "Reject"))
  (for-each (lambda (f) (f #f)) (clicks-on sx "cal-intent-willing"))
  (for-each (lambda (f) (f #f)) (clicks-on sx "cal-btn-primary"))
  (for-each (lambda (f) (f #f)) (clicks-on sx "cal-btn-danger"))
  (check "willing fires with #t (opt in)"  (and (member '(willing . #t) got) #t))
  (check "commit fires"                    (and (memq 'commit got) #t))
  (check "reject fires"                    (and (memq 'reject got) #t)))

;; (P2) a non-suggested user: Willing (withdraw — bob already opted in)
;;      + Reject, but NO Commit.
(let ((sx (panel (offered-event) "bob"
                 #:on-accept-assignment  (lambda (e) #f)
                 #:on-decline-assignment (lambda (e) #f)
                 #:on-express-willingness (lambda (e w?) #f))))
  (check "non-suggested still gets the section" (has? sx "Your response"))
  (check "bob's willing shows withdraw"         (has? sx "withdraw"))
  (check "non-suggested gets NO Commit"         (not (has? sx "Commit"))))

;; (P3) no acting-as ⇒ no response section, pick-user hint instead.
(let ((sx (panel (offered-event) #f
                 #:on-express-willingness (lambda (e w?) #f))))
  (check "no acting-as: no response section" (not (has? sx "Your response")))
  (check "no acting-as: pick-user hint"      (has? sx "Acting as")))

;; (P4) declined status surfaces the re-open hint.
(let ((sx (panel (offered-event (race '("ada" "Ada" declined))) "ada"
                 #:on-express-willingness (lambda (e w?) #f))))
  (check "declined shows the re-open hint" (has? sx "re-opens")))

(test-summary!)
