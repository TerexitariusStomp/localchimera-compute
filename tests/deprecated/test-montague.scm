;;; test-montague.scm — Montague-style semantic composition demo
;;;
;;; A direct port of the BB1 ch.2.4 lambda machinery into our planner repo,
;;; plus a small grammar demonstration showing how natural-language phrases
;;; turn into first-order formulas via β-reduction.
;;;
;;; Run standalone (no planner deps):
;;;
;;;   cd planner && guile --no-auto-compile -q -l tests/test-montague.scm
;;;
;;; Or via the full test runner (which includes it):
;;;
;;;   cd planner && ./run-tests.sh

(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (ice-9 format))

(let ((dir (dirname (current-filename))))
  (use-modules (playnet deprecated planner relational lambda))
  (use-modules (playnet deprecated planner relational mont-lex))
  (use-modules (playnet deprecated planner relational mont-grammar)))

(lam-reset-counter!)

(define show-count 0)
;;; ── Display helpers ───────────────────────────────────────────────────────

(define (line c n) (make-string n c))

(define (banner str)
  (newline)
  (display (line #\═ 78)) (newline)
  (display "  ") (display str) (newline)
  (display (line #\═ 78)) (newline))

(define (section str)
  (newline)
  (let ((pad (max 1 (- 73 (string-length str)))))
    (display "── ") (display str) (display " ") (display (line #\─ pad))
    (newline)))

(define (showcase phrase)
  "Parse PHRASE, print raw λ-term, full β-reduction trace, and result."
  (set! show-count (+ show-count 1))
  (newline)
  (format #t "  PHRASE   ~a~%" phrase)
  (let ((raw (mont-parse phrase)))
    (cond
      ((not raw)
       (format #t "  PARSE    ✗ failed to parse~%")
       (set! fail-count (+ fail-count 1)))
      (else
       (format #t "  λ-TERM   ~a~%" (lam-pretty raw))
       (let ((trace (lam-beta-trace raw)))
         (when (> (length trace) 1)
           (display "  REDUCE") (newline)
           (let loop ((steps trace) (i 0))
             (cond
               ((null? steps) #f)
               (else
                (format #t "    [~a]    ~a~%" i (lam-pretty (car steps)))
                (loop (cdr steps) (+ i 1)))))))
       (format #t "  RESULT   ~a~%" (lam-pretty (lam-beta-normalize raw)))))))

(define (assert-meaning phrase expected)
  "Parse PHRASE, β-normalize, and check it is α-equivalent to EXPECTED."
  (let ((actual (mont-meaning phrase)))
    (cond
      ((not actual)
       (format #t "  ✗ ~s → no parse~%" phrase)
       (set! fail-count (+ fail-count 1)))
      ((lam-alpha-equiv? actual expected)
       (format #t "  ✓ ~22@a  ⤳  ~a~%" phrase (lam-pretty actual))
       (set! pass-count (+ pass-count 1)))
      (else
       (format #t "  ✗ ~s~%      expected: ~a~%      got:      ~a~%"
               phrase (lam-pretty expected) (lam-pretty actual))
       (set! fail-count (+ fail-count 1))))))
;;; ══════════════════════════════════════════════════════════════════════════
;;;  Demo
;;; ══════════════════════════════════════════════════════════════════════════

(banner "Montague composition: λ-calculus over our lexicon (BB1 ch.2)")

(section "Lexical entries (each one is a λ-term)")
(format #t "  vincent  →  ~a~%" (lam-pretty (mont-lookup-pn "vincent")))
(format #t "  mia      →  ~a~%" (lam-pretty (mont-lookup-pn "mia")))
(format #t "  every    →  ~a~%" (lam-pretty (mont-lookup-det "every")))
(format #t "  a        →  ~a~%" (lam-pretty (mont-lookup-det "a")))
(format #t "  no       →  ~a~%" (lam-pretty (mont-lookup-det "no")))
(format #t "  boxer    →  ~a~%" (lam-pretty (mont-lookup-noun "boxer")))
(format #t "  walks    →  ~a~%" (lam-pretty (mont-lookup-iv "walks")))
(format #t "  loves    →  ~a~%" (lam-pretty (mont-lookup-tv "loves")))
(section "Intransitive: subject + verb")
(showcase "vincent walks")
(showcase "mia snorts")
(section "Transitive: subject + verb + object")
(showcase "vincent loves mia")
(showcase "butch likes mia")
(section "Quantified subject — every / a")
(showcase "every boxer walks")
(showcase "a woman snorts")
(section "Quantified subject AND object — the α-conversion stress test")
(showcase "every man loves a woman")
(showcase "no factory makes flour")
(section "Planner-relevant vocabulary")
(showcase "every commune produces bread")
(showcase "every farmer grows wheat")
(showcase "a worker needs bread")
(showcase "no factory makes flour")
(section "α-conversion check (manually constructed colliding term)")
;; (λx.λy.(x y)) y — naïve substitution would let the inner λy. capture
;; the free y. Our subst should rename the inner binder before substituting.
(let* ((bad-redex '(app (lam x (lam y (app x y))) y))
       (one-step  (lam-beta-step bad-redex)))
  (format #t "  input    ~a~%" (lam-pretty bad-redex))
  (format #t "  step     ~a~%" (lam-pretty one-step))
  (format #t "  (the inner λy. has been α-renamed so it doesn't capture~%")
  (format #t "   the free y on the right of the application)~%"))
(section "Assertions (compared up to α-equivalence)")

(assert-meaning "vincent walks"
                '(walk vincent))

(assert-meaning "mia snorts"
                '(snort mia))

(assert-meaning "vincent loves mia"
                '(love vincent mia))

(assert-meaning "butch likes mia"
                '(like butch mia))

(assert-meaning "every boxer walks"
                '(forall x (imp (boxer x) (walk x))))

(assert-meaning "a woman snorts"
                '(exists x (and (woman x) (snort x))))

(assert-meaning "every man loves a woman"
                '(forall x
                   (imp (man x)
                        (exists y (and (woman y) (love x y))))))

(assert-meaning "no factory makes flour"
                '(not (exists x (and (factory x) (make x flour)))))

(assert-meaning "every commune produces bread"
                '(forall x (imp (commune x) (produce x bread))))

(assert-meaning "every farmer grows wheat"
                '(forall x (imp (farmer x) (grow x wheat))))

(assert-meaning "a worker needs bread"
                '(exists x (and (worker x) (need x bread))))
(section "Summary")
(format #t "  ~a phrases shown, ~a assertions passed, ~a failed~%"
        show-count pass-count fail-count)
(newline)

(if (> fail-count 0)
    (exit 1)
    (exit 0))
