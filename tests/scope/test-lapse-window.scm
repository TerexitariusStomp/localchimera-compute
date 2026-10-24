;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-lapse-window.scm — the silence rail of the Validation Gate.
;;;
;;; Directed work vests on the recipient's word, immediately. Diffuse work —
;;; tending the commons, no recipient to confirm — has the scope itself as
;;; the confirmer, and the scope speaks by objecting: the hours stand in a
;;; window (%validation-window), any member may contest them there, and an
;;; uncontested lapse vests them in full. This suite pins the rail's
;;; properties on the observer's one chokepoint (event-fraction /
;;; validated-gross / pending-gross):
;;;
;;;   1. inside the window the hours read through pending-gross and count
;;;      zero in the credit fold;
;;;   2. at the lapse they move whole from pending to validated;
;;;   3. wherever a recipient's stated desire reaches the work's process,
;;;      that word governs and the window rail steps back;
;;;   4. silence-vested hours are local — the federation-level reading
;;;      leaves them out, the discipline loose intents already follow;
;;;   5. a void correction takes lapsed hours back out of the fold;
;;;   6. undated work opens no window: it waits for a recipient's word.
;;;
;;; Dates stand on today (one clock): "in the window" is now − 1 day,
;;; "lapsed" is now − 8 days, against the 7-day default.
;;;
;;; Run:  guile -q -L module tests/scope/test-lapse-window.scm

(use-modules ((localchimera utils units) #:select (%effort-unit)))
(use-modules (localchimera test harness))
(use-modules (localchimera scope root) (localchimera vf schemas))
(use-modules (goblins) (goblins persistence-store memory) (srfi srfi-1))
(use-modules ((localchimera utils clock) #:select (now days->seconds instant->civil))
             ((localchimera observation observer) #:select (void-event))
             ((localchimera test scope) #:select (record-work!)))

(define (approx= a b) (< (abs (- a b)) 1e-9))
(define (days-ago d) (instant->civil (- (now) (days->seconds d))))

(define* (diffuse! obs aid hours eid #:key process when)
  "Work with no recipient's word: no satisfies, dated WHEN (or undated)."
  ($ obs 'record-event
     (make-economic-event
       #:id eid #:action 'work #:output-of process #:resource-conforms-to "commons-care"
       #:provider aid #:effort-quantity (make-measure hours %effort-unit)
       #:has-beginning when #:has-point-in-time when)))

(define mem-store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Lapse Test")) mem-store))

(display "\n── in the window: pending, and zero in the fold ──\n")
(with-vat vat
  (let ((obs ($ scope 'observer)))
    (diffuse! obs "ana" 6 "d1" #:when (days-ago 1))
    (check "the credit fold counts the windowed hours zero"
           (approx= 0 ($ obs 'validated-gross "ana")))
    (check "pending-gross holds them whole"
           (approx= 6 ($ obs 'pending-gross "ana")))
    (check "scope-wide pending is the same reading, unkeyed"
           (approx= 6 ($ obs 'pending-gross)))))

(display "\n── at the lapse: the hours move whole, pending to validated ──\n")
(with-vat vat
  (let ((obs ($ scope 'observer)))
    (diffuse! obs "ana" 4 "d2" #:when (days-ago 8))
    (check "the lapsed hours vest in full"
           (approx= 4 ($ obs 'validated-gross "ana")))
    (check "…and leave pending"
           (approx= 6 ($ obs 'pending-gross "ana")))
    (check "validated + pending = every diffuse hour, one conservation"
           (approx= 10 (+ ($ obs 'validated-gross "ana") ($ obs 'pending-gross "ana"))))))

(display "\n── a recipient's word reaches the process: the word governs ──\n")
(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; a recipient states a desire of 10 on "tend"; bea's directed event
    ;; brings 4 → the process carries a word, satisfied 0.4.
    ($ obs 'register-intent
       (make-intent #:id "i-tend" #:action 'work #:resource-conforms-to "spec-labor" #:effort-quantity (make-measure 10 %effort-unit)
                    #:provider "bea"))
    ($ obs 'record-event
       (make-economic-event
         #:id "w1" #:action 'work #:input-of "tend" #:resource-conforms-to "spec-labor"
         #:provider "bea" #:effort-quantity (make-measure 4 %effort-unit)
         #:has-beginning (days-ago 8) #:has-point-in-time (days-ago 8) #:satisfies "i-tend"))
    ;; cal's diffuse hours on the same process, long past the window:
    ;; the aggregate word (0.4) governs, the lapse vests nothing extra.
    (diffuse! obs "cal" 10 "d3" #:process "tend" #:when (days-ago 9))
    (check "the process's aggregate fraction prices cal's hours"
           (approx= 4 ($ obs 'validated-gross "cal")))
    (check "…and the word's presence keeps them out of pending"
           (approx= 0 ($ obs 'pending-gross "cal")))))

(display "\n── silence-vested hours stay home ──\n")
(with-vat vat
  (let ((obs ($ scope 'observer)))
    (check "the federation-level reading leaves ana's lapsed hours out"
           (approx= 0 ($ obs 'validated-gross "ana" "Region")))))

(display "\n── the contest's void takes lapsed hours back out ──\n")
(with-vat vat
  (let ((obs ($ scope 'observer)))
    ($ obs 'record-event (void-event ($ obs 'get-event "d2") "d2-void" "contested and voided" #f (days-ago 0)))
    (check "the voided event leaves the fold"
           (approx= 0 ($ obs 'validated-gross "ana")))
    (check "the windowed hours stand untouched"
           (approx= 6 ($ obs 'pending-gross "ana")))))

(display "\n── undated work opens no window ──\n")
(with-vat vat
  (let ((obs ($ scope 'observer)))
    (diffuse! obs "dev" 5 "d4")
    (check "no instant, no lapse: the fold waits for a word"
           (approx= 0 ($ obs 'validated-gross "dev")))
    (check "…and pending states only open windows"
           (approx= 0 ($ obs 'pending-gross "dev")))))

;; ── a commitment that stands for an intent has a word, so the window has none ──
(display "\n── work that fulfils a commitment for an intent waits on that intent, not the window ──\n")
(with-vat vat
  (let ((obs ($ scope 'observer)))
    ($ obs 'register-intent
       (make-intent #:id "i-bo" #:action 'work #:resource-conforms-to "commons-care"
                    #:effort-quantity (make-measure 3 %effort-unit) #:provider "bo"))
    ($ obs 'register-commitment
       (make-commitment #:id "wc-bo" #:action 'work #:resource-conforms-to "commons-care"
                        #:effort-quantity (make-measure 3 %effort-unit) #:provider "bo" #:satisfies "i-bo"))
    ($ obs 'record-event
       (copy-economic-event
        (make-economic-event #:id "d-bo" #:action 'work #:resource-conforms-to "commons-care" #:provider "bo" #:effort-quantity (make-measure 1 %effort-unit)
                             #:has-beginning (days-ago 1) #:has-point-in-time (days-ago 1))
        #:fulfills "wc-bo"))
    (check "the intent's word governs the hours: none are pending on the window"
           (approx= 0 ($ obs 'pending-gross "bo")))))

(test-summary!)
