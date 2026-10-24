;;; docs/dev-scope.sexp — the development scope's people.
;;;
;;; One datum: a list of people, in module/localchimera/knowledge/
;;; recipes/dev.scm's own shape. Each states an ID and the HOURS they give
;;; localchimera's own development in a week — the one number the plan
;;; (module/localchimera/dev/plan.scm) weighs every want against.
;;; AREAS narrows the areas whose work they take (`all`, the default, is
;;; every area the week's issues name); ROLES narrows the meeting roles
;;; they take (`all` by default for a person, none for an agent, unless
;;; stated); KIND `agent` marks a machine — no body to feed, no seat at the
;;; meeting, and it never earns credit (module/localchimera/bridge/
;;; dev-ledger.scm books its work to a human, or not at all); DID, when
;;; stated, is the person's Radicle identity, read by tools/dev-loop-
;;; close.scm to credit a solved issue to its assignee when no commitment
;;; already names who did it.
;;;
;;; AID, when stated, is the real localchimera identity (a KERI AID, minted on
;;; whichever box's gateway you have gone through personhood on — a
;;; runtime, per-deployment fact this repo cannot state for you) a booked
;;; hour's `provider` field carries — what account.scm's `credit-balance`/
;;; `skill-hours-of` actually key on. Left unstated, a booking still lands,
;;; under your bare id above: real, and readable inside this one commune,
;;; but not yet recognized as YOUR identity by the credit system anywhere
;;; else. Fill it in once you know it; nothing else here needs to change.
;;;
;;; Read by tools/dev/dev-plan.scm, tools/dev/dev-signal-cycle.scm and
;;; tools/dev/dev-loop-close.scm; DEV_SCOPE_PATH overrides this path. Edit the
;;; hours here as they change — nothing else in the loop needs to know.

(((id . "ops") (hours . 30) (areas . all)
  (did . "did:key:z6MkhFnFe4dPHjHfZb4YAoYGf48AiaLAZHDj53yZBzfCJKVf")
  (aid . #f))   ; not yet filled in — see AID above
 ((id . "box") (hours . 20) (areas . all) (kind . agent)))
