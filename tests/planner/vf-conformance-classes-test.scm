;;; vf-conformance-classes-test.scm — the vocabulary file, held to the vocabulary's classes.
;;;
;;; `module/playnet/vf/schemas.scm` is the ValueFlows core of this
;;; codebase. The vocabulary's Turtle file (docs/valueflows/assets/all_vf.TTL) is
;;; the authority on what the core is. This test PARSES that file at run time and
;;; holds the two to each other in both directions:
;;;
;;;   records → classes   every record type the vocabulary file exports is a class
;;;                       of the TTL, or is named in `*named-otherwise*` (the
;;;                       action table's row; the OWL-Time duration vf:hasDuration
;;;                       points at);
;;;   classes → records   every class of the TTL has a record, or is named in
;;;                       `*carried-otherwise*` with how the repo carries it.
;;;
;;; What playnet adds stands in a module of its own, one per family, listed in
;;; `*families*`: the buffer planner (ddmrp/records), recurring schedules
;;; (beyond/schedules), the lot (beyond/lot), the planning scenario
;;; (beyond/scenario) and the books' states (observation/states). Each family
;;; holds its records and none of them is a class of the TTL or a record of the
;;; vocabulary file. So the core is what the TTL says, and each family is named
;;; with the route by which it may fold into the core
;;; (docs/planning/codebase-organization.md §7). A record that enters the
;;; vocabulary file without a class behind it fails here until it takes a family.
;;; Both lists are checked for rot: an entry that names no record, or names one
;;; that is a class, fails.
;;;
;;; Run:
;;;   cd <repo> && guix shell --pure -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- \
;;;     guile --no-auto-compile -q -L module tests/planner/vf-conformance-classes-test.scm

(use-modules (playnet test harness)
             (playnet vf schemas)
             (playnet ddmrp records)
             (playnet vf beyond schedules)
             (playnet vf beyond lot)
             (playnet vf beyond scenario)
             (playnet observation states)
             (srfi srfi-1) (srfi srfi-13))

(use-modules (playnet test vf-ttl))

;;; ── the TTL's classes ───────────────────────────────────────────────────────
;;; A class is a subject `vf:Name` (capital initial) at the head of a block.

(define ttl-classes
  (delete-duplicates
   (filter-map
    (lambda (line)
      (and (string-prefix? "vf:" line)
           (> (string-length line) 3)
           (char-upper-case? (string-ref line 3))
           (let ((end (or (string-index line (lambda (c) (not (or (char-alphabetic? c) (char-numeric? c)))) 3)
                          (string-length line))))
             (substring line 3 end))))
    (read-lines (string-append (vf-repo-root) "/" %ttl-path)))))

;;; ── the vocabulary file's record types ──────────────────────────────────────
;;; Read off the module's interface: every exported `<name>`.

(define (record-names module-name)
  (sort
   (filter-map (lambda (sym)
                 (let ((s (symbol->string sym)))
                   (and (string-prefix? "<" s) (string-suffix? ">" s)
                        (string->symbol (substring s 1 (- (string-length s) 1))))))
               (module-map (lambda (sym var) sym) (resolve-interface module-name)))
   (lambda (a b) (string<? (symbol->string a) (symbol->string b)))))

(define core-records (record-names '(playnet vf schemas)))

(define (kebab->camel sym)
  (string-concatenate
   (map string-titlecase (string-split (symbol->string sym) #\-))))

;;; A record whose name differs from its class, or that the TTL references and does
;;; not define.
(define *named-otherwise*
  '((action-definition . "one row of the TTL's Actions table (vf:Action and its effect columns)")
    (duration          . "the range of vf:hasDuration is OWL-Time's Duration, which the TTL references")))

(define (class-of record) (kebab->camel record))
(define (class? record) (and (member (class-of record) ttl-classes) #t))

;;; ── the families ────────────────────────────────────────────────────────────
;;; (name module route): each family's records stand in the module, and the route
;;; is the way each may fold into the core, to be tried (codebase-organization.md §7).

(define *families*
  `((buffer-planner (playnet ddmrp records)
      "a buffer as a standing Intent, a profile as a classification, a signal as an Intent, a snapshot as a reading of events")
    (schedules      (playnet vf beyond schedules)
      "dated Intents over the horizon, against one recurrence extension")
    (lot            (playnet vf beyond lot)
      "the code is trackingIdentifier; the expiry is expiresOn, which has one date and no kind")
    (scenario       (playnet vf beyond scenario)
      "a vf:Scenario under a ScenarioDefinition; the stochastic weights are the part VF has no slot for")
    (states         (playnet observation states)
      "derived from the events that fulfil, satisfy and settle; an account is an EconomicResource of a credit specification")))

;;; ── carried otherwise ───────────────────────────────────────────────────────
;;; (class how). Classes of the TTL the repo carries without a record of that name.

(define *carried-otherwise*
  '(("Person"            "an <agent> whose agent-type is 'person")
    ("Organization"      "an <agent> whose agent-type is 'organization")
    ("EcologicalAgent"   "an <agent> whose agent-type is 'ecological-agent")
    ("ProposalPurpose"   "the symbol in a <proposal>'s purpose field")
    ("EventQuantity"     "the symbols of <action-definition>'s event-quantity column")
    ("InputOutput"       "the symbols of the input-output column")
    ("CreateResource"    "the symbols of the create-resource column")
    ("AccountingEffect"  "the symbols of the accounting-effect column")
    ("OnhandEffect"      "the symbols of the onhand-effect column")
    ("LocationEffect"    "the symbols of the location-effect column")
    ("ContainedEffect"   "the symbols of the contained-effect column")
    ("AccountableEffect" "the symbols of the accountable-effect column")
    ("StageEffect"       "the symbols of the stage-effect column")
    ("StateEffect"       "the symbols of the state-effect column")))

;;; ── records → classes ───────────────────────────────────────────────────────

(format #t "\n── the vocabulary file: ~a record types, ~a classes in the TTL ──\n"
        (length core-records) (length ttl-classes))

(for-each
 (lambda (r)
   (check (format #f "<~a> is ~a" r
                  (cond ((class? r) (string-append "vf:" (class-of r)))
                        ((assq r *named-otherwise*) (cdr (assq r *named-otherwise*)))
                        (else "a class of the TTL, or a family's record, not the vocabulary file's")))
          (or (class? r) (and (assq r *named-otherwise*) #t))))
 core-records)

(for-each
 (lambda (e)
   (check (format #f "declared <~a> is a record of the vocabulary file and no class of the TTL" (car e))
          (and (memq (car e) core-records) (not (class? (car e))))))
 *named-otherwise*)

;;; ── classes → records ───────────────────────────────────────────────────────

(format #t "\n── every class of the TTL is carried ──\n")

(define core-classes (cons "Action" (map class-of (filter class? core-records))))

(for-each
 (lambda (c)
   (let ((how (assoc c *carried-otherwise*)))
     (check (format #f "vf:~a ~a" c
                    (cond ((member c core-classes) "has its record")
                          (how (string-append "is " (cadr how)))
                          (else "has a record or is declared carried otherwise")))
            (or (and (member c core-classes) #t) (and how #t)))))
 ttl-classes)

(for-each
 (lambda (e)
   (check (format #f "declared vf:~a is a class of the TTL with no record of its name" (car e))
          (and (member (car e) ttl-classes) (not (member (car e) core-classes)))))
 *carried-otherwise*)

(check "the three agent kinds the TTL names are the agent types"
       (equal? (sort (map symbol->string *agent-types*) string<?)
               '("ecological-agent" "organization" "person")))

;;; ── each family stands apart ────────────────────────────────────────────────

(for-each
 (lambda (family)
   (let* ((name (car family)) (module (cadr family)) (records (record-names module)))
     (format #t "\n── ~a (~a): ~a record types ──\n" name module (length records))
     (check (format #f "~a holds at least one record" name) (pair? records))
     (for-each
      (lambda (r)
        (check (format #f "<~a> is no record of the vocabulary file" r) (not (memq r core-records)))
        (check (format #f "<~a> is no class of the TTL" r) (not (class? r))))
      records)))
 *families*)

(check "the buffer planner has nine record types"
       (= 9 (length (record-names '(playnet ddmrp records)))))

(test-summary!)
