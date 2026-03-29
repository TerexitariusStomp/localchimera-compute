(use-modules (guix packages)
             (guix gexp)
             (guix build-system copy)
             (gnu packages base)
             (gnu packages guile)
             (gnu packages guile-xyz)
             ((guix licenses) #:prefix license:))

(package
  (name "meta-org")
  (version "0.1.0-HEAD")
  (source (local-file "." "meta-org-checkout" #:recursive? #t))
  (build-system copy-build-system)
  (arguments
   (list #:install-plan
         #~'(("module" "share/meta-org/module")
             ("server" "share/meta-org/server")
             ("browser" "share/meta-org/browser")
             ("docs" "share/meta-org/docs")
             ("Makefile" "share/meta-org/Makefile"))
         #:phases
         #~(modify-phases %standard-phases
             (add-after 'install 'create-wrapper
               (lambda* (#:key inputs outputs #:allow-other-keys)
                 (let* ((out (assoc-ref outputs "out"))
                        (bin (string-append out "/bin"))
                        (wrapper (string-append bin "/meta-org-repl"))
                        (guile-bin (search-input-file inputs "bin/guile")))
                   (mkdir-p bin)
                   (with-output-to-file wrapper
                     (lambda ()
                       (display
                        (string-append "#!/bin/sh\nexec " guile-bin " \\\n  -L " out "/share/meta-org/module \\\n  " out "/share/meta-org/server/repl.scm \"$@\"\n"))))
                   (chmod wrapper #o555)))))))
  (inputs (list guile-next guile-hoot gnu-make guile-json-4 guile-goblins))
  (home-page "https://github.com/interplaynetary/meta-org")
  (synopsis "meta-org desktop REPL")
  (description "A bundled release of the meta-org terminal REPL.")
  (license license:agpl3))
