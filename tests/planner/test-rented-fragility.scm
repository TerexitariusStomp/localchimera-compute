;;; test-rented-fragility.scm — the GENERAL rented/tenure fragility.
;;;
;;; A resource held under SPLIT tenure — custody here, rights elsewhere — is one
;;; fragility, whether it is a rented social-media channel (the platform can
;;; deplatform you) or a temporarily-socialized means of production (the owner can
;;; recall the grant). This proves the ONE predicate (schemas.scm) classifies both,
;;; that comms's channel-rented? is now just an alias for it, that the profile is a
;;; single source of truth, and that rented-spec-fragilities — the fragility twin of
;;; svc-eco-caps — folds any such resource into eco-spec-frag entries on its Svc|
;;; service good. No solve, no observer ⇒ pure data.
;;;
;;; Run: guile -L module tests/planner/test-rented-fragility.scm

(use-modules (playnet test harness) (playnet vf schemas) (srfi srfi-1))

;; tests run from the repository root (each file's own Run: line); the root is
;; resolved by its marker rather than by current-filename, which is #f or
;; -L-relative depending on how the file was loaded — both wrong for paths.
(define root (or (and (file-exists? "module/playnet/solve/engine.scm") (getcwd))
                 (error "run this test from the repository root")))
(define here (string-append root "/tests/planner"))
(load (string-append root "/module/playnet/comms/fragility.scm"))  ; channel-resource + the aliases

;; a resource with an explicit custody/rights split (positions mirror channel-resource)
(define (res id spec accountable custody)
  (make-economic-resource
   #:id id #:name id          ; id name note image tracking-identifier
   #:conforms-to spec #:classified-as '("infrastructure") ; conforms-to classified-as
   #:primary-accountable accountable #:custodian-scope custody      ; primary-accountable custodian-scope
))

(define me "org:me")
;; three tenures from THIS scope's view:
(define retic  (res "r1" "spec:channel-reticulum" me me))            ; sovereign — I hold the rights
(define rented (res "r2" "spec:channel-x"          "org:x" me))      ; rented — platform holds rights, I custody
(define bike   (res "r3" "spec:bike"               "owner:ana" me))  ; loaned-in means — owner holds rights
(define bike2  (res "r4" "spec:bike"               "owner:bo" me))   ; a SECOND borrowed bike, same spec

;;; ─── 1. ONE predicate classifies every tenure ──────────────────────────────
(display "\n── resource-rented? / resource-sovereign? : the one tenure test ──\n")
(check "a channel I am primary-accountable for is SOVEREIGN"   (resource-sovereign? retic me) #t)
(check "a channel the platform is accountable for is RENTED"   (resource-rented? rented me) #t)
(check "a loaned-in means (owner keeps the rights) is RENTED"  (resource-rented? bike me) #t)
(check "sovereign is exactly not-rented"                       (resource-rented? retic me) #f)
(check "rented from MY scope is not rented from the owner's"   (resource-rented? bike "owner:ana") #f)
(check "scope-free (no scope arg): custody split from rights is rented" (resource-rented? bike) #t)
(check "scope-free: a sovereign resource is never rented"      (resource-rented? retic) #f)

;;; ─── 2. comms names are aliases — not a second predicate ───────────────────
(display "\n── channel-rented? is the SAME procedure, not a copy ──\n")
(check "channel-rented? IS resource-rented?"       (eq? channel-rented? resource-rented?) #t)
(check "channel-sovereign? IS resource-sovereign?" (eq? channel-sovereign? resource-sovereign?) #t)
(check "the comms profile IS the general profile"  (equal? comms-rented-profile %rented-frag-profile) #t)

;;; ─── 3. rented-goods — the split-tenure resources' Svc| service goods ───────
(display "\n── rented-goods: split-tenure → its Svc| good, deduped ──\n")
(define goods (rented-goods (list retic rented bike bike2) me))
(check "only the rented resources contribute (sovereign drops out)"
       (sort goods string<?)
       (sort (list "Svc|spec:channel-x" "Svc|spec:bike") string<?))
(check "two borrowed bikes of one spec share ONE good (deduped by spec)"
       (length (filter (lambda (g) (equal? g "Svc|spec:bike")) goods)) 1)

;;; ─── 4. scope-free form — the right test inside a scope's OWN view ──────────
;;; (the wire uses no scope: every resource in the view is already held here, so a
;;; custody≠rights split IS loaned-in — no need to name the scope.)
(display "\n── scope-free: a split within one's own view is loaned-in ──\n")
(define goods* (rented-goods (list retic rented bike)))
(check "scope-free finds the same rented specs"
       (sort goods* string<?)
       (sort (list "Svc|spec:channel-x" "Svc|spec:bike") string<?))
(check "a sovereign resource never contributes, scope-free either"
       (member "Svc|spec:channel-reticulum" goods*) #f)

;;; ─── 5. the shared tip is ONE exported constant (no re-derivation) ──────────
(display "\n── the shared profile: %rented-frag-tip = quantile_alpha[lo,hi] ──\n")
(check "tip = 4 (lean on ~4 units of borrowed capacity before it bites)" %rented-frag-tip 4.0)
(check "weight = 1 (the governance steepness)" (list-ref %rented-frag-profile 3) 1.0)

;;; ─── 6. per-spec overrides: recall does not cost every dependence equally ───
;; Pulling a channel loses reach; pulling a bed loses someone's HOME. The
;; housing rows bite sooner and twice as steeply; a spec with no row of its own
;; reads the shared profile, so the one source of truth stays one.
(display "\n── per-spec profiles: housing bites sooner and steeper ──\n")
(check "an unnamed spec reads the shared profile"
       (rented-frag-profile "spec:channel-x") %rented-frag-profile)
(check "…and the shared tip" (rented-frag-tip "spec:channel-x") %rented-frag-tip)
(check "a bed's tip = 2 — half the lean the shared profile tolerates"
       (rented-frag-tip "spec-bed") 2.0)
(check "a bed's weight = 2 — twice the steepness (recall = displacement)"
       (list-ref (rented-frag-profile "spec-bed") 3) 2.0)
(check "the dwelling row matches its beds (one housing dial, two carriers)"
       (rented-frag-profile "spec-dwelling") (rented-frag-profile "spec-bed"))

(display "\n")
(test-summary!)
