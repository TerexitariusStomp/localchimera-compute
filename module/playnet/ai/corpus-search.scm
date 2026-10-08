;;; module/playnet/ai/corpus-search.scm — phase 4 of
;;; docs/planning/faces/corpus-guile-native.md: hybrid (BM25 + dense) search over
;;; a built corpus domain, entirely in Guile — no Node, no subprocess.
;;; Mirrors tools/corpus/lib/search.mjs's own algorithm exactly (reciprocal
;;; rank fusion over the same two halves), reading the SAME `.index/corpus.db`
;;; files the Node indexer already produces, via the primitives phases 1–3
;;; proved: `(playnet ai wordpiece)` + `(playnet ai onnx-embed)` for the
;;; dense half, `(sqlite3)`'s FTS5 for the sparse half.
;;;
;;; A citizen's question ("what fixes nitrogen in soil") never touches an
;;; embedding model directly here beyond this module's own call to
;;; `embed-sentence` — the SAME model file and dtype the real indexer used,
;;; so a query vector and a stored passage vector live in the same space
;;; (proved in tests/ai/test-onnx-embed.scm, not assumed again here).

(define-module (playnet ai corpus-search)
  #:use-module (sqlite3)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:use-module (playnet ai onnx-embed)
  #:export (open-corpus
            corpus?
            corpus-slug
            close-corpus
            search-corpus
            corpus-stats))

(define-record-type <corpus>
  (make-corpus db slug)
  corpus?
  (db corpus-db)
  (slug corpus-slug))

(define (open-corpus domain-dir)
  "Open the built index under DOMAIN-DIR (e.g. \"docs/corpus/permaculture\")
   read-only. Errors if the domain has never been built — this module never
   builds one; `/corpus build <domain>` (Node) is what produces it."
  (let ((path (string-append domain-dir "/.index/corpus.db")))
    (unless (file-exists? path)
      (error "corpus-search: no built index — run `/corpus build` for this domain first:" path))
    (make-corpus (sqlite-open path SQLITE_OPEN_READONLY)
                 (last (string-split domain-dir #\/)))))

(define (close-corpus corpus) (sqlite-close (corpus-db corpus)))

(define (corpus-stats corpus)
  "(chunks . N) (sources . N) — a cheap sanity read, not used by search itself."
  (define (count table)
    (let* ((stmt (sqlite-prepare (corpus-db corpus) (string-append "SELECT count(*) FROM " table)))
           (rows (sqlite-fold cons '() stmt)))
      (sqlite-finalize stmt)
      (vector-ref (car rows) 0)))
  `((chunks . ,(count "chunks")) (sources . ,(count "sources"))))

;; ── the sparse half: FTS5 + bm25(), same query-building as search.mjs ────

;; tools/corpus/lib/search.mjs's own STOPWORDS, verbatim — kept as ONE list
;; to diff against if that file's ever changes, not re-derived independently
(define %stopwords
  (let ((h (make-hash-table)))
    (for-each (lambda (w) (hash-set! h w #t))
              (string-split
               (string-append
                "a an the of for and or to in on at is are was were be been it its this that "
                "these those with from by as how what which when where why do does can could "
                "should would we you they i")
               #\space))
    h))

;; splits on anything that ISN'T a letter, digit, dot, hyphen or slash —
;; the same character class search.mjs's toFtsQuery uses, so "34.3 g/kg" and
;; hyphenated terms survive as one token the way they do there
(define (split-fts-words text)
  (let loop ((chars (string->list (string-downcase text))) (cur '()) (out '()))
    (define (keep? c) (or (char-alphabetic? c) (char-numeric? c) (memv c '(#\. #\- #\/))))
    (define (flush) (if (pair? cur) (cons (list->string (reverse cur)) out) out))
    (cond ((null? chars) (reverse (flush)))
          ((keep? (car chars)) (loop (cdr chars) (cons (car chars) cur) out))
          (else (loop (cdr chars) '() (flush))))))

(define (trim-edge-punct w)
  (string-trim-both w (lambda (c) (memv c '(#\. #\- #\/)))))

(define (fts-match-string text)
  "TEXT → an FTS5 MATCH expression (each real term quoted, OR'd together),
   or #f when nothing survives stopword/length filtering — a query that is
   ALL stopwords (\"what is this for\") has no sparse half, same as
   search.mjs's own toFtsQuery."
  (let ((terms (filter (lambda (w) (and (> (string-length w) 1) (not (hash-ref %stopwords w))))
                       (map trim-edge-punct (split-fts-words text)))))
    (and (pair? terms)
         (fold (lambda (w acc) (if acc (string-append acc " OR \"" w "\"") (string-append "\"" w "\"")))
               #f terms))))

(define (sparse-search corpus text k)
  "The top K chunk ids by bm25() rank (best first), or '() when TEXT has no
   usable terms at all."
  (let ((match (fts-match-string text)))
    (if (not match) '()
        (let* ((stmt (sqlite-prepare (corpus-db corpus)
                      "SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH ?
                       ORDER BY bm25(chunks_fts) LIMIT ?"))
               (_ (sqlite-bind-arguments stmt match k))
               ;; fold-right, not fold: cons-as-kons reverses encounter
               ;; order, and RANK (best first) is exactly what RRF needs
               (rows (sqlite-fold-right cons '() stmt)))
          (sqlite-finalize stmt)
          (map (lambda (r) (vector-ref r 0)) rows)))))

;; ── the dense half: cosine over the corpus's own stored vectors ─────────

(define (bv-dot bv qvec dim)
  (let loop ((i 0) (acc 0.0))
    (if (>= i dim) acc
        (loop (1+ i) (+ acc (* (bytevector-ieee-single-ref bv (* i 4) (endianness little))
                               (vector-ref qvec i)))))))

(define (dense-search corpus embedder text k)
  "The top K chunk ids by cosine similarity to TEXT's own embedding (best
   first) — brute-force over every stored vector, same trade-off
   store.mjs's own header states: \"a book-scale corpus is tens of
   thousands of chunks… single-digit milliseconds\", well under the cost
   of embedding TEXT itself."
  (let* ((qvec (embed-sentence embedder text))
         (dim (vector-length qvec))
         (stmt (sqlite-prepare (corpus-db corpus) "SELECT chunk_id, vec FROM vectors"))
         (rows (sqlite-fold cons '() stmt)))
    (sqlite-finalize stmt)
    (let* ((scored (map (lambda (r) (cons (vector-ref r 0) (bv-dot (vector-ref r 1) qvec dim))) rows))
           (ranked (sort scored (lambda (a b) (> (cdr a) (cdr b))))))
      (map car (if (> (length ranked) k) (list-head ranked k) ranked)))))

;; ── reciprocal rank fusion — search.mjs's RRF_K, unchanged ──────────────

(define %rrf-k 60)

(define (rrf-fuse id-lists limit)
  "Fuse several RANKED (best-first) id lists by reciprocal rank: an id's
   score is the sum, over every list it appears in, of 1/(RRF_K + rank + 1)
   — an id both searches agree on outranks one only one found, without
   either half's raw score scale mattering at all. Returns (id . score)
   pairs, best first — the score rides along so a CALLER merging several
   corpora's own results can re-rank across them, rather than only ever
   truncating one at a time (search-corpus's own #:limit stays a per-corpus
   cut; cross-corpus merging is `(playnet gateway corpus-service)`'s job)."
  (let ((scores (make-hash-table)))
    (for-each
     (lambda (ids)
       (let loop ((ids ids) (rank 0))
         (unless (null? ids)
           (hash-set! scores (car ids) (+ (or (hash-ref scores (car ids)) 0) (/ 1.0 (+ %rrf-k rank 1))))
           (loop (cdr ids) (1+ rank)))))
     id-lists)
    (let ((ranked (sort (hash-map->list cons scores) (lambda (a b) (> (cdr a) (cdr b))))))
      (if (> (length ranked) limit) (list-head ranked limit) ranked))))

;; ── reading the winning chunks back out ─────────────────────────────────

(define (chunk-row corpus id score)
  (let* ((stmt (sqlite-prepare (corpus-db corpus)
               "SELECT c.text, c.heading, c.source, c.line_start, c.line_end, s.title, s.author
                FROM chunks c JOIN sources s ON s.slug = c.source WHERE c.id = ?"))
         (_ (sqlite-bind-arguments stmt id))
         (rows (sqlite-fold cons '() stmt)))
    (sqlite-finalize stmt)
    (and (pair? rows)
         (let ((r (car rows)))
           `((id . ,id) (score . ,score) (text . ,(vector-ref r 0)) (heading . ,(vector-ref r 1))
             (source . ,(vector-ref r 2)) (line-start . ,(vector-ref r 3))
             (line-end . ,(vector-ref r 4)) (title . ,(vector-ref r 5)) (author . ,(vector-ref r 6)))))))

(define* (search-corpus corpus embedder query #:key (limit 8) (pool #f))
  "QUERY → up to LIMIT chunks (alists: id, score, text, heading, source,
   title, author, line-start, line-end), hybrid-ranked — the same
   RRF-of-BM25-and-cosine tools/corpus/lib/search.mjs runs, over the same
   index file. SCORE is the RRF fusion score, carried along so a caller
   merging several corpora's results can re-rank across them."
  (let* ((pool (or pool (max 40 (* limit 6))))
         (dense (dense-search corpus embedder query pool))
         (sparse (sparse-search corpus query pool))
         (fused (rrf-fuse (list dense sparse) limit)))
    (filter-map (lambda (p) (chunk-row corpus (car p) (cdr p))) fused)))
