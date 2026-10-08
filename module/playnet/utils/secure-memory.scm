;;; module/playnet/utils/secure-memory.scm — mlock + secure-zero for secrets
;;;
;;; Guile has no built-in mlock/mprotect. This module wraps libc's
;;; mlock()/munlock() via (system foreign) FFI, and provides a
;;; secure-zero! function that overwrites a bytevector before freeing
;;; it. Together these prevent secrets (wallet passwords, RPC tokens,
;;; signing keys) from being paged to swap.
;;;
;;; Usage:
;;;
;;;   (use-modules (playnet utils secure-memory))
;;;
;;;   ;; Read a password, lock it in memory, use it, zero+unlock
;;;   (define pw-bv (string->utf8 (read-password-from-file path)))
;;;   (secure-lock! pw-bv)
;;;   ;; ... use pw-bv for auth ...
;;;   (secure-unlock+zero! pw-bv)
;;;
;;; On failure (e.g., RLIMIT_MEMLOCK exceeded), the functions log a
;;; warning but do NOT throw — degraded security is better than a
;;; crash that leaves the password in an inconsistent state.
;;;
;;; Defense-in-depth: LUKS full-disk encryption means swap IS encrypted
;;; at rest, so mlock is a second layer. The primary threat mlock
;;; addresses is a core dump or /proc/pid/mem read on a running process.

(define-module (playnet utils secure-memory)
  #:use-module (system foreign)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 format)
  #:use-module (ice-9 threads)
  #:export (secure-lock!
            secure-zero!
            secure-unlock+zero!
            with-secure-bytevector
            split-secret
            unsplit-secret
            with-split-secret
            make-suspend-watchdog
            suspend-watchdog-stop!))

;;; ── libc FFI bindings ────────────────────────────────────────────────

(define %libc (dynamic-link))

(define %mlock
  (pointer->procedure int
    (dynamic-func "mlock" %libc)
    (list '* size_t)))

(define %munlock
  (pointer->procedure int
    (dynamic-func "munlock" %libc)
    (list '* size_t)))

;;; ── Public API ───────────────────────────────────────────────────────

(define (secure-lock! bv)
  "Lock the memory pages containing BV so they cannot be swapped to disk.
Returns #t on success, #f on failure (logs a warning but does not throw)."
  (let ((ptr (bytevector->pointer bv))
        (len (bytevector-length bv)))
    (if (zero? (%mlock ptr len))
        #t
        (begin
          (format (current-error-port)
                  "[secure-memory] mlock failed for ~a bytes (RLIMIT_MEMLOCK?)~%"
                  len)
          #f))))

(define (secure-zero! bv)
  "Overwrite BV with zeros. Uses bytevector-fill! which the compiler
should not optimize away (Guile does not do dead-store elimination
on bytevectors). Call before releasing memory containing secrets."
  (bytevector-fill! bv 0))

(define (secure-unlock+zero! bv)
  "Zero the bytevector contents, then unlock the memory pages.
Always zeros first — even if munlock fails, the secret is gone."
  (secure-zero! bv)
  (let ((ptr (bytevector->pointer bv))
        (len (bytevector-length bv)))
    (%munlock ptr len)))

(define (with-secure-bytevector bv thunk)
  "Lock BV in memory, call THUNK, then zero + unlock regardless of
whether THUNK succeeds or throws. Ensures secrets are wiped even
on error paths."
  (secure-lock! bv)
  (dynamic-wind
    (lambda () #f)
    thunk
    (lambda () (secure-unlock+zero! bv))))

;;; ── Secret splitting (XOR masking) ──────────────────────────────────
;;;
;;; Defense against hypervisor memory snapshots. Instead of storing a
;;; secret as a single contiguous bytevector, split it into two random
;;; shares: mask and share, where mask ⊕ share = secret. The actual
;;; secret exists in memory ONLY during the microseconds when
;;; unsplit-secret runs — otherwise only random-looking blobs exist.
;;;
;;; A memory dump captures two random bytevectors that an attacker
;;; can't identify as password halves (among all the GC heap noise).
;;; Even if they find both, they don't know which blobs go together.
;;;
;;; Usage:
;;;   (define-values (mask share) (split-secret (string->utf8 "password")))
;;;   ;; "password" no longer exists in memory — only mask and share
;;;   ;; Both are mlock'd
;;;   ;;
;;;   ;; When you need the secret briefly:
;;;   (let ((pw (unsplit-secret mask share)))
;;;     (do-auth-with pw)
;;;     (secure-zero! pw))

(define (split-secret bv)
  "Split BV into two XOR shares. The original BV is zeroed. Both
shares are mlock'd. Returns (values mask share)."
  (let* ((len (bytevector-length bv))
         (mask (make-bytevector len))
         (share (make-bytevector len)))
    ;; Fill mask with cryptographic random bytes
    (let ((port (open-file "/dev/urandom" "rb")))
      (let loop ((i 0))
        (when (< i len)
          (bytevector-u8-set! mask i (get-u8 port))
          (loop (+ i 1))))
      (close-port port))
    ;; share = secret XOR mask
    (let loop ((i 0))
      (when (< i len)
        (bytevector-u8-set! share i
          (logxor (bytevector-u8-ref bv i)
                  (bytevector-u8-ref mask i)))
        (loop (+ i 1))))
    ;; Zero the original — it no longer exists
    (secure-zero! bv)
    ;; Lock both shares in physical RAM
    (secure-lock! mask)
    (secure-lock! share)
    (values mask share)))

(define (unsplit-secret mask share)
  "Recover the secret from two XOR shares. Returns a NEW bytevector
containing the secret. Caller MUST secure-zero! it after use.
The shares remain valid for future unsplit calls."
  (let* ((len (bytevector-length mask))
         (result (make-bytevector len)))
    (let loop ((i 0))
      (when (< i len)
        (bytevector-u8-set! result i
          (logxor (bytevector-u8-ref mask i)
                  (bytevector-u8-ref share i)))
        (loop (+ i 1))))
    result))

(define (with-split-secret mask share thunk)
  "Recover the secret, call (THUNK secret-bv), then zero the secret.
The secret exists in memory only during THUNK's execution."
  (let ((secret (unsplit-secret mask share)))
    (secure-lock! secret)
    (dynamic-wind
      (lambda () #f)
      (lambda () (thunk secret))
      (lambda () (secure-unlock+zero! secret)))))

;;; ── VM suspend detection (monotonic clock watchdog) ─────────────────
;;;
;;; A hypervisor suspend/snapshot freezes the VM. When it resumes, the
;;; monotonic clock jumps forward. A background thread polls
;;; CLOCK_MONOTONIC every INTERVAL seconds. If the observed delta
;;; exceeds THRESHOLD (default: 3× interval), a suspend is assumed.
;;;
;;; On detection the watchdog calls PANIC-FN — typically a procedure
;;; that zeros all secret material and halts the wallet service.
;;; The attacker has the snapshot, but the LIVE process is now clean.
;;;
;;; Usage:
;;;   (define wd (make-suspend-watchdog
;;;                #:interval 1
;;;                #:threshold 5
;;;                #:on-suspend (lambda (gap)
;;;                               (zero-all-secrets!)
;;;                               (format #t "SUSPEND DETECTED: ~as gap~%" gap))))
;;;   ;; ... later ...
;;;   (suspend-watchdog-stop! wd)

(define CLOCK_MONOTONIC 1)

(define %clock-gettime
  (pointer->procedure int
    (dynamic-func "clock_gettime" %libc)
    (list int '*)))

(define (monotonic-seconds)
  "Return CLOCK_MONOTONIC time as an inexact real (seconds + nanoseconds)."
  (let ((buf (make-bytevector 16 0)))
    (%clock-gettime CLOCK_MONOTONIC (bytevector->pointer buf))
    (+ (bytevector-sint-ref buf 0 (native-endianness) 8)
       (/ (bytevector-sint-ref buf 8 (native-endianness) 8)
          1e9))))

(define* (make-suspend-watchdog #:key
           (interval 1)
           (threshold 5)
           (on-suspend (lambda (gap)
                         (format (current-error-port)
                                 "[secure-memory] VM SUSPEND DETECTED: ~,1fs gap~%"
                                 gap))))
  "Start a background thread that detects VM suspend/resume by monitoring
CLOCK_MONOTONIC. Returns a watchdog record (pass to suspend-watchdog-stop!).

INTERVAL: seconds between polls (default 1).
THRESHOLD: max acceptable gap in seconds (default 5). If the monotonic
  clock jumps by more than this between polls, ON-SUSPEND is called.
ON-SUSPEND: (lambda (gap-seconds)) — called once per detected suspend."
  (let ((running (make-mutex))
        (stop?   #f))
    (define thread
      (call-with-new-thread
       (lambda ()
         (let loop ((prev (monotonic-seconds)))
           (sleep interval)
           (let* ((now  (monotonic-seconds))
                  (gap  (- now prev)))
             (when (> gap threshold)
               (on-suspend gap))
             (unless stop?
               (loop now)))))))
    (list thread (lambda () (set! stop? #t)))))

(define (suspend-watchdog-stop! wd)
  "Stop a suspend watchdog. The background thread exits after its
current sleep cycle."
  ((cadr wd)))
