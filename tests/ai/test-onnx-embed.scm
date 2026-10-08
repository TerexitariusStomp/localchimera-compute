;;; test-onnx-embed.scm — phase 3 of docs/planning/faces/corpus-guile-native.md,
;;; the genuinely unproven piece: does the Guile FFI kernel produce the
;;; SAME embedding a Node/transformers.js pipeline does, for a real
;;; sentence, run through the SAME model file.
;;;
;;; tests/ai/fixtures/ref-embed-nitrogen.json is that reference: bge-small
;;; run via @huggingface/transformers's AutoModel/AutoTokenizer on "what
;;; fixes nitrogen in soil", mean-pooled and L2-normalized exactly as
;;; tools/corpus/lib/embed.mjs does it. If this test passes, a vector
;;; embedded here and one embedded by the Node indexer are directly
;;; comparable by cosine — not merely "both produce 384 numbers."
;;;
;;; The reference is generated at dtype "q8" — the SAME quantized
;;; model_quantized.onnx this module and the real indexer both load, not
;;; the full-precision model. A first attempt compared against an fp32
;;; reference and landed at a real-but-lower cosine (quantization moves
;;; every dimension slightly) — worth naming so nobody "fixes" the
;;; reference back to fp32 later and reintroduces the mismatch.
;;;
;;; Needs the real onnxruntime shared library and the real cached model —
;;; skips (not fails) if either is missing, since this is a heavier
;;; dependency than the rest of the suite.
;;;
;;; Run: guile -L module tests/ai/test-onnx-embed.scm

(use-modules (playnet test harness))
(use-modules (json))
(use-modules (srfi srfi-1))

(define LIB-PATH (or (getenv "ONNXRUNTIME_LIB")
                     "/gnu/store/mzxdr22bjpwaa0rzgp5zyj6jhp390avs-onnxruntime-1.22.0/lib/libonnxruntime.so"))
(define MODEL-PATH "docs/corpus/.models/Xenova/bge-small-en-v1.5/onnx/model_quantized.onnx")

(define (dot a b)
  (let loop ((i 0) (acc 0.0))
    (if (>= i (vector-length a)) acc
        (loop (1+ i) (+ acc (* (vector-ref a i) (vector-ref b i)))))))

(define (run-real-tests)
  (use-modules (playnet ai onnx-embed))
  (let* ((embedder (load-embedder #:lib-path LIB-PATH #:model-path MODEL-PATH))
         (v (begin (display "\n── shape ──\n") (embed-sentence embedder "what fixes nitrogen in soil"))))
    (check "384-dim output" (vector-length v) 384)

    (display "\n── against the Node pipeline's own embedding, cosine ──\n")
    (let* ((ref (call-with-input-file "tests/ai/fixtures/ref-embed-nitrogen.json" json->scm))
           (cos (dot v ref)))
      (check "cosine similarity to the real Node-pipeline embedding is ~1.0 (>0.999)"
             (> cos 0.999) #t cos))

    (display "\n── properties worth asserting directly ──\n")
    (check "the vector is already L2-normalized (norm ~1.0)"
           (< (abs (- (sqrt (dot v v)) 1.0)) 0.001) #t (sqrt (dot v v)))
    (let ((v2 (embed-sentence embedder "a completely different sentence about bicycles")))
      (check "a different sentence gets a meaningfully different embedding"
             (< (dot v v2) 0.9) #t (dot v v2)))
    (let ((v3 (embed-sentence embedder "what fixes nitrogen in soil")))
      (check "the same sentence embeds identically on a second call (deterministic, no leaked state)"
             (> (dot v v3) 0.9999) #t (dot v v3)))

    (close-embedder embedder)))

(if (not (and (file-exists? LIB-PATH) (file-exists? MODEL-PATH)))
    (begin
      (display "\nskipped: onnxruntime lib or the cached model is not present at\n")
      (display LIB-PATH) (newline) (display MODEL-PATH) (newline)
      (check "skipped, not failed — see message above" #t))
    (run-real-tests))

(test-summary!)
