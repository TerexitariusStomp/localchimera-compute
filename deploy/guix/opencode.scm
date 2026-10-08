;;; deploy/guix/opencode.scm — the opencode agentic coding CLI, as a pinned
;;; prebuilt binary package.
;;;
;;; Why prebuilt: opencode is a Bun-compiled TypeScript application — building
;;; it from source needs Bun and the full npm dependency graph, neither of
;;; which Guix carries. The reproducibility here is the same contract
;;; radicle-httpd-service.scm's package already establishes in this channel:
;;; the exact upstream release artifact, pinned by content hash, so every
;;; machine that builds this package gets bit-identical inputs and a
;;; deterministic wrapper around the one binary inside.
;;;
;;; The binary links ONLY glibc-family libraries (libc, libm, libpthread,
;;; libdl — verified with ldd on the 1.18.15 release). It CANNOT be
;;; patchelf'd: Bun-compiled executables carry their JavaScript bundle
;;; appended to the ELF image, and patchelf's rewrite corrupts that
;;; self-lookup — the patched binary segfaults on the spot (verified).
;;; Instead the pristine binary is kept in libexec/ and bin/opencode is a
;;; two-line wrapper that execs it THROUGH Guix's glibc loader
;;; (ld-linux-x86-64.so.2 <binary> …), which runs unmodified foreign
;;; binaries and needs no rpath — the Guix loader's default search already
;;; covers its own glibc, and glibc-family libs are all this binary wants.
;;; Verified locally: the loader-invoked binary prints its version and runs.
;;; (The upstream musl variant is NOT static either — it wants
;;; /lib/ld-musl-x86_64.so.1 — so it buys nothing over this.)
;;;
;;; server/dev-bridge.scm launches this via AGENT_CLI=opencode; the model
;;; backend (e.g. a TEE-attested nano-gpt endpoint) is opencode's own
;;; provider configuration, not this package's concern.

(define-module (opencode)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix build-system trivial)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages base)                ;glibc, tar
  #:use-module (gnu packages bash)                ;bash-minimal (wrapper shebang)
  #:use-module (gnu packages compression)        ;gzip (for tar xzf)
  #:export (opencode))

(define-public opencode
  (package
    (name "opencode")
    (version "1.18.15")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/sst/opencode/releases/download/v" version
             "/opencode-linux-x64.tar.gz"))
       (file-name (string-append name "-" version ".tar.gz"))
       (sha256
        (base32 "071v57q96kvgwm0n1fmjjvdn96q0541nzp5ph6j75ii2qvlf0hnq"))))
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (setenv "PATH" (string-append #+(@ (gnu packages base) tar) "/bin:"
                                        #+gzip "/bin"))
          (invoke "tar" "xzf" #$source)
          (let* ((libexec (string-append #$output "/libexec"))
                 (bin     (string-append #$output "/bin"))
                 (real    (string-append libexec "/opencode"))
                 (loader  (string-append #+(@ (gnu packages base) glibc)
                                         "/lib/ld-linux-x86-64.so.2")))
            (install-file "opencode" libexec)
            (chmod real #o755)
            (mkdir-p bin)
            (call-with-output-file (string-append bin "/opencode")
              (lambda (port)
                (format port "#!~a/bin/sh~%exec ~a ~a \"$@\"~%"
                        #+bash-minimal loader real)))
            (chmod (string-append bin "/opencode") #o755))
          #t)))
    (home-page "https://opencode.ai/")
    (synopsis "Agentic coding CLI (prebuilt release binary, pinned by hash)")
    (description
     "@command{opencode} is an open-source agentic coding assistant CLI that
drives an LLM through an edit/run/test loop over a working directory, with the
model backend chosen by its own provider configuration (any OpenAI-compatible
endpoint, including self-hosted or TEE-attested ones).  This package installs
the upstream release binary for the pinned version, run through Guix's glibc
loader by a wrapper — see the module header for why a source build (and a
patchelf) are both out of reach.")
    (license license:expat)))
