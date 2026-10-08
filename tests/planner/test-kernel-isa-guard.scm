;;; test-kernel-isa-guard.scm — the compiled kernel says which cpu it needs, and
;;; the loader believes it.
;;;
;;; kernel.c is built -march=native, so the object is tuned to whichever machine
;;; compiled it. Loading it elsewhere is fine — dlopen executes nothing — and
;;; then the first solve dies on an illegal instruction: SIGILL, no message, no
;;; backtrace through the FFI, nothing naming a copied .so as the cause.
;;;
;;; So the object exports `pk_required_isa`, a string constant naming the
;;; extensions -march enabled, and the loader compares it against /proc/cpuinfo
;;; before offering the backend.
;;;
;;; WHY THIS TEST EXISTS RATHER THAN A GREEN RUN ON A GOOD MACHINE. The first
;;; version of the guard read the cpu's flags with `read-line`, which lives in
;;; (ice-9 rdelim) and is not imported by solver.scm. Inside false-if-exception
;;; the unbound variable became #f, #f meant "cannot tell", and "cannot tell"
;;; was treated as "nothing to object to" — so the guard reported a kernel
;;; requiring AVX-512 as perfectly runnable on a machine with no AVX-512 at all.
;;; It passed every test that only ever showed it a correct object. A check
;;; whose failure mode is silent approval has to be shown a WRONG one, which is
;;; what the negative control below does.
;;;
;;; Run from repo root:
;;;   guile --no-auto-compile -q -L module tests/planner/test-kernel-isa-guard.scm

(use-modules (playnet test planner prelude)
             (playnet planner solve solver)
             (srfi srfi-1)
             (ice-9 format)
             (system foreign))

;;; ── the cpu can be read at all ──────────────────────────────────────────────
;;; On Linux this must answer. If it ever returns #f here the guard has gone
;;; blind again, and blind means permissive.
(define flags (%cpu-flags))

(check "the running cpu's feature flags are legible"
            (and (list? flags) (pair? flags)))
(check "…and they are the flags of a real x86-64 (fpu among them)"
            (and (member "fpu" flags) #t))

;;; ── the object declares itself ──────────────────────────────────────────────
;;; Absent the symbol the kernel predates the guard: nothing claimed, nothing
;;; refused. Present, it must be a string — possibly empty, which is what an
;;; `agnostic` or `portable` build honestly requires.
(define declared
  (and *kern-lib*
       (false-if-exception
        (pointer->string (dynamic-pointer "pk_required_isa" *kern-lib*)))))

(when *kern-lib*
  (format #t "  pk_required_isa = ~s~%" declared)
  (format #t "  cpu reports ~a flags; missing from this build: ~a~%"
          (length flags) *kern-isa-missing*))

(check "the kernel in this checkout declares an ISA requirement"
            (or (not *kern-lib*) (string? declared)))

;;; ── and it is satisfied, here, now ──────────────────────────────────────────
;;; The kernel this suite is about to solve with must be one this machine can
;;; execute. If this fails the backend is unavailable and says why, which is the
;;; whole point — but it means the .so was built somewhere else.
(check "…and this machine satisfies it, so the backend is on offer"
            (or (not *kern-lib*) (kern-available?)))

;;; ── NEGATIVE CONTROL: show it something it must refuse ──────────────────────
;;; The rule is exercised against a requirement no cpu can meet. A guard that
;;; cannot be made to fire is not passing, it is absent — and this one silently
;;; approved an AVX-512 object on a machine without AVX-512 until it was shown a
;;; wrong one.
;;;
;;; The comparison is re-derived here rather than mocked, because what is being
;;; tested is the comparison: a fabricated requirement against the real cpu.
(define (missing-against requirement)
  (let loop ((r (string-tokenize requirement)) (miss '()))
    (cond ((null? r) (reverse miss))
          ((member (car r) flags) (loop (cdr r) miss))
          (else (loop (cdr r) (cons (car r) miss))))))

(check "a requirement no cpu satisfies is reported as missing"
            (equal? '("nosuchisa") (missing-against "nosuchisa")))
(check "…and a mixed requirement keeps only the part that is absent"
            (equal? '("nosuchisa") (missing-against "fpu nosuchisa")))
(check "…while a requirement the cpu meets is empty"
            (null? (missing-against "fpu")))

;;; and the refusal is a sentence someone can act on — naming the feature that
;;; is missing and the two builds that fix it, rather than "unavailable". Read
;;; as a pure function of the missing list, because a healthy machine satisfies
;;; its own kernel and would otherwise never see this text at all.
(define refusal (kern-isa-refusal '("avx512f")))
(check "the refusal names the feature the object needed"
       (and (string-contains refusal "avx512f") #t))
(check "…and points at a rebuild"
       (and (string-contains refusal "clean all") #t))
(check "…and at the build that runs anywhere"
       (and (string-contains refusal "agnostic") #t))

(check-done)
