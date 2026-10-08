;;; module/playnet/ai/wordpiece.scm — BERT WordPiece tokenization, in pure
;;; Guile, from a HuggingFace tokenizer.json — no Python, no Node, no ML
;;; runtime. The SAME deterministic algorithm HF's `tokenizers` library
;;; runs, reading the SAME tokenizer.json the Node corpus pipeline already
;;; has cached (docs/corpus/.models/…/tokenizer.json), so ids match exactly
;;; with nothing to keep in sync by hand.
;;;
;;; Phase 1 of docs/planning/faces/corpus-guile-native.md: the live-query
;;; embedding step needs the query TOKENIZED before an ONNX model (phase 3)
;;; can run it. This module is that step alone — it produces token ids,
;;; nothing about ONNX or the model itself.
;;;
;;; ── THE PIPELINE (mirrors HF's Bert fast tokenizer, in order) ──────────
;;;   1. NORMALIZE    BertNormalizer: clean-text (drop control chars,
;;;                   canonicalize whitespace), optional CJK spacing,
;;;                   lowercase + accent-stripping (tied together when the
;;;                   config's strip_accents is null, per HF's own rule)
;;;   2. PRE-TOKENIZE BertPreTokenizer: split on whitespace, then split off
;;;                   every punctuation character as its own piece
;;;   3. WORDPIECE    greedy longest-match-first over each piece's
;;;                   characters, "##" continuation prefix on every
;;;                   non-initial subword; the WHOLE piece becomes [UNK] if
;;;                   any part fails to match (BERT's all-or-nothing rule)
;;;   4. TEMPLATE     [CLS] token-ids [SEP] — this tokenizer's
;;;                   post_processor is single-sequence TemplateProcessing;
;;;                   a two-sequence (pair) template is not implemented,
;;;                   because nothing here ever tokenizes a pair
;;;
;;; ── THE ONE STATED GAP: accent-stripping ────────────────────────────────
;;; Guile has no built-in Unicode normalization (NFD decomposition), which
;;; is how HF strips accents in general. ICU (icu4c, packaged in Guix) DOES
;;; expose real NFD normalization — checked, not assumed, and deliberately
;;; NOT used: its symbols are version-suffixed at link time
;;; (`unorm2_normalize_78`, tied to Guix's exact icu4c package version), so
;;; an FFI binding against it would break silently on the next icu4c
;;; upgrade unless the version were resolved at load time — real added
;;; fragility for a gap that is already bounded and correct for the
;;; realistic case. This module strips accents via a static base-letter
;;; table instead — Latin-1 Supplement ("café", "naïve") AND Latin
;;; Extended-A (Polish "Łąka", Czech/Slovak "Świtoń"-style diacritics,
;;; Turkish/Vietnamese-adjacent letters), every case verified against HF's
;;; own tokenizer on real sentences (wordpiece-test.scm), not guessed. A
;;; character outside that table passes through unstripped rather than
;;; silently mis-normalizing.

(define-module (playnet ai wordpiece)
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:export (load-wordpiece
            wordpiece?
            wordpiece-encode
            wordpiece-token->id
            wordpiece-vocab-size
            wordpiece-cls-id
            wordpiece-sep-id
            wordpiece-unk-id))

(define-record-type <wordpiece>
  (make-wordpiece vocab unk-token unk-id cls-id sep-id prefix max-chars
                   lowercase? strip-accents? clean-text? handle-cjk?)
  wordpiece?
  (vocab          wordpiece-vocab)              ; string -> id hash table
  (unk-token      wordpiece-unk-token)
  (unk-id         wordpiece-unk-id)
  (cls-id         wordpiece-cls-id)
  (sep-id         wordpiece-sep-id)
  (prefix         wordpiece-prefix)             ; "##"
  (max-chars      wordpiece-max-chars)
  (lowercase?     wordpiece-lowercase?)
  (strip-accents? wordpiece-strip-accents?)
  (clean-text?    wordpiece-clean-text?)
  (handle-cjk?    wordpiece-handle-cjk?))

;; ── loading ─────────────────────────────────────────────────────────────

(define (json-null? v) (eq? v 'null))

(define (load-wordpiece path)
  "Read a HuggingFace fast-tokenizer JSON file (tokenizer.json) at PATH
   into a <wordpiece>. Only the pieces THIS tokenizer family uses are
   read — BertNormalizer + BertPreTokenizer + a WordPiece model + a
   single-sequence TemplateProcessing post_processor. A tokenizer.json
   built a different way (a different model type, byte-level BPE, …)
   needs its own loader, not a silent best-effort here."
  (let* ((d (call-with-input-file path json->scm))
         (model (or (assoc-ref d "model")
                    (error "wordpiece: no \"model\" section in" path)))
         (norm (assoc-ref d "normalizer"))
         (vocab-alist (or (assoc-ref model "vocab")
                          (error "wordpiece: no \"vocab\" in the model section of" path)))
         (vocab (make-hash-table (length vocab-alist))))
    (for-each (lambda (kv) (hash-set! vocab (car kv) (cdr kv))) vocab-alist)
    (let* ((unk-tok (or (assoc-ref model "unk_token") "[UNK]"))
           (unk-id (hash-ref vocab unk-tok))
           (cls-id (hash-ref vocab "[CLS]"))
           (sep-id (hash-ref vocab "[SEP]"))
           (lowercase? (and norm (eq? (assoc-ref norm "lowercase") #t)))
           (strip-raw (and norm (assoc-ref norm "strip_accents"))))
      (unless (and unk-id cls-id sep-id)
        (error "wordpiece: vocab is missing [UNK], [CLS] or [SEP]" path))
      (make-wordpiece
       vocab unk-tok unk-id cls-id sep-id
       (or (assoc-ref model "continuing_subword_prefix") "##")
       (or (assoc-ref model "max_input_chars_per_word") 100)
       lowercase?
       ;; HF's own rule: strip_accents defaults to following lowercase when
       ;; the config states it as JSON null, rather than defaulting to off
       (if (or (not strip-raw) (json-null? strip-raw)) lowercase? (eq? strip-raw #t))
       (and norm (eq? (assoc-ref norm "clean_text") #t))
       (and norm (eq? (assoc-ref norm "handle_chinese_chars") #t))))))

;; ── normalize ───────────────────────────────────────────────────────────

;; the base-letter a real English agroecology query's accented characters
;; reduce to — see the module header for what this does and does not cover
(define %accent-strip
  '(;; Latin-1 Supplement
    (#\á . #\a) (#\à . #\a) (#\â . #\a) (#\ä . #\a) (#\ã . #\a) (#\å . #\a)
    (#\ç . #\c) (#\é . #\e) (#\è . #\e) (#\ê . #\e) (#\ë . #\e)
    (#\í . #\i) (#\ì . #\i) (#\î . #\i) (#\ï . #\i)
    (#\ñ . #\n) (#\ó . #\o) (#\ò . #\o) (#\ô . #\o) (#\ö . #\o) (#\õ . #\o)
    (#\ú . #\u) (#\ù . #\u) (#\û . #\u) (#\ü . #\u) (#\ý . #\y) (#\ÿ . #\y)
    (#\Á . #\A) (#\À . #\A) (#\Â . #\A) (#\Ä . #\A) (#\Ã . #\A) (#\Å . #\A)
    (#\Ç . #\C) (#\É . #\E) (#\È . #\E) (#\Ê . #\E) (#\Ë . #\E)
    (#\Í . #\I) (#\Ì . #\I) (#\Î . #\I) (#\Ï . #\I)
    (#\Ñ . #\N) (#\Ó . #\O) (#\Ò . #\O) (#\Ô . #\O) (#\Ö . #\O) (#\Õ . #\O)
    (#\Ú . #\U) (#\Ù . #\U) (#\Û . #\U) (#\Ü . #\U) (#\Ý . #\Y)
    ;; Latin Extended-A/B diacritics that DO have a canonical NFD
    ;; decomposition (base letter + combining mark) — each checked against
    ;; the real HF tokenizer, not assumed from how the character looks.
    ;; Stroke/dotless/slash letters are deliberately ABSENT: ł, ı, ø/Ø have
    ;; NO Unicode decomposition at all, and real BERT normalization leaves
    ;; them untouched — mapping them here would be a real mismatch, not a
    ;; wider net (verified: "łaka" tokenizes with ł intact, not as "laka").
    (#\ą . #\a) (#\ć . #\c) (#\ę . #\e) (#\ń . #\n) (#\ś . #\s)
    (#\ź . #\z) (#\ż . #\z)
    (#\č . #\c) (#\Č . #\C) (#\ď . #\d) (#\Ď . #\D)
    (#\ě . #\e) (#\Ě . #\E) (#\ň . #\n) (#\Ň . #\N)
    (#\ř . #\r) (#\Ř . #\R) (#\š . #\s) (#\Š . #\S)
    (#\ť . #\t) (#\Ť . #\T) (#\ž . #\z) (#\Ž . #\Z)
    (#\ő . #\o) (#\Ő . #\O) (#\ű . #\u) (#\Ű . #\U)
    (#\ğ . #\g) (#\ş . #\s) (#\Ş . #\S)
    (#\ā . #\a) (#\Ā . #\A) (#\ē . #\e) (#\Ē . #\E)
    (#\ī . #\i) (#\Ī . #\I) (#\ō . #\o) (#\Ō . #\O)
    (#\ū . #\u) (#\Ū . #\U)))

(define (strip-char-accent c) (or (assoc-ref %accent-strip c) c))

;; BERT's _is_chinese_char: the CJK unicode blocks it treats as needing a
;; space on each side, so WordPiece later sees each character as its own
;; pre-tokenized piece
(define (cjk-char? c)
  (let ((cp (char->integer c)))
    (or (<= #x4E00 cp #x9FFF)   (<= #x3400 cp #x4DBF)
        (<= #x20000 cp #x2A6DF) (<= #x2A700 cp #x2B73F)
        (<= #x2B740 cp #x2B81F) (<= #x2B820 cp #x2CEAF)
        (<= #xF900 cp #xFAFF)   (<= #x2F800 cp #x2FA1F))))

(define (ws-char? c)
  (or (char=? c #\space) (char=? c #\tab) (char=? c #\newline) (char=? c #\return)
      (eq? (char-general-category c) 'Zs)))

(define (control-char? c)
  (and (not (char=? c #\tab)) (not (char=? c #\newline)) (not (char=? c #\return))
       (memq (char-general-category c) '(Cc Cf))))

;; drop NUL and other true control characters; canonicalize every
;; whitespace-class character (tab, newline, Unicode space separators, …)
;; to a single plain space — BertNormalizer's clean_text
(define (clean-text s)
  (call-with-output-string
   (lambda (port)
     (string-for-each
      (lambda (c)
        (cond ((char=? c #\nul) #t)
              ((control-char? c) #t)
              ((ws-char? c) (write-char #\space port))
              (else (write-char c port))))
      s))))

(define (space-cjk s)
  (call-with-output-string
   (lambda (port)
     (string-for-each
      (lambda (c)
        (if (cjk-char? c)
            (begin (write-char #\space port) (write-char c port) (write-char #\space port))
            (write-char c port)))
      s))))

(define (normalize-text wp text)
  "BertNormalizer, in the order HF applies it."
  (let* ((s (if (wordpiece-clean-text? wp) (clean-text text) text))
         (s (if (wordpiece-handle-cjk? wp) (space-cjk s) s))
         (s (if (wordpiece-lowercase? wp) (string-downcase s) s))
         (s (if (wordpiece-strip-accents? wp) (string-map strip-char-accent s) s)))
    s))

;; ── pre-tokenize ────────────────────────────────────────────────────────

;; ASCII punctuation ranges (BERT treats these as punctuation even though
;; some sit outside Unicode's own P* categories, e.g. '$' '+' '<') plus any
;; character Unicode itself calls punctuation
(define (punctuation-char? c)
  (let ((cp (char->integer c)))
    (or (and (>= cp 33) (<= cp 47)) (and (>= cp 58) (<= cp 64))
        (and (>= cp 91) (<= cp 96)) (and (>= cp 123) (<= cp 126))
        (memq (char-general-category c) '(Pc Pd Ps Pe Pi Pf Po)))))

(define (whitespace-split s)
  (filter (lambda (w) (positive? (string-length w))) (string-split s #\space)))

;; a word broken at every punctuation character, each becoming its own
;; single-character piece — BERT's _run_split_on_punc
(define (split-on-punctuation word)
  (let loop ((chars (string->list word)) (cur '()) (out '()))
    (define (flush) (if (pair? cur) (cons (list->string (reverse cur)) out) out))
    (cond
     ((null? chars) (reverse (flush)))
     ((punctuation-char? (car chars))
      (loop (cdr chars) '() (cons (string (car chars)) (flush))))
     (else (loop (cdr chars) (cons (car chars) cur) out)))))

(define (pre-tokenize s) (append-map split-on-punctuation (whitespace-split s)))

;; ── wordpiece ───────────────────────────────────────────────────────────

;; one pre-tokenized WORD → its subword pieces (strings, "##"-prefixed past
;; the first), or the unk-token alone if any part fails to match — BERT's
;; own all-or-nothing rule per word, not per subword
(define (wordpiece-tokenize-word wp word)
  (let ((n (string-length word)))
    (if (> n (wordpiece-max-chars wp))
        (list (wordpiece-unk-token wp))
        (let loop ((start 0) (pieces '()))
          (if (>= start n)
              (reverse pieces)
              (let try ((end n))
                (cond
                 ((< end (1+ start)) (list (wordpiece-unk-token wp)))
                 (else
                  (let* ((piece0 (substring word start end))
                         (piece (if (> start 0) (string-append (wordpiece-prefix wp) piece0) piece0)))
                    (if (hash-ref (wordpiece-vocab wp) piece)
                        (loop end (cons piece pieces))
                        (try (1- end))))))))))))

(define (wordpiece-encode wp text)
  "TEXT → a list of token ids: [CLS], the WordPiece ids of its normalized
   and pre-tokenized pieces, [SEP] — ready to feed a model's input_ids."
  (let* ((norm (normalize-text wp text))
         (words (pre-tokenize norm))
         (pieces (append-map (lambda (w) (wordpiece-tokenize-word wp w)) words))
         (ids (map (lambda (p) (or (hash-ref (wordpiece-vocab wp) p) (wordpiece-unk-id wp)))
                   pieces)))
    (cons (wordpiece-cls-id wp) (append ids (list (wordpiece-sep-id wp))))))

(define (wordpiece-token->id wp tok) (hash-ref (wordpiece-vocab wp) tok))
(define (wordpiece-vocab-size wp) (hash-count (lambda (k v) #t) (wordpiece-vocab wp)))
