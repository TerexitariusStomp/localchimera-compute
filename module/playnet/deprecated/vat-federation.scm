;;; vat-federation.scm — greenfield vat-spanning federation substrate
;;;
;;; Parallel companion to module/playnet/planner/relational/federation.scm.
;;; The existing federation is a deeply synchronous, ~950-line substrate
;;; built around a miniKanren goal (plan-federation-o). This module is the
;;; vow-native counterpart: leaf planners are actor refs, dispatch is
;;; parallel, and every public entry point returns a vow. It co-exists
;;; with the old federation; neither depends on the other.
;;;
;;; See docs/kan-comp/GOBLINS-KANREN.md for the underlying primitive
;;; (vat-spanning interleaved streams). This module layers a small
;;; federation protocol on top of that substrate, in phases:
;;;
;;;   Phase 1 (this file)
;;;     ^scope-leaf       — inventory-only capability-attenuated leaf
;;;     federate-demand   — parallel fan-out + greedy combine
;;;     plan-federate     — user-facing entry point
;;;
;;;   Phase 2 (noted, not built)
;;;     multi-demand federation (plan-federate-many)
;;;     lateral-match — surplus ↔ deficit across scopes
;;;     stream-based proposals via ^stream-actor
;;;
;;;   Phase 3+  retraction, harmony, real planner leaves, distributed netter
;;;
;;; NOT Hoot-compatible — uses goblins (native Guile only).

(define-module (playnet deprecated vat-federation)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib joiners)
  #:use-module (goblins actor-lib on)
  #:use-module (goblins actor-lib timers)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:export (^scope-leaf
            vow-all
            vow-allsettled
            with-sever-handling
            federate-demand
            federate-demand-resilient
            federate-demand-with-deadline
            lateral-match
            plan-federate
            plan-federate-resilient
            plan-federate-with-deadline))


;;; ── vow-all — parallel vow collection ─────────────────────────────────────
;;;
;;; Given N vows, return one vow that resolves to the list of their
;;; values in the original order. Handlers register immediately for all
;;; N — total latency is max(vow), not sum(vow). The existing
;;; vow-fold-async in federation/vows.scm is sequential; we need this
;;; parallel variant so slow peers don't block others in federation.

;;; `all-of*` from `(goblins actor-lib joiners)` is exactly the
;;; parallel-collect-vows primitive — we were hand-rolling it. Alias
;;; under our original name so callers don't change. The `#:promise?`
;;; variant wasn't needed either; Goblins handles short-circuit on
;;; first break internally.
(define vow-all all-of*)


;;; ── inexact-unless-int — Syrup/OCapN wire safety ────────────────────────
;;;
;;; Goblins' Syrup serialization format doesn't support exact rationals
;;; (it supports integers and inexacts). Any actor whose methods might
;;; return a rational-valued number over OCapN must coerce. We preserve
;;; integers untouched so existing tests that assert `(equal? c 1)` etc.
;;; keep passing — only non-integer rationals (1/2, 3/4, ...) are
;;; coerced to inexact (0.5, 0.75, ...). Non-numbers pass through.

(define (inexact-unless-int x)
  (if (and (rational? x) (not (integer? x))) (exact->inexact x) x))


;;; ── vow-allsettled — resilient parallel collection ────────────────────────
;;;
;;; Like vow-all, but each vow's outcome is captured individually as
;;; an outcome record. The combined vow NEVER breaks — it resolves
;;; with a list of outcomes even if some inputs broke. Mirrors
;;; JavaScript's Promise.allSettled. Use when partial success is
;;; acceptable (resilient federation, best-effort queries).
;;;
;;; Outcome shape:
;;;   (fulfilled . value)  — vow resolved successfully
;;;   (broken    . reason) — vow broke (peer dead, method error, timeout)
;;;
;;; Implementation: wrap each input vow so it NEVER breaks — fulfilled
;;; results become `(fulfilled . v)`, broken results become
;;; `(broken . err)`. Now `all-of*` can safely collect them since
;;; none of the wrapped vows can break the combined promise. Three
;;; lines of composition replacing ~25 lines of hand-rolled vector
;;; mutation + resolver juggling.

(define (vow-allsettled vows)
  (all-of*
   (map (lambda (v)
          (on v
              (lambda (val) (cons 'fulfilled val))
              #:catch (lambda (err) (cons 'broken err))
              #:promise? #t))
        vows)))


;;; ── with-sever-handling — composable dead-peer detection ────────────────
;;;
;;; Composable utility: for each far-ref in LEAF-REFS, register an
;;; on-sever handler that calls (ON-DEAD ref reason) if that peer's
;;; OCapN connection is severed (remote vat died, transport dropped).
;;; Calls BODY-THUNK; cancels all handlers when body returns.
;;;
;;; Local refs are ignored — they don't sever. If a local vat is
;;; killed, outstanding vows break via the normal vow-break path, not
;;; via on-sever.
;;;
;;; If a ref is already severed when registration happens, on-sever
;;; fires the handler immediately (Goblins guarantee). This gives
;;; early-warning without having to wait for the next <- to break.
;;;
;;; In plan-federate-resilient, this is used as a diagnostic: severed
;;; peers already surface as broken vows through vow-allsettled (the
;;; correctness path); with-sever-handling just makes the failure
;;; visible to logs/observers sooner.

(define (with-sever-handling leaf-refs on-dead body-thunk)
  ;; Register-and-forget: we don't cancel handlers when BODY returns,
  ;; because BODY typically returns a vow whose lifetime extends
  ;; beyond the thunk call — a severance could fire between body
  ;; returning and the vow resolving. Handlers live as long as the
  ;; refs do; when the refs are GC'd the handlers become unreachable.
  ;;
  ;; Guard with `remote-refr?` (not `far-refr?`). Goblins distinguishes:
  ;;   far-refr?    — needs <- to call (either cross-vat in-process OR
  ;;                  cross-process via OCapN)
  ;;   remote-refr? — specifically in a DIFFERENT process (OCapN).
  ;; on-sever is a CapTP/netlayer concept — it only makes sense for
  ;; refs whose connection CAN be severed, which is remote-refr? refs.
  ;; Calling on-sever on an in-process cross-vat ref raises a
  ;; match-error because no netlayer owns that reference. For
  ;; in-process refs, vat-death surfaces via normal vow-break paths.
  (for-each
    (lambda (ref)
      (when (remote-refr? ref)
        (on-sever ref
                  (lambda (severance-type reason)
                    (on-dead ref reason)))))
    leaf-refs)
  (body-thunk))


;;; ── ^scope-leaf — minimal capability-attenuated inventory leaf ────────────
;;;
;;; A scope-leaf is the smallest thing that counts as a federation
;;; member. It wraps an inventory alist (spec . qty) — the scope's
;;; private fact base — and exposes a single capability: propose-for.
;;; The full inventory is never sent anywhere; only what's relevant
;;; to the incoming demand is disclosed in the response.
;;;
;;; A real planner leaf would do much more (recipe lookup, CLP(FD)
;;; allocation, buffer-zone evaluation). This Phase-1 leaf is enough
;;; to demonstrate the shape and validate the cross-vat plumbing.

(define (^scope-leaf bcom scope-id inventory)
  (methods
   ((describe) scope-id)
   ((propose-for demand)
    ;; demand = (spec qty)
    (let* ((spec  (car demand))
           (need  (cadr demand))
           (have  (or (assoc-ref inventory spec) 0))
           (alloc (min have need))
           (unmet (- need alloc)))
      `((scope     . ,scope-id)
        (plan      . ((,spec . ,alloc)))
        (deficits  . ,(if (> unmet 0)
                          `(((scope-id . ,scope-id)
                             (spec-id  . ,spec)
                             (qty      . ,unmet)))
                          '()))
        (surpluses . ())
        (residual  . ,unmet)
        (coherence . ,(inexact-unless-int
                        (if (zero? need) 1 (/ alloc need)))))))))


;;; ── combine-results — greedy first-fit aggregation ────────────────────────
;;;
;;; Each leaf independently allocates min(have, need) from its own
;;; inventory; naive summation double-allocates when multiple scopes
;;; could each fully satisfy. Greedy first-fit walks the leaf results
;;; in order, giving each up to the remaining need. Deterministic in
;;; leaf-refs list order. Phase 2 will introduce smarter splitting
;;; (proportional, weighted, or bid-based) when we have per-scope
;;; coherence signals to bias with.

(define (combine-results leaf-results demand)
  (let* ((spec (car demand))
         (need (cadr demand))
         ;; Greedy first-fit: walk leaf-results, give each up to
         ;; (remaining-need), capped by what it offered.
         (final-allocs
           (let loop ((rs leaf-results) (remaining need) (out '()))
             (cond
              ((null? rs) (reverse out))
              (else
               (let* ((r        (car rs))
                      (sid      (assq-ref r 'scope))
                      (offered  (or (assoc-ref (assq-ref r 'plan) spec) 0))
                      (give     (min offered remaining)))
                 (loop (cdr rs)
                       (- remaining give)
                       (cons (list sid spec give) out)))))))
         (total-final (fold + 0 (map caddr final-allocs)))
         (residual    (max 0 (- need total-final))))
    `((scope     . federation)
      (demand    . ,demand)
      (plan      . ,(map (lambda (a)
                           (cons (car a) `((,(cadr a) . ,(caddr a)))))
                         final-allocs))
      (deficits  . ,(if (> residual 0)
                        `(((scope-id . federation)
                           (spec-id  . ,spec)
                           (qty      . ,residual)))
                        '()))
      (surpluses . ())
      (residual  . ,residual)
      (coherence . ,(inexact-unless-int
                      (if (zero? need) 1 (/ total-final need)))))))


;;; ── federate-demand — parallel fan-out ────────────────────────────────────

(define (federate-demand leaf-refs demand)
  "Send DEMAND = (spec qty) to each leaf ref in parallel via <-, await
   all responses, combine into one federation-result. Returns a vow."
  (let ((proposals (map (lambda (ref) (<- ref 'propose-for demand)) leaf-refs)))
    (on (vow-all proposals)
        (lambda (results) (combine-results results demand))
        #:promise? #t)))


;;; ── lateral-match — deferred ─────────────────────────────────────────────
;;;
;;; Phase-1 identity. Real cross-scope surplus↔deficit rebalancing
;;; requires the multi-demand model: surplus only appears when a
;;; scope's inventory exceeds its *local* allocation across several
;;; demands, and a matching deficit exists on a sibling. Keeping the
;;; API slot so Phase 2 can replace the body without a signature change.

(define (lateral-match combined-result)
  combined-result)


;;; ── plan-federate — user-facing entry point ───────────────────────────────

(define (plan-federate leaf-refs demand)
  "Federate DEMAND across LEAF-REFS. Returns a vow of a federation-result.
   Strict mode: if ANY leaf's propose-for breaks, the whole federation
   breaks. Use plan-federate-resilient for best-effort behaviour where
   dead peers become attributed deficits instead of failing the plan."
  (on (federate-demand leaf-refs demand)
      lateral-match
      #:promise? #t))


;;; ── Resilient variant — tolerates dead peers ─────────────────────────────
;;;
;;; Uses vow-allsettled to separate fulfilled and broken outcomes. Broken
;;; outcomes are converted into scope-attributed deficits for the
;;; demand spec — so the coordinator sees "peer X couldn't respond,
;;; here's the shortfall they would have covered." The rest of the
;;; federation proceeds normally.
;;;
;;; A broken vow here most commonly means OCapN severance (remote vat
;;; died), but also covers method errors and timeouts. The outcome
;;; record carries the reason in cdr for logging.
;;;
;;; NOTE: there's no per-peer capacity estimate in this simple version —
;;; a dead peer contributes its full demand-qty as a deficit (overstate).
;;; Future: treat `on-sever` as a long-term signal and cache expected
;;; capacity so the deficit attribution is more informed.

;;; ── Internals shared by the resilient variants ──────────────────────────
;;;
;;; `federate-demand-resilient` and `federate-demand-with-deadline` differ
;;; only in how each peer's vow is shaped — raw `<-` for the former,
;;; `vow-with-deadline`-wrapped for the latter. Both:
;;;   1. Install sever handlers for remote peers (diagnostics).
;;;   2. Collect per-peer vows via `vow-allsettled` (lenient — broken
;;;      vows become outcomes instead of failing the whole federation).
;;;   3. Convert each broken outcome to a synthetic deficit result.
;;;   4. Run `combine-results` over the full set.
;;;
;;; Shared core below; the public variants are one-liners on top.

(define (log-sever ref reason)
  "Standard stderr log for severance events during federation. Uses
   refr-name so labeled actors show as `commune-A` rather than an
   opaque `#<local-object>`."
  (format (current-error-port)
          "[vat-federation] peer severed: ~a (reason: ~a)~%"
          (or (refr-name ref) ref)
          reason))

(define (outcome->result outcome idx demand)
  "Map a `(fulfilled . val)` / `(broken . reason)` outcome to a
   federation-result suitable for combine-results. Fulfilled pass
   through; broken become synthetic deficits attributed to a
   generated dead-peer-N scope."
  (match outcome
    (('fulfilled . val) val)
    (('broken . reason)
     (let ((spec (car demand))
           (need (cadr demand)))
       `((scope . ,(string->symbol
                     (string-append "dead-peer-" (number->string idx))))
         (plan . ())
         (deficits . (((scope-id . dead-peer)
                       (spec-id . ,spec)
                       (qty . ,need)
                       (reason . ,reason))))
         (surpluses . ())
         (residual . ,need)
         (coherence . 0))))))

(define (federate-demand-with-vow-wrapper leaf-refs demand wrap-vow)
  "Core: for each ref, build `(wrap-vow (<- ref 'propose-for demand))`;
   allsettled the vows; convert outcomes; combine. WRAP-VOW is either
   identity (resilient variant) or `(vow-with-deadline _ seconds)`
   (deadline variant). Returns a vow of a combined federation-result."
  (with-sever-handling leaf-refs log-sever
    (lambda ()
      (let ((proposals (map (lambda (ref)
                              (wrap-vow (<- ref 'propose-for demand)))
                            leaf-refs)))
        (let-on ((outcomes (vow-allsettled proposals)))
          (combine-results
            (map (lambda (o i) (outcome->result o i demand))
                 outcomes (iota (length outcomes)))
            demand))))))

(define (federate-demand-resilient leaf-refs demand)
  "Like federate-demand but dead peers don't fail the plan. Broken
   proposals become deficits attributed to a synthetic dead-peer
   scope. Returns a vow."
  (federate-demand-with-vow-wrapper leaf-refs demand (lambda (v) v)))

(define (plan-federate-resilient leaf-refs demand)
  "Resilient variant of plan-federate. Broken peer proposals become
   scope-attributed deficits; the federation continues with whoever
   answered. Returns a vow that resolves even if all peers died."
  (on (federate-demand-resilient leaf-refs demand)
      lateral-match
      #:promise? #t))


;;; ── Deadlined variants: race + timeout per peer ──────────────────────────
;;;
;;; Each peer gets SECONDS to respond. If the peer's vow hasn't
;;; settled by then, the `timeout` vow fires first, `race` picks it
;;; as the winner, `vow-with-deadline` converts the 'deadline sentinel
;;; into a break, and vow-allsettled handles it like any other broken
;;; vow — synthetic deficit, federation proceeds.
;;;
;;; `timeout` is promise-based (doesn't block the vat). `race` picks
;;; whichever vow settles first.

(define (vow-with-deadline vow seconds)
  "Return a vow that either resolves with VOW's value (if VOW settles
   first), or BREAKS with 'deadline-exceeded (if SECONDS elapse first)."
  (on (race vow (timeout seconds 'deadline))
      (lambda (v)
        (if (eq? v 'deadline)
            (error 'deadline-exceeded)
            v))
      #:promise? #t))

(define (federate-demand-with-deadline leaf-refs demand seconds)
  "Each peer has SECONDS to respond. Missed deadlines become broken
   vows with reason 'deadline-exceeded, processed identically to
   dead peers. Returns a vow of a federation-result."
  (federate-demand-with-vow-wrapper
    leaf-refs demand
    (lambda (v) (vow-with-deadline v seconds))))

(define (plan-federate-with-deadline leaf-refs demand seconds)
  "Same as plan-federate-resilient but with per-peer SECONDS deadline."
  (on (federate-demand-with-deadline leaf-refs demand seconds)
      lateral-match
      #:promise? #t))
