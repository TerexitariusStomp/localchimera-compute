;;; emit-law-snapshot.scm — run the REAL legal fold over the free-food
;;; federation and emit browser/data/snapshots/law-snapshot.json (the law-face fallback).
;;;
;;; What the browser shows is the OUTPUT of this fold over the real rule
;;; library — not invented. The live planner-service regenerates the same
;;; shape on demand; this committed file is the offline fallback.
;;;
;;;   guile -L module tools/emit-law-snapshot.scm [OUT]      (make law-snapshot)
;;;
;;; `make check-law-fresh` regenerates it and refuses a stale committed copy.
;;;
;;; (bare guile — legal/registry.scm needs only srfi-1/13 + ice-9 format.)

(add-to-load-path (dirname (dirname (current-filename))))

(define here (dirname (current-filename)))
(define root (dirname here))
(define (rel p) (string-append root "/" p))

(use-modules (playnet vf schemas))                                  ; VF records (ProcessSpec/RecipeProcess/Recipe) for legal-aspects
(use-modules (playnet legal registry))
(use-modules (playnet legal crossings))                               ; the OPEN crossing catalogue
(use-modules (playnet vf facts places))                        ; the ONE containment tree
(use-modules (playnet knowledge law context-pack))        ; a jurisdiction = one drop-in file
(use-modules (playnet knowledge catalogues us-states-fips))
(use-modules (playnet legal reform))                                  ; (L,I,D) diff + its move
(use-modules (playnet knowledge law aspects))                ; aspects as ProcessSpecs + recipe-aspects (grounds L,I,D)
(use-modules (playnet knowledge worlds free-food-distribution))
(use-modules (playnet knowledge law activities))
(use-modules (playnet knowledge law reform-mirrors))     ; the I/D mirrors
(use-modules (playnet knowledge law structural-demands)) ; the abolitions (deep program)
(use-modules (playnet knowledge law snapshot-build))  ; the shared builder

(use-modules (ice-9 format))
(define out (if (> (length (command-line)) 1)
                (cadr (command-line))
                (rel "browser/data/snapshots/law-snapshot.json")))
(call-with-output-file out
  (lambda (port)
    (set-port-encoding! port "UTF-8")          ; statutes carry § — keep UTF-8
    (display (law-snapshot-string) port) (newline port)))
(format #t "wrote ~a (shared builder)~%" out)
