;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-comms-fragility.scm — channel concentration is measurably more fragile.
;;;
;;; Proves the tag→barrier bridge (comms/fragility.scm): a campaign that reaches
;;; the commons only through RENTED channels scores hotter on the SAME frag
;;; barrier (φ = −w·log s) the ecological layer uses than one that spreads across
;;; rented + OWNED (self-run) channels — with no new solver machinery. Part (b)
;;; runs a real solve-native and shows the planner ROUTES reach onto the owned
;;; channel to stay off fragile rented infra.
;;;
;;; Run:  guile --no-auto-compile -L module/localchimera/planner \
;;;         tests/solve/test-comms-fragility.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (localchimera solve engine) (localchimera solve world)
             (localchimera solve solver)
             (localchimera vf schemas))
;; comms/fragility.scm is a fragment over the engine's world: it loads into
;; this module and reads the engine through the imports above.
(primitive-load (%search-load-path "localchimera/comms/fragility.scm"))

(define (check label got expected)
  (if (equal? got expected)
      (format #t "  ok: ~a~%" label)
      (format #t "  FAIL: ~a~%    expected: ~s~%    got: ~s~%" label expected got)))
(define fails 0)
(define (check* label pass?) (unless pass? (set! fails (+ fails 1)))
  (format #t "  ~a: ~a~%" (if pass? "ok" "FAIL") label))

;; held channel resources — ownership is a fact about the RESOURCE, not a spec tag.
;; (positional make-economic-resource: id name note image tracking conforms-to
;;  classified accounting onhand loc vloc primary-accountable custodian stage
;;  state contained-in unit lot prev avail — primary-accountable @12, custodian @13.)
(define SCOPE "scope:us")
(define (chan-res id conforms accountable custodian)
  (make-economic-resource #:id id #:name id #:conforms-to conforms
                          #:classified-as '("infrastructure" "channel")
                          #:primary-accountable accountable #:custodian-scope custodian))
;; X: the scope has CUSTODY but the platform holds the rights → rented.
(define x-account (chan-res "res:x" "spec:channel-x" "org:twitter" SCOPE))
;; self-hosted Mastodon: the scope is primary-accountable → sovereign.
(define mastodon  (chan-res "res:masto" "spec:channel-mastodon" SCOPE SCOPE))

;; three ways to deliver a 2-post campaign
(define concentrated (list (cons x-account 2)))                ; both via rented
(define diversified  (list (cons x-account 1) (cons mastodon 1))) ; one each
(define sovereign    (list (cons mastodon 2)))                 ; both self-run

;;; ─── (a) the rights/custody test : who can deplatform you ──────────────────
(display "\n── rented ⟺ custody without the rights (compliance's own test) ──\n")
(check* "the X account is rented (scope custodies, platform is accountable)"
        (channel-rented? x-account SCOPE))
(check* "self-hosted Mastodon is sovereign (scope is primary-accountable)"
        (and (channel-sovereign? mastodon SCOPE) (not (channel-rented? mastodon SCOPE))))

(display "\n── rented concentration draws down the barrier; sovereign draws nothing ──\n")
(check "concentrated draws 2 (both posts on rights-less infra)" (rented-draw concentrated SCOPE) 2)
(check "diversified draws 1 (the sovereign channel adds no pressure)" (rented-draw diversified SCOPE) 1)
(check "sovereign draws 0 (a channel the scope has rights to is not a fragility)" (rented-draw sovereign SCOPE) 0)

(display "\n── the SAME frag φ = −w·log(s) scores concentration hotter ──\n")
(check* "diversified keeps MORE rights-less headroom than concentrated"
        (> (campaign-rented-slack diversified SCOPE) (campaign-rented-slack concentrated SCOPE)))
(check* "concentrated is HOTTER (higher φ) than diversified"
        (> (campaign-fragility concentrated SCOPE) (campaign-fragility diversified SCOPE)))
(check* "the all-sovereign campaign is the coolest of the three"
        (< (campaign-fragility sovereign SCOPE) (campaign-fragility diversified SCOPE)))
(check* "leaning on rights-less infra past its headroom is deplatform-fatal (+inf)"
        (= (campaign-fragility (list (cons x-account 4)) SCOPE) +inf.0))

;;; ─── (b) a real solve : the planner routes reach onto the owned channel ────
;;; x0 = posts via rented (draws the frag barrier), x1 = posts via owned (free).
;;; Both deliver reach; a desire wants reach = x0+x1 ≥ D. The solver should push
;;; reach onto x1 to avoid the rented φ.
(display "\n── solve: equal reach, the planner prefers the owned channel ──\n")
(define D 3.0) (define wd 5.0)
(define forms
  (list (mk-des (mk-bar 0.0 '((0 . 1.0) (1 . 1.0))) D wd)   ; want x0+x1 → D (reach)
        (mk-bar D '((0 . -1.0) (1 . -1.0)))                 ; reach ≤ D (no waste)
        (mk-frag comms-rented-tip '((0 . -1.0)) comms-rented-weight) ; rented x0 is fragile
        (mk-bar 0.0 '((0 . 1.0)))                           ; x0 ≥ 0
        (mk-bar 0.0 '((1 . 1.0)))))                         ; x1 ≥ 0
(call-with-values (lambda () (solve-native forms '() (vector 0.5 0.5)))
  (lambda (x t . _)
    (let ((x0 (vector-ref x 0)) (x1 (vector-ref x 1)))
      (format #t "  solved: rented x0=~,3f  owned x1=~,3f  (reach=~,3f)~%" x0 x1 (+ x0 x1))
      (check* "the planner routes MORE reach through the owned channel (x1 > x0)"
              (> x1 x0))
      (check* "reach is still met (x0+x1 ≈ D)" (> (+ x0 x1) (* 0.8 D))))))

;;; ─── (c) the platform registry : real platforms classified by tenure ───────
(display "\n── real platforms: X/IG/Threads rented; self-hosted sovereign ──\n")
(define UC "scope:uc")
(define (rented-plat? p) (channel-rented? (channel-resource "c" p UC) UC))
(check* "X is rented (X/Meta is primary-accountable, can deplatform)" (rented-plat? 'x))
(check* "Instagram is rented"                                         (rented-plat? 'instagram))
(check* "Threads is rented"                                           (rented-plat? 'threads))
(check* "a HOSTED Mastodon is rented (the instance admin can suspend)" (rented-plat? 'mastodon))
(check* "a self-hosted Mastodon is SOVEREIGN"
        (channel-sovereign? (channel-resource "m" 'mastodon UC #:self-hosted? #t) UC))
(check* "Reticulum is always sovereign"
        (channel-sovereign? (channel-resource "r" 'reticulum UC) UC))
(check* "an UNKNOWN platform is assumed rented (fail-safe)"           (rented-plat? 'somenewthing))
;; and the scoring composes over real platforms:
(let ((all-rented (list (cons (channel-resource "x1" 'x UC) 2)))
      (mixed      (list (cons (channel-resource "x2" 'x UC) 1)
                        (cons (channel-resource "m1" 'mastodon UC #:self-hosted? #t) 1))))
  (check* "a campaign only on X is hotter than one split with self-hosted Mastodon"
          (> (campaign-fragility all-rented UC) (campaign-fragility mixed UC))))

;;; ─── (d) build-located integration : frag caps DERIVED from rights/custody ─
(display "\n── seed-channel-fragility!: rented channels get a cap, sovereign none ──\n")
(declare-world! #:places '(("town" 0.0 0.0)))
(let ((x-ch (channel-resource "x1" 'x UC))
      (m-ch (channel-resource "m1" 'mastodon UC #:self-hosted? #t))
      (c    (cell "town" 0)))
  (seed-channel-fragility! UC (list x-ch m-ch) c)
  (check* "the RENTED X channel got a frag cap on its Svc good"
          (and (hash-ref *frag-cap* (lg "Svc|spec:channel-x" c) #f) #t))
  (check* "the SOVEREIGN Mastodon channel got NONE (fragility is derived)"
          (not (hash-ref *frag-cap* (lg "Svc|spec:channel-mastodon" c) #f))))

(format #t "~%=== comms-fragility: ~a failure(s) ===~%" fails)
(exit (if (zero? fails) 0 1))
