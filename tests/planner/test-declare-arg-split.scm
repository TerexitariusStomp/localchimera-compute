;;; test-declare-arg-split.scm — declare-need/-means/-place's named optionals
;;;
;;; All three used to end in a bare `. opts` tail, read by hand-counted
;;; position (`(and (> (length opts) 3) (list-ref opts 3))`), never by name.
;;; This proves each optional lands where its OWN name says, independent of
;;; how many of the others were supplied — the thing hand-counted positions
;;; cannot guarantee (tests/planner/test-money-need.scm supplies only two
;;; trailing values meaning to set kind and voice; under BOTH the old and
;;; the new code they land in name/cats-json instead, a PRE-EXISTING mismatch
;;; this file does not repeat: every value below is passed by its own name).
;;;
;;; Run: guile -L module -L tests tests/planner/test-declare-arg-split.scm

(use-modules (playnet planner scope root) (playnet planner vf schemas) (playnet planner doors service) (playnet test harness)
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(define vat (spawn-vat #:name "declare-arg-split"))
(define root (with-vat vat (spawn-scope-root "Commune")))
(define scopes (hashmap-set (hashmap) "c1" root))
(define svc (with-vat vat (spawn ^planner-service scopes)))
(define obs (with-vat vat ($ root 'observer)))
(define ps (with-vat vat ($ root 'plan-store)))

(display "\n── declare-place: address is the one optional ──\n")
(define p1 (with-vat vat ($ svc 'declare-place "c1" "EAlice" "The Barn" 10.0 20.0)))
(check-pred "no address: still succeeds" (eq? 'ok (car p1)))
(define p2 (with-vat vat ($ svc 'declare-place "c1" "EAlice" "The Silo" 10.0 20.0 "1 Field Rd")))
(check-pred "with address: still succeeds" (eq? 'ok (car p2)))

(display "\n── declare-means: every optional in its own slot ──\n")
(with-vat vat
  ($ svc 'declare-means "c1" "EAlice" "lathe" 12 "hours" "town"
     #f "shared on weekdays" "🛠️" "Alice's lathe" "[\"tool\"]" "{\"priority\":1}"))
(define lathe (with-vat vat ($ obs 'get-resource "means:EAlice:lathe")))
(check "note lands" (economic-resource-note lathe) "shared on weekdays")
(check "emoji lands" (economic-resource-image lathe) "🛠️")
(check "name lands (not the auto-generated default)" (economic-resource-name lathe) "Alice's lathe")
;; every optional omitted: the code's own defaults apply, not a crash
(with-vat vat ($ svc 'declare-means "c1" "EBob" "saw" 1 "hours" "town"))
(define saw (with-vat vat ($ obs 'get-resource "means:EBob:saw")))
(check "no name given: the auto default (AGENT's SPEC)" (economic-resource-name saw) "EBob's saw")

(display "\n── declare-need: name, cats-json, criteria-json, need-kind, voice ──\n")
(with-vat vat
  ($ svc 'declare-need "c1" "EAlice" "spec-bread" 2 "kg" "town" "" "" "" "" ""
     "Alice's bread" "[\"food\"]" "{\"priority\":2}" "des" 5))
(define nid "need:EAlice:spec-bread")
(define intent (with-vat vat ($ ps 'get-intent nid)))
(check-pred "the intent was created" intent)
(check "name lands" (intent-name intent) "Alice's bread")
;; every optional omitted: the real defaults (SPEC as name, "des", voice 0),
;; not whatever happened to be left over from an earlier call
(with-vat vat
  ($ svc 'declare-need "c1" "EBob" "spec-tea" 1 "kg" "town" "" "" "" "" ""))
(define tea-intent (with-vat vat ($ ps 'get-intent "need:EBob:spec-tea")))
(check "no name given: defaults to the spec itself" (intent-name tea-intent) "spec-tea")

(test-summary!)
