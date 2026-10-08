;;; deploy/guix/gnu/packages/playnet-keri.scm — the KERI / ACDC / Signify library and the
;;; First Person (OpenVTC) credentials over it, as a Guix package
;;;
;;;   guix shell guile guile-playnet-keri -- guile -c '(use-modules (playnet keri acdc))'
;;;
;;; This file serves two channels. The core is one (deploy/guix is its channel
;;; directory), and the published playnet-keri repository is the other
;;; (`tools/publish-keri-lib.sh` places this file at
;;; guix/gnu/packages/playnet-keri.scm there). The source is the channel's own checkout, so the package builds
;;; exactly the commit a channel pin names.
;;;
;;; The module sits in the (gnu packages) namespace, which is where `guix
;;; install`, `guix shell` and `guix build` look a package up by name.
;;;
;;; The modules are the set `tools/lint-keri-lib.scm --manifest` prints: the
;;; library layers plus their support modules. Native libraries (libsodium,
;;; libblake3) are propagated, so a profile holding this package finds them
;;; the way the modules look for them (GUIX_ENVIRONMENT, ~/.guix-profile).

(define-module (gnu packages playnet-keri)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix build-system guile)
  #:use-module (gnu packages)
  #:use-module (gnu packages guile)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (srfi srfi-1)
  #:export (guile-playnet-keri))

(define-syntax channel-root
  ;; The checkout this file sits in, found when the file is COMPILED: deploy/guix/
  ;; gnu/packages/ inside the core, guix/gnu/packages/ in playnet-keri. A channel
  ;; loads the compiled module from its own profile, where no source location
  ;; exists any more, so the path is a constant of the compiled code. The
  ;; library's modules are under module/ at the root.
  (lambda (x)
    (syntax-case x ()
      ((_)
       (let* ((file (assq-ref (syntax-source x) 'filename))
              (here (dirname (if (absolute-file-name? file)
                                 file
                                 (or (search-path %load-path file)
                                     (canonicalize-path file)))))
              (root (find (lambda (r) (file-exists? (string-append r "/module/playnet/keri")))
                          (list (string-append here "/../../../..")     ; core
                                (string-append here "/../../.."))))) ; playnet-keri
         (unless root (error "playnet-keri: no module/playnet/keri above" here))
         (datum->syntax x (canonicalize-path root)))))))

(define %channel-root (channel-root))

(define %library-paths
  ;; What the package takes from the checkout, relative to its root.
  '("module/playnet/keri" "module/playnet/openvtc"
    "module/playnet/utils/clock.scm" "module/playnet/utils/hex.scm"
    "module/playnet/utils/common.scm" "module/playnet/utils/said-store.scm"))

(define (library-file? file stat)
  "A directory on the way to a library path, or a file under one."
  (let ((rel (and (string-prefix? %channel-root file)
                  (string-drop file (min (string-length file)
                                         (+ 1 (string-length %channel-root)))))))
    (and rel
         (or (string-null? rel)
             (any (lambda (p)
                    (or (string=? rel p)
                        (string-prefix? (string-append p "/") rel)
                        (string-prefix? (string-append rel "/") p)))
                  %library-paths))
         (not (string-suffix? ".md" rel)))))

(define-public guile-playnet-keri
  (package
    (name "guile-playnet-keri")
    (version "0.1.0")
    (source (local-file %channel-root "guile-playnet-keri-checkout"
                        #:recursive? #t
                        #:select? library-file?))
    (build-system guile-build-system)
    (arguments
     (list #:source-directory "module"
           ;; the browser twin of crypto-primitives imports (hoot ffi), which
           ;; only Hoot's compiler provides; it ships as source
           #:not-compiled-file-regexp "crypto-primitives-browser\\.scm$"
           #:phases
           #~(modify-phases %standard-phases
               ;; Compiling a module loads the ones it imports, and blake3.scm
               ;; opens libblake3 at load: the build sees it through the loader path.
               (add-before 'build 'find-native-libraries
                 (lambda* (#:key inputs #:allow-other-keys)
                   (setenv "LD_LIBRARY_PATH"
                           (string-join
                            (map (lambda (n) (string-append (assoc-ref inputs n) "/lib"))
                                 '("libsodium" "libblake3"))
                            ":")))))))
    (inputs
     (list (specification->package "libsodium")
           (specification->package "libblake3")))
    (propagated-inputs
     (list (specification->package "guile-goblins")
           (specification->package "guile-fibers")
           (specification->package "guile-gcrypt")
           (specification->package "guile-json")
           (specification->package "guile-gnutls")
           (specification->package "libsodium")
           (specification->package "libblake3")))
    (native-inputs (list guile-3.0))
    (home-page "https://playnet.earth/z3qCP3JyrjAMMXTd2Zq7EFyaNWMTN.git")
    (synopsis "KERI, ACDC and Signify in Guile, with the OpenVTC credentials over them")
    (description
     "Self-addressing identifiers, key event logs, ACDC credentials, a
Signify client and the First Person (PHC/VRC) credential layer, as Guile
modules under (playnet keri …) and (playnet openvtc …).  The library computes
its identifiers standalone: Blake3-256 through libblake3, Ed25519 and X25519
through libsodium.")
    (license license:agpl3+)))
