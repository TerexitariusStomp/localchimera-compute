;;; test-flow.scm — Conversational flows + call-context wiring
;;;
;;; Exercises ^flow-runner directly and through ^channel (with a stub
;;; backend and stub transport — no network, no scope). Verifies:
;;;
;;;   - validators (non-empty, one-of, yes-no)
;;;   - flow-registry register/lookup
;;;   - flow-runner: start, feed (advance), validation failure re-prompt,
;;;     terminal finish, cancel
;;;   - channel routing: /start enters flow, raw input fed while active,
;;;     backend bypassed while active, /cancel aborts
;;;
;;; Run from project root:
;;;   guile -L module tests/interface/test-flow.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)
(add-to-load-path "module")

(define (contains? s sub) (and (string? s) (string-contains s sub) #t))

(use-modules (playnet test harness)
             (goblins)
             (goblins vat)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (ice-9 receive)
             (ice-9 match)
             (playnet interface call-context)
             (playnet interface flow)
             (playnet interface channel)
             (playnet interface output-sink))


;;; ── Stub transport / backend ────────────────────────────────────────────

(define (^stub-transport bcom prefix sent)
  ;; Records every send-message into a reversed list. parse-command strips
  ;; PREFIX from /-style commands.
  (methods
    ((parse-command text)
     (cond
      ((or (not text) (string-null? text))
       (cons #f #f))
      ((string-prefix? prefix text)
       (let* ((rest (substring text (string-length prefix)))
              (sp   (string-index rest #\space)))
         (if sp
             (cons (substring rest 0 sp)
                   (string-trim-both (substring rest (+ sp 1))))
             (cons rest ""))))
      (else (cons #f #f))))
    ((send-message _ctx text)
     (bcom (^stub-transport bcom prefix (cons text sent))))
    ((send-formatted _ctx text) ($ bcom 'send-message _ctx text))
    ((sent) (reverse sent))))

(define (^stub-backend bcom calls)
  ;; Always replies ('response "BACKEND: <cmd> <args>"). Records every call.
  (methods
    ((handle req-ctx cmd args)
     (bcom (^stub-backend bcom
             (cons (list (ctx-user req-ctx) cmd args) calls))
           (list 'response (format #f "BACKEND: ~a ~a" cmd args))))
    ((available-commands) '("noop"))
    ((wire-output _sink) 'ok)
    ((calls) (reverse calls))))


;;; ── Vat ─────────────────────────────────────────────────────────────────

(define test-vat (spawn-vat #:name "test-flow"))


;;; ── 1. Validators ──────────────────────────────────────────────────────

(display "\n── 1. validators ──\n")

(check "non-empty rejects blank"     (car (non-empty "   ")) 'error)
(check "non-empty accepts text"      (non-empty "hello")     '(ok "hello"))
(check "non-empty trims"             (non-empty "  hi  ")    '(ok "hi"))

(let ((v (one-of "a" "b" "c")))
  (check "one-of accepts member"     (v "b")  '(ok "b"))
  (check "one-of rejects non-member" (car (v "z")) 'error))

(check "yes-no parses yes"           (yes-no "Yes")  '(ok #t))
(check "yes-no parses no"            (yes-no "n")    '(ok #f))
(check "yes-no rejects garbage"      (car (yes-no "maybe")) 'error)


;;; ── 2. Flow definition + registry ──────────────────────────────────────

(display "\n── 2. flow registry ──\n")

(define collected-final #f)

(define signup-flow
  (make-flow
    #:name 'signup
    #:intro "Welcome — let's set you up."
    #:steps (list (make-step 'handle "What handle?")
                  (make-step 'server "Which server?"
                             (one-of "alpha" "beta"))
                  (make-step 'confirm "Confirm? (yes/no)" yes-no))
    #:finish (lambda (ctx data)
               (set! collected-final data)
               (format #f "Done: ~a on ~a (confirmed=~a)"
                       (assq-ref data 'handle)
                       (assq-ref data 'server)
                       (assq-ref data 'confirm)))))

(define registry
  (with-vat test-vat
    (let ((r (spawn ^flow-registry (hashmap))))
      ($ r 'register signup-flow)
      r)))

(check "registry lookup hit"
       (with-vat test-vat
         (eq? signup-flow ($ registry 'lookup 'signup))) #t)
(check "registry lookup miss"
       (with-vat test-vat ($ registry 'lookup 'nope)) #f)
(check "registry names lists signup"
       (with-vat test-vat (member 'signup ($ registry 'names))) '(signup))


;;; ── 3. flow-runner direct: start → feed → finish ───────────────────────

(display "\n── 3. flow-runner direct ──\n")

(define runner
  (with-vat test-vat (spawn ^flow-runner registry (hashmap))))

(define (ctx-for user)
  (make-request-ctx user "test-channel" #f "raw-text-placeholder"))

(with-vat test-vat
  (check "runner not active initially"
         ($ runner 'active? "u1") #f)

  (let ((r ($ runner 'start (ctx-for "u1") 'signup)))
    (check "start returns response"  (car r) 'response)
    (check "start prompts step 1"
           (contains? (cadr r) "[1/3]") #t))

  (check "runner now active for u1"   ($ runner 'active? "u1") #t)
  (check "runner not active for u2"   ($ runner 'active? "u2") #f)

  (let ((r ($ runner 'feed (ctx-for "u1") "juniper")))
    (check "feed advances to step 2"
           (contains? (cadr r) "[2/3]") #t))

  ;; Invalid choice — re-prompts with error, stays on step 2.
  (let ((r ($ runner 'feed (ctx-for "u1") "gamma")))
    (check "feed invalid: response"   (car r) 'response)
    (check "feed invalid: error msg"
           (contains? (cadr r) "alpha, beta") #t)
    (check "still on step 2"
           (contains? (cadr r) "[2/3]") #t))
  (check "still active after invalid" ($ runner 'active? "u1") #t)

  (let ((r ($ runner 'feed (ctx-for "u1") "alpha")))
    (check "feed valid advances to step 3"
           (contains? (cadr r) "[3/3]") #t))

  (let ((r ($ runner 'feed (ctx-for "u1") "yes")))
    (check "finish returns response"  (car r) 'response)
    (check "finish text mentions handle"
           (contains? (cadr r) "juniper") #t))

  (check "runner no longer active"    ($ runner 'active? "u1") #f)
  (check "finish collected handle"    (assq-ref collected-final 'handle) "juniper")
  (check "finish collected server"    (assq-ref collected-final 'server) "alpha")
  (check "finish collected confirm"   (assq-ref collected-final 'confirm) #t))


;;; ── 4. flow-runner: cancel mid-flow ────────────────────────────────────

(display "\n── 4. cancel ──\n")

(with-vat test-vat
  ($ runner 'start (ctx-for "u2") 'signup)
  (check "u2 active"               ($ runner 'active? "u2") #t)
  (let ((r ($ runner 'cancel (ctx-for "u2"))))
    (check "cancel response"        (car r) 'response))
  (check "u2 inactive after cancel" ($ runner 'active? "u2") #f))


;;; ── 5. flow-runner: unknown flow ───────────────────────────────────────

(display "\n── 5. unknown flow ──\n")

(with-vat test-vat
  (let ((r ($ runner 'start (ctx-for "u3") 'nope)))
    (check "unknown flow → error"   (car r) 'error)))


;;; ── 6. Channel-level wiring: /start, feed, /cancel ─────────────────────

(display "\n── 6. channel + flow integration ──\n")

(define (make-stub-channel channel-id)
  (with-vat test-vat
    (let* ((backend   (spawn ^stub-backend '()))
           (sink      (spawn ^output-sink #f #f
                             (lambda (x) (if (string? x) x (format #f "~a" x)))
                             '()))
           (transport (spawn ^stub-transport "/" '()))
           (fr        (spawn ^flow-runner registry (hashmap)))
           (chan      (make-channel channel-id backend sink
                                    #:flow-runner fr)))
      ($ chan 'bind-transport transport "ctx-key")
      (values chan backend transport fr))))

(receive (chan backend transport fr) (make-stub-channel "ch-1")

  ;; The channel uses <- (async) to talk to the backend so remote
  ;; backends work. Each with-vat is one turn — we send a message in
  ;; one turn, then check observable state in the next.
  (define (step thunk) (with-vat test-vat (thunk)))

  ;; --- A normal command goes through the backend ---
  (step (lambda () ($ chan 'handle-input "alice" "/noop hi")))
  (step (lambda ()  ;; pump for the <- to deliver
          (check "backend called once"
                 (length ($ backend 'calls)) 1)
          (check "transport got backend reply"
                 (contains? (car ($ transport 'sent)) "BACKEND") #t)))

  ;; --- /start switches into flow ---
  (step (lambda () ($ chan 'handle-input "alice" "/start signup")))
  (step (lambda ()
          (check "alice in flow"           ($ fr 'active? "alice") #t)
          (check "intro+prompt sent"
                 (contains? (cadr ($ transport 'sent)) "[1/3]") #t)))

  ;; --- Raw text while in flow goes to flow (NOT backend) ---
  (step (lambda () ($ chan 'handle-input "alice" "juniper")))
  (step (lambda ()
          (check "still active after step 1" ($ fr 'active? "alice") #t)
          (check "backend NOT called again"  (length ($ backend 'calls)) 1)
          (check "step 2 prompt sent"
                 (contains? (caddr ($ transport 'sent)) "[2/3]") #t)))

  ;; --- /cancel aborts ---
  (step (lambda () ($ chan 'handle-input "alice" "/cancel")))
  (step (lambda ()
          (check "alice no longer in flow"  ($ fr 'active? "alice") #f)))

  ;; --- Backend dispatch resumes after cancel ---
  (step (lambda () ($ chan 'handle-input "alice" "/noop again")))
  (step (lambda ()
          (check "backend called again" (length ($ backend 'calls)) 2))))


;;; ── 7. extend-ctx threads scope/org refs ───────────────────────────────

(display "\n── 7. extend-ctx ──\n")

;; extend-ctx is layer-pure: it just appends fields. We test it with the
;; generic ctx-ref accessor; backend-specific accessors (ctx-scope, etc.)
;; live with the backend that owns those fields.
(let* ((req (make-request-ctx "u1" "c1" 'chan-ref-placeholder "raw"))
       (ext (extend-ctx req 'scope-ref 'scope-x 'org-ref 'org-y)))
  (check "request preserves user"     (ctx-user req)              "u1")
  (check "extended has scope-ref"     (ctx-ref ext 'scope-ref)    'scope-x)
  (check "extended has org-ref"       (ctx-ref ext 'org-ref)      'org-y)
  (check "extended preserves user"    (ctx-user ext)              "u1")
  (check "extended preserves chan"    (ctx-channel ext)           'chan-ref-placeholder)
  (check "request lacks scope-ref"    (ctx-ref req 'scope-ref)    #f))


;;; ── 8. Dynamic prompts (prompt = procedure of answers-so-far) ─────────

(display "\n── 8. dynamic prompts ──\n")

(define interp-flow
  (make-flow
    #:name 'interp
    #:steps (list
             (make-step 'name "What's your name?")
             (make-step 'mood
                        (lambda (so-far)
                          (format #f "Nice to meet you, ~a. How are you?"
                                  (assq-ref so-far 'name)))))
    #:finish (lambda (ctx data)
               (format #f "Got it: ~a (~a)"
                       (assq-ref data 'name)
                       (assq-ref data 'mood)))))

(with-vat test-vat
  ($ registry 'register interp-flow)
  (let* ((r1 ($ runner 'start (ctx-for "u9") 'interp))
         (_  ($ runner 'feed  (ctx-for "u9") "alice"))
         ;; The second prompt should now interpolate "alice".
         (r2 ($ runner 'feed  (ctx-for "u9") "")))  ;; trigger non-empty fail
    (check "dynamic prompt interpolates name"
           (contains? (cadr r2) "alice") #t)
    (check "still on step 2"
           (contains? (cadr r2) "[2/2]") #t))
  ;; Finish cleanly
  ($ runner 'feed (ctx-for "u9") "good"))


;;; ── 9. integer-in validator ───────────────────────────────────────────

(display "\n── 9. integer-in ──\n")

(let ((v (integer-in 1 10)))
  (check "integer-in accepts in-range"  (v "5")   '(ok 5))
  (check "integer-in rejects low"       (car (v "0"))   'error)
  (check "integer-in rejects high"      (car (v "99"))  'error)
  (check "integer-in rejects non-num"   (car (v "abc")) 'error))


;;; ── 10. define-flow macro ──────────────────────────────────────────────

(display "\n── 10. define-flow ──\n")

(define-flow tiny
  (intro "Quick check.")
  (city  "Where are you?")
  (count "How many? (1–10)" (integer-in 1 10))
  (finish (_ data)
    (format #f "~a x~a"
            (assq-ref data 'city)
            (assq-ref data 'count))))

(check "define-flow creates a flow"   (flow? tiny) #t)
(check "define-flow sets name"        (flow-name tiny) 'tiny)
(check "define-flow sets intro"       (flow-intro tiny) "Quick check.")
(check "define-flow has 2 steps"      (length (flow-steps tiny)) 2)
(check "first step key"               (step-key (car (flow-steps tiny))) 'city)
(check "second step uses integer-in"
       (let ((v (step-validate (cadr (flow-steps tiny)))))
         (car (v "5"))) 'ok)

;; Drive it through a runner end-to-end.
(with-vat test-vat
  ($ registry 'register tiny)
  ($ runner 'start (ctx-for "uX") 'tiny)
  ($ runner 'feed  (ctx-for "uX") "Sofia"))
(with-vat test-vat
  (let ((r ($ runner 'feed (ctx-for "uX") "3")))
    (check "macro flow finishes"           (car r) 'response)
    (check "macro flow includes city"      (contains? (cadr r) "Sofia") #t)
    (check "macro flow includes count"     (contains? (cadr r) "3")     #t)))


;;; ── 11. define-flow clause ordering ────────────────────────────────────

(display "\n── 11. define-flow clause ordering ──\n")

;; intro can appear last, finish first, steps interspersed.
(define-flow scrambled
  (finish (_ d) (format #f "~a" (assq-ref d 'q1)))
  (q1 "First?")
  (intro "Order doesn't matter."))

(check "scrambled: name"     (flow-name scrambled)  'scrambled)
(check "scrambled: intro"    (flow-intro scrambled) "Order doesn't matter.")
(check "scrambled: 1 step"   (length (flow-steps scrambled)) 1)


(test-summary!)
