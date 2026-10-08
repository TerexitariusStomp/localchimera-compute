;;; test-wordpiece.scm — the Guile WordPiece tokenizer against REAL ground
;;; truth: every expected id sequence below is what
;;; @huggingface/transformers' own AutoTokenizer.from_pretrained produced
;;; on the SAME docs/corpus/.models/Xenova/bge-small-en-v1.5/tokenizer.json,
;;; on the exact sentences below — not hand-derived, not guessed. Any
;;; divergence here is this module's bug, not a hypothesis about one.
;;;
;;; Covers: plain words, an em-dash + comma + period, a question mark +
;;; parens + a decimal-looking hyphenated number, accented characters
;;; (the one stated gap — a static table, not full Unicode NFD), and
;;; whitespace/tab canonicalization.
;;;
;;; Run: guile -L module tests/ai/test-wordpiece.scm

(use-modules (playnet test harness))
(use-modules (playnet ai wordpiece))
(use-modules (srfi srfi-1))

(define TOKENIZER "docs/corpus/.models/Xenova/bge-small-en-v1.5/tokenizer.json")

;; The tokenizer file is a gitignored download (docs/corpus/.models/), present
;; on a dev machine and absent from a CI checkout. Decline cleanly, as
;; test-onnx-embed does, rather than fail on a file that was never there.
(unless (file-exists? TOKENIZER)
  (display "\nskipped: the cached tokenizer is not present at\n")
  (display TOKENIZER) (newline)
  (check "skipped, not failed — see message above" #t)
  (test-summary!))

(define wp (load-wordpiece TOKENIZER))

(display "\n── loading ──\n")
(check "vocab size matches the real vocab (30522 tokens)" (wordpiece-vocab-size wp) 30522)
(check "[CLS] id" (wordpiece-cls-id wp) 101)
(check "[SEP] id" (wordpiece-sep-id wp) 102)
(check "[UNK] id" (wordpiece-unk-id wp) 100)

(display "\n── ground truth, from the real HF tokenizer on this exact file ──\n")
(define CASES
  '(("what fixes nitrogen in soil"
     (101 2054 8081 2229 14114 1999 5800 102))
    ("Closing the nutrient loop — composting, mulching, and cover crops."
     (101 5494 1996 26780 7077 1517 4012 19894 2075 1010 14163 29358 2075 1010 1998 3104 8765 1012 102))
    ("How deep should a swale be dug? (30-45cm is typical.)"
     (101 2129 2784 2323 1037 25430 9453 2022 8655 1029 1006 2382 1011 3429 27487 2003 5171 1012 1007 102))
    ("café-grown coffee, naïve gardeners"
     (101 7668 1011 4961 4157 1010 15743 19785 2015 102))
    ("  multiple   spaces\tand\ttabs  "
     (101 3674 7258 1998 21628 2015 102))))

(for-each
 (lambda (case)
   (let* ((text (car case)) (want (cadr case))
          (got (wordpiece-encode wp text)))
     (check (string-append "encode: " text) got want)))
 CASES)

(display "\n── properties worth asserting directly ──\n")
(check "every encoding starts with [CLS]" (= (car (wordpiece-encode wp "anything")) 101))
(check "every encoding ends with [SEP]"
       (= (last (wordpiece-encode wp "anything")) 102))
;; WordPiece is good at decomposing even nonsense LETTER strings (single
;; ASCII letters are themselves valid subwords) — real ground truth shows
;; "zzzxxxqqqjjjvvv" tokenizes without ever needing [UNK] at all. A
;; genuine miss needs a character truly outside the vocabulary (an emoji)
;; or a "word" longer than max_input_chars_per_word — both verified
;; against the real tokenizer to actually produce it.
(check "an emoji (genuinely outside the vocabulary) becomes [UNK]"
       (wordpiece-encode wp "🌱🍅") '(101 100 102))
(check "a word past max_input_chars_per_word (100) becomes [UNK] outright"
       (wordpiece-encode wp (make-string 150 #\a)) '(101 100 102))
(check "an empty string is still [CLS] [SEP]" (wordpiece-encode wp "") '(101 102))
(check "case does not matter (lowercase is on for this tokenizer)"
       (equal? (wordpiece-encode wp "NITROGEN") (wordpiece-encode wp "nitrogen")))

(display "\n── Latin Extended-A: only what real NFD actually decomposes ──\n")
;; ground truth again — tok.decode() on real HF output, not assumed from
;; how a character LOOKS: ń/ś (combining acute) strip, ł (a stroke letter,
;; no Unicode decomposition at all) does NOT — real BERT keeps it literally
(check "'Świtoń' strips to 'swi ##ton' — ś and ń both decompose"
       (wordpiece-encode wp "Świtoń") '(101 25430 9956 2078 102))
(check "'Łąka' keeps ł untouched (no NFD decomposition exists for it) while ą still strips"
       (wordpiece-encode wp "Łąka") '(101 1105 11905 102))
(check "'façade' strips ç exactly as café strips é" (wordpiece-encode wp "façade") '(101 8508 102))

(test-summary!)
