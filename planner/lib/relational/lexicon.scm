;;; lexicon.scm — Bridge between human words and planning facts
;;;
;;; Spec-name resolution grounded in live facts. The grammar never touches
;;; strings directly — it delegates to these relations. Bidirectional:
;;; ground the word to find spec-ids, or ground the spec-id to find words.

(use-modules (playnet kanren-constraints))


;;; ── Spec resolution ────────────────────────────────────────────────────────

(define (spec-name-o ctx word spec-id)
  "Relate a single lowercase WORD (string) to a SPEC-ID via live facts.
   Uses O(1) index when available, falls back to scanning spec-name facts."
  (let ((indexes (ctx-indexes ctx)))
    (if indexes
        (fresh ()
          (project (word)
            (let ((w (if (string? word) word (symbol->string word))))
              (let ((matches (idx-ref indexes 'specs-by-word w)))
                (if (null? matches) fail
                    (in-list-o spec-id matches))))))
        ;; Fallback: scan
        (fresh (name)
          (in-list-o `(spec-name ,spec-id ,name) (ctx-facts ctx))
          (project (name word)
            (let ((w (string-downcase
                       (if (string? word) word (symbol->string word)))))
              (if (string=? w (string-downcase name)) succeed fail)))))))

(define (spec-word-o ctx spec-id word)
  "Given ground SPEC-ID, unify WORD with its lowercase display name."
  (fresh (name)
    (in-list-o `(spec-name ,spec-id ,name) (ctx-facts ctx))
    (project (name) (== word (string-downcase name)))))


;;; ── Location resolution ────────────────────────────────────────────────────

(define (location-word-o ctx loc-id word)
  "Location-id → display word. Strips common 'loc-' prefix."
  (project (loc-id)
    (if (and (string? loc-id)
             (> (string-length loc-id) 4)
             (string=? "loc-" (substring loc-id 0 4)))
        (== word (substring loc-id 4))
        (== word (if (string? loc-id) loc-id "unknown")))))


;;; ── Tokenization ───────────────────────────────────────────────────────────

(define (tokenize-phrase str)
  "Split a phrase into lowercase word tokens. Numbers become integers.
   Ground Scheme helper, not a relation."
  (map (lambda (w)
         (let ((n (string->number w)))
           (or n (string-downcase w))))
       (filter (lambda (s) (not (string=? s "")))
               (string-split str #\space))))
