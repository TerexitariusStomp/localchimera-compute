;;; tools/dev-signal-cycle.scm — the live priority queue → one MQTT deficit
;;; signal → server/dev-bridge.scm.
;;;
;;; Was: docs/dev-priorities.sexp, a hand-curated file duplicating title +
;;; body content that already lives in Radicle issues (and, before that, in
;;; docs/radicle-issues.md's own pre-filing staging board — a second
;;; duplicate). Then: sorted open Radicle issues, prio:p0 > p1 > p2 >
;;; unlabeled, with no notion of who has the hours. Now: THE WEEK'S PLAN
;;; (module/playnet/planner/dev/plan.scm) decides — an open issue is
;;; a want, the box agent's own stated hours and area skills are its
;;; capacity, and the rows the plan places on the box are the candidates,
;;; first want first. Two sources feed it, in priority order —
;;;
;;;   1. The anonymous feedback pool (server/serve-static.scm's /feedback),
;;;      watched for growth against docs/feedback-triage-watermark.txt. When
;;;      it grows, this queues a triage task: cluster new entries, draft
;;;      candidate Radicle issues as 🟡 rows in docs/radicle-issues.md. It
;;;      never opens an issue itself and never touches the pool — see
;;;      module/playnet/planner/dev/priorities.scm's %triage-body for
;;;      the exact brief.
;;;   2. The week's plan over open Radicle issues (`rad cob show`/`rad cob
;;;      list`, via (playnet planner dev rad-issues)) — the rows the plan
;;;      places on the box agent, DEV_SCOPE_PATH's own stated hours and
;;;      areas (docs/dev-scope.sexp by default; see tools/dev-plan.scm).
;;;      When the plan cannot run (no scope declared yet, the solver
;;;      unavailable), this falls back to the plain prio: sort, so the loop
;;;      still moves before a scope is set up.
;;;
;;; Finds the first candidate that has no already-open Radicle patch for its
;;; spec-id (a local or remote branch named agent/<id>), and publishes ONE
;;; deficit signal for it. One task per run by design — dev-bridge.scm's own
;;; 300s cooldown paces actual Claude launches; this script just decides
;;; WHICH task is next, each time it's run (by hand, or on a timer you add).
;;;
;;; DISPATCHING BOOKS NOTHING. box never holds a commitment or a work event
;;; of its own (dev-ledger.scm's own header: mimir.md's precedent, an AI is
;;; a consumed resource, never labour) — only a human's merge, once Radicle
;;; marks the issue solved, is a creditable act (tools/dev-loop-close.scm,
;;; the other half of this loop). This script's own plan computation is
;;; read-only — a forecast of what box should try next, run over its own
;;; throwaway scope, exactly like `make dev-plan`'s report; nothing here
;;; ever needs the real "playnet development" commune under `earth`.
;;;
;;; Publishes to playnet/signals/deficit/<spec-id>, built by `signal-topic`
;;; from module/playnet/planner/bridge/signal-publisher.scm — the ONE place
;;; the signal topic contract lives, and the same shape server/dev-bridge.scm
;;; subscribes to (SIGNAL_TOPIC = playnet/signals/deficit/#).
;;;
;;; The decision logic (priority ranking, issue→entry shape, the watermark
;;; gate, the plan itself) is pure and lives in (playnet planner bridge
;;; dev-priorities) and (playnet planner dev plan) — see
;;; tests/tools/test-dev-priorities.scm and tests/planner/test-dev-world.scm.
;;; This script is the I/O shell: shell out to `rad`, read the watermark
;;; file, run the plan, book the take, publish.
;;;
;;; Usage:
;;;   guile -L module tools/dev-signal-cycle.scm
;;;   guile -L module tools/dev-signal-cycle.scm --dry-run
;;;
;;; Requires: mosquitto_pub and rad on PATH (both skipped harmlessly under
;;; --dry-run, other than rad, which is needed to even find candidates), and
;;; the planner's solve environment for the plan half (`make dev-signal`
;;; supplies both — see Makefile DEV_ENV). Without a solve environment the
;;; plan half fails closed to the plain sort, per the fallback above.
;;;
;;; The branch-exists check shells out to `git ls-remote`; if that fails
;;; (no `rad` remote configured in the calling checkout, offline, etc.) it
;;; logs a note and proceeds WITHOUT the check rather than blocking — false
;;; negatives here just mean an occasional duplicate signal, which
;;; dev-bridge's cooldown already dampens.

(use-modules (playnet mqtt publish)
             ((playnet planner bridge signal-publisher)  ; THE topic contract
              #:select (signal-topic))
             ((playnet planner dev priorities)
              #:select (fact-ref fact->entry issues->facts spec-id->oid
                        sort-issue-entries feedback-triage-entry parse-watermark))
             ((playnet planner dev plan)
              #:select (read-dev-people seed-dev-scope!
                        plan-dev-week read-dev-plan rows-for row-ref))
             ((playnet planner dev rad-issues) #:select (rad-issue-pairs))
             (playnet planner scope root) (srfi srfi-1)
             ((playnet utils paths) #:select (state-file))
             (goblins) (goblins vat)
             (json)
             (ice-9 popen)
             (ice-9 textual-ports)
             (ice-9 rdelim)
             (srfi srfi-1))

(define WATERMARK_PATH
  (or (getenv "FEEDBACK_TRIAGE_WATERMARK_PATH")
      "docs/feedback-triage-watermark.txt"))

(define PEOPLE_PATH (or (getenv "DEV_SCOPE_PATH") "docs/dev-scope.sexp"))
;; the identity the plan asks to carry — the AI dev loop's own seat in the
;; scope (recipes/dev.scm's `(kind . agent)` person)
(define BOX_ID (or (getenv "DEV_BOX_ID") "box"))

(define DRY_RUN?
  (member "--dry-run" (command-line)))

;; ── The feedback pool's live byte size ───────────────────────────────────

(define (pool-bytes)
  (let ((p (state-file "feedback-pool.scm")))
    (if (file-exists? p) (stat:size (stat p)) 0)))

(define (read-watermark)
  (parse-watermark
   (catch #t
     (lambda () (call-with-input-file WATERMARK_PATH get-string-all))
     (lambda _ ""))))

;; ── The week's plan, computed once and shared by the candidate list and
;;    the take ──────────────────────────────────────────────────────────
;; 'unset until first asked, so a plan that legitimately cannot run (an
;; unpopulated scope) is cached as #f rather than retried every reader.

(define %plan-cache 'unset)

(define (dev-plan-once all-facts)
  "(people . rows) for this run's ALL-FACTS, memoized — or #f when the plan
   cannot run (no people declared at PEOPLE_PATH, the solver unavailable).
   Read via plan-candidates/book-take!, never called twice."
  (when (eq? %plan-cache 'unset)
    (set! %plan-cache
          (catch #t
            (lambda ()
              (let ((people (read-dev-people PEOPLE_PATH)))
                (and (pair? people)
                     (with-vat (spawn-vat #:name "dev-signal-cycle")
                       (let ((scope (spawn-scope-root "playnet development")))
                         (seed-dev-scope! scope all-facts people)
                         (cons people (read-dev-plan (plan-dev-week scope all-facts people)
                                                     all-facts people)))))))
            (lambda (key . args)
              (format (current-error-port)
                      "[dev-signal-cycle] the plan could not run (~a ~s) — falling back to the priority sort~%"
                      key args)
              #f))))
  %plan-cache)

(define (plan-candidates all-facts)
  "BOX_ID's own rows off the week's plan (a read-only forecast — see the
   header), first want first, as dev-priorities entries — every row it
   carries any share of (rows-for), the fuller answer a dispatched coding
   session still resolves against the ROW's own recorded shares. '() (not
   #f) when the plan ran but the box has no share of anything this week;
   #f when the plan could not run at all."
  (let ((cached (dev-plan-once all-facts)))
    (and cached
         (filter-map (lambda (r) (fact->entry (find (lambda (f) (equal? (row-ref r 'oid) (fact-ref f 'oid)))
                                                     all-facts)))
                     (rows-for BOX_ID (cdr cached))))))

;; ── Candidates, in priority order ────────────────────────────────────────
;; A '() from plan-candidates (the plan ran, box legitimately has no share
;; of anything — e.g. a scope where a bigger person covers every area) is
;; treated the same as a #f (the plan could not run) for candidate
;; selection: a real backlog with real box capacity and nothing queued is
;; a worse outcome than falling back to the plain sort, matching the
;; branch-check's own "a false negative just means an occasional
;; duplicate signal" philosophy above.

(define (candidate-entries all-facts)
  (let* ((feedback (feedback-triage-entry (pool-bytes) (read-watermark)))
         (pc       (plan-candidates all-facts)))
    (when (equal? pc '())
      (format #t "[dev-signal-cycle] the plan ran, but ~a shares nothing this week — falling back to the priority sort~%" BOX_ID))
    (append (if feedback (list feedback) '())
            (if (pair? pc) pc (sort-issue-entries (rad-issue-pairs))))))

;; ── Dedup on an already-open patch, then publish — unchanged from the
;;    hand-curated-file version ────────────────────────────────────────────

(define (entry-ref e key default)
  (let ((p (assq key e))) (if p (cdr p) default)))

(define (patch-branch-exists? spec-id)
  "Best-effort: is there already a local or remote agent/<spec-id> branch?
   Never throws — a check that can't run answers #f, not an error."
  (catch #t
    (lambda ()
      (let* ((branch (string-append "agent/" spec-id))
             (port (open-input-pipe
                    (string-append "git ls-remote --heads rad " branch " 2>/dev/null; "
                                   "git rev-parse --verify " branch " >/dev/null 2>&1 && echo LOCAL")))
             (out (read-string port)))
        (close-pipe port)
        (> (string-length (string-trim-both out)) 0)))
    (lambda (key . args)
      (format #t "[dev-signal-cycle] branch check unavailable (~a); proceeding without it~%" key)
      #f)))

(define (next-entry entries)
  (find (lambda (e) (not (patch-branch-exists? (entry-ref e 'id #f)))) entries))

(define (signal-json entry)
  (scm->json-string
   `(("kind" . "deficit")
     ("spec-id" . ,(entry-ref entry 'id #f))
     ("title" . ,(entry-ref entry 'title ""))
     ("body" . ,(entry-ref entry 'body ""))
     ("due" . ,(let ((d (entry-ref entry 'due #f))) (if d d 'null))))))

;; the "publisher" mosquitto user, per its ACL: `topic write playnet/signals/#`
;; — the account signal-publisher.scm's doc comment already names for this
(define MQTT_CRED_DIR (or (getenv "MQTT_CRED_DIR") "/var/lib/playnet/mosquitto"))
(define MQTT_PASSWORD_FILE (mqtt-password-file "publisher" MQTT_CRED_DIR))

(define (publish! spec-id payload)
  (let ((topic (signal-topic `((kind . deficit) (spec-id . ,spec-id)))))
    (if DRY_RUN?
        (format #t "[dev-signal-cycle] DRY RUN — would publish to ~a:~%~a~%" topic payload)
        (let ((rc (mqtt-publish! #:topic topic #:message payload
                                 #:username "publisher" #:password-file MQTT_PASSWORD_FILE)))
          (format #t "[dev-signal-cycle] published to ~a (mosquitto_pub exit ~a)~%" topic rc)))))

(define (main)
  (let* ((facts   (issues->facts (rad-issue-pairs)))
         (entries (candidate-entries facts)))
    (if (null? entries)
        (format #t "[dev-signal-cycle] no untriaged feedback and no open Radicle issue — nothing queued.~%")
        (let ((entry (next-entry entries)))
          (if entry
              (publish! (entry-ref entry 'id #f) (signal-json entry))
              (format #t "[dev-signal-cycle] every candidate already has an open patch — nothing to do.~%"))))))

(main)
