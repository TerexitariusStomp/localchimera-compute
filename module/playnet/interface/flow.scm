;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/interface/flow.scm — Conversational flows
;;;
;;; A flow is a small, declarative state machine for multi-turn
;;; interactions: signup, onboarding, plan proposal — anything that
;;; needs to collect more than one piece of input before acting.
;;;
;;; Flows are data:
;;;
;;;   (make-flow
;;;     #:name 'signup
;;;     #:intro "Let's get you signed up."
;;;     #:steps (list
;;;       (make-step 'handle "What handle would you like?")
;;;       (make-step 'server
;;;                  (lambda (so-far)
;;;                    (format #f "Hi ~a — which server? (alpha / beta)"
;;;                            (assq-ref so-far 'handle)))
;;;                  (one-of "alpha" "beta")))
;;;     #:finish (lambda (ctx data)
;;;                (format #f "Signed up as ~a on ~a"
;;;                        (assq-ref data 'handle)
;;;                        (assq-ref data 'server))))
;;;
;;; A step has three parts:
;;;
;;;   key       — the symbol the answer is collected under
;;;   prompt    — either a string, OR a procedure (answers-so-far) → string
;;;               so prompts can reference earlier answers
;;;   validate  — (text) → (ok value) | (fail msg)
;;;               Use the `ok` and `fail` helpers to build results.
;;;
;;; Two actors:
;;;
;;;   ^flow-registry  — Names → flow definitions. Shared across channels;
;;;                     populated once at startup.
;;;
;;;   ^flow-runner    — Per channel. Tracks each user's active session and
;;;                     advances it as text arrives. The channel routes
;;;                     raw text to the runner whenever a user has an
;;;                     active flow.
;;;
;;; Both `feed` and `start` return the standard channel reply shape so
;;; the channel can treat flows and backend handlers uniformly:
;;;
;;;   ('response text)  — send TEXT back to the user
;;;   ('error reason)   — send "Error: reason" back to the user
;;;   ('silent)         — do not send anything

(define-module (playnet interface flow)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 match)
  #:use-module (playnet interface call-context)
  #:export (;; declarative flow definition
            define-flow
            ;; flow / step constructors + accessors
            make-flow make-step
            flow? flow-name flow-intro flow-steps flow-finish
            step? step-key step-prompt step-validate
            ;; validator result helpers
            ok fail
            ;; built-in validators
            non-empty one-of yes-no integer-in matches-regex
            ;; actors
            ^flow-registry ^flow-runner))


;; =========================================================================
;; Validator result helpers
;; =========================================================================
;; A validator is just (text) → result.  Two shapes:
;;
;;   (ok value)   the user's input parsed successfully into VALUE
;;                (which is what's stored under the step's key)
;;   (fail msg)   reject the input; MSG is shown to the user, then the
;;                step's prompt is shown again
;;
;; Defining validators is then nearly free:
;;
;;   (define (valid-handle text)
;;     (let ((t (string-trim-both text)))
;;       (if (string-match "^[a-z][a-z0-9_]{2,15}$" t)
;;           (ok t)
;;           (fail "Handle must be lowercase, 3–16 chars."))))

(define (ok value) (list 'ok value))
(define (fail msg) (list 'error msg))


;; =========================================================================
;; Records
;; =========================================================================

(define-record-type <flow-step>
  (make-step* key prompt validate)
  step?
  (key      step-key)
  (prompt   step-prompt)
  (validate step-validate))

(define* (make-step key prompt #:optional (validate non-empty))
  "Construct a step. PROMPT is a string or (answers-alist) → string.
   VALIDATE defaults to `non-empty`."
  (unless (symbol? key)
    (error "make-step: KEY must be a symbol" key))
  (unless (or (string? prompt) (procedure? prompt))
    (error "make-step: PROMPT must be a string or procedure" prompt))
  (unless (procedure? validate)
    (error "make-step: VALIDATE must be a procedure" validate))
  (make-step* key prompt validate))

(define-record-type <flow>
  (make-flow* name intro steps finish)
  flow?
  (name   flow-name)
  (intro  flow-intro)
  (steps  flow-steps)
  (finish flow-finish))

(define* (make-flow #:key name intro (steps '()) finish)
  "Construct a flow. #:intro is optional (a string shown before step 1)."
  (unless (symbol? name)
    (error "make-flow: #:name must be a symbol" name))
  (unless (procedure? finish)
    (error "make-flow: #:finish must be a procedure" finish))
  (unless (and (list? steps) (every step? steps))
    (error "make-flow: #:steps must be a list of <flow-step>" steps))
  (make-flow* name intro steps finish))


;; =========================================================================
;; define-flow — declarative top-level flow definition
;; =========================================================================
;;
;; Sugar for the make-flow / make-step combo. Three clause forms:
;;
;;   (intro STRING)
;;     Optional. Sent verbatim before the first step's prompt.
;;
;;   (KEY PROMPT)             — shorthand step, non-empty validator
;;   (KEY PROMPT VALIDATE)    — shorthand step with explicit validator
;;     KEY is an unquoted symbol (the answer is stored under it).
;;     PROMPT is a string OR a procedure (answers-so-far) → string.
;;
;;   (finish (CTX DATA) BODY ...)
;;     Inline finish procedure. BODY is one or more expressions evaluated
;;     with CTX (the request context) and DATA (forward-order alist of
;;     answers) in scope. The last expression's value is sent to the user.
;;
;; Clauses can appear in any order. `intro` and `finish` are reserved as
;; clause keywords — don't use them as step keys. Example:
;;
;;   (define-flow signup
;;     (intro "Welcome!")
;;     (handle  "What handle?")
;;     (server  "Which server?" (one-of "alpha" "beta"))
;;     (finish (_ data)
;;       (format #f "Hello ~a" (assq-ref data 'handle))))

(define-syntax define-flow
  (syntax-rules (intro finish ::build)
    ;; ----- accumulator state: ::build NAME INTRO (STEPS...) FINISH -----

    ;; intro clause
    ((_ ::build n _ steps fin (intro str) rest ...)
     (define-flow ::build n str steps fin rest ...))

    ;; finish clause
    ((_ ::build n in steps _ (finish (ctx-id data-id) body0 body ...) rest ...)
     (define-flow ::build n in steps
       (lambda (ctx-id data-id) body0 body ...)
       rest ...))

    ;; step: (KEY PROMPT)
    ((_ ::build n in (steps ...) fin (key prompt) rest ...)
     (define-flow ::build n in (steps ... (make-step 'key prompt)) fin rest ...))

    ;; step: (KEY PROMPT VALIDATE)
    ((_ ::build n in (steps ...) fin (key prompt validate) rest ...)
     (define-flow ::build n in (steps ... (make-step 'key prompt validate))
       fin rest ...))

    ;; clauses exhausted — build the flow
    ((_ ::build n in (steps ...) fin)
     (make-flow #:name 'n #:intro in
                #:steps (list steps ...) #:finish fin))

    ;; ----- entry point -----
    ((_ name clauses ...)
     (define name (define-flow ::build name #f () #f clauses ...)))))


;; =========================================================================
;; Built-in validators
;; =========================================================================

(define (non-empty text)
  (let ((t (string-trim-both (or text ""))))
    (if (string-null? t)
        (fail "I need a non-empty answer.")
        (ok t))))

(define (one-of . choices)
  (lambda (text)
    (let ((t (string-trim-both (or text ""))))
      (if (member t choices)
          (ok t)
          (fail (format #f "Please answer one of: ~a"
                        (string-join choices ", ")))))))

(define (yes-no text)
  (let ((t (string-downcase (string-trim-both (or text "")))))
    (cond
     ((member t '("y" "yes")) (ok #t))
     ((member t '("n" "no"))  (ok #f))
     (else (fail "Please answer yes or no.")))))

(define (integer-in lo hi)
  (lambda (text)
    (let ((n (string->number (string-trim-both (or text "")))))
      (cond
       ((not (and n (integer? n) (exact? n)))
        (fail "Please enter a whole number."))
       ((or (< n lo) (> n hi))
        (fail (format #f "Must be between ~a and ~a." lo hi)))
       (else (ok n))))))

(define (matches-regex rx-string error-msg)
  ;; Lazy: only compile when actually used.
  (let ((rx #f))
    (lambda (text)
      (unless rx (set! rx (make-regexp rx-string)))
      (let ((t (string-trim-both (or text ""))))
        (if (regexp-exec rx t) (ok t) (fail error-msg))))))


;; =========================================================================
;; Flow sessions (internal state)
;; =========================================================================
;; A session is one user's progress through one flow.  Answers are stored
;; in reverse insertion order internally (so we can cons in O(1)); the
;; forward-order view is exposed via `session-answers` for prompts and
;; the finish callback.

(define-record-type <flow-session>
  (make-session flow index answers-rev)
  session?
  (flow         session-flow)
  (index        session-index)
  (answers-rev  session-answers-rev))

(define (session-answers s)        (reverse (session-answers-rev s)))
(define (session-step-count s)     (length (flow-steps (session-flow s))))
(define (session-current-step s)   (list-ref (flow-steps (session-flow s))
                                             (session-index s)))
(define (session-complete? s)      (>= (session-index s) (session-step-count s)))

(define (session-record-answer s key value)
  (make-session (session-flow s)
                (session-index s)
                (cons (cons key value) (session-answers-rev s))))

(define (session-advance s)
  (make-session (session-flow s)
                (+ 1 (session-index s))
                (session-answers-rev s)))

(define (render-prompt session)
  "Format the prompt for the session's current step.  Handles both
   string prompts and procedure prompts (which receive answers-so-far)."
  (let* ((step (session-current-step session))
         (p    (step-prompt step))
         (body (if (procedure? p) (p (session-answers session)) p)))
    (format #f "[~a/~a] ~a"
            (+ 1 (session-index session))
            (session-step-count session)
            body)))


;; =========================================================================
;; ^flow-registry — name → flow lookup
;; =========================================================================

(define (^flow-registry bcom flows)
  (methods
    ((register flow)
     (bcom (^flow-registry bcom (hashmap-set flows (flow-name flow) flow))))
    ((lookup name)
     (hashmap-ref flows name #f))
    ((names)
     (hashmap-fold (lambda (k v acc) (cons k acc)) '() flows))))


;; =========================================================================
;; ^flow-runner — per-channel per-user state machine
;; =========================================================================

(define (^flow-runner bcom registry sessions)

  (define (commit sessions* reply)
    "Become a runner with SESSIONS* and return REPLY."
    (bcom (^flow-runner bcom registry sessions*) reply))

  (define (session-of user)  (hashmap-ref sessions user #f))
  (define (with-session  u s) (hashmap-set sessions u s))
  (define (without-session u) (hashmap-remove sessions u))

  (define (open-session ctx flow user)
    "First step of a fresh session.  Degenerate empty-flow case: just
     run finish."
    (if (null? (flow-steps flow))
        (list 'response ((flow-finish flow) ctx '()))
        (let* ((s      (make-session flow 0 '()))
               (intro  (flow-intro flow))
               (prompt (render-prompt s))
               (text   (if intro (string-append intro "\n" prompt) prompt)))
          (commit (with-session user s) (list 'response text)))))

  (define (record-and-advance ctx user session value)
    "Store VALUE under the current step's key; advance; if that
     completes the flow, run finish."
    (let* ((step (session-current-step session))
           (s+   (session-record-answer session (step-key step) value))
           (next (session-advance s+)))
      (cond
       ((session-complete? next)
        (let ((reply ((flow-finish (session-flow next))
                      ctx (session-answers s+))))
          (commit (without-session user) (list 'response reply))))
       (else
        (commit (with-session user next)
                (list 'response (render-prompt next)))))))

  (methods

    ((active? user) (and (session-of user) #t))
    ((names)        ($ registry 'names))

    ((start ctx flow-name)
     (let ((flow (and (symbol? flow-name) ($ registry 'lookup flow-name)))
           (user (ctx-user ctx)))
       (cond
        ((not flow) (fail (format #f "No such flow: ~a" flow-name)))
        ((session-of user)
         (fail "You already have an active flow. Use /cancel first."))
        (else (open-session ctx flow user)))))

    ((cancel ctx)
     (let ((user (ctx-user ctx)))
       (if (session-of user)
           (commit (without-session user) (list 'response "Flow cancelled."))
           (list 'response "No active flow."))))

    ((feed ctx text)
     (let* ((user    (ctx-user ctx))
            (session (session-of user)))
       (cond
        ((not session) (list 'silent))
        (else
         (match ((step-validate (session-current-step session)) text)
           (('ok value)
            (record-and-advance ctx user session value))
           (('error msg)
            (list 'response
                  (string-append msg "\n" (render-prompt session))))
           (other
            (fail (format #f "Validator returned ~a (expected ok/error)"
                          other))))))))))
