;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-corpus-sqlite-spike.scm — phase 2 of docs/planning/faces/corpus-guile-native.md:
;;; does guile-sqlite3 actually round-trip a BLOB column and run an FTS5
;;; MATCH query, against a REAL corpus .db (not a synthetic fixture) —
;;; docs/corpus/permaculture/.index/corpus.db, built by the Node pipeline,
;;; 1515 chunks / 384-dim bge-small vectors, unmodified.
;;;
;;; This is a SPIKE, not the final door: it proves the primitive works
;;; before phase 4 wires a whole hybrid-search RPC on top of it.
;;;
;;; Run: guile -L module tests/ai/test-corpus-sqlite-spike.scm

(use-modules (localchimera test harness))
(use-modules (sqlite3))
(use-modules (rnrs bytevectors))
(use-modules (srfi srfi-1))

(define DB "docs/corpus/permaculture/.index/corpus.db")

;; The corpus .db is built by the Node pipeline and gitignored, so a CI
;; checkout has none. Decline cleanly, as test-onnx-embed does; on a machine
;; that should have it, `node tools/corpus/corpus.mjs build permaculture`.
(unless (file-exists? DB)
  (display "\nskipped: no built corpus at\n")
  (display DB) (newline)
  (check "skipped, not failed — see message above" #t)
  (test-summary!))

(define db (sqlite-open DB SQLITE_OPEN_READONLY))

(display "\n── the store's own shape, read back as-is ──\n")
(check "sqlite-open succeeds on a real corpus db" (sqlite-db? db))

(let* ((stmt (sqlite-prepare db "SELECT value FROM meta WHERE key = ?"))
       (_ (sqlite-bind-arguments stmt "embedding_dim"))
       (rows (sqlite-fold cons '() stmt)))
  (sqlite-finalize stmt)
  (check "meta table: embedding_dim readable" (vector-ref (car rows) 0) "384"))

(display "\n── FTS5 MATCH, the sparse half ──\n")
(let* ((stmt (sqlite-prepare db
              "SELECT rowid, bm25(chunks_fts) AS score FROM chunks_fts
               WHERE chunks_fts MATCH ? ORDER BY score LIMIT 5"))
       (_ (sqlite-bind-arguments stmt "\"nitrogen\" OR \"nutrient\""))
       ;; fold-right, not fold: cons-as-kons naturally reverses encounter
       ;; order, and this test is specifically checking that order
       (rows (sqlite-fold-right cons '() stmt)))
  (sqlite-finalize stmt)
  (check "FTS5 MATCH runs and returns rows" (> (length rows) 0) #t (length rows))
  (check "bm25() score is a real number, not a placeholder"
         (every (lambda (r) (real? (vector-ref r 1))) rows) #t)
  ;; bm25() in SQLite is a NEGATIVE cost — lower (more negative) is a
  ;; better match, exactly what tools/corpus/lib/search.mjs's own
  ;; sparseSearch already assumes (`ORDER BY score` ascending, no negation).
  (check "results are sorted ascending — SQLite's bm25() convention, not inverted"
         (let loop ((rs rows)) (or (null? (cdr rs))
                                    (and (<= (vector-ref (car rs) 1) (vector-ref (cadr rs) 1))
                                         (loop (cdr rs)))))
         #t))

(display "\n── the vector BLOB, the dense half ──\n")
(let* ((stmt (sqlite-prepare db "SELECT chunk_id, vec FROM vectors LIMIT 1"))
       (row (sqlite-fold cons '() stmt))
       (_ (sqlite-finalize stmt))
       (bv (vector-ref (car row) 1)))
  (check "the vec column comes back as a bytevector" (bytevector? bv))
  (check "384 float32s = 1536 bytes, exactly" (bytevector-length bv) (* 384 4))
  (let ((v0 (bytevector-ieee-single-ref bv 0 (endianness little)))
        (v1 (bytevector-ieee-single-ref bv 4 (endianness little))))
    (check "the first float decodes to a plausible normalized-embedding value (|x|<2)"
           (< (abs v0) 2.0) #t v0)
    (check "the second float differs from the first (not reading the same bytes twice)"
           (not (= v0 v1)))))

(display "\n── cosine similarity, end to end: two real chunks, self and each other ──\n")
(define (read-vector db id)
  (let* ((stmt (sqlite-prepare db "SELECT vec FROM vectors WHERE chunk_id = ?"))
         (_ (sqlite-bind-arguments stmt id))
         (row (sqlite-fold cons '() stmt))
         (_ (sqlite-finalize stmt))
         (bv (vector-ref (car row) 0)))
    (let ((v (make-vector 384)))
      (let loop ((i 0))
        (when (< i 384)
          (vector-set! v i (bytevector-ieee-single-ref bv (* i 4) (endianness little)))
          (loop (1+ i))))
      v)))
(define (dot a b) (fold + 0 (map * (vector->list a) (vector->list b))))
(let* ((ids (let* ((stmt (sqlite-prepare db "SELECT chunk_id FROM vectors LIMIT 2"))
                    (rows (sqlite-fold cons '() stmt)))
              (sqlite-finalize stmt)
              (map (lambda (r) (vector-ref r 0)) rows)))
       (v0 (read-vector db (car ids)))
       (v1 (read-vector db (cadr ids))))
  (check "a normalized embedding's self-dot-product is ~1.0 (bge-small vectors are pre-normalized)"
         (< (abs (- (dot v0 v0) 1.0)) 0.01) #t (dot v0 v0))
  (check "two DIFFERENT real chunks are not identical vectors"
         (< (abs (- (dot v0 v1) 1.0)) 0.01) #f (dot v0 v1)))

(sqlite-close db)
(test-summary!)
