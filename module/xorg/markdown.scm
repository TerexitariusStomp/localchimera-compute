;;; markdown.scm — Bidirectional markdown ↔ S-expression transpilation
;;; Uses miniKanren relations: the same relation parses AND renders.
;;; Hoot/WASM compatible.
;;;
;;; Usage:
;;;   (use-modules (xorg markdown) (xorg kanren))
;;;
;;;   ;; Render S-expression → markdown string
;;;   (run* (md) (markdown-o '((heading 1 "Title") (paragraph "Hello.")) md))
;;;
;;;   ;; Parse markdown string → S-expression AST (limited — line-level)
;;;   (sexp->markdown '((heading 1 "Title") (paragraph "Hello.")))
;;;   ;; => "# Title\n\nHello.\n"
;;;
;;; The miniKanren relation markdown-element-o is bidirectional for structured
;;; elements. The pure Scheme functions sexp->markdown and markdown->sexp
;;; handle the full rendering/parsing for practical use.

(define-module (xorg markdown)
  #:use-module (xorg kanren)
  #:use-module (srfi srfi-1)
  #:export (;; S-expression AST constructors
            heading paragraph bullet code-inline code-block
            table-row table link bold italic
            horizontal-rule
            ;; Bidirectional miniKanren relations
            markdown-element-o
            heading-o paragraph-o bullet-o
            code-block-o link-o bold-o
            ;; Pure Scheme renderers (practical use)
            sexp->markdown
            markdown->sexp
            render-element
            ;; Skill ↔ KB bridge
            skill->facts
            facts->skill-section))

;;; ── AST constructors ──────────────────────────────────────────────────────
;;; Tagged lists. Plain symbols, no keywords. Unifiable by miniKanren.

(define (heading level text)       `(heading ,level ,text))
(define (paragraph text)           `(paragraph ,text))
(define (bullet text)              `(bullet ,text))
(define (code-inline text)         `(code-inline ,text))
(define (code-block lang text)     `(code-block ,lang ,text))
(define (table-row cells)          `(table-row ,cells))
(define (table rows)               `(table ,rows))
(define (link text url)            `(link ,text ,url))
(define (bold text)                `(bold ,text))
(define (italic text)              `(italic ,text))
(define (horizontal-rule)          '(hr))

;;; ── miniKanren relations ──────────────────────────────────────────────────
;;; Bidirectional: bind either side and the other is computed.

(define (heading-o level text md)
  "Relate heading components to markdown string.
   Structural: unifies elem ↔ (heading level text) ↔ markdown prefix+text."
  (conde
   ((== level 1) (== md `(md-heading 1 ,text)))
   ((== level 2) (== md `(md-heading 2 ,text)))
   ((== level 3) (== md `(md-heading 3 ,text)))
   ((== level 4) (== md `(md-heading 4 ,text)))))

(define (paragraph-o text md)
  "Relate paragraph text to its markdown representation."
  (== md `(md-paragraph ,text)))

(define (bullet-o text md)
  "Relate bullet text to its markdown representation."
  (== md `(md-bullet ,text)))

(define (bold-o text md)
  "Relate bold text to its markdown representation."
  (== md `(md-bold ,text)))

(define (code-block-o lang text md)
  "Relate code block to its markdown representation."
  (== md `(md-code-block ,lang ,text)))

(define (link-o text url md)
  "Relate link to its markdown representation."
  (== md `(md-link ,text ,url)))

(define (markdown-element-o elem md)
  "Bidirectional relation between a markdown AST element and its intermediate form.
   Both sides are S-expressions so miniKanren can unify in either direction.
   Use render-md-form to get the final markdown string from the intermediate form."
  (conde
   ((fresh (level text)
      (== elem `(heading ,level ,text))
      (heading-o level text md)))
   ((fresh (text)
      (== elem `(paragraph ,text))
      (paragraph-o text md)))
   ((fresh (text)
      (== elem `(bullet ,text))
      (bullet-o text md)))
   ((fresh (text)
      (== elem `(bold ,text))
      (bold-o text md)))
   ((fresh (lang text)
      (== elem `(code-block ,lang ,text))
      (code-block-o lang text md)))
   ((fresh (text url)
      (== elem `(link ,text ,url))
      (link-o text url md)))
   ((== elem '(hr))
    (== md '(md-hr)))))

;;; ── Pure Scheme renderer ──────────────────────────────────────────────────
;;; For practical rendering when you have the S-expression and want markdown.
;;; Uses string operations directly (more efficient than miniKanren for bulk).

(define (repeat-string s n)
  (let loop ((i 0) (acc ""))
    (if (>= i n) acc
        (loop (+ i 1) (string-append acc s)))))

(define (render-element elem)
  "Render one AST element to a markdown string."
  (cond
   ((not (pair? elem)) "")
   ((eq? (car elem) 'heading)
    (let ((level (cadr elem))
          (text  (caddr elem)))
      (string-append (repeat-string "#" level) " " text)))
   ((eq? (car elem) 'paragraph)
    (cadr elem))
   ((eq? (car elem) 'bullet)
    (string-append "- " (cadr elem)))
   ((eq? (car elem) 'code-inline)
    (string-append "`" (cadr elem) "`"))
   ((eq? (car elem) 'code-block)
    (let ((lang (cadr elem))
          (text (caddr elem)))
      (string-append "```" lang "\n" text "\n```")))
   ((eq? (car elem) 'table)
    (render-table (cadr elem)))
   ((eq? (car elem) 'table-row)
    (render-table-row (cadr elem)))
   ((eq? (car elem) 'link)
    (string-append "[" (cadr elem) "](" (caddr elem) ")"))
   ((eq? (car elem) 'bold)
    (string-append "**" (cadr elem) "**"))
   ((eq? (car elem) 'italic)
    (string-append "_" (cadr elem) "_"))
   ((eq? (car elem) 'hr)
    "---")
   (else (format #f "~a" elem))))

(define (render-table-row cells)
  (string-append "| "
                 (string-join (map (lambda (c) (format #f "~a" c)) cells) " | ")
                 " |"))

(define (render-table rows)
  (if (null? rows) ""
      (let* ((header (car rows))
             (header-line (render-table-row header))
             (sep-line (render-table-row (map (lambda (_) "---") header)))
             (data-lines (map render-table-row (cdr rows))))
        (string-join (cons header-line (cons sep-line data-lines)) "\n"))))

(define (sexp->markdown elements)
  "Render a list of AST elements to a markdown string."
  (string-join
   (map (lambda (elem)
          (let ((rendered (render-element elem)))
            (if (and (pair? elem)
                     (memq (car elem) '(heading paragraph hr)))
                (string-append rendered "\n")
                rendered)))
        elements)
   "\n"))

;;; ── Pure Scheme parser ────────────────────────────────────────────────────
;;; Line-level markdown → S-expression AST.

(define (string-prefix? prefix str)
  (and (>= (string-length str) (string-length prefix))
       (string=? (substring str 0 (string-length prefix)) prefix)))

(define (count-leading-char str ch)
  (let loop ((i 0))
    (if (and (< i (string-length str))
             (char=? (string-ref str i) ch))
        (loop (+ i 1))
        i)))

(define (string-trim-left str)
  (let loop ((i 0))
    (if (and (< i (string-length str))
             (char=? (string-ref str i) #\space))
        (loop (+ i 1))
        (substring str i))))

(define (parse-line line)
  "Parse a single markdown line into an AST element."
  (cond
   ;; Heading
   ((string-prefix? "#" line)
    (let* ((level (count-leading-char line #\#))
           (rest  (string-trim-left (substring line level))))
      `(heading ,level ,rest)))
   ;; Horizontal rule
   ((string=? line "---")
    '(hr))
   ;; Bullet
   ((string-prefix? "- " line)
    `(bullet ,(substring line 2)))
   ((string-prefix? "* " line)
    `(bullet ,(substring line 2)))
   ;; Table row
   ((string-prefix? "|" line)
    (let* ((trimmed (substring line 1))
           (cells (map string-trim-left
                       (filter (lambda (s) (not (string=? s "")))
                               (string-split trimmed #\|)))))
      ;; Skip separator rows (all dashes)
      (if (and (pair? cells)
               (every (lambda (c)
                        (string-prefix? "---" (string-trim-left c)))
                      cells))
          #f  ;; separator row, skip
          `(table-row ,cells))))
   ;; Empty line
   ((string=? line "")
    #f)
   ;; Paragraph
   (else
    `(paragraph ,line))))

(define (markdown->sexp md-string)
  "Parse a markdown string into a list of AST elements.
   Code blocks are handled as multi-line units."
  (let loop ((lines (string-split md-string #\newline))
             (acc '())
             (in-code-block #f)
             (code-lang "")
             (code-lines '()))
    (if (null? lines)
        ;; Close any open code block
        (let ((final (if in-code-block
                         (cons `(code-block ,code-lang
                                            ,(string-join (reverse code-lines) "\n"))
                               acc)
                         acc)))
          (reverse (filter identity final)))
        (let ((line (car lines))
              (rest (cdr lines)))
          (cond
           ;; Code block fence
           ((and (not in-code-block) (string-prefix? "```" line))
            (let ((lang (substring line 3)))
              (loop rest acc #t lang '())))
           ((and in-code-block (string=? line "```"))
            (loop rest
                  (cons `(code-block ,code-lang
                                     ,(string-join (reverse code-lines) "\n"))
                        acc)
                  #f "" '()))
           ;; Inside code block
           (in-code-block
            (loop rest acc #t code-lang (cons line code-lines)))
           ;; Normal line
           (else
            (let ((parsed (parse-line line)))
              (loop rest
                    (if parsed (cons parsed acc) acc)
                    #f "" '()))))))))

;;; ── Skill ↔ KB bridge ────────────────────────────────────────────────────
;;; Extract hyperarc-compatible facts from parsed skill markdown.

(define (skill->facts skill-name md-string)
  "Extract knowledge facts from a skill's markdown.
   Returns an alist of (section-name . items) pairs."
  (let* ((elements (markdown->sexp md-string))
         (sections (group-by-heading elements)))
    (map (lambda (section)
           (cons (car section)
                 (extract-facts-from-section skill-name (car section) (cdr section))))
         sections)))

(define (group-by-heading elements)
  "Group AST elements by their heading sections."
  (let loop ((elems elements)
             (current-heading "preamble")
             (current-items '())
             (acc '()))
    (if (null? elems)
        (reverse (if (null? current-items)
                     acc
                     (cons (cons current-heading (reverse current-items)) acc)))
        (let ((elem (car elems)))
          (if (and (pair? elem) (eq? (car elem) 'heading))
              (loop (cdr elems)
                    (caddr elem)  ;; heading text
                    '()
                    (if (null? current-items)
                        acc
                        (cons (cons current-heading (reverse current-items)) acc)))
              (loop (cdr elems)
                    current-heading
                    (cons elem current-items)
                    acc))))))

(define (extract-facts-from-section skill-name section-name items)
  "Extract structured facts from a section's items."
  (filter-map
   (lambda (item)
     (cond
      ;; Table rows become key-value facts
      ((and (pair? item) (eq? (car item) 'table-row))
       (let ((cells (cadr item)))
         (if (>= (length cells) 2)
             `(fact ,skill-name ,section-name ,(car cells) ,(cadr cells))
             #f)))
      ;; Bullets become facts
      ((and (pair? item) (eq? (car item) 'bullet))
       `(fact ,skill-name ,section-name ,(cadr item)))
      ;; Code blocks become code facts
      ((and (pair? item) (eq? (car item) 'code-block))
       `(code-fact ,skill-name ,section-name ,(cadr item) ,(caddr item)))
      (else #f)))
   items))

(define (facts->skill-section title facts)
  "Generate markdown AST elements from a list of facts."
  (cons (heading 2 title)
        (map (lambda (f)
               (cond
                ((and (pair? f) (eq? (car f) 'fact))
                 (if (= (length f) 5)
                     ;; key-value fact → table would be better but bullet is simpler
                     (bullet (string-append (list-ref f 3) " — " (list-ref f 4)))
                     (bullet (list-ref f 3))))
                ((and (pair? f) (eq? (car f) 'code-fact))
                 (code-block (list-ref f 3) (list-ref f 4)))
                (else (paragraph (format #f "~a" f)))))
             facts)))
