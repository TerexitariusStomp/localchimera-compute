(use-modules (guix packages)
             (guix gexp)
             (guix build-system copy)
             (gnu packages base)
             (gnu packages guile)
             (gnu packages guile-xyz)
             (gnu packages tls)
             (gnu packages gnupg)
             (gnu packages crypto)
             ((guix licenses) #:prefix license:))

(package
  (name "playnet")
  (version "0.1.0-HEAD")
  (source (local-file "." "playnet-checkout"
                      #:recursive? #t
                      #:select? (lambda (file stat)
                                  ;; Exclude .git, node_modules, etc.
                                  (not (or (string-suffix? "/.git" file)
                                           (string-contains file "/.git/")
                                           (string-suffix? "/node_modules" file)
                                           (string-contains file "/node_modules/"))))))
  (build-system copy-build-system)
  (arguments
   (list #:install-plan
          #~'(("module" "share/playnet/module")
              ("server" "share/playnet/server")
              ("deploy" "share/playnet/deploy")
              ("browser" "share/playnet/browser")
              ("tests" "share/playnet/tests")
              ("docs" "share/playnet/docs")
              ("tools" "share/playnet/tools")
              ("Makefile" "share/playnet/Makefile"))
         #:phases
         #~(modify-phases %standard-phases
             (add-before 'install 'check
               (lambda* (#:key inputs #:allow-other-keys)
                 (let ((guile (search-input-file inputs "bin/guile")))
                   ;; Knowledge tests (kanren, knowledge, system-kb)
                   (invoke guile "--no-auto-compile" "-q"
                           "-L" "module"
                           "tests/lang/test-knowledge.scm")
                   ;; Relational planner tests (imports (playnet deprecated planner))
                   (invoke guile "--no-auto-compile" "-q"
                           "-L" "module"
                           "tests/deprecated/relational-planner.scm"))))
             (add-after 'install 'create-wrappers
               (lambda* (#:key inputs outputs #:allow-other-keys)
                 ;; Generate self-contained launchers under $out/bin.
                 ;; Each wrapper bakes in GUILE_LOAD_PATH for every input
                 ;; that ships Guile modules, so the wrappers work in
                 ;; `guix pack`, in a bare `guix install`, and inside
                 ;; Docker — no outer `guix shell` env required.
                 (let* ((out         (assoc-ref outputs "out"))
                        (bin         (string-append out "/bin"))
                        (base        (string-append out "/share/playnet"))
                        (guile-bin   (search-input-file inputs "bin/guile"))
                        ;; Auto-discover Guile-bearing inputs: any input
                        ;; whose store path has share/guile/site/3.0
                        ;; contributes its modules. Add new runtime deps
                        ;; to (inputs ...) and they'll be picked up here
                        ;; automatically — no list to keep in sync.
                        (dep-paths
                         (let loop ((ins (map cdr inputs)) (acc '()))
                           (cond ((null? ins) (reverse acc))
                                 ((file-exists?
                                   (string-append (car ins)
                                                  "/share/guile/site/3.0"))
                                  (loop (cdr ins) (cons (car ins) acc)))
                                 (else (loop (cdr ins) acc)))))
                        (subdirs
                         (lambda (suffix)
                           (string-join
                            (map (lambda (p) (string-append p suffix))
                                 dep-paths)
                            ":")))
                        (site-dirs   (subdirs "/share/guile/site/3.0"))
                        (ccache-dirs (subdirs "/lib/guile/3.0/site-ccache"))
                        ;; Every input's lib/ dir on LD_LIBRARY_PATH so
                        ;; FFI dlopen() of basenames (e.g. libsodium.so)
                        ;; resolves. Harmless for inputs whose lib/ only
                        ;; contains Guile artifacts.
                        (lib-dirs
                         (string-join
                          (map (lambda (p) (string-append p "/lib"))
                               (let loop ((ins (map cdr inputs)) (acc '()))
                                 (cond ((null? ins) (reverse acc))
                                       ((file-exists?
                                         (string-append (car ins) "/lib"))
                                        (loop (cdr ins)
                                              (cons (car ins) acc)))
                                       (else (loop (cdr ins) acc)))))
                          ":"))
                        (env-prelude
                         (string-append
                          "export GUILE_LOAD_PATH=\""
                          base "/module:" site-dirs
                          "${GUILE_LOAD_PATH:+:$GUILE_LOAD_PATH}\"\n"
                          "export GUILE_LOAD_COMPILED_PATH=\""
                          ccache-dirs
                          "${GUILE_LOAD_COMPILED_PATH:+:$GUILE_LOAD_COMPILED_PATH}\"\n"
                          "export LD_LIBRARY_PATH=\""
                          lib-dirs
                          "${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\"\n"))
                        (write-wrapper
                         (lambda (name body)
                           ;; body: post-env-prelude shell text, including
                           ;; the final `exec <guile> ...`.
                           (let ((path (string-append bin "/" name)))
                             (with-output-to-file path
                               (lambda ()
                                 (display (string-append
                                           "#!/bin/sh\n"
                                           env-prelude
                                           body))))
                             (chmod path #o555)))))
                   (mkdir-p bin)
                   (write-wrapper
                    "playnet-repl"
                    (string-append "exec " guile-bin " "
                                   base "/server/repl.scm \"$@\"\n"))
                   (write-wrapper
                    "playnet-planner"
                    (string-append "exec " guile-bin
                                   " --no-auto-compile"
                                   " -c '(use-modules (playnet boot prelude))"
                                   " ((@ (system repl repl) start-repl))'"
                                   " \"$@\"\n"))
                   ;; Gateway: `cd $base` so terminal.scm's relative
                   ;; `primitive-load \"deploy/guix/users.scm\"` resolves;
                   ;; also expose `$base/deploy` on the load path.
                    (write-wrapper
                     "playnet-gateway"
                     (string-append "cd " base "\n"
                                    "export GUILE_LOAD_PATH=\""
                                    base "/deploy:$GUILE_LOAD_PATH\"\n"
                                    "exec " guile-bin " "
                                    base "/server/gateway.scm \"$@\"\n"))
                    (write-wrapper
                     "sms-verify"
                     (string-append "exec " guile-bin " --no-auto-compile -L "
                                    base "/module "
                                    base "/tools/dev/sms-verify.scm \"$@\"\n"))))))))
  (inputs (list guile-next guile-hoot gnu-make guile-json-4 guile-goblins
                guile-fibers guile-gnutls guile-websocket guile-gcrypt
                ;; Native shared libs the Guile FFI dlopens by basename.
                libsodium))
  (home-page "https://app.radicle.xyz/nodes/seed.radicle.garden/rad:z27dFkN28LQAsSsG3DVHcfBqYAArQ")
  (synopsis "Communal computer — relational planning over capability-secure actors")
  (description
   "Playnet is a commons computer built on Spritely Goblins.  It provides
relational economic planning (miniKanren over ValueFlows), capability-secure
governance (actors, facets, revocation), and mesh networking (Reticulum).
Facts are plain S-expression tuples queried via unification.  Every
allocation is reversible, every inference is traceable, every capability
is unforgeable.")
  (license license:agpl3))
