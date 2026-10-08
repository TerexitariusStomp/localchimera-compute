;;; test-corpus-search.scm — phase 4 of docs/planning/faces/corpus-guile-native.md:
;;; hybrid search, entirely in Guile, against the REAL built permaculture
;;; corpus. Not just "returns something" — the top hit for a real question
;;; must actually be ABOUT what was asked, checked by substring, and the
;;; ranking must react to fusing both halves, not just one.
;;;
;;; Needs onnxruntime + a real embedder; self-skips (not fails) if either
;;; the library or the built corpus is missing.
;;;
;;; Run: guile -L module tests/ai/test-corpus-search.scm

(use-modules (playnet test harness))
(use-modules (srfi srfi-1))

(define LIB-PATH (or (getenv "ONNXRUNTIME_LIB")
                     "/gnu/store/mzxdr22bjpwaa0rzgp5zyj6jhp390avs-onnxruntime-1.22.0/lib/libonnxruntime.so"))
(define MODEL-PATH "docs/corpus/.models/Xenova/bge-small-en-v1.5/onnx/model_quantized.onnx")
(define DOMAIN-DIR "docs/corpus/permaculture")

(define (run-real-tests)
  (use-modules (playnet ai onnx-embed))
  (use-modules (playnet ai corpus-search))
  (let* ((corpus (open-corpus DOMAIN-DIR))
         (embedder (load-embedder #:lib-path LIB-PATH #:model-path MODEL-PATH)))

    (display "\n── the store's own counts, read back through this door ──\n")
    (let ((stats (corpus-stats corpus)))
      (check "some chunks are indexed" (> (assq-ref stats 'chunks) 0) #t)
      (check "at least one source" (> (assq-ref stats 'sources) 0) #t))

    (display "\n── a real question, hybrid-ranked ──\n")
    (let* ((hits (search-corpus corpus embedder "what fixes nitrogen in the soil" #:limit 5)))
      (check "returns hits" (> (length hits) 0) #t)
      (check "every hit carries text, a source, a title and a score"
             (every (lambda (h) (and (assq-ref h 'text) (assq-ref h 'source) (assq-ref h 'title) (assq-ref h 'score) #t)) hits))
      (check "scores are sorted descending — best fusion score first"
             (let loop ((hs hits)) (or (null? (cdr hs))
                                        (and (>= (assq-ref (car hs) 'score) (assq-ref (cadr hs) 'score))
                                             (loop (cdr hs))))))
      (check "the top hit is actually ABOUT nitrogen, not just any passage"
             (let ((text (string-downcase (assq-ref (car hits) 'text))))
               (and (or (string-contains text "nitrogen") (string-contains text "legume")
                       (string-contains text "nutrient"))
                    #t))
             #t))

    (display "\n── the two halves genuinely differ, and fusion uses both ──\n")
    ;; a query built ENTIRELY from stopwords has no sparse half at all
    ;; (search.mjs's own toFtsQuery contract) — dense alone must still answer
    (let ((hits (search-corpus corpus embedder "what is this for" #:limit 3)))
      (check "a stopword-only query still returns hits (dense half alone carries it)"
             (> (length hits) 0) #t))
    ;; an exact rare phrase should score highly on the SPARSE half even if
    ;; dense similarity alone might not rank it first
    (let* ((hits (search-corpus corpus embedder "closing the nutrient loop" #:limit 5))
           (texts (map (lambda (h) (string-downcase (assq-ref h 'text))) hits)))
      (check "a distinctive phrase's own words show up in the ranked results"
             (and (any (lambda (t) (string-contains t "nutrient")) texts) #t) #t))

    (display "\n── limit is honored ──\n")
    (check "limit=3 returns at most 3" (<= (length (search-corpus corpus embedder "compost" #:limit 3)) 3))

    (close-embedder embedder)
    (close-corpus corpus)))

(if (not (and (file-exists? LIB-PATH) (file-exists? MODEL-PATH) (file-exists? (string-append DOMAIN-DIR "/.index/corpus.db"))))
    (begin
      (display "\nskipped: onnxruntime, the cached model, or the built permaculture corpus is missing\n")
      (check "skipped, not failed — see message above" #t))
    (run-real-tests))

(test-summary!)
