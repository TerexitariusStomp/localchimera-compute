;;; module/playnet/ai/conform.scm — ONE door for "ask a model for a shape".
;;;
;;; Every model reply is untrusted text. Each caller that wants a STRUCTURE out
;;; of it does the same four things: read the first S-expression or JSON object
;;; out of whatever prose surrounds it, check the value against its shape, and
;;; when the check fails, either ask again with the failure spelled out or fall
;;; back to a deterministic floor. This module is that loop, written once. The
;;; legal-statute extractor (planner/knowledge/law/scrape.scm), the comms restyle fence
;;; (planner/comms/ai.scm) and the browser's log passes (ui/app/conform.ts, the
;;; same loop in TypeScript) all stand on it.
;;;
;;; The shape of the loop is the "self-healing AI pipe" of the match repo
;;; (match/src/lib/core/ai/ai-pipe.ts): generate → validate → on failure, re-ask
;;; with the previous output and the validation errors quoted back → repeat up
;;; to N times. Zod is the schema there; here a schema is two procedures the
;;; caller owns, so no schema library enters the tree:
;;;
;;;   read   : raw-text → candidate | #f     (#f = nothing readable in the reply)
;;;   check  : candidate → #f | reason-string (#f = it conforms; a string = why not)
;;;   accept : candidate → value             (the result; identity by default)
;;;
;;; and the HOUSE DISCIPLINE is the fourth: the floor. The AI can only
;;; refine; when it cannot conform, the caller's deterministic answer ships.
;;; `floor` is a procedure of the LAST candidate (or #f when nothing was ever
;;; readable), so a caller that can salvage a partly-good reply (drop the bad
;;; records, keep the good) does so there, and one that cannot ignores its
;;; argument and returns the dry answer.
;;;
;;; A transport error (the gateway is down, the completer raises) goes straight
;;; to the floor with no retry: a retry cannot fix an absent network, and the
;;; caller has already said what to ship in that case.
;;;
;;; The completer is the (prompt → text) thunk llm-completer (playnet ai llm)
;;; returns, or any lambda of that shape in a test. Healing is expressed as a
;;; NEW PROMPT to that same thunk — the previous output, the reasons, and the
;;; original request — so the seam every caller already has is unchanged.

(define-module (playnet ai conform)
  #:use-module (ice-9 format)
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (conform
            read-first-sexp
            read-first-json-object
            default-heal-prompt
            %conform-default-retries))

;; one re-ask by default: a second call is cheap next to a dropped record, and
;; a model that cannot conform on the second try rarely does on the third.
(define %conform-default-retries 1)

;;; ─── readers : the first structure inside a reply, prose and fences stripped ─

(define (read-first-sexp raw)
  "The first S-expression in RAW, or #f. Leading prose, a code fence, a trailing
   remark — all skipped. A reply with no open paren, or one whose first form
   does not read, is #f."
  (and (string? raw)
       (let ((i (string-index raw #\()))
         (and i
              (catch #t
                (lambda () (with-input-from-string (substring raw i) read))
                (lambda _ #f))))))

(define (read-first-json-object raw)
  "The first {…} object in RAW (outermost braces) as a guile-json alist, or #f
   when there is none or it does not parse. An array is not one object."
  (and (string? raw)
       (let ((a (string-index raw #\{))
             (b (string-rindex raw #\})))
         (and a b (> b a)
              (let ((v (catch #t (lambda () (json-string->scm (substring raw a (+ b 1))))
                              (lambda _ #f))))
                (and (list? v) v))))))

;;; ─── the healing prompt ───────────────────────────────────────────────────

(define (default-heal-prompt original raw reason)
  "What the model sees on a re-ask: its previous output, why it failed, and the
   original request again. RAW is the previous reply text (or #f when the
   completer returned non-text); REASON is the check's string."
  (string-append
   "Your previous response failed validation. Here is what went wrong.\n\n"
   "Previous output:\n" (if (string? raw) raw "(no text)") "\n\n"
   "Validation errors:\n" reason "\n\n"
   "Reply again, corrected, in exactly the shape the original request asks for "
   "and nothing else.\n\n"
   "Original request:\n" original))

;;; ─── the loop ─────────────────────────────────────────────────────────────

(define* (conform complete prompt
                  #:key read check floor (accept identity)
                        (retries %conform-default-retries)
                        (heal default-heal-prompt)
                        (trace #f))
  "Ask COMPLETE (prompt → text) for PROMPT until READ+CHECK accept the reply, at
   most RETRIES re-asks, each phrased by HEAL (original raw reason → prompt).
   Returns (ACCEPT candidate) for a conforming reply; otherwise (FLOOR last),
   where last is the most recent readable candidate or #f. FLOOR is required:
   a caller without a deterministic answer has not finished designing its door.
   TRACE, when a procedure, receives (attempt raw reason) per failed attempt."
  (unless (procedure? complete) (error "conform: COMPLETE must be (prompt -> text)"))
  (unless (procedure? read)     (error "conform: supply #:read (text -> candidate | #f)"))
  (unless (procedure? check)    (error "conform: supply #:check (candidate -> #f | reason)"))
  (unless (procedure? floor)    (error "conform: supply #:floor (last-candidate -> value)"))
  (let loop ((attempt 0) (ask prompt) (last #f))
    (call-with-values
      (lambda ()
        (catch #t
          (lambda () (values #t (complete ask)))
          (lambda (k . args) (values #f (cons k args)))))
      (lambda (ok? raw)
        (cond
         ((not ok?)                            ; transport failure: floor, no retry
          (when trace (trace attempt #f (format #f "transport error: ~s" raw)))
          (floor last))
         (else
          (let* ((candidate (read raw))
                 (reason (if candidate
                             (check candidate)
                             "the reply carried nothing readable in the required shape")))
            (cond
             ((not reason) (accept candidate)) ; conforms
             (else
              (when trace (trace attempt raw reason))
              (let ((last (or candidate last)))
                (if (< attempt retries)
                    (loop (+ attempt 1) (heal prompt raw reason) last)
                    (floor last))))))))))))
