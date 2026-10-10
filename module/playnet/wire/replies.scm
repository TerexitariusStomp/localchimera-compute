;;; wire/replies.scm — what the read doors answer, as the page reads it.
;;;
;;; A door of the planner answers an alist in its own vocabulary; the page reads
;;; a JSON object (the row types of ui/app/seam.ts and the face that asks).
;;; `reply->wire` is that reading: each door's reply is a table, found by the door's name.
;;; The page's spine (hoot/day-boot.scm) and the demo recorder
;;; (tools/emit/demo-emit.scm) both answer through it. Plain Scheme.

(define-module (playnet wire replies)
  #:use-module (playnet wire rows)
  #:use-module (playnet wire snapshot)   ; the `expected` table a count's reply nests
  #:use-module (srfi srfi-1)
  #:re-export (reply->wire finished finishing))

(define (keyed key) (lambda (row ctx) (alist-ref row key)))
(define (text-only key) (lambda (row ctx) (let ((v (alist-ref row key))) (and (string? v) v))))

;; the schedule of counts (planner count-schedule): each target with its cadence
(define %count-row-wire
  (wire-table 'count-row #f
  '(("id" id str) ("name" name str) ("place" place str)
    ("onhand" onhand num) ("unit" unit str)
    ("lines" lines int) ("hours" hours num)
    ("interval" interval num) ("class" class str)
    ("regime" regime str) ("lastCount" last-count str)
    ("due" due str) ("overdue" overdue? bool))))

;; the counts of a stock, newest first, as a member reads them to contest one
;; (planner count-history): the figure found, the difference landed, the ballot
;; a contest of it is
(define %count-history-wire
  (wire-table 'count-history #f
  '(("id" id str) ("ballot" ballot str) ("at" at str)
    ("counted" counted num) ("delta" delta num) ("unit" unit str)
    ("counter" counter str) ("technique" technique str) ("evidence" evidence str)
    ("mine" mine bool))))

;; the contests open in the scope, as they stand to this seat (governance
;; contests): what each names, whose act it is, and what this seat may do
(define %contest-wire
  (wire-table 'contest #f
  '(("id" id str) ("eventId" event-id str) ("kind" kind str) ("resource" resource str) ("worker" worker str)
    ("by" by str) ("reason" reason str) ("role" role str))))

;; the citizen's order book (service my-claims): a want the plan has not
;; answered (asked), a claim commitment it registered (held, with what remains),
;; a row confirmed in full (taken). Numbers ride as strings, as ClaimRow says
;; (ui/app/seam.ts), "" where the good has no price.
(define %claim-row-wire
  (wire-table 'claim-row #f
  '(("id" id str) ("spec" spec str) ("name" name str) ("place" place str)
    ("when" when str) ("total" total num) ("fulfilled" fulfilled num)
    ("remaining" remaining num) ("snlt" snlt num) ("state" state str))))

;; what every source says of a spec: the reading fold's rows and drift (service readings-of)
(define %reading-row-wire
  (wire-table 'reading-row #f
  '(("technique" technique str) ("action" action str) ("unit" unit str) ("source" source str)
    ("nominal" nominal num) ("n" n num) ("sum" sum num) ("min" min num) ("max" max num)
    ("at" at str) ("latest" latest num))))

;; a count landed (planner count-stock): its event and record, the hours it
;; earned, the difference and the ledger after, how it stands beside a later
;; count (sighting), and the range the plan left the stock in
(define %counted-wire
  (wire-table 'counted #f
  '(("event" event str) ("record" record str)
    ("hours" hours num) ("delta" delta num) ("onhand" onhand num)
    ("sighting" sighting str))))

;; A slot, a need or a means: {id, spec, name, emoji, note, qty, unit, where,
;; from, until, tension, voice, cats, arcs}, its arcs the recurrence arcs a
;; record's window speaks (wire/snapshot.scm arc); a capacity row carries no
;; tension and no voice and reads "" for both.
(define %slot-entries
  `(("id" ,(text-only 'id) str) ("spec" ,(text-only 'spec) str) ("name" ,(text-only 'name) str)
    ("emoji" ,(text-only 'emoji) str) ("note" ,(text-only 'note) str)
    ("qty" qty num) ("unit" ,(text-only 'unit) str) ("where" ,(text-only 'where) str)
    ("from" ,(text-only 'from) str) ("until" ,(text-only 'until) str)
    ("tension" ,(text-only 'tension) str) ("voice" voice num)
    ("cats" cats strs) ("arcs" arcs (rows arc))
    ;; the sidecar a need declares (a filter rule, a minimum size, a link), read
    ;; back on the row as declared
    ("criteria" ,(lambda (s ctx) (let ((c (alist-ref s 'criteria))) (and (pair? c) (plain->wire c))))
     (omit-false (map any)))))
(define %slot-wire (wire-table 'slot #f %slot-entries))

;; a slot of the pool, with its person: `who` on a need (its citizen), `owner`
;; on a means (the rights-holder); on the map a means row also carries how
;; occupied the solve left it (0..1)
(define %need-slot-wire
  (wire-table 'need-slot #f `(("who" ,(text-only 'who) str) ,@%slot-entries)))
(define %means-slot-wire
  (wire-table 'means-slot #f `(("owner" ,(text-only 'owner) str) ,@%slot-entries)))
(define %drawn-slot-wire
  (wire-table 'drawn-means-slot #f
    `(("drawn" ,(lambda (s ctx) (let ((d (alist-ref s 'drawn))) (and (number? d) d))) (omit-false num))
      ,@(wire-table-entries %means-slot-wire))))

;; Our: the scope's fold, cells of (spec, where, window) with the asker's share
(define %cell-wire
  (wire-table 'slot-cell #f
    `(("spec" spec str) ("where" where str) ("from" from str)
      ("until" until str) ("tension" tension str) ("unit" unit str)
      ("qty" qty num) ("mine" mine num))))

;; one scored pairing of the match ring, and a need with its pairings
(define %hit-dim-wire (wire-table 'hit-dim #f `(("dim" ,(lambda (d ctx) (car d)) str)
                                                ("score" ,(lambda (d ctx) (cdr d)) num))))
(define %hit-wire
  (wire-table 'hit #f
    `(("id" id str) ("score" score num) ("term" term str)
      ("distance" distance num) ("specificity" specificity num)
      ("dims" ,(lambda (m ctx)
                 (filter (lambda (d) (and (pair? d) (number? (cdr d))))
                         (->list (or (alist-ref m 'breakdown) '()))))
       (rows hit-dim)))))
(define %match-wire
  (wire-table 'match #f `(("need" need str) ("hits" hits (rows hit)))))

;; ── WHAT EACH DOOR ANSWERS ───────────────────────────────────────────────────
;; One table per door, under the door's name (rows.scm reply-table).
(define (needs-and-means need means)
  `(("needs" needs (rows ,need)) ("means" means (rows ,means))))

(reply-table 'count-schedule '(("rows" rows (rows count-row))))
(reply-table 'count-history  '(("rows" rows (rows count-history))))
;; the contests door answers its rows first
(reply-table 'contests `(("rows" ,(lambda (v ctx) (and (pair? v) (car v))) (rows contest))))
(reply-table 'my-claims '(("rows" rows (rows claim-row))))
(reply-table 'my-slots  (needs-and-means 'slot 'slot))
(reply-table 'our-slots (needs-and-means 'slot-cell 'slot-cell))
;; the scope's pool, as the map reads it
(reply-table 'slots-at  (needs-and-means 'need-slot 'drawn-means-slot))
;; the match ring's one read: the pool with its people, and every scored pairing
(reply-table 'match-slots `(,@(needs-and-means 'need-slot 'means-slot) ("matches" matches (rows match))))
(define %drift-wire
  (wire-table 'reading-drift #f '(("n" n num) ("meanAbs" mean-abs num) ("net" net num))))
(define %latest-wire
  (wire-table 'reading-latest #f '(("reading" reading num) ("at" at str) ("unit" unit str) ("source" source str))))
(reply-table 'scope-readings
  `(("rows" rows (rows reading-row))
    ("drift" ,(lambda (v ctx) (or (alist-ref v 'drift) '())) (row reading-drift))
    ("latest" latest (row reading-latest))))
(reply-table 'readings-between '(("rows" rows (rows reading-row)) ("fold" fold (rows reading-row))))
(reply-table 'count-stock
  `(,@(wire-table-entries %counted-wire)
    ;; a count of an instant lands once: the door says when it had this one
    ("again" again (omit-false bool))
    ("expected" ,(lambda (v ctx) (let ((e (alist-ref v 'expected #f))) (and (pair? e) e)))
     (omit-false (row expected)))))
;; the code a stock is known by, for its label, and what a label names: the
;; thing and what is in it, each an inventory row
(reply-table 'label-stock '(("code" code str) ("id" id str) ("name" name str) ("minted" minted bool)))
(reply-table 'read-label '(("resource" resource (row inventory-resource)) ("contents" contents (rows inventory-resource))))
;; the week's unplanned photo reads (lobby-session allotment): how many remain, of
;; how many, the instant the week opens again, and whether a picture can be read here
(reply-table 'allotment
  '(("remaining" remaining int) ("perWeek" per-week int) ("opens" opens str) ("sees" sees? bool)))
