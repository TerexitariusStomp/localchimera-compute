;;; tools/dev/dev-plan.scm — the development scope's week, planned and printed.
;;;
;;; Reads the repository's Radicle issues and the scope's people, plans the
;;; week over them with the planner, and prints who carries what and what
;;; waits. It reads and prints; it writes nothing, publishes nothing, and
;;; leaves Radicle as it stands.
;;;
;;;   issues   every open issue is a want for its deliverable
;;;            (module/playnet/dev/priorities.scm issue-facts)
;;;   people   docs/dev-scope.sexp, or DEV_SCOPE_PATH
;;;            (module/playnet/dev/recipes.scm)
;;;   plan     module/playnet/dev/plan.scm
;;;
;;; Usage:
;;;   make dev-plan
;;;   guile -L module tools/dev/dev-plan.scm                 every planned row, the first rows of the rest
;;;   guile -L module tools/dev/dev-plan.scm --all           every row
;;;   guile -L module tools/dev/dev-plan.scm --for box       the rows one agent leads
;;;   guile -L module tools/dev/dev-plan.scm --issues FILE   issues read off FILE, a list of
;;;                                                      (oid . json-alist), in place of `rad`
;;;   guile -L module tools/dev/dev-plan.scm --dump-issues   the issues as that list, and no plan
;;;
;;; Requires: rad on PATH (unless --issues), and the planner's solve
;;; environment (the dev-test manifest; `make dev-plan` supplies it).

(use-modules (playnet scope root)
             (playnet dev priorities)
             (playnet dev plan)
             (playnet dev rad-issues)
             ((playnet dev recipes) #:select (person-ref))
             (goblins) (goblins vat)
             (ice-9 format)
             (ice-9 pretty-print)
             (srfi srfi-1))

(define args (cdr (command-line)))
(define (flag? f) (and (member f args) #t))
(define (option f) (let ((m (member f args))) (and m (pair? (cdr m)) (cadr m))))

(define PEOPLE_PATH (or (getenv "DEV_SCOPE_PATH") "docs/dev-scope.sexp"))
(define SHOWN 12)   ; rows of each waiting kind printed without --all

(define (issue-pairs)
  (let ((file (option "--issues")))
    (if file (call-with-input-file file read) (rad-issue-pairs))))

(define (short oid) (if (> (string-length oid) 7) (substring oid 0 7) oid))
(define (clip str n) (if (> (string-length str) n) (string-append (substring str 0 (- n 1)) "…") str))

(define (print-row r)
  (format #t "  p~a  ~a  ~5,1fh~a  ~12a  ~a~a~%"
          (row-ref r 'prio) (short (row-ref r 'oid)) (row-ref r 'hours)
          (if (row-ref r 'estimated?) " " "~")      ; ~ marks hours taken from the kind
          (or (row-ref r 'area) "-")
          (case (row-ref r 'state)
            ((planned) (string-append
                        (string-join (map (lambda (s) (format #f "~a ~,1fh" (car s) (cdr s)))
                                          (row-ref r 'shares))
                                     " + ")
                        "  "))
            ((waits) (format #f "on ~a  " (string-join (row-ref r 'waits-on) ", ")))
            (else ""))
          (clip (row-ref r 'title) 70)))

(define (print-rows title rows)
  (unless (null? rows)
    (format #t "~%~a (~a)~%" title (length rows))
    (let ((shown (if (flag? "--all") rows (take rows (min SHOWN (length rows))))))
      (for-each print-row shown)
      (when (< (length shown) (length rows))
        (format #t "  … ~a more (--all)~%" (- (length rows) (length shown)))))))

(define (main)
  (let ((pairs (issue-pairs)))
    (cond
     ((flag? "--dump-issues")
      (write pairs) (newline))
     (else
      (let ((people (read-dev-people PEOPLE_PATH))
            (facts  (issues->facts pairs)))
        (when (null? people)
          (format (current-error-port)
                  "dev-plan: the scope states its people in ~a — a list of ((id . \"…\") (hours . N) (areas . all | (\"planner\" …)))~%"
                  PEOPLE_PATH)
          (exit 2))
        (let* ((span   (dev-week-span))
               (result (with-vat (spawn-vat #:name "dev-plan")
                         (let ((scope (spawn-scope-root "playnet development")))
                           (seed-dev-scope! scope facts people)
                           (plan-dev-week scope facts people #:span span))))
               (rows   (read-dev-plan result facts people))
               (totals (dev-plan-totals result rows people))
               (of     (lambda (state) (filter (lambda (r) (eq? state (row-ref r 'state))) rows)))
               (who    (option "--for")))
          (format #t "~%playnet development — the week ~a … ~a~%" (car span) (cdr span))
          (format #t "~a open issue~:p asking ~,1f hours; the plan places ~,1f~%"
                  (length rows) (assq-ref totals 'asked) (assq-ref totals 'planned))
          (format #t "~%  ~12a ~8@a ~8@a~%" "" "stated" "planned")
          (for-each (lambda (p) (format #t "  ~12a ~7,1fh ~7,1fh~%" (car p) (cadr p) (caddr p)))
                    (assq-ref totals 'people))
          (format #t "~%  the weekly meeting: ~a~%"
                  (if (assq-ref totals 'meeting) "held" "no hours for it this week"))
          (unless (eq? #t (assq-ref result 'feasible))
            (format #t "~%  the plan reads feasible: ~a~%" (assq-ref result 'feasible)))
          (if who
              (print-rows (string-append who "'s shares this week") (rows-for who rows))
              (begin
                (let ((planned (of 'planned)))
                  (unless (null? planned)
                    (format #t "~%planned (~a)~%" (length planned))
                    (for-each print-row planned)))
                (print-rows "waits on an issue still open" (of 'waits))
                (print-rows "asks a skill nobody of the scope holds" (of 'unheld))
                (print-rows "the week's hours went to other wants" (of 'unplanned))))
          (format #t "~%  ~~ hours taken from the issue's kind; an est: label on the issue states its own~%")))))))

(main)
