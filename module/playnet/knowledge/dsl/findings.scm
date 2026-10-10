;;; module/playnet/knowledge/dsl/findings.scm — what a lint says, in one shape
;;;
;;; A finding is (severity kind subject detail): severity ∈ error | warning |
;;; info, kind a symbol naming the rule, subject the thing it is about, detail
;;; one sentence stating the fact. The law lint and the ValueFlows lint both
;;; speak it, so one reader — a report, a gate's exit code, a door's JSON, or
;;; the reason a model is asked again with — serves every lint.
;;;
;;; `findings->reason` is that last reader: the error-tier findings as the
;;; numbered facts a re-ask quotes back ((playnet ai conform)), most severe
;;; first and capped, so a second reply chases the ones that matter.

(define-module (playnet knowledge dsl findings)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:export (finding finding-severity finding-kind finding-subject finding-detail
            errors-only findings-by-severity format-findings findings->wire findings->reason))

(define (finding severity kind subject detail) (list severity kind subject detail))
(define (finding-severity f) (list-ref f 0))
(define (finding-kind f)     (list-ref f 1))
(define (finding-subject f)  (list-ref f 2))
(define (finding-detail f)   (list-ref f 3))

(define (errors-only findings)
  (filter (lambda (f) (eq? 'error (finding-severity f))) findings))

(define %rank '((error . 0) (warning . 1) (info . 2)))
(define (findings-by-severity findings)
  "FINDINGS ordered error, warning, info; stable within a tier."
  (let ((rank (lambda (f) (or (assq-ref %rank (finding-severity f)) 3))))
    (sort findings (lambda (a b) (< (rank a) (rank b))))))

(define (format-findings findings)
  (string-join
   (map (lambda (f)
          (format #f "  ~a ~a  ~a — ~a"
                  (case (finding-severity f)
                    ((error) "ERROR  ") ((warning) "warning") (else "info   "))
                  (finding-kind f) (finding-subject f) (finding-detail f)))
        findings)
   "\n"))

(define (findings->wire findings)
  "FINDINGS as a vector of JSON objects: severity, kind, subject, detail."
  (list->vector
   (map (lambda (f)
          `(("severity" . ,(symbol->string (finding-severity f)))
            ("kind" . ,(symbol->string (finding-kind f)))
            ("subject" . ,(format #f "~a" (finding-subject f)))
            ("detail" . ,(finding-detail f))))
        findings)))

(define* (findings->reason findings #:key (limit 8))
  "The error-tier findings as the numbered facts a model is asked again with,
or #f when there are none. At most LIMIT lines, and a line for the rest."
  (let* ((errs (errors-only (findings-by-severity findings)))
         (shown (if (> (length errs) limit) (take errs limit) errs)))
    (and (pair? errs)
         (string-join
          (append
           (map (lambda (f i) (format #f "~a. ~a: ~a" i (finding-subject f) (finding-detail f)))
                shown (iota (length shown) 1))
           (if (> (length errs) limit)
               (list (format #f "…and ~a more of the same kinds" (- (length errs) limit)))
               '()))
          "\n"))))
