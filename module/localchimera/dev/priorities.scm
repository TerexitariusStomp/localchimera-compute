;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; dev-priorities.scm — what a Radicle issue states about the work it asks for.
;;;
;;; One reader of the repository's Radicle issues (`rad cob show` JSON), and
;;; everything downstream reads its facts rather than the JSON a second
;;; time: the AI dev loop's priority queue (issue-oid-entries,
;;; sort-issue-entries, tools/dev/dev-signal-cycle.scm), and the development
;;; scope's plan (module/localchimera/dev/recipes.scm,
;;; bridge/dev-plan.scm).
;;;
;;; issue-facts is the one derivation: the area names the skill, the kind
;;; names the recipe, `est:`/`spent:` state hours, `prio:` the weight of the
;;; want, `needs:` the issues whose deliverable it cites. fact->entry then
;;; projects a fact down to the OLDER, narrower shape the priority queue
;;; ships as a deficit signal: ((id . spec-id) (title . str) (body . str)
;;; (due . str-or-#f)) — kept for tools/dev/dev-signal-cycle.scm's own wire,
;;; which predates the plan and is simpler than it.
;;;
;;; Also holds the feedback-pool half of the queue (feedback-triage-entry,
;;; %triage-body, parse-watermark) — a second source PLUS the issues, not
;;; itself an issue. See tests/tools/test-dev-priorities.scm.

(define-module (localchimera dev priorities)
  #:use-module (srfi srfi-1)
  #:export (issue-prio-rank
            issue-oid-entries
            sort-issue-entries
            feedback-triage-entry
            parse-watermark
            %triage-body
            split-labels label-value parse-hours
            issue-facts issues->facts open-facts
            fact-ref fact->entry issue-spec-id spec-id->oid
            solved-oids needs-open ready-facts))

;; ── reading a label ───────────────────────────────────────────────────────

(define (split-labels labels)
  "LABELS as the separate labels they state. Radicle keeps a label as the
   string it was filed with, and an issue filed with one string
   \"area:planner,kind:feature,prio:p2\" carries three labels in it: each
   is split at its commas and trimmed, so every reader sees the same set."
  (append-map (lambda (l)
                (if (string? l)
                    (filter (lambda (s) (not (string-null? s)))
                            (map string-trim-both (string-split l #\,)))
                    '()))
              labels))

(define (issue-prio-rank labels)
  "LABELS is a list of strings (a `rad cob show` JSON `labels` array,
   already vector->list'd by the caller). Lower sorts first: p0=0, p1=1,
   p2=2, p3 and unlabeled=3."
  (let ((labels (split-labels labels)))
    (cond
     ((member "prio:p0" labels) 0)
     ((member "prio:p1" labels) 1)
     ((member "prio:p2" labels) 2)
     (else 3))))

(define (label-value labels key)
  "The value of the first KEY:value label among LABELS, or #f."
  (let ((prefix (string-append key ":")))
    (any (lambda (l) (and (string-prefix? prefix l)
                          (let ((v (substring l (string-length prefix))))
                            (and (not (string-null? v)) v))))
         labels)))

(define (label-values labels key)
  (let ((prefix (string-append key ":")))
    (filter-map (lambda (l) (and (string-prefix? prefix l)
                                 (let ((v (substring l (string-length prefix))))
                                   (and (not (string-null? v)) v))))
                labels)))

(define (parse-hours str)
  "An `est:`/`spent:` value in hours: \"3h\" and \"3\" are three hours,
   \"90m\" an hour and a half, \"2d\" two working days of eight hours. #f
   for anything else, so an estimate nobody can read is an estimate nobody
   stated."
  (and (string? str) (not (string-null? str))
       (let* ((n    (string-length str))
              (last (string-ref str (- n 1)))
              (unit (and (char-alphabetic? last) (char-downcase last)))
              (num  (string->number (if unit (substring str 0 (- n 1)) str)))
              (per  (case unit ((#f #\h) 1) ((#\m) 1/60) ((#\d) 8) (else #f))))
         (and num per (real? num) (> num 0)
              (exact->inexact (* num per))))))

(define (labels-of json-alist)
  (let ((l (assoc-ref json-alist "labels")))
    (cond ((vector? l) (vector->list l))
          ((list? l) l)
          (else '()))))

(define (issue-comment-body thread-alist oid)
  "The issue's own root comment body — keyed by the issue's own OID, the
   COB convention `rad cob show`'s thread.comments uses (the issue
   description IS comment zero, keyed by the issue's own id)."
  (let* ((comments (or (assoc-ref thread-alist "comments") '()))
         (root     (assoc-ref comments oid)))
    (and root (assoc-ref root "body"))))

;; the spec an issue's deliverable is, and the way back: the id a deficit
;; signal, an agent/<spec-id> branch and the plan's want all name
(define %issue-spec-prefix "spec-dev-issue-")
(define (issue-spec-id oid) (string-append %issue-spec-prefix oid))
(define (spec-id->oid spec-id)
  (and (string? spec-id) (string-prefix? %issue-spec-prefix spec-id)
       (substring spec-id (string-length %issue-spec-prefix))))

;; ── one issue → its facts ─────────────────────────────────────────────────

(define (issue-facts oid json-alist)
  "One issue's facts, off its (OID . `rad cob show` JSON-ALIST), or #f for
   an issue that states no title. STATE is 'open, 'solved or 'closed; BODY
   is its root comment, or #f where the COB read carried none."
  (let* ((title  (assoc-ref json-alist "title"))
         (state  (or (assoc-ref json-alist "state") '()))
         (status (assoc-ref state "status"))
         (labels (split-labels (labels-of json-alist)))
         (thread (assoc-ref json-alist "thread"))
         (who    (let ((a (assoc-ref json-alist "assignees")))
                   (cond ((vector? a) (vector->list a)) ((list? a) a) (else '())))))
    (and (string? title)
         `((oid       . ,oid)
           (title     . ,title)
           (body      . ,(and thread (issue-comment-body thread oid)))
           (state     . ,(cond ((equal? status "open") 'open)
                               ((equal? (assoc-ref state "reason") "solved") 'solved)
                               (else 'closed)))
           (area      . ,(label-value labels "area"))
           (kind      . ,(label-value labels "kind"))
           (prio      . ,(issue-prio-rank labels))
           (est       . ,(parse-hours (label-value labels "est")))
           (spent     . ,(parse-hours (label-value labels "spent")))
           (needs     . ,(label-values labels "needs"))
           (assignees . ,who)))))

(define (issues->facts oid+json-pairs)
  "The facts of every issue that states a title, open or ended."
  (filter-map (lambda (p) (issue-facts (car p) (cdr p))) oid+json-pairs))

(define (fact-ref facts key) (assq-ref facts key))

(define (open-facts all-facts)
  "The facts of ALL-FACTS still open."
  (filter (lambda (f) (eq? 'open (fact-ref f 'state))) all-facts))

;; ── needs: what waits, what is ready ────────────────────────────────────

(define (solved-oids all-facts)
  (filter-map (lambda (f) (and (eq? 'solved (fact-ref f 'state)) (fact-ref f 'oid)))
              all-facts))

(define (needs-open facts all-facts)
  "The needs of FACTS that stand unsolved: each `needs:` value names an
   issue by its id or a prefix of it, and a need naming no issue at all
   stands open, since nothing shows its deliverable exists."
  (let ((solved (solved-oids all-facts)))
    (filter (lambda (need)
              (not (any (lambda (oid) (string-prefix? need oid)) solved)))
            (fact-ref facts 'needs))))

(define (ready-facts all-facts)
  "The open issues whose every need is solved: the wants a plan can take
   this period."
  (filter (lambda (f) (null? (needs-open f all-facts))) (open-facts all-facts)))

;; ── facts → the priority queue's own entry shape ─────────────────────────
;; tools/dev/dev-signal-cycle.scm's wire predates the plan and carries less: one
;; task, a title and a body, no skill or hours. fact->entry is the one
;; narrowing, so an issue's title and body are read once, here, whichever
;; queue asks for them.

(define (fact->entry f)
  "One dev-priorities entry off issue FACTS, or #f when it has no usable
   body — a degraded/partial COB read should drop the issue, not publish a
   broken task."
  (and (string? (fact-ref f 'body))
       `((id    . ,(issue-spec-id (fact-ref f 'oid)))
         (title . ,(fact-ref f 'title))
         (body  . ,(fact-ref f 'body))
         (due   . #f))))

(define (issue-oid-entries oid+json-pairs)
  "OID+JSON-PAIRS is a list of (OID . JSON-ALIST), one per `rad cob show`
   call. Filters to open issues, builds entries, drops any issue a
   partial/degraded fetch left without a usable entry. Does NOT sort —
   see sort-issue-entries."
  (filter-map fact->entry (open-facts (issues->facts oid+json-pairs))))

(define (sort-issue-entries oid+json-pairs)
  "issue-oid-entries's own facts, ranked p0 first — stable, so two issues
   at the same priority keep the order `rad` returned them in."
  (filter-map fact->entry
              (stable-sort (open-facts (issues->facts oid+json-pairs))
                           (lambda (a b) (< (fact-ref a 'prio) (fact-ref b 'prio))))))

;; ── Feedback pool → a triage entry ───────────────────────────────────────

(define %triage-body
  "Read every entry in the feedback pool (LOCALCHIMERA_DATA_DIR, default \
/var/lib/localchimera — server/serve-static.scm's `feedback-file`) whose \
byte offset is past the watermark recorded in \
docs/feedback-triage-watermark.txt (a single integer, in bytes). Entry \
shape: ((id . \"fb-...\") (t . epoch-seconds) (ua . \"user-agent\") \
(json . \"raw client JSON string\")) — read the file with Guile's \
`read` in a loop (it is a plain sequence of s-expressions, not a JSON \
array or a single list).\n\
\n\
For each entry, or cluster of related entries: decide whether it names \
a real, actionable issue (a bug, a confusing UX moment, a feature \
request) or is noise / spam / not actionable. For real signal, draft \
ONE row per cluster into docs/radicle-issues.md's matching Backlog \
table, following its existing area:/kind:/prio: label taxonomy and row \
format exactly. Provenance column: 💬. Status column: 🟡 (draft — a \
human still runs `rad issue open` before anything becomes a real, \
permanent Radicle issue). Cite the contributing entry id(s) in the \
row's Source ref column.\n\
\n\
When every entry past the watermark has been triaged, overwrite \
docs/feedback-triage-watermark.txt with the CURRENT byte size of the \
feedback-pool file (stat it again at the end, in case new entries \
arrived while you worked) — a single integer, nothing else in the \
file.\n\
\n\
Do NOT call `rad issue open` yourself — drafting into \
docs/radicle-issues.md is the whole job; a human reviews the patch and \
files the ones worth filing. Do NOT delete or modify entries in the \
feedback pool file itself — it is the anonymous, append-only source of \
record; only the token-gated admin HTTP routes prune it.")

(define (parse-watermark str)
  "Parse STR (docs/feedback-triage-watermark.txt's contents) as a
   non-negative integer. Anything unparseable — missing file, empty
   file, garbage — reads as 0, so a broken watermark fails OPEN (queues
   a triage pass) rather than silently never triaging again."
  (or (and (string? str)
           (let ((n (string->number (string-trim-both str))))
             (and (number? n) (exact? n) (>= n 0) n)))
      0))

(define (feedback-triage-entry pool-bytes watermark)
  "POOL-BYTES is the live feedback-pool file's current size; WATERMARK is
   the last-triaged byte count (parse-watermark's result). Returns a
   dev-priorities entry when POOL-BYTES has grown past WATERMARK, else
   #f. The entry's id embeds POOL-BYTES itself, so once a merged patch
   advances the watermark to that value, the SAME candidate naturally
   stops being produced (patch-branch-exists?'s own dedup, matching
   every other entry, needs no special case here)."
  (and (> pool-bytes watermark)
       `((id    . ,(string-append "spec-dev-triage-feedback-" (number->string pool-bytes)))
         (title . "Triage new feedback-pool entries into docs/radicle-issues.md drafts")
         (body  . ,%triage-body)
         (due   . #f))))
