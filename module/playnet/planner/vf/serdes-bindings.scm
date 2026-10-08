;;; serdes-bindings.scm — Register every VF record type for generic serdes
;;;
;;; This is the one place to add a new record type to the persistence
;;; pipeline. After (register-vf-record! <my-type>), `vf-serialize` and
;;; `vf-deserialize` from `lib/utils/serdes.scm` handle round-tripping
;;; through goblins persistence — including nested records and lists
;;; of records.
;;;
;;; A module whose whole body is one side effect. Its "loaded after schemas.scm
;;; and serdes.scm" ordering used to be the umbrella's job to get right, and both
;;; umbrellas included it, so the registration ran twice. Imports state the order
;;; and the module system runs the body exactly once.
;;;
;;; A family that stands apart from the vocabulary registers its own types where
;;; it defines them (ddmrp/records.scm does).
;;;
;;; If you add a new <foo> record to lib/schemas.scm, add
;;; (register-vf-record! <foo>) here. Forgetting it produces a clear
;;; error at the first attempt to serialize an instance — not a silent
;;; persistence corruption like before.

(define-module (playnet planner vf serdes-bindings)
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner vf serdes))

(register-vf-records!
  ;; Primitives
  <measure>
  <duration>
  <unit>
  <spatial-thing>

  ;; Action behavioral table
  <action-definition>

  ;; Agents
  <agent>
  <agent-relationship-role>
  <agent-relationship>

  ;; Knowledge layer — specifications
  <resource-specification>
  <process-specification>

  ;; Knowledge layer — recipes
  <recipe-flow>
  <recipe-process>
  <recipe-exchange>
  <recipe>
  <recipe-group>

  ;; Observation layer
  <economic-resource>
  <economic-event>
  <process>

  ;; Planning layer — intents/commitments/claims
  <intent>
  <commitment>
  <claim>
  <plan>
  <scenario-definition>
  <scenario>
  <agreement>
  <agreement-bundle>
  <proposal>
  <proposal-list>)
