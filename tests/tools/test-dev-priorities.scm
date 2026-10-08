;;; tests/tools/test-dev-priorities.scm — pure parts of the AI dev loop's
;;; live priority queue (module/playnet/planner/dev/priorities.scm)
;;;
;;; The impure half (shelling out to `rad`, reading the watermark file,
;;; publishing to MQTT) lives in tools/dev-signal-cycle.scm and is
;;; exercised manually via --dry-run against a real checkout; this pins
;;; the decision logic: priority ranking, issue→entry shape, the
;;; feedback-pool watermark gate.
;;;
;;; Run: guile -L module -L tests tests/tools/test-dev-priorities.scm

(use-modules (playnet test harness)
             (playnet planner dev priorities)
             ((srfi srfi-1) #:select (every find))
             ((srfi srfi-13) #:select (string-prefix? string-contains)))

(display "\n── issue-prio-rank ──\n")
(check "p0 ranks first" (issue-prio-rank '("area:governance" "prio:p0")) 0)
(check "p1 ranks second" (issue-prio-rank '("kind:bug" "prio:p1")) 1)
(check "p2 ranks third" (issue-prio-rank '("prio:p2" "kind:chore")) 2)
(check "unlabeled ranks last" (issue-prio-rank '("area:planner" "kind:bug")) 3)

(display "\n── issue-oid-entries + sort-issue-entries ──\n")

(define* (fake-issue oid title body labels #:optional (status "open"))
  `(("title" . ,title)
    ("state" . (("status" . ,status)))
    ("labels" . ,(list->vector labels))
    ("thread" . (("comments" . ((,oid . (("body" . ,body)))))))))

(let* ((pairs (list (cons "OID_A" (fake-issue "OID_A" "A low-prio thing" "body A" '("prio:p2")))
                    (cons "OID_B" (fake-issue "OID_B" "A p0 thing" "body p0" '("prio:p0")))))
       (entries (issue-oid-entries pairs)))
  (check "both open issues produce an entry" (length entries) 2)
  (check-pred "each entry has a spec-dev-issue- id"
              (every (lambda (e) (string-prefix? "spec-dev-issue-" (assq-ref e 'id))) entries))
  (let ((sorted (sort-issue-entries pairs)))
    (check "p0 sorts before p2" (assq-ref (car sorted) 'title) "A p0 thing")))

(let* ((closed (fake-issue "OID_B" "Already solved" "irrelevant" '("prio:p0") "solved"))
       (entries (issue-oid-entries (list (cons "OID_B" closed)))))
  (check "a non-open issue produces no entry" entries '()))

(let* ((broken `(("title" . "No thread field at all")
                 ("state" . (("status" . "open")))
                 ("labels" . #())))
       (entries (issue-oid-entries (list (cons "OID_C" broken)))))
  (check "an issue with no usable body is dropped, not crashed on" entries '()))

(display "\n── labels, as the labels they state ──\n")
(check "one string of three labels is three labels"
       (split-labels '("area:planner,kind:feature,prio:p2"))
       '("area:planner" "kind:feature" "prio:p2"))
(check "…with the spaces a person typed after the commas"
       (split-labels '("area:infra, kind:bug, prio:p1"))
       '("area:infra" "kind:bug" "prio:p1"))
(check "separate labels stay as they are"
       (split-labels '("design" "voice")) '("design" "voice"))
(check "a joined label string ranks by the priority it states"
       (issue-prio-rank '("area:planner,kind:feature,prio:p0")) 0)

(display "\n── parse-hours ──\n")
(check "3h is three hours" (parse-hours "3h") 3.0)
(check "a bare number is hours" (parse-hours "3") 3.0)
(check "90m is an hour and a half" (parse-hours "90m") 1.5)
(check "2d is two working days" (parse-hours "2d") 16.0)
(check "half hours are stated in decimals" (parse-hours "0.5h") 0.5)
(check "an estimate nobody can read is no estimate" (parse-hours "soon") #f)
(check "…and neither is a length of nothing" (parse-hours "0h") #f)

(display "\n── issue-facts ──\n")
(define* (labelled oid labels #:optional (status "open") (reason #f))
  (cons oid
        `(("title" . ,(string-append "issue " oid))
          ("state" . (("status" . ,status) ,@(if reason `(("reason" . ,reason)) '())))
          ("labels" . ,(list->vector labels))
          ("assignees" . #("did:key:z6Mk-someone")))))

(let ((f (issue-facts "abc123" (cdr (labelled "abc123" '("area:gateway,kind:hardening,prio:p1" "est:6h" "needs:def4"))))))
  (check "the area names the skill's area" (fact-ref f 'area) "gateway")
  (check "the kind names the recipe's kind" (fact-ref f 'kind) "hardening")
  (check "the priority is the rank" (fact-ref f 'prio) 1)
  (check "the estimate is hours" (fact-ref f 'est) 6.0)
  (check "a need names an issue" (fact-ref f 'needs) '("def4"))
  (check "an open issue is open" (fact-ref f 'state) 'open)
  (check "the assignees ride along" (fact-ref f 'assignees) '("did:key:z6Mk-someone")))
(let ((f (issue-facts "abc123" (cdr (labelled "abc123" '("design"))))))
  (check "an issue naming no area states none" (fact-ref f 'area) #f)
  (check "…no kind" (fact-ref f 'kind) #f)
  (check "…and no estimate" (fact-ref f 'est) #f))
(check "solved is closed with the reason solved"
       (fact-ref (issue-facts "a" (cdr (labelled "a" '() "closed" "solved"))) 'state) 'solved)
(check "closed for any other reason is closed"
       (fact-ref (issue-facts "a" (cdr (labelled "a" '() "closed" "other"))) 'state) 'closed)
(check "an issue stating no title has no facts"
       (issue-facts "a" '(("state" . (("status" . "open"))))) #f)

(display "\n── the spec an issue's deliverable is ──\n")
(check "the spec is the id the deficit signal and the agent's branch name"
       (issue-spec-id "abc123")
       (assq-ref (car (issue-oid-entries
                       (list (cons "abc123" (fake-issue "abc123" "t" "b" '())))))
                 'id))
(check "…and it reads back to the issue" (spec-id->oid (issue-spec-id "abc123")) "abc123")
(check "a spec of another family names no issue" (spec-id->oid "spec-dev-triage-feedback-1500") #f)

(display "\n── needs: what waits, what is ready ──\n")
(let* ((all (issues->facts
             (list (labelled "aaaa1111" '("kind:bug"))
                   (labelled "bbbb2222" '("kind:bug" "needs:aaaa"))
                   (labelled "cccc3333" '("kind:bug" "needs:dddd"))
                   (labelled "dddd4444" '("kind:bug") "closed" "solved")
                   (labelled "eeee5555" '("kind:bug" "needs:ffff")))))
       (of  (lambda (oid) (find (lambda (f) (equal? oid (fact-ref f 'oid))) all)))
       (ready (map (lambda (f) (fact-ref f 'oid)) (ready-facts all))))
  (check "a need on an open issue stands open" (needs-open (of "bbbb2222") all) '("aaaa"))
  (check "a need on a solved issue is met" (needs-open (of "cccc3333") all) '())
  (check "a need naming no issue stands open" (needs-open (of "eeee5555") all) '("ffff"))
  (check "the ready issues: open, every need solved" ready '("aaaa1111" "cccc3333")))

(display "\n── parse-watermark ──\n")
(check "a plain integer parses" (parse-watermark "1234\n") 1234)
(check "an empty/missing file reads as 0" (parse-watermark "") 0)
(check "garbage reads as 0 (fails open, not silently stuck)" (parse-watermark "not-a-number") 0)
(check "a negative number reads as 0" (parse-watermark "-5") 0)

(display "\n── feedback-triage-entry: the watermark gate ──\n")
(check "no growth past the watermark → no candidate"
       (feedback-triage-entry 1000 1000) #f)
(check "shrinkage (e.g. an admin prune) → no candidate"
       (feedback-triage-entry 500 1000) #f)
(check-pred "growth past the watermark → a candidate"
            (feedback-triage-entry 1500 1000))
(check "the candidate's id embeds the current byte count"
       (assq-ref (feedback-triage-entry 1500 1000) 'id)
       "spec-dev-triage-feedback-1500")
(check-pred "the candidate names the triage task, not a code fix"
            (string-contains (assq-ref (feedback-triage-entry 1500 1000) 'body)
                              "docs/radicle-issues.md"))
(check-pred "the candidate explicitly refuses to auto-file"
            (string-contains (assq-ref (feedback-triage-entry 1500 1000) 'body)
                              "Do NOT call `rad issue open`"))

(test-summary!)
