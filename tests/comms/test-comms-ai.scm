;;; test-comms-ai.scm — Stage 3, the fenced AI restyle (live-shaped, mock completer).
;;;
;;; Proves the ONLY AI seam in comms cannot ship a fabricated fact: a faithful
;;; restyle passes through; one that invents a number, drops the citation, errors,
;;; or returns non-text all fall back to the dry skeleton. Uses a (prompt → text)
;;; completer — the exact shape llm-completer returns — so the test drives the
;;; real code path with a lambda standing in for the gateway.
;;;
;;; Run: guile -L module tests/comms/test-comms-ai.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness) (playnet vf schemas) (playnet observation states) (srfi srfi-1) (srfi srfi-1) (srfi srfi-13))

(define here (dirname (current-filename)))
(define root (dirname (dirname here)))
(define (pl p) (load (string-append root "/module/playnet/planner/" p)))
(use-modules (playnet comms plan)) (use-modules (playnet comms ai))

;; fixtures (as in test-comms) — real <intent> + <satisfaction-state>
(define* (mk-intent id #:key (action 'produce) (name #f) (classified '()))
  (make-intent #:id id #:action action #:name name #:resource-classified-as classified
               #:in-scope-of '()))
(define* (mk-sat iid desired satisfied #:key (unit "kg"))
  (make-satisfaction-state iid (make-measure desired unit)
                           (make-measure satisfied unit) '() '() #f "plan-1"))

(define i-food (mk-intent "intent-food" #:name "Community Meal"))
(define i-cook (mk-intent "intent-cook" #:action 'work #:name "cook-hours"))
(define i-floor (mk-intent "intent-floor" #:name "Calories" #:classified '("reproduction-floor")))
(define s-food (mk-sat "intent-food" 52 40))
(define s-cook (mk-sat "intent-cook" 8 6 #:unit %effort-unit))
(define s-floor (mk-sat "intent-floor" 2000 1500 #:unit "kcal"))
(define intents (list i-food i-cook i-floor))
(define sats    (list s-food s-cook s-floor))

(define sk (render-skeleton i-food s-food))

;; ─── the completers (stand in for the gateway) ─────────────────────────────
;; faithful: echo the skeleton (everything after "Message:\n") with a warm prefix
;; — preserves every number and the [cite:…] token, invents nothing.
(define (faithful prompt)
  (let ((i (string-contains prompt "Message:\n")))
    (string-append "🌱 Friends — " (substring prompt (+ i 9)))))
(define (fabricating prompt) "🚨 We now need 999 kg immediately!! [cite:intent-food]")
(define (erroring prompt) (error "gateway down"))
(define (non-text prompt) #f)

;;; ─── 1. a faithful restyle passes the fence and changes the voice ──────────
(display "\n── a faithful restyle ships (entails the skeleton, new voice) ──\n")
(define good (restyle-skeleton faithful sk #:channel "mastodon"))
(check "the restyle differs from the dry skeleton" (not (string=? good sk)) #t)
(check "the restyle still entails the skeleton (fence would accept it)"
       (entails-skeleton? sk good) #t)
(check "the restyle keeps the number and the citation"
       (and (string-contains good "12") (string-contains good "[cite:intent-food]") #t) #t)

;;; ─── 2. every unfaithful completer falls back to the dry skeleton ──────────
(display "\n── a fabricated / broken restyle falls back to the skeleton ──\n")
(check "inventing a number ⇒ the dry skeleton ships"
       (restyle-skeleton fabricating sk) sk)
(check "a gateway error ⇒ the dry skeleton ships (no crash)"
       (restyle-skeleton erroring sk) sk)
(check "a non-text response ⇒ the dry skeleton ships"
       (restyle-skeleton non-text sk) sk)

;;; ─── 2b. the fence names what broke; a re-ask that reads it ships ───────
;;; (playnet ai conform) quotes skeleton-fence-reason back to the model once.
(display "\n── a restyle that breaks the fence is asked again with the fact named ──\n")
(define prompts '())
(define (learning prompt)                      ; fabricates first, then reads the reason
  (set! prompts (cons prompt prompts))
  (if (string-contains prompt "failed validation") (faithful prompt) (fabricating prompt)))
(define healed (restyle-skeleton learning sk #:channel "mastodon"))
(check "the healed restyle ships and entails the skeleton" (entails-skeleton? sk healed) #t)
(check "…and it is the warm voice, not the dry skeleton" (string-prefix? "🌱" healed) #t)
(check "two calls" (length prompts) 2)
(check-pred "the re-ask names the invented number"
            (string-contains (car prompts) "999"))
(check-pred "…in the fence's own words"
            (string-contains (car prompts) "not in the message and must not appear"))
(check "skeleton-fence-reason: #f for a faithful restyle" (skeleton-fence-reason sk (faithful (string-append "Message:\n" sk))) #f)
(check-pred "skeleton-fence-reason: the missing citation is the first thing named"
            (string-contains (skeleton-fence-reason sk "Friends, 12 kg please") "citation token"))

;;; ─── 3. plan->posts : the whole live pipeline, fenced end to end ───────────
(display "\n── plan->posts folds plan → skeletons → fenced restyles ──\n")
(define posts (plan->posts faithful intents sats #:channel "mastodon"))
(check "one post per under-satisfied intent" (length posts) 3)
(check "every post entails its own skeleton (no fabrication anywhere)"
       (every (lambda (p sk) (entails-skeleton? sk p))
              posts (plan->skeletons intents sats)) #t)
(check "a fabricating gateway yields all-skeleton posts (safe degradation)"
       (equal? (plan->posts fabricating intents sats)
               (plan->skeletons intents sats)) #t)

(display "\n")
(test-summary!)
