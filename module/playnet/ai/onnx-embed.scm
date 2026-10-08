;;; module/playnet/ai/onnx-embed.scm — a sentence embedding, in-process, via
;;; ONNX Runtime's C API called directly through Guile's FFI. No Node, no
;;; Python, no subprocess: the same shape of thing
;;; `module/playnet/planner/solve/solver.scm` already does for OSQP (`*kern-lib*`,
;;; `dynamic-link`/`pointer->procedure`, marshaling arrays across the
;;; boundary) — phase 3 of docs/planning/faces/corpus-guile-native.md, the one
;;; piece that doc named as genuinely unproven until it ran.
;;;
;;; ── THE C API IS A VTABLE, NOT NAMED SYMBOLS ────────────────────────────
;;; `dynamic-func` finds a library's EXPORTED symbols by name; ONNX
;;; Runtime's C API exposes exactly one of those (`OrtGetApiBase`), and
;;; everything else — CreateEnv, CreateSession, Run, … — is a function
;;; pointer sitting at a fixed BYTE OFFSET inside the `OrtApi` struct that
;;; call returns. Those offsets are NOT hand-counted from the header (a
;;; 250+ field struct invites exactly the off-by-one a human would make) —
;;; they come from `offsetof()`, compiled and run against the real header
;;; onnxruntime.h ships (see the offsets inlined below, one comment each,
;;; not a guess). If onnxruntime ever ships a header whose field order
;;; changed, these offsets would need re-deriving the same way, not by hand.
;;;
;;; ── THE PIPELINE ─────────────────────────────────────────────────────────
;;;   text --wordpiece--> token ids --Run--> [1, seq, dim] hidden states
;;;        --mean-pool over seq--> --L2-normalize--> one DIM-float vector
;;; mirroring tools/corpus/lib/embed.mjs's `{pooling: "mean", normalize:
;;; true}` exactly, so a vector from here and one from the Node indexer are
;;; directly comparable by cosine — verified, not assumed
;;; (tests/ai/test-onnx-embed.scm diffs against the Node pipeline's own
;;; output on the same sentence).

(define-module (playnet ai onnx-embed)
  #:use-module (system foreign)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-9)
  #:use-module (playnet ai wordpiece)
  #:export (load-embedder
            embedder?
            embed-sentence
            close-embedder))

;; ── the vtable primitive ─────────────────────────────────────────────────

;; the pointer VALUE stored OFFSET bytes into whatever BASE points at —
;; reading a field out of a C struct we have no Scheme record for
(define (struct-ref-pointer base offset)
  (make-pointer (bytevector-u64-native-ref (pointer->bytevector base 8 offset) 0)))

;; offsetof(OrtApi, NAME), against onnxruntime 1.22.0's real
;; onnxruntime_c_api.h (ORT_API_VERSION 22) — compiled and run, not counted
(define %off:CreateEnv 24)
(define %off:CreateSessionOptions 80)
(define %off:SetIntraOpNumThreads 192)
(define %off:CreateSession 56)
(define %off:Run 72)
(define %off:CreateCpuMemoryInfo 552)
(define %off:CreateTensorWithDataAsOrtValue 392)
(define %off:GetTensorMutableData 408)
(define %off:GetErrorMessage 16)
(define %off:ReleaseStatus 744)
(define %off:ReleaseEnv 736)
(define %off:ReleaseSession 760)
(define %off:ReleaseSessionOptions 800)
(define %off:ReleaseMemoryInfo 752)
(define %off:ReleaseValue 768)

;; ONNXTensorElementDataType — only the one this module ever creates
(define %ONNX_INT64 7)
;; OrtLoggingLevel: WARNING (quiet unless something is actually wrong)
(define %ORT_LOGGING_LEVEL_WARNING 2)
(define %ORT_API_VERSION 22)

(define-record-type <ort-api>
  (make-ort-api ptr CreateEnv CreateSessionOptions SetIntraOpNumThreads
                CreateSession Run CreateCpuMemoryInfo
                CreateTensorWithDataAsOrtValue GetTensorMutableData
                GetErrorMessage ReleaseStatus ReleaseEnv ReleaseSession
                ReleaseSessionOptions ReleaseMemoryInfo ReleaseValue)
  ort-api?
  (ptr ort-api-ptr)
  (CreateEnv ort-CreateEnv) (CreateSessionOptions ort-CreateSessionOptions)
  (SetIntraOpNumThreads ort-SetIntraOpNumThreads) (CreateSession ort-CreateSession)
  (Run ort-Run) (CreateCpuMemoryInfo ort-CreateCpuMemoryInfo)
  (CreateTensorWithDataAsOrtValue ort-CreateTensorWithDataAsOrtValue)
  (GetTensorMutableData ort-GetTensorMutableData)
  (GetErrorMessage ort-GetErrorMessage) (ReleaseStatus ort-ReleaseStatus)
  (ReleaseEnv ort-ReleaseEnv) (ReleaseSession ort-ReleaseSession)
  (ReleaseSessionOptions ort-ReleaseSessionOptions)
  (ReleaseMemoryInfo ort-ReleaseMemoryInfo) (ReleaseValue ort-ReleaseValue))

(define (load-ort-api lib-path)
  "Load libonnxruntime's C API vtable from the shared library at LIB-PATH.
   An absolute path — `dynamic-link`'s bare-name search does not see a
   Guix package's own lib/ directory unless it is already on the loader's
   search path (LD_LIBRARY_PATH), which a `guix shell onnxruntime` alone
   does not set (checked directly, not assumed)."
  (let* ((lib (dynamic-link lib-path))
         (get-api-base (pointer->procedure '* (dynamic-func "OrtGetApiBase" lib) '()))
         (api-base (get-api-base))
         (get-api (pointer->procedure '* (struct-ref-pointer api-base 0) (list uint32)))
         (api (get-api %ORT_API_VERSION)))
    (when (null-pointer? api)
      (error "onnx-embed: this onnxruntime does not support ORT_API_VERSION" %ORT_API_VERSION))
    (define (fn offset ret args) (pointer->procedure ret (struct-ref-pointer api offset) args))
    (make-ort-api api
                  (fn %off:CreateEnv '* (list int '* '*))
                  (fn %off:CreateSessionOptions '* (list '*))
                  (fn %off:SetIntraOpNumThreads '* (list '* int))
                  (fn %off:CreateSession '* (list '* '* '* '*))
                  (fn %off:Run '* (list '* '* '* '* size_t '* size_t '*))
                  (fn %off:CreateCpuMemoryInfo '* (list int int '*))
                  (fn %off:CreateTensorWithDataAsOrtValue '* (list '* '* size_t '* size_t int '*))
                  (fn %off:GetTensorMutableData '* (list '* '*))
                  (fn %off:GetErrorMessage '* (list '*))
                  (fn %off:ReleaseStatus void (list '*))
                  (fn %off:ReleaseEnv void (list '*))
                  (fn %off:ReleaseSession void (list '*))
                  (fn %off:ReleaseSessionOptions void (list '*))
                  (fn %off:ReleaseMemoryInfo void (list '*))
                  (fn %off:ReleaseValue void (list '*)))))

;; every ORT_API2_STATUS call returns an OrtStatus* — NULL is success, a
;; real pointer is an error whose message must be read (and the status
;; itself released) before it leaks
(define (check-status! api status label)
  (unless (null-pointer? status)
    (let ((msg (pointer->string ((ort-GetErrorMessage api) status))))
      ((ort-ReleaseStatus api) status)
      (error (string-append "onnx-embed: " label " failed:") msg))))

;; ── the embedder: one env + one loaded session, reused across calls ─────

(define-record-type <embedder>
  (make-embedder api env session mem-info wp dim)
  embedder?
  (api embedder-api) (env embedder-env) (session embedder-session)
  (mem-info embedder-mem-info) (wp embedder-wp) (dim embedder-dim))

;; the default LIB-PATH, same shape as planner/solve/solver.scm's *kern-lib* (an
;; env override checked FIRST, exactly the escape hatch a deployment needs)
;; — with one real difference: solver.scm's fallback is a path relative to
;; THIS REPO's own build output, stable across checkouts; onnxruntime is a
;; GUIX PACKAGE, so there is no such stable relative path, only this
;; checkout's current store hash. `guix shell onnxruntime` alone does not
;; put the library on the loader's search path (checked directly — a bare
;; "libonnxruntime.so" dynamic-link fails in that shell), so there is no
;; bare-name fallback to reach for either. The hash below WILL go stale on
;; the next `onnxruntime` rebuild; ONNXRUNTIME_LIB is not a nicety here, it
;; is the only durable way to point this at a real library — a deployment
;; (a Guix service, a shepherd unit) is expected to set it, the same way
;; one would set PLANNER_KERNEL.
(define %default-lib-path
  (or (getenv "ONNXRUNTIME_LIB")
      "/gnu/store/mzxdr22bjpwaa0rzgp5zyj6jhp390avs-onnxruntime-1.22.0/lib/libonnxruntime.so"))

;; docs/corpus/.models — a default only, deliberately NOT derived from
;; `current-filename`: tried that (deriving the repo root from this
;; source file's own location, the same trick planner/solve/solver.scm uses for
;; PLANNER_KERNEL) and found it EMPIRICALLY UNRELIABLE — `current-filename`
;; came back #f even for a plain module load with an absolute -L entry,
;; for reasons that took real effort to chase without landing on a fully
;; certain mechanism. Its failure mode was SILENT wrong behaviour too
;; ("<cwd>/docs/corpus/.models" instead of an error) — the honest answer
;; is that this path is not reliably derivable from inside the module
;; itself. This module stays deliberately corpus-AGNOSTIC otherwise (it is
;; a general "embed a sentence" primitive), so it does not know about
;; PLAYNET_CORPUS_DIR — a CALLER that already knows both roots
;; (`(playnet gateway corpus-service)`'s %embedder-args) passes explicit
;; #:model-path/#:tokenizer-path instead of relying on this default at
;; all. PLAYNET_CORPUS_MODELS_DIR below is this module's OWN escape hatch
;; for being loaded standalone; the (getcwd) fallback past that is a dev
;; convenience for ad-hoc runs from the repo root ONLY — not a deployment
;; answer on its own.
(define %models-root
  (or (getenv "PLAYNET_CORPUS_MODELS_DIR")
      (string-append (getcwd) "/docs/corpus/.models")))
(define %default-model-path
  (string-append %models-root "/Xenova/bge-small-en-v1.5/onnx/model_quantized.onnx"))
(define %default-tokenizer-path
  (string-append %models-root "/Xenova/bge-small-en-v1.5/tokenizer.json"))

(define* (load-embedder #:key
                        (lib-path %default-lib-path)
                        (model-path %default-model-path)
                        (tokenizer-path %default-tokenizer-path)
                        (dim 384))
  "Load the ONNX Runtime API, the bge-small model at MODEL-PATH, and its
   WordPiece tokenizer — everything one call to EMBED-SENTENCE needs, held
   for reuse rather than reloaded per query."
  (let* ((api (load-ort-api lib-path))
         (out (make-bytevector 8 0)))
    (check-status! api ((ort-CreateEnv api) %ORT_LOGGING_LEVEL_WARNING
                        (string->pointer "playnet-corpus-embed") (bytevector->pointer out))
                   "CreateEnv")
    (let ((env (make-pointer (bytevector-u64-native-ref out 0)))
          (so-out (make-bytevector 8 0)))
      (check-status! api ((ort-CreateSessionOptions api) (bytevector->pointer so-out))
                     "CreateSessionOptions")
      (let ((session-options (make-pointer (bytevector-u64-native-ref so-out 0)))
            (sess-out (make-bytevector 8 0)))
        (check-status! api ((ort-SetIntraOpNumThreads api) session-options 1)
                       "SetIntraOpNumThreads")
        (check-status! api ((ort-CreateSession api) env (string->pointer model-path)
                            session-options (bytevector->pointer sess-out))
                       "CreateSession")
        (let ((session (make-pointer (bytevector-u64-native-ref sess-out 0)))
              (mi-out (make-bytevector 8 0)))
          (check-status! api ((ort-CreateCpuMemoryInfo api) 0 0 (bytevector->pointer mi-out))
                         "CreateCpuMemoryInfo")
          (make-embedder api env session
                         (make-pointer (bytevector-u64-native-ref mi-out 0))
                         (load-wordpiece tokenizer-path) dim))))))

;; a bytevector of N int64s, native-endian, from a Scheme list
(define (int64-bytevector xs)
  (let* ((n (length xs)) (bv (make-bytevector (* n 8) 0)))
    (let loop ((i 0) (xs xs))
      (when (pair? xs)
        (bytevector-s64-native-set! bv (* i 8) (car xs))
        (loop (1+ i) (cdr xs))))
    bv))

;; an OrtValue* tensor wrapping BV's bytes as SHAPE — BV must outlive the
;; tensor (CreateTensorWithDataAsOrtValue borrows the buffer, per the C API
;; docs, rather than copying it)
(define (make-int64-tensor api mem-info bv shape-bv shape-len)
  (let ((out (make-bytevector 8 0)))
    (check-status! api
                   ((ort-CreateTensorWithDataAsOrtValue api) mem-info (bytevector->pointer bv)
                    (bytevector-length bv) (bytevector->pointer shape-bv) shape-len
                    %ONNX_INT64 (bytevector->pointer out))
                   "CreateTensorWithDataAsOrtValue")
    (make-pointer (bytevector-u64-native-ref out 0))))

(define (pointer-array . ptrs)
  (let ((bv (make-bytevector (* 8 (length ptrs)) 0)))
    (let loop ((i 0) (ps ptrs))
      (when (pair? ps)
        (bytevector-u64-native-set! bv (* i 8) (pointer-address (car ps)))
        (loop (1+ i) (cdr ps))))
    bv))

(define (embed-sentence embedder text)
  "TEXT → its bge-small sentence embedding: a Guile vector of
   (embedder-dim EMBEDDER) f64s, mean-pooled over the token sequence and
   L2-normalized — the SAME two steps tools/corpus/lib/embed.mjs applies,
   so a vector from here and one from the Node indexer compare directly by
   cosine (tests/ai/test-onnx-embed.scm proves this, not just that the
   shapes match)."
  (let* ((api (embedder-api embedder))
         (ids (wordpiece-encode (embedder-wp embedder) text))
         (n (length ids))
         (dim (embedder-dim embedder))
         (ids-bv (int64-bytevector ids))
         (ones-bv (int64-bytevector (make-list n 1)))
         (zeros-bv (int64-bytevector (make-list n 0)))
         (shape-bv (int64-bytevector (list 1 n)))
         (mem-info (embedder-mem-info embedder))
         (t-ids (make-int64-tensor api mem-info ids-bv shape-bv 2))
         (t-mask (make-int64-tensor api mem-info ones-bv shape-bv 2))
         (t-type (make-int64-tensor api mem-info zeros-bv shape-bv 2))
         (input-names (pointer-array (string->pointer "input_ids")
                                     (string->pointer "attention_mask")
                                     (string->pointer "token_type_ids")))
         (inputs (pointer-array t-ids t-mask t-type))
         (output-names (pointer-array (string->pointer "last_hidden_state")))
         (outputs (make-bytevector 8 0)))
    (check-status! api
                   ((ort-Run api) (embedder-session embedder) %null-pointer
                    (bytevector->pointer input-names) (bytevector->pointer inputs) 3
                    (bytevector->pointer output-names) 1 (bytevector->pointer outputs))
                   "Run")
    (let* ((out-value (make-pointer (bytevector-u64-native-ref outputs 0)))
           (data-out (make-bytevector 8 0))
           (_ (check-status! api ((ort-GetTensorMutableData api) out-value (bytevector->pointer data-out))
                             "GetTensorMutableData"))
           (data (pointer->bytevector (make-pointer (bytevector-u64-native-ref data-out 0)) (* n dim 4)))
           (mean (make-vector dim 0.0)))
      ;; mean-pool over the SEQ_LEN axis — every position weighted equally,
      ;; correct here because this module never pads (one sentence, one
      ;; sequence length, no attention_mask zero to exclude)
      (let loop-s ((s 0))
        (when (< s n)
          (let loop-d ((d 0))
            (when (< d dim)
              (vector-set! mean d (+ (vector-ref mean d)
                                     (/ (bytevector-ieee-single-native-ref data (* (+ (* s dim) d) 4)) n)))
              (loop-d (1+ d))))
          (loop-s (1+ s))))
      ;; ReleaseValue on the three inputs + the one output, per the C API's
      ;; own contract; the underlying token bytevectors are Scheme-GC'd
      ;; separately, since CreateTensorWithDataAsOrtValue never took
      ;; ownership of them
      (for-each (lambda (v) ((ort-ReleaseValue api) v)) (list t-ids t-mask t-type out-value))
      (let ((norm (sqrt (fold (lambda (x acc) (+ acc (* x x))) 0.0 (vector->list mean)))))
        (list->vector (map (lambda (x) (/ x norm)) (vector->list mean)))))))

(define (close-embedder embedder)
  "Release the session and environment. Not required before process exit —
   the OS reclaims everything — but correct to call in a long-lived
   process that loads and drops embedders more than once."
  (let ((api (embedder-api embedder)))
    ((ort-ReleaseSession api) (embedder-session embedder))
    ((ort-ReleaseEnv api) (embedder-env embedder))))

;; needed for `fold` above without pulling in all of srfi-1 at the top —
;; kept local and tiny rather than importing a module for one function
(define (fold f init lst)
  (if (null? lst) init (fold f (f (car lst) init) (cdr lst))))
