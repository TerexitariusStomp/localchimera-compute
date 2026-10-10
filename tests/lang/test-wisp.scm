;;; test-wisp.scm — Tests for wisp transpiler

(add-to-load-path (string-append (dirname (current-filename)) "/../module"))

(use-modules (playnet lang wisp))

(define pass 0)
(define fail 0)

(define (assert-equal name expected actual)
  (if (equal? expected actual)
      (begin
        (set! pass (+ pass 1))
        (format #t "  PASS: ~a\n" name))
      (begin
        (set! fail (+ fail 1))
        (format #t "  FAIL: ~a\n    expected: ~s\n    actual:   ~s\n" name expected actual))))

;;; ── wisp->sexp-string tests ──────────────────────────────────────────────

(format #t "\n=== wisp->sexp-string ===\n")

(assert-equal "empty string"
  ""
  (wisp->sexp-string ""))

(assert-equal "blank string"
  ""
  (wisp->sexp-string "   "))

(assert-equal "passthrough: already parenthesized"
  "(define x 5)"
  (wisp->sexp-string "(define x 5)"))

(assert-equal "passthrough: multiple sexp"
  "(define x 5)\n(display x)"
  (wisp->sexp-string "(define x 5)\n(display x)"))

(assert-equal "single line"
  "(define x 5)"
  (wisp->sexp-string "define x 5"))

(assert-equal "two top-level expressions"
  "(define x 5) (display x)"
  (wisp->sexp-string "define x 5\ndisplay x"))

(assert-equal "two expressions separated by blank line"
  "(define x 5)\n(display x)"
  (wisp->sexp-string "define x 5\n\ndisplay x"))

(assert-equal "simple nesting"
  "(define (greet name) (string-append \"Hello \" name \"!\"))"
  (wisp->sexp-string "define (greet name)\n  string-append \"Hello \" name \"!\""))

(assert-equal "deep nesting"
  "(define (add-drawing p f) (define drawer (make-pict-drawer p)) (new canvas% (parent f)))"
  (wisp->sexp-string
   (string-append "define (add-drawing p f)\n"
                  "  define drawer\n"
                  "    make-pict-drawer p\n"
                  "  new canvas%\n"
                  "    parent f")))

(assert-equal "dot continuation"
  "(render-to-file \"cool-cat.png\" (make-cat-drawing #:happy? #t #:size 100))"
  (wisp->sexp-string
   (string-append "render-to-file\n"
                  "  . \"cool-cat.png\"\n"
                  "  make-cat-drawing\n"
                  "    . #:happy? #t\n"
                  "    . #:size 100")))

(assert-equal "colon expansion"
  "(define name (input \"Name:\"))"
  (wisp->sexp-string "define name : input \"Name:\""))

(assert-equal "nested colon expansion"
  "(define name (input (string-append \"What is \" \"Name?\")))"
  (wisp->sexp-string "define name : input : string-append \"What is \" \"Name?\""))

(assert-equal "comment passthrough"
  ";;; bindings\n(modify! 'x 5)"
  (wisp->sexp-string ";;; bindings\nmodify! 'x 5"))

(assert-equal "parenthesized line in wisp"
  "(new canvas% (parent f) (style '(border)))"
  (wisp->sexp-string
   (string-append "new canvas%\n"
                  "  parent f\n"
                  "  (style '(border))")))

(assert-equal "full heart.md example"
  (string-append "(define (add-drawing p f) (define drawer (make-pict-drawer p))"
                 " (new canvas% (parent f) (style '(border))"
                 " (paint-callback (lambda (self dc) (drawer dc 0 0)))))")
  (wisp->sexp-string
   (string-append "define (add-drawing p f)\n"
                  "  define drawer\n"
                  "    make-pict-drawer p\n"
                  "  new canvas%\n"
                  "    parent f\n"
                  "    style '(border)\n"
                  "    paint-callback\n"
                  "      lambda (self dc)\n"
                  "        drawer dc 0 0")))

;;; ── sexp->wisp-string tests ──────────────────────────────────────────────

(format #t "\n=== sexp->wisp-string ===\n")

(assert-equal "empty string"
  ""
  (sexp->wisp-string ""))

(assert-equal "simple expression"
  "modify! 'x 5"
  (sexp->wisp-string "(modify! 'x 5)"))

(assert-equal "nested expression"
  "enact! (lambda (e n v pre post) #t)"
  (sexp->wisp-string "(enact! (lambda (e n v pre post) #t))"))

(assert-equal "comment lines preserved"
  ";;; bindings\nmodify! 'x 5\n"
  (sexp->wisp-string ";;; bindings\n(modify! 'x 5)\n"))

(assert-equal "blank lines preserved"
  ";;; bindings\nmodify! 'x 5\n\n;;; validator\n"
  (sexp->wisp-string ";;; bindings\n(modify! 'x 5)\n\n;;; validator\n"))

(assert-equal "comment-only line"
  ";; alice"
  (sexp->wisp-string ";; alice"))

(assert-equal "history comment preserved"
  ";; v1 [alice] (modify! 'x 5)"
  (sexp->wisp-string ";; v1 [alice] (modify! 'x 5)"))

;;; ── Round-trip tests ─────────────────────────────────────────────────────

(format #t "\n=== Round-trip (wisp->sexp is readable) ===\n")

(assert-equal "round-trip: simple"
  5
  (let* ((wisp "define x 5")
         (sexp (wisp->sexp-string wisp))
         (parsed (read (open-input-string sexp))))
    (caddr parsed)))

(assert-equal "round-trip: nested"
  '(string-append "Hello " name "!")
  (let* ((wisp "define (greet name)\n  string-append \"Hello \" name \"!\"")
         (sexp (wisp->sexp-string wisp))
         (parsed (read (open-input-string sexp))))
    (caddr parsed)))

;;; ── Summary ──────────────────────────────────────────────────────────────

(format #t "\n~a passed, ~a failed\n\n" pass fail)
(when (> fail 0)
  (exit 1))
