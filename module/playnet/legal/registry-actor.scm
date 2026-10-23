;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; legal-registry-actor.scm — the legal rule registry as a governance actor,
;;; the SIBLING of tension-registry.scm (legal-crossings.md §7, §11).
;;;
;;; Registering or repealing a law is a production-governance act, so — by the
;;; coinductive-at-boundaries principle — the registry is an ACTOR: an event-
;;; sourced catalogue of guarded demands, custodied, handing the fold a read-
;;; only view. The per-(crossing,jurisdiction) MATH stays in legal/registry.scm
;;; (the pure fold the emitter and the hot path read); this file only wraps it
;;; in governance, exactly as tension-registry wraps tension-kinds.
;;;
;;; A `forbid` the registry yields IS a possibility-tension — it prunes the
;;; activity's column in the solve (see tests/scope/test-legal-gate.scm).
;;;
;;; Run:  guile -L . module/playnet/legal/registry-actor.scm

(define-module (playnet legal registry-actor)
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib facet)
  #:export (^legal-registry legal-registry-env restore-legal-registry lr-rule-banland
            lr-rule-permit parent-of ctx-at lr-demo)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib facet)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (playnet legal registry)
  #:use-module ((playnet utils catch) #:select (catch* throw* with-throw-handler*)))


;; the pure fold + vocabulary: legal-demands, rule, guards, legal-rule-label …

;;; ─── the actor : the rule catalogue, custodied ───────────────────────────
;;; register!/repeal mutate by spawning a successor (bcom) — event-sourced.
;;; `demands`/`forbids?` fold the live rule set; `compile` hands out a flat
;;; snapshot the fold can read with zero actor overhead per call (one turn per
;;; solve, like tension-registry's `compile`).
;;; A define-actor, so a ^scope-root that holds one persists it with its other
;;; stores: the Goblins portrait IS the rule-pack form (rules->sexp), the same
;;; plain data `save-rule-pack` writes, so a vat's persisted law and a steward's
;;; folder are one shape. The `portrait` METHOD below is that same read for
;;; callers outside persistence (tests, the law face).
(define-actor (^legal-registry bcom rules)
  #:portrait (lambda () (list (rules->sexp rules)))
  #:version 1
  #:restore (lambda (version sexps)
              (case version
                ((1) (spawn ^legal-registry (sexp->rules sexps)))
                (else (error "^legal-registry: unknown portrait version" version))))
  (methods
   [(rules) rules]                                   ; governance view
   [(labels) (map legal-rule-label rules)]
   [(register! r)                                    ; a production-governance act
    (if (member (legal-rule-label r) (map legal-rule-label rules))
        (bcom (^legal-registry bcom rules) 'already)
        (bcom (^legal-registry bcom (cons r rules)) 'ok))]
   [(repeal label)                                   ; drop a law, recompute
    (bcom (^legal-registry bcom
            (filter (lambda (r) (not (equal? label (legal-rule-label r)))) rules))
          'ok)]
   [(compile) rules]                                 ; flat snapshot for the fold
   ;; AS-OF is optional: given, only the rules in force that day are folded;
   ;; omitted, the whole catalogue stands — the timeless read.
   [(demands ctx . as-of)                            ; the bill at a context
    (call-with-values
        (lambda () (legal-demands ctx #:rules rules
                                  #:as-of (and (pair? as-of) (car as-of))))
      list)]
   [(forbids? ctx . as-of)                           ; the possibility-tension query
    (call-with-values
        (lambda () (legal-demands ctx #:rules rules
                                  #:as-of (and (pair? as-of) (car as-of))))
      (lambda (bill hits) (eq? (bill-stance bill hits) 'off)))]
   [(portrait) (rules->sexp rules)]))                ; PLAIN DATA — disk-persistable

(define legal-registry-env
  (make-persistence-env
    `((((playnet legal registry-actor) ^legal-registry) ,^legal-registry))))                ; PLAIN DATA — disk-persistable
;;; The guard is a serializable FORM (not a closure), so portrait is plain
;;; S-expressions that `write`/`read` round-trips to disk — the registry now
;;; persists like tension-registry's symbol tags, only with richer data.
(define (restore-legal-registry sexps) (spawn ^legal-registry (sexp->rules sexps)))

;;; ─── demonstration (only when run as a script) ───────────────────────────
(define (lr-rule-banland)
  (rule (all-of (in-jurisdiction "banland") (on-crossing 'share-food))
        (list (forbid #:reason "public food-sharing ordinance"))
        #:label "banland/no-sharing" #:source "(example ordinance)"
        #:confidence 'verified #:steward "scope:test"))
(define (lr-rule-permit)
  (rule (all-of (in-jurisdiction "permitland") (on-crossing 'share-food))
        (list (obtain #:rides 'entity #:name "Temporary Food permit"
                      #:per 'each-event #:spec '(handwashing temp-control)))
        #:label "permitland/permit" #:source "(example code)"
        #:confidence 'verified #:steward "scope:test"))
(define (parent-of id) (if (member id '("banland" "permitland")) "world" #f))
(define (ctx-at place) (legal-context #:crossings '(share-food)
                                      #:place-path (jurisdiction-path place parent-of)
                                      #:act 'activity))

(define (lr-demo)
  (define vat (spawn-vat))
  (with-vat vat
    (define reg (spawn-named "legal-registry" ^legal-registry
                            (list (lr-rule-banland) (lr-rule-permit))))
    (format #t "~%── 1 · the catalogue (governance view) ──~%")
    (format #t "  laws: ~a~%" ($ reg 'labels))
    (format #t "~%── 2 · forbids? — the possibility-tension query ──~%")
    (format #t "  banland forbids share-food : ~a~%"   ($ reg 'forbids? (ctx-at "banland")))
    (format #t "  permitland forbids?        : ~a (a permit, not a ban)~%"
            ($ reg 'forbids? (ctx-at "permitland")))
    (format #t "~%── 3 · governance — repeal the ban (event-sourced) ──~%")
    (format #t "  repeal banland/no-sharing → ~a~%" ($ reg 'repeal "banland/no-sharing"))
    (format #t "  banland forbids now        : ~a  (the ban withered)~%"
            ($ reg 'forbids? (ctx-at "banland")))
    (format #t "~%── 4 · attenuation — the fold gets a read-only facet ──~%")
    (let ((solver (facet reg 'compile 'forbids? 'demands)))
      (format #t "  facet forbids? permitland  : ~a~%" ($ solver 'forbids? (ctx-at "permitland")))
      (format #t "  facet register! (denied)   : ~a~%"
              (catch* #t (lambda () ($ solver 'register! (lr-rule-banland)) "UNEXPECTED")
                     (lambda _ "✓ denied (not on facet)"))))
    (format #t "~%── 5 · portrait → restore (in-process) ──~%")
    (let ((revived (restore-legal-registry ($ reg 'portrait))))
      (format #t "  restored laws: ~a  ~a~%" ($ revived 'labels)
              (if (equal? ($ reg 'labels) ($ revived 'labels)) "✓ round-trips" "✗")))
    (newline)))

;; run as a program on a host; a page loads this as a library only
(cond-expand
 (guile
  (when (and (pair? (command-line))
             (string-suffix? "legal-registry-actor.scm" (car (command-line))))
    (lr-demo)))
 (else))
