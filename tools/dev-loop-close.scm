;;; tools/dev-loop-close.scm — the other half of the loop: notices a merged
;;; agent/<spec-id> patch and closes it out.
;;;
;;; A merged branch whose issue Radicle already marks solved is BOOKED on
;;; the REAL "playnet development" commune under `earth` — a live gateway
;;; process, reached over its own REPL socket
;;; (module/playnet/utils/repl-client.scm), never a private store: the work
;;; event lands on the SAME commune `account.scm`/`skill-law.scm` already
;;; read for every other commune, so a merge is real, credited VF labour,
;;; not only the MQTT fulfilment signal. Booked by whoever the ledger
;;; already has committed (a human's own commit-row!, if one took the row
;;; first) or by the issue's assignee — box never holds a commitment or a
;;; work event of its own (module/playnet/dev/ledger.scm's
;;; own header: mimir.md's precedent, an AI is a consumed resource, never
;;; labour). A merge whose issue is not yet marked solved is reported, not
;;; booked: closing the issue on Radicle is the human's word, never
;;; inferred from a branch.
;;;
;;; So this script's two halves:
;;;
;;;   1. Enumerate every agent/* branch that exists AT ALL (git refs, no
;;;      `rad` CLI output parsing), check each against rad/main via `git
;;;      merge-base --is-ancestor` (true after ANY merge shape — fast-
;;;      forward, rebase, a Radicle merge commit), and publish a
;;;      fulfillment signal for any newly merged one — unconditionally,
;;;      whatever the issue's own state, since this is the wire dev-
;;;      bridge.scm's cooldown reads.
;;;   2. For a merged branch naming an issue (spec-id->oid), gather its
;;;      facts LOCALLY (this script has `rad` on PATH; the gateway process
;;;      may not) and, once Radicle marks it solved, send ONE self-
;;;      contained `book-issue-done!` form to the live gateway's REPL —
;;;      the real commune, `book-issue-done!` and `planner-vat` are all
;;;      already bound there (server/gateway.scm's own REPL-environment
;;;      setup; `book-issue-done!`/`booked?` reach it because that script
;;;      runs in `(guile-user)`, like every `use-module` in it).
;;;
;;; No persistent "already reported" state across runs for the fulfilment
;;; signal — a rerun after a restart may republish once for the same
;;; branch, which is why any real consumer treats it as idempotent, same
;;; discipline as dev-signal-cycle's own deficit signal. The booking half
;;; has its own idempotence: book-issue-done! and booked?, read off the
;;; REAL commune's own observer, so a rerun after a restart — of THIS
;;; script or of the gateway — books nothing twice.
;;;
;;; Run from a checkout with a `rad` remote fetched (DEV_CHECKOUT_DIR on the
;;; box; `--no-fetch` skips the fetch, e.g. for a dry test against local
;;; state), on the SAME host as the gateway process (the REPL socket is a
;;; local Unix socket, `GATEWAY_REPL_SOCK` names it).
;;;
;;; Usage:
;;;   guile -L module tools/dev-loop-close.scm
;;;   guile -L module tools/dev-loop-close.scm --dry-run --no-fetch

(use-modules (playnet mqtt publish)
             ((playnet utils common) #:select (capture non-empty-lines))
             ((playnet utils repl-client) #:select (repl-eval/read))
             ((playnet dev priorities) #:select (spec-id->oid issue-facts fact-ref))
             ((playnet dev rad-issues) #:select (rad-self-rid rad-cob-show))
             ((playnet dev plan) #:select (read-dev-people person-for-did))
             (json)
             (ice-9 popen)
             (ice-9 rdelim)
             (srfi srfi-1)
             ((srfi srfi-13) #:select (string-prefix?)))

;; the "publisher" mosquitto user — same account/ACL as dev-signal-cycle.scm
(define MQTT_CRED_DIR (or (getenv "MQTT_CRED_DIR") "/var/lib/playnet/mosquitto"))
(define MQTT_PASSWORD_FILE (mqtt-password-file "publisher" MQTT_CRED_DIR))
(define DRY_RUN? (member "--dry-run" (command-line)))
(define NO_FETCH? (member "--no-fetch" (command-line)))
(define PEOPLE_PATH (or (getenv "DEV_SCOPE_PATH") "docs/dev-scope.sexp"))
;; server/gateway.scm's own gateway-repl-sock path (mode 0600) — same host,
;; same user the gateway process runs as
(define GATEWAY_REPL_SOCK
  (or (getenv "GATEWAY_REPL_SOCK")
      (string-append (or (and=> (getenv "XDG_RUNTIME_DIR") (lambda (d) (string-append d "/playnet")))
                         "/var/run/playnet")
                     "/gateway-repl.sock")))

;; capture/non-empty-lines are the shared (playnet utils common) helpers —
;; also used by tools/dev-signal-cycle.scm, the other half of this loop.

(define (agent-branch-spec-ids)
  "Every spec-id with an agent/<spec-id> branch on the rad remote —
   refs/remotes/rad/agent/*, prefix stripped. Empty (not an error) when
   there's no rad remote at all."
  (let ((out (capture (list "git" "for-each-ref"
                            "--format=%(refname:short)"
                            "refs/remotes/rad/agent/*"))))
    (if (not out) '()
        (filter-map
         (lambda (line)
           (and (string-prefix? "rad/agent/" line)
                (substring line (string-length "rad/agent/"))))
         (non-empty-lines out)))))

(define (sh-ok? . argv)
  (zero? (status:exit-val (apply system* argv))))

(define (branch-merged? spec-id)
  "Is agent/<spec-id> fully reachable from rad/main? Never throws — a check
   that can't run (no such ref, no rad remote) answers #f, not an error."
  (catch #t
    (lambda () (sh-ok? "git" "merge-base" "--is-ancestor"
                        (string-append "rad/agent/" spec-id) "rad/main"))
    (lambda (key . args) #f)))

(define (publish-fulfillment! spec-id)
  (let* ((topic (string-append "playnet/signals/fulfillment/" spec-id))
         (payload (scm->json-string
                   `(("kind" . "fulfillment") ("spec-id" . ,spec-id)))))
    (if DRY_RUN?
        (format #t "[dev-loop-close] DRY RUN — would publish to ~a:~%~a~%" topic payload)
        (mqtt-publish! #:topic topic #:message payload
                       #:username "publisher" #:password-file MQTT_PASSWORD_FILE))))

;; ── booking the merge, once Radicle marks the issue solved ────────────────

(define (issue-facts-for oid)
  "OID's current facts off Radicle, or #f when they cannot be read (`rad`
   unavailable, no such issue any more)."
  (let ((rid (rad-self-rid)))
    (and rid (let ((json (rad-cob-show rid oid))) (and json (issue-facts oid json))))))

(define (already-booked? oid)
  "Does the REAL commune's own books already hold OID's deliverable? A #f
   reply from the REPL (gateway unreachable, dev-commune not yet up) reads
   as \"not booked\" — book-merge!* below then tries the real booking call,
   which will itself report the same unreachability, once, clearly."
  (eq? #t (repl-eval/read GATEWAY_REPL_SOCK `(booked? dev-commune ,oid))))

(define (book-merge!* people spec-id)
  "SPEC-ID's issue, booked on the real dev-commune if it names one and
   Radicle marks it solved. BY, read when the ledger holds no commitment
   already (book-issue-done!'s own fallback), is the person the issue's
   first assignee resolves to in PEOPLE — #f when none does, in which case
   book-issue-done! records only the deliverable. FACTS travels to the
   gateway's REPL as one self-contained, `write`n form — nothing there
   needs `rad` of its own."
  (let ((oid (spec-id->oid spec-id)))
    (if (not oid)
        (format #t "[dev-loop-close] ~a names no issue — nothing to book~%" spec-id)
        (let ((facts (issue-facts-for oid)))
          (cond
           ((not facts)
            (format #t "[dev-loop-close] ~a's issue could not be read — nothing booked~%" spec-id))
           ((already-booked? oid)
            (format #t "[dev-loop-close] ~a already booked~%" spec-id))
           ((not (eq? 'solved (fact-ref facts 'state)))
            (format #t "[dev-loop-close] ~a merged, but its issue is not marked solved — a human closes it, not this~%" spec-id))
           (else
            (let* ((assignee (and (pair? (fact-ref facts 'assignees)) (car (fact-ref facts 'assignees))))
                   (by       (and assignee (person-for-did people assignee)))
                   (ids      (repl-eval/read GATEWAY_REPL_SOCK
                              `(with-vat planner-vat
                                 (book-issue-done! dev-commune ',facts #:by ,by #:people ',people)))))
              (if (not ids)
                  (format (current-error-port)
                          "[dev-loop-close] ~a: the gateway's REPL did not answer (~a) — nothing booked this run~%"
                          spec-id GATEWAY_REPL_SOCK)
                  (format #t "[dev-loop-close] ~a booked~a (~a event~a)~%" spec-id
                          (if by (format #f ", by ~a" by) "") (length ids)
                          (if (= 1 (length ids)) "" "s"))))))))))

(define (book-merge! people spec-id)
  "book-merge!*, never throwing — one issue's booking failure never blocks
   the rest."
  (catch #t
    (lambda () (book-merge!* people spec-id))
    (lambda (key . args)
      (format (current-error-port) "[dev-loop-close] could not book ~a (~a ~s)~%" spec-id key args))))

(define (main)
  (unless NO_FETCH?
    (catch #t (lambda () (system* "git" "fetch" "rad"))
      (lambda (key . args)
        (format #t "[dev-loop-close] git fetch rad failed (~a) — checking local refs only~%" key))))
  (let* ((spec-ids (agent-branch-spec-ids))
         (merged (filter branch-merged? spec-ids)))
    (if (null? merged)
        (format #t "[dev-loop-close] nothing merged among ~a agent branch~a.~%"
                (length spec-ids) (if (= 1 (length spec-ids)) "" "es"))
        (begin
          (for-each
           (lambda (spec-id)
             (format #t "[dev-loop-close] MERGED: ~a — publishing fulfillment~%" spec-id)
             (publish-fulfillment! spec-id))
           merged)
          (if DRY_RUN?
              (format #t "[dev-loop-close] dry run — the real commune is left untouched~%")
              (let ((people (read-dev-people PEOPLE_PATH)))
                (for-each (lambda (spec-id) (book-merge! people spec-id)) merged)))))))

(main)
