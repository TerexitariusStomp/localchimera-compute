;;; autocomplete.scm — Autocomplete for xorg REPL (Hoot/WASM compatible)

(define-module (xorg autocomplete)
  #:use-module (ice-9 match)
  #:use-module (goblins)
  #:export (get-completions
            extract-token
            get-completion-context))

;;; ── Completion candidates ──────────────────────────────────────────────────

(define special-forms
  '("modify!" "enact!" "rollback!" "defexpressor" "as"
    "show-history" "show-expressors"
    "ai" "ai-eval"
    "make-org" "enter!" "exit!" "list-orgs" "delete-org"))

(define scheme-forms
  '("lambda" "let" "let*" "letrec" "letrec*"
    "if" "cond" "case" "when" "unless"
    "and" "or" "not"
    "define" "set!"
    "begin" "do"
    "quote" "quasiquote"
    "run*" "run" "fresh" "conde"
    "==" "succeed" "fail" "appendo" "membero"))

;;; ── String utilities (Hoot-compatible) ─────────────────────────────────────

(define (string-prefix? prefix str)
  (and (>= (string-length str) (string-length prefix))
       (string=? (substring str 0 (string-length prefix)) prefix)))

(define (string-contains? sub str)
  (let ((slen (string-length str))
        (sublen (string-length sub)))
    (let loop ((i 0))
      (cond
       ((> (+ i sublen) slen) #f)
       ((string=? (substring str i (+ i sublen)) sub) #t)
       (else (loop (+ i 1)))))))

;;; ── Token extraction ───────────────────────────────────────────────────────

(define (extract-token input cursor-pos)
  "Extract the token being typed at CURSOR-POS."
  (let ((len (string-length input)))
    (if (= len 0) ""
    (let ((start (let loop ((i (max 0 (- cursor-pos 1))))
                   (if (or (< i 0)
                           (memv (string-ref input i)
                                 '(#\space #\newline #\tab #\( #\) #\' #\")))
                       (+ i 1)
                       (loop (- i 1)))))
          (end (let loop ((i cursor-pos))
                 (if (or (>= i len)
                         (memv (string-ref input i)
                               '(#\space #\newline #\tab #\( #\) #\' #\")))
                     i
                     (loop (+ i 1))))))
      (if (< start end)
          (substring input start end)
          "")))))  ;; extra paren closes the (if (= len 0) ...)

;;; ── Completion matching ────────────────────────────────────────────────────

(define (prefix-match? token candidate)
  (string-prefix? token candidate))

(define (fuzzy-match? token candidate)
  (string-contains? token candidate))

(define (filter-completions token candidates match-fn)
  (let loop ((rest candidates) (acc '()))
    (if (null? rest)
        (reverse acc)
        (if (match-fn token (car rest))
            (loop (cdr rest) (cons (car rest) acc))
            (loop (cdr rest) acc)))))

(define (rank-by-length lst)
  "Sort strings by length, shortest first."
  (let loop ((unsorted lst) (sorted '()))
    (if (null? unsorted)
        sorted
        (let ((item (car unsorted)))
          (let insert ((acc '()) (remaining sorted))
            (cond
             ((null? remaining)
              (loop (cdr unsorted) (append acc (list item))))
             ((< (string-length item) (string-length (car remaining)))
              (loop (cdr unsorted) (append acc (cons item remaining))))
             (else
              (insert (append acc (list (car remaining))) (cdr remaining)))))))))

;;; ── Get bindings from org ──────────────────────────────────────────────────

(define (get-binding-names ref)
  "Extract binding names from org ref as strings."
  (let ((bindings ($ ref 'bindings)))
    (let loop ((rest bindings) (acc '()))
      (if (null? rest)
          (reverse acc)
          (loop (cdr rest)
                (cons (symbol->string (car (car rest))) acc))))))

;;; ── Main completion function ───────────────────────────────────────────────

(define (get-completions input cursor-pos ref)
  "Get completion suggestions for INPUT at CURSOR-POS.
Returns list of completion strings, max 10 items."
  (let* ((token (extract-token input cursor-pos))
         (binding-names (get-binding-names ref))
         (all-candidates (append special-forms scheme-forms binding-names))
         (prefix-matches (filter-completions token all-candidates prefix-match?))
         (fuzzy-matches (if (null? prefix-matches)
                            (filter-completions token all-candidates fuzzy-match?)
                            '()))
         (all-matches (append prefix-matches fuzzy-matches))
         (ranked (rank-by-length all-matches)))
    ;; Take top 10
    (let take ((n 10) (lst ranked) (acc '()))
      (if (or (= n 0) (null? lst))
          (reverse acc)
          (take (- n 1) (cdr lst) (cons (car lst) acc))))))

;;; ── Context for AI suggestions ─────────────────────────────────────────────

(define (get-completion-context input cursor-pos ref)
  "Get context information for AI-powered suggestions.
Returns alist with context data."
  (let* ((token (extract-token input cursor-pos))
         (bindings ($ ref 'bindings))
         (history ($ ref 'history))
         (current-exp ($ ref 'expressor-name ($ ref 'current-expressor)))
         ;; Take last 3 history entries
         (recent-history (let loop ((h (reverse history)) (n 3) (acc '()))
                           (if (or (= n 0) (null? h))
                               (reverse acc)
                               (loop (cdr h) (- n 1) (cons (car h) acc))))))
    `((token . ,token)
      (cursor-pos . ,cursor-pos)
      (current-expressor . ,current-exp)
      (recent-bindings . ,(let loop ((b bindings) (n 5) (acc '()))
                            (if (or (= n 0) (null? b))
                                (reverse acc)
                                (loop (cdr b) (- n 1) (cons (car b) acc)))))
      (recent-history . ,recent-history))))
