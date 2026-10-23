;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-comms-mandate.scm — permission to speak IS a competence on publish work.
;;;
;;; The last "not derived" item collapses too. A governance mandate to speak in
;;; the scope's voice is not a bolt-on gate — it is a COMPETENCE the publish
;;; `work` flow requires, exactly as legal/gate.scm renders a licence as a skill
;;; ("a person `obtain` IS a skill", legal/gate.scm:51). So permission-ENFORCEMENT
;;; is the ordinary skill-match: no agent holding `mandate:speak` is schedulable ⇒
;;; the publish work cannot be filled ⇒ publish fills 0 ⇒ nothing is said. The
;;; GRANT of the mandate stays a governance act (upstream); only its enforcement
;;; folds into the same solve as fragility / scheduling / selection.
;;;
;;; compose (work: copywriting) → post-draft; publish (work: mandate:speak) uses a
;;; channel + the draft → reach. Two runs: with and without a mandate-holder.
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner \
;;;         tests/solve/test-comms-mandate.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet knowledge dsl shorthand))
(use-modules (playnet solve report) (playnet solve engine) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas))
;; comms/metabolism.scm is a fragment over the engine's world: it loads into
;; this module and reads the engine through the imports above.
(primitive-load (%search-load-path "playnet/comms/metabolism.scm"))

(define fails 0)
(define (check* label pass?) (unless pass? (set! fails (+ fails 1)))
  (format #t "  ~a: ~a~%" (if pass? "ok" "FAIL") label))

;; compose needs the COPYWRITING skill; publish needs the SPEAK MANDATE.
(define compose-tpl
  (car (compile-recipe (list (rp "compose" "Compose"))
         (list (out "c1" "post-draft" 1.0 "compose")
               (wk* "c2" "copywriting" 0.5 "compose")))))
(define publish-tpl
  (car (compile-recipe (list (rp "publish" "Publish"))
         (list (in "p1" "post-draft" 1.0 "publish") (out "p2" "reach" 1.0 "publish")
;; the `use` draw is denominated in HOURS, like the cap it draws against.
               ;; It said "slot", which is not a time unit, and `publish` states no
               ;; has-duration — so the untimed-`use` fallback gave each run the
               ;; RUN'S OWN LENGTH, i.e. the whole 24 h period. One publish then
               ;; monopolised the channel for a day and a cap of 100 bought
               ;; 100/24 = 4.17 runs, whatever the demand: reach saturated at 4.17
               ;; from demand 5 upward, which is what made this look like an unmet
               ;; want rather than a unit mismatch. The invariant is the one
               ;; test-use-unit-lint holds: a use's draw and its spec's capacity are
               ;; denominated the same way.
               (use* "p3" "chan" "publish" 1.0 #:qty 1.0)
               (wk* "p4" "mandate:speak" 0.1 "publish")))))

(define (run-campaign workers)
  (declare-world! #:places '(("town" 0.0 0.0))
                  #:templates (list compose-tpl publish-tpl)
                  #:workers workers)
  (hash-set! *cap* (lg "Svc|chan" (cell "town" 0)) 100.0)   ; channel ample
  (hash-set! *demand* (lg "reach" (cell "town" 0)) 20.0)    ; the need
  (call-with-values comms-solve
    (lambda (x t cols idx report)
      (cons (cdr (car (process-schedule x idx "publish" "town" '(0))))    ; reach published
            (cdr (car (process-schedule x idx "compose" "town" '(0))))))) ; drafts composed
  )

;;; ─── WITH a mandate-holder : the campaign schedules ────────────────────────
(display "\n── a mandate-holder is available → the campaign is scheduled ──\n")
(define mandated
  (run-campaign (list (list "spokesperson" '("copywriting" "mandate:speak") (cell "town" 0) 100.0))))
(format #t "  published reach = ~,2f   composed drafts = ~,2f~%" (car mandated) (cdr mandated))
(check* "the reach need is met when a mandate-holder can do the publish work"
        (> (car mandated) 15.0))

;;; ─── WITHOUT a mandate-holder : the campaign CANNOT be scheduled ───────────
;;; A writer holds copywriting but NOT the speak mandate. Drafts could be written,
;;; but nothing may be PUBLISHED in the scope's voice — the work can't be filled.
(display "\n── no mandate-holder → nothing is said (permission enforced by scheduling) ──\n")
(define unmandated
  (run-campaign (list (list "writer" '("copywriting") (cell "town" 0) 100.0))))
(format #t "  published reach = ~,2f   composed drafts = ~,2f~%" (car unmandated) (cdr unmandated))
(check* "with no mandate-holder, publish fills 0 (nothing is said)"
        (< (car unmandated) 0.01))
(check* "the reach need goes unmet — permission is a hard prerequisite"
        (< (car unmandated) 0.01))
(check* "the mandate skill is unavailable at the cell (skilled-worker-at? #f)"
        (not (skilled-worker-at? "mandate:speak" (cell "town" 0))))
(check* "the SAME setup with the mandate granted DID schedule (the gate, not scarcity)"
        (> (car mandated) (* 100.0 (max 1e-9 (car unmandated)))))

(format #t "~%=== comms-mandate: ~a failure(s) ===~%" fails)
(exit (if (zero? fails) 0 1))
