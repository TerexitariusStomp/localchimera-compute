;;; agent-tags.scm — the "key:value" tags an agent carries.
;;;
;;; A person's profile reaches the planner as typed tags on their Agent record
;;; ("age:34", "sleep:23:00-07:00", "away:2026-09-28..2026-09-30:sick"). This
;;; module is the one place that reads them: the subsistence context, the
;;; schedule and the labour pool all take a value the same way.
;;;
;;; Pure: no I/O, no mutation. Hoot/WASM compatible.

(define-module (playnet planner facts agent-tags)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner vf schemas)     ; agent-classified-as
  #:export (tag-value tag-values tag-number tag-key? agent-tag-value agent-tag-values %tag-keys))

(define (prefix-of key) (string-append key ":"))

;; The keys a "key:value" classification tag may carry, each read through
;; tag-value / tag-values and nowhere by a hand substring. A key read anywhere
;; in the planner stands here (tests/planner/test-tag-keys-registered.scm holds
;; every `string-prefix? "<key>:"` in the planner to this list, the time keys
;; (facts/agent-time) and the tension terms (facts/tension-terms)).
(define %tag-keys
  '("diet" "allergy" "excludes"      ; a person's diet (catalogues/diets, subsistence)
    "work"                           ; a process's work intensity (subsistence)
    "manner"                         ; a transport process's routing costing (compile, live)
    "self"                           ; a condition a person tells the commons (live)
    "skill"                          ; a skill spec's law, skill:<key>:<n> (formulas/skill-law)
    "attests"                        ; a dwelling's attestations (housing-substance)
    "jurisdiction"                   ; an adapter's mask (doors/adapters)
    "vf:perishability"               ; a food's perishability class (worlds/feel-the-food)
    "tag:plan"                       ; a plan's own tags (plan/store)
    "sex" "age" "pregnant" "lactating" "region" "labour-hours" "standard" "shed"   ; the profile (scope/live)
    "weight-kg" "height-cm" "altitude-m" "lat" "month"))

(define (tag-key? t key)
  "Is T a \"KEY:…\" tag?"
  (let ((pfx (prefix-of key)))
    (and (string? t) (>= (string-length t) (string-length pfx)) (string=? (substring t 0 (string-length pfx)) pfx))))

(define (tag-values tags key)
  "Every value of a \"key:value\" tag in TAGS, in order, as strings."
  (let* ((pfx (prefix-of key)) (n (string-length pfx)))
    (filter-map (lambda (t)
                  (and (string? t) (>= (string-length t) n) (string=? (substring t 0 n) pfx)
                       (substring t n)))
                tags)))

(define (tag-value tags key)
  "The value of the first \"key:value\" tag, as a string, or #f."
  (let ((vs (tag-values tags key))) (and (pair? vs) (car vs))))

(define (tag-number tags key fallback)
  (let* ((v (tag-value tags key)) (n (and v (string->number v))))
    (if (and n (real? n)) n fallback)))

(define (agent-tags a) (or (agent-classified-as a) '()))
(define (agent-tag-value a key) (tag-value (agent-tags a) key))
(define (agent-tag-values a key) (tag-values (agent-tags a) key))
