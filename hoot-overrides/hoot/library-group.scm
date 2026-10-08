;;; Library-group expander
;;; Copyright (C) 2024, 2025 Igalia, S.L.
;;; Copyright (C) 2025 David Thompson <dave@spritely.institute>
;;;
;;; Licensed under the Apache License, Version 2.0 (the "License");
;;; you may not use this file except in compliance with the License.
;;; You may obtain a copy of the License at
;;;
;;;    http://www.apache.org/licenses/LICENSE-2.0
;;;
;;; Unless required by applicable law or agreed to in writing, software
;;; distributed under the License is distributed on an "AS IS" BASIS,
;;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;;; See the License for the specific language governing permissions and
;;; limitations under the License.

;;; Commentary:
;;;
;;; Parser, linker, and expander for `library-group` form.
;;;
;;; Code:

(define-module (hoot library-group)
  #:use-module (hoot library)
  #:use-module (ice-9 match)
  #:use-module (language tree-il)
  #:use-module (language tree-il primitives)
  #:use-module ((srfi srfi-1) #:select (append-map partition fold))
  #:use-module (srfi srfi-9)
  #:use-module ((system syntax internal) #:select (syntax? syntax-sourcev))
  #:export (import?
            import-modname
            import-exported-name
            import-imported-name
            library-group?
            parse-library-group
            concatenate-library-groups
            link-library-group
            expand-library-group
            make-statement statement?
            make-definition
            trivial-residualize-handlers)
  #:re-export (parse-library))

(define-record-type <program>
  (make-program src trusted? duplicates isets body)
  program?
  (src program-src)
  (trusted? program-trusted?)
  (duplicates program-duplicates)
  (isets program-isets)
  (body program-body))

(define-record-type <library-group>
  (make-library-group src libraries programs)
  library-group?
  (src library-group-src)
  (libraries library-group-libraries)
  (programs library-group-programs))

(define-record-type <import>
  (make-import modname exported-name imported-name)
  import?
  (modname import-modname)
  (exported-name import-exported-name)
  (imported-name import-imported-name))

(define-record-type <lexical>
  (make-lexical sym)
  lexical?
  (sym lexical-sym))

(define-record-type <primitive>
  (make-primitive name)
  primitive?
  (name primitive-name))

(define-record-type <host-primitive>
  (make-host-primitive name)
  host-primitive?
  (name host-primitive-name))

(define-record-type <expand-time-value>
  (make-expand-time-value)
  expand-time-value?)

;; <value> := <lexical>
;;          | <primitive>
;;          | <host-primitive>
;;          | <expand-time-value>
(define-record-type <module-definitions>
  (make-module-definitions private public replacements provenance)
  module-definitions?
  ;; Hash table of symbol -> <value>.
  (private module-private-definitions)
  ;; Hash table of symbol -> <value>.
  (public module-public-definitions)
  ;; The following fields are to support Guile-flavored modules which
  ;; have complicated duplicate binding rules unlike standard Scheme
  ;; which simply forbids them.
  ;;
  ;; Hash table of symbol -> boolean
  (replacements module-replacements)
  ;; Hash table of <value> -> <module-definitions>
  (provenance module-provenance))

(define-record-type <definition>
  (make-definition name sym val)
  definition?
  (name definition-name)
  (sym definition-sym)
  (val definition-val))

(define-record-type <statement>
  (make-statement exp)
  statement?
  (exp statement-exp))

(define (name-matches? stx sym)
  (eq? (syntax->datum stx) sym))
(define-syntax-rule (symbolic-match? name)
  (name-matches? #'name 'name))

(define imported-library-name
  (match-lambda
    (($ <iset-only> iset select) (imported-library-name iset))
    (($ <iset-except> iset hide) (imported-library-name iset))
    (($ <iset-rename> iset renamings) (imported-library-name iset))
    (($ <iset-prefix> iset prefix) (imported-library-name iset))
    (($ <iset-rename-proc> iset code) (imported-library-name iset))
    (($ <iset-library> name version) name)))

(define (lookup-replacement defs name)
  (match defs
    (($ <module-definitions> _ _ replacements)
     (hashq-ref replacements name))))

(define (forbid-duplicate-bindings name old-defs old new-defs new)
  (match old
    ((? import?) (error "duplicate imports" old new))
    (_ (error "duplicate definition" name))))

(define (make-duplicate-handler duplicates)
  (define (symbol->duplicate-handler sym)
    (match sym
      ('check
       (lambda (name old-defs old new-defs new prev)
         (forbid-duplicate-bindings name old-defs old new-defs new)))
      ('first
       (lambda (name old-defs old new-defs new prev)
         (or prev old)))
      ('last
       (lambda (name old-defs old new-defs new prev)
         (or prev new)))
      ('noop
       (lambda (name old-defs old new-defs new prev)
         #f))
      ('replace
          (lambda (name old-defs old new-defs new prev)
            (let ((old-replace? (lookup-replacement old-defs name))
                  (new-replace? (lookup-replacement new-defs name)))
              (if old-replace?
                  (if new-replace?
                      new
                      (or prev old))
                  new))))
      ;; FIXME: Print warnings.  As of writing, warnings will be
      ;; printed *twice* due to how library compilation works.
      ;; Also, we don't have the necessary data to know if we are
      ;; overriding a core binding.
      ('warn
       (lambda (name old-defs old new-defs new prev)
         #f))
      ('warn-override-core
       (lambda (name old-defs old new-defs new prev)
         #f))
      ;; TODO: We don't support GOOPS yet.
      ('merge-generics
       (lambda (name old-defs old new-defs new prev)
         (error "GOOPS is unsupported")))
      ('merge-accessors
       (lambda (name old-defs old new-defs new prev)
         (error "GOOPS is unsupported")))))
  (if duplicates
      (let ((handlers (map symbol->duplicate-handler duplicates)))
        (lambda (name old-defs old new-defs new)
          (let lp ((prev #f) (handlers handlers))
            (match handlers
              (() (or prev (error "unresolved duplicate definition" name)))
              ((handler . rest)
               (match (handler name old-defs old new-defs new prev)
                 (#f (lp prev rest))
                 (binding (lp binding rest))))))))
      forbid-duplicate-bindings))

(define (includes-forbidden filename)
  (error "library-group include clause forbidden" filename))

(define* (parse-library-group form #:key (include-file includes-forbidden)
                              (features '()))
  "Parse a @code{library-group} form to a @code{<library-group>} record,
processing includes.  No other expansion or analysis is performed beyond
syntactic validity."

  (define* (parse forms libraries #:key (trusted? #f))
    "For each form in @var{forms}, which should be a list of syntax objects,
process any includes, collecting the prefix of @code{<library>} forms
and then parsing the tail @code{<program>}, or @code{#f} if there is no
program."
    (syntax-case forms ()
      (() (values (reverse libraries) '()))
      ((form . forms)
       (syntax-case #'form ()
         (#:untrusted
          (parse #'forms libraries #:trusted? #f))
         ((library . _)
          (symbolic-match? library)
          (parse #'forms (cons (parse-r6rs-library #'form trusted?) libraries)
                 #:trusted? trusted?))
         ((define-library . _)
          (symbolic-match? define-library)
          (parse #'forms
                 (cons (parse-r7rs-library #'form trusted? include-file
                                           features)
                       libraries)
                 #:trusted? trusted?))
         ((include filename)
          (symbolic-match? include)
          (let ((included (include-file (syntax->datum #'filename))))
            (syntax-case included ()
              (((define-module modname . modargs) . body)
               (symbolic-match? define-module)
               (parse #'forms
                      (cons (parse-guile-library
                             #'(define-module modname . modargs) #'body
                             trusted?)
                            libraries)
                      #:trusted? trusted?))
              (_
               (parse (append included #'forms) libraries
                      #:trusted? trusted?)))))
         ((import import-spec ...)
          (symbolic-match? import)
          (values (reverse libraries)
                  (list
                   (make-program #f trusted? #f
                                 (parse-r7rs-imports
                                  (syntax->datum #'(import-spec ...)))
                                 #'forms))))
         ((use-modules import-spec ...)
          (symbolic-match? use-modules)
          (values (reverse libraries)
                  (list
                   (make-program #f trusted? %default-guile-duplicates
                                 (finish-guile-imports
                                  (map parse-guile-import #'(import-spec ...))
                                  #:pure? #f)
                                 #'forms))))))))

  (syntax-case form ()
    ((library-group form ...)
     (symbolic-match? library-group)
     (let ((src (and (syntax? #'library-group)
                     (syntax-sourcev #'library-group))))
       (call-with-values (lambda () (parse #'(form ...) '() #:trusted? #t))
         (lambda (libraries programs)
           (make-library-group src libraries programs)))))
    (_
     (error "invalid library-group" form))))

(define (concatenate-library-groups a-group b-group)
  (match a-group
    (($ <library-group> a-src a-libraries a-programs)
     (match b-group
       (($ <library-group> b-src b-libraries b-programs)
        (make-library-group
         (or a-src b-src)
         (append a-libraries b-libraries)
         (append a-programs b-programs)))))))

(define* (link-library-group group #:key
                             (load-library (lambda* (name #:key (features '()))
                                             #f))
                             (features '())
                             (allow-dangling-import? (lambda (name) #f)))
  (define linked '()) ;; List of libraries.
  (define by-name (make-hash-table))

  (define (link-library! library)
    (let ((name (library-name library)))
      (when (hash-ref by-name name)
        (error "duplicate library definition" name))
      (hash-set! by-name name 'linking)
      (for-each link-import! (library-isets library))
      (set! linked (cons library linked))
      (hash-set! by-name name 'linked)))

  (define (link-import! iset)
    (let ((name (imported-library-name iset)))
      (match (hash-ref by-name name 'unvisited)
        ('linked (values))
        ('linking (error "cycle in module graph" name))
        ('unvisited
         (cond
          ((allow-dangling-import? name) (values))
          ((load-library name #:features features) => link-library!)
          (else (error "module not found" name)))))))

  (match group
    (($ <library-group> src libraries programs)
     (for-each link-library! libraries)
     (for-each (lambda (program)
                 (for-each link-import! (program-isets program)))
               programs)
     (make-library-group src (reverse linked) programs))))

;; FIXME: Get this exported from (language tree-il primitives).
(define (primitive-for-variable box)
  (hashq-ref (@@ (language tree-il primitives) *interesting-primitive-vars*)
             box))

(define* (expand-library call-with-target mod form
                         #:key (residualize-syntax-transformers? #f))
  "Expand the syntax object @var{form} in the module @var{mod}.

The term will be expanded twice: once to create the expand-time module,
which will then be evaluated directly, and once to residualize a Tree-IL
term for the compilation unit.

Syntax transformers (macros) will be evaluated at expansion-time.  By
default, they are not residualized into the compilation unit."
  (save-module-excursion
   (lambda ()
     (set-current-module mod)
     (primitive-eval (macroexpand form 'e '(compile eval)))
     (call-with-target
      (lambda ()
        (macroexpand form 'c (if residualize-syntax-transformers?
                                 '(load)
                                 '())))))))

(define* (expand-program call-with-target mod form
                         #:key (residualize-syntax-transformers? #f))
  "Expand the syntax object @var{form} in the module @var{mod}.

Syntax transformers (macros) will be evaluated at expansion-time.  By
default, they are not residualized into the compilation unit."
  (save-module-excursion
   (lambda ()
     (set-current-module mod)
     (call-with-target
      (lambda ()
        (macroexpand form 'c (if residualize-syntax-transformers?
                                 '(load compile)
                                 '(compile))))))))

(define (trivial-residualize-handlers)
  (define (lift state)
    state)
  (define (add-definition name sym val state)
    (cons (make-definition name sym val) state))
  (define (add-statement exp state)
    (cons (make-statement exp) state))
  (define (lower state)
    state)
  (values lift add-definition add-statement lower))

(define* (expand-library-group group #:key
                               (call-with-target (lambda (f) (f)))
                               (rewrite-primitive
                                (lambda (exp make-module-ref) exp))
                               (rewrite-host-reference
                                (lambda (exp make-module-ref)
                                  (error "unknown host reference" exp)))
                               (rewrite-host-primitive
                                (lambda (src name make-module-ref)
                                  (error
                                   "reference to host primitive in generated code"
                                   src name)))
                               (residualize-handlers
                                (lambda _ (trivial-residualize-handlers)))
                               (missing-library (lambda (modname) #f))
                               (primitives #f)
                               (residualize-syntax-transformers? #f))
  "Take a @code{<library-group>} record and expand it to a big
@code{letrec*}.
The libraries in the group are expanded one-by-one.  Expanding a library
residualises a Tree-IL AST node as part of the compilation unit, and
additionally populates a compile-time host module with definitions.  If
expanding a module needs compile-time values from another module, it
uses the bindings in the host module.

All definitions and expressions in the expanded libraries are then
rewritten to be part of a big @code{letrec*}, and top-level and module
references in those definitions and expressions are rewritten to use
lexical references.

The final program in the @code{<library-group>} is given the same
treatment, except that its final expression (if any) is evaluated in
tail position."
  ;; A mapping from module,name,public? tuple to <binding> record, for
  ;; all modules in the library group.
  (define module-definitions (make-hash-table))
  (define (add-module-definitions! modname)
    (when (hash-ref module-definitions modname)
      (error "duplicate module" modname))
    (define defs
      (make-module-definitions (make-hash-table)
                               (make-hash-table)
                               (make-hash-table)
                               (make-hash-table)))
    (hash-set! module-definitions modname defs)
    defs)
  (define (lookup-module-definitions modname)
    (or (hash-ref module-definitions modname)
        (begin
          (missing-library modname)
          (error "unknown module" modname))))

  (define (add-definition! defs from name public? duplicate-handler value)
    (match defs
      (($ <module-definitions> private public _ provenance)
       (let ((t (if public? public private)))
         (match (hashq-ref t name)
           (#f
            (hashq-set! t name value)
            (hashq-set! provenance value from))
           ;; TODO: Need to get modules where bindings came from.
           (existing
            (let* ((from* (hashq-ref provenance existing))
                   (winner (duplicate-handler name from* existing from value)))
              (unless (eq? winner existing)
                (hashq-set! t name winner)
                (hashq-set! provenance winner from)))))))))
  (define (lookup-definition defs name public?)
    (match defs
      (($ <module-definitions> private public)
       (hashq-ref (if public? public private) name))))

  (define (add-replacement! defs name)
    (match defs
      (($ <module-definitions> _ _ replacements)
       (hashq-set! replacements name #t))))

  ;; Add definitions from primitive module.
  (when primitives
    (let ((defs (add-module-definitions! primitives)))
      (module-for-each
       (lambda (name box)
         (add-definition! defs #f name #t #f
                          (match (primitive-for-variable box)
                            (#f (make-host-primitive name))
                            (name (make-primitive name)))))
       (resolve-interface primitives))))

  (define (parse-isets isets trusted?)
    (define parse-iset
      (match-lambda
        (($ <iset-only> iset select)
         (filter (match-lambda
                   (($ <import> mod-name exported imported)
                    (memq imported select)))
                 (parse-iset iset)))
        (($ <iset-except> iset hide)
         (filter (match-lambda
                   (($ <import> mod-name exported imported)
                    (not (memq imported hide))))
                 (parse-iset iset)))
        (($ <iset-prefix> iset prefix)
         (map (match-lambda
                (($ <import> mod-name exported imported)
                 (let ((renamed (symbol-append prefix imported)))
                   (make-import mod-name exported renamed))))
              (parse-iset iset)))
        (($ <iset-rename> iset renamings)
         (map (match-lambda
                (($ <import> mod-name exported imported)
                 (define renamed
                   (or (assq-ref renamings imported) imported))
                 (make-import mod-name exported renamed)))
              (parse-iset iset)))
        (($ <iset-rename-proc> iset exp)
         (let ((module (make-module))
               (root (resolve-module '() #f)))
           (module-use! module the-scm-module)
           (let ((rename (eval exp module)))
             ;; Remove temporary module from global module tree.
             (hashq-remove! (module-submodules root) (module-name module))
             (map (match-lambda
                    (($ <import> mod-name exported imported)
                     (make-import mod-name exported (rename imported))))
                  (parse-iset iset)))))
        (($ <iset-library> modname version)
         (unless (null? version)
           (error "version references unsupported"))
         (when (equal? modname primitives)
           (unless trusted?
             (error "untrusted module cannot import primitives")))
         (let ((exports (module-public-definitions
                         (lookup-module-definitions modname))))
           (define (id<? a b)
             (string<? (symbol->string a) (symbol->string b)))
           (define (import<? a b)
             (id<? (import-exported-name a) (import-exported-name b)))
           (sort (hash-map->list (lambda (name binding)
                                   (make-import modname name name))
                                 exports)
                 import<?)))))
    (append-map parse-iset isets))

  ;; Because each invocation of expand-library-group gets its own
  ;; namespace, we don't have to deal with lingering definitions from
  ;; any previous expansion; all modules defined by this compilation
  ;; unit are fresh.  This also allows expansion to happen in parallel.
  (define namespace (gensym "%library-group"))

  (define (host-modname? modname)
    (match modname
      (('% (? (lambda (ns) (eq? ns namespace))) . tail) #f)
      (_ #t)))
  (define (annotate-modname modname)
    (if (equal? modname primitives)
        modname
        (cons* '% namespace modname)))
  (define (strip-modname modname)
    (match modname
      (('% (? (lambda (x) (eq? x namespace))) . modname) modname)
      (_
       (unless (equal? modname primitives)
         (error "unexpected modname" modname))
       modname)))

  (define (make-namespaced-module-ref src mod name public?)
    (make-module-ref src (annotate-modname mod) name public?))
  (define (make-namespaced-module-set src mod name public? val)
    (make-module-set src (annotate-modname mod) name public? val))

  (define (make-expand-time-module modname filename version imports exports
                                   replacements duplicate-handler)
    "Create the host module in which to store compile-time library
definitions.  The module may import other host libraries."
    (define imports-by-module (make-hash-table))
    (define (add-import! modname exported imported)
      (define tail (hash-ref imports-by-module modname '()))
      (define entry (cons exported imported))
      (hash-set! imports-by-module modname (cons entry tail)))
    (for-each (match-lambda
                (($ <import> modname exported imported)
                 (add-import! modname exported imported)))
              imports)
    (define (id<? a b)
      (string<? (symbol->string a) (symbol->string b)))
    (define (modname<? a b)
      (match a
        (() #t)
        ((a . a*) (match b
                    (() #f)
                    ((b  . b*) (and (id<? a b) (modname<? a* b*)))))))
    (define module-import-decls
      (sort (hash-map->list (lambda (modname entries)
                              (list (annotate-modname modname)
                                    #:select
                                    (sort entries
                                          (lambda (a b)
                                            (id<? (car a) (car b))))))
                            imports-by-module)
            (lambda (a b)
              (modname<? (car a) (car b)))))
    (define-values (module-export-decls module-re-export-decls)
      (let ()
        (define imports-by-name (make-hash-table))
        (for-each (match-lambda
                    ((and import ($ <import> import-modname _ imported))
                     (match (hashq-ref imports-by-name imported)
                       (#f (hashq-set! imports-by-name imported import))
                       ((and existing ($ <import> existing-modname))
                        (hashq-set! imports-by-name imported
                                    (duplicate-handler
                                     imported
                                     (lookup-module-definitions existing-modname)
                                     existing
                                     (lookup-module-definitions import-modname)
                                     import))))))
                  imports)
        (partition (match-lambda
                     ((local . public)
                      (or (not (hashq-ref imports-by-name local))
                          ;; Replacements of imported bindings should
                          ;; not be considered re-exports.
                          (assq-ref replacements local))))
                   exports)))
    (define-module* (annotate-modname modname)
      #:filename filename
      #:pure #t
      #:declarative? #t
      #:version version
      #:imports module-import-decls
      #:exports module-export-decls
      #:re-exports module-re-export-decls
      #:replacements replacements))

  (define (tree-il-for-each f exp)
    (define fold (make-tree-il-folder))
    (fold exp (lambda (exp) (values)) f))

  (define (tree-il->reversed-bindings exp modname imports exports replacements
                                      duplicate-handler
                                      add-definition add-statement
                                      bindings)
    "Given the expanded library @var{exp}, as a Tree-IL node, transform it to
a sequence of definitions and expressions, as @code{<binding>} nodes.
Rewrite references to other top-level bindings to refer to primitive
or lexical definitions.  Append those @code{<binding>} nodes to
@var{bindings}, in reverse order.  The @var{duplicate-handler}
procedure is called to resolve issues of duplicate definitions."
    ;; Make defs for module.
    (define defs (add-module-definitions! modname))

    (define (has-expand-time-value? name)
      (module-variable (resolve-module (annotate-modname modname)) name))

    ;; Add definitions for imports.
    (for-each (match-lambda
                (($ <import> imod exported imported)
                 (let ((from (lookup-module-definitions imod)))
                   (match (lookup-definition from exported #t)
                     (#f (error "unknown import?" imod exported))
                     (value (add-definition! defs from imported #f
                                             duplicate-handler value))))))
              imports)

    ;; Prohibit set! to imports.  Check module on expanded toplevel defs
    ;; and uses.
    (tree-il-for-each (match-lambda
                        (($ <toplevel-define> src mod name val)
                         (unless (equal? (strip-modname mod) modname)
                           (error "unexpected mod" exp mod modname))
                         (values))
                        (($ <toplevel-ref> src mod name)
                         (unless (equal? (strip-modname mod) modname)
                           (error "unexpected mod" exp mod modname))
                         (values))
                        (($ <toplevel-set> src mod name val)
                         (unless (equal? (strip-modname mod) modname)
                           (error "unexpected mod" exp mod modname))
                         (when (lookup-definition defs name #f)
                           (error "set! to imported binding" src name))
                         (values))
                        (_ (values)))
                      exp)

    ;; Record local definitions and allocate lexicals for them.
    (tree-il-for-each (match-lambda
                        (($ <toplevel-define> src mod name exp)
                         (add-definition! defs defs name #f duplicate-handler
                                          (make-lexical (gensym "top")))
                         (values))
                        (_ (values)))
                      exp)

    ;; Check for unbound top-levels.
    (tree-il-for-each (match-lambda
                        (($ <toplevel-ref> src mod name)
                         (unless (lookup-definition defs name #f)
                           (error "unbound top-level" src name))
                         (values))
                        (($ <toplevel-set> src mod name val)
                         (unless (lookup-definition defs name #f)
                           (error "unbound top-level" src name))
                         (values))
                        (_ (values)))
                      exp)

    ;; Find local definitions for exports.
    (for-each (match-lambda
                ((local . exported)
                 (match (lookup-definition defs local #f)
                   (#f
                    ;; An export without a binding in the compilation
                    ;; unit.  Perhaps it is an expansion-time binding.
                    (unless (has-expand-time-value? local)
                      (error "missing definition for export"
                             modname local exported))
                    (let ((val (make-expand-time-value)))
                      (add-definition! defs defs local #f duplicate-handler val)
                      (add-definition! defs defs exported #t duplicate-handler val)))
                   (val (add-definition! defs defs exported #t duplicate-handler val)))))
              (append exports replacements))

    ;; Register replacement bindings.
    (for-each (match-lambda
                ((_ . exported)
                 (add-replacement! defs exported)))
              replacements)

    ;; Resolve references to local definitions to lexical-ref or
    ;; primitive-ref.
    (define (rewrite-toplevels exp)
      (post-order
       (match-lambda
         (($ <toplevel-ref> src mod name)
          (match (lookup-definition defs name #f)
            (($ <lexical> sym) (make-lexical-ref src name sym))
            (($ <primitive> name) (make-primitive-ref src name))
            (($ <host-primitive> name)
             (rewrite-host-primitive src name
                                     make-namespaced-module-ref))
            (($ <expand-time-value>)
             (error "reference to expansion-time value in generated code"
                    src modname name))))
         (($ <toplevel-set> src mod name val)
          (match (lookup-definition defs name #f)
            (($ <lexical> sym) (make-lexical-set src name sym val))
            (($ <host-primitive> name)
             (error "assignment to host primitive" name))
            (($ <expand-time-value>)
             (error "reference to expansion-time value in generated code"
                    src modname name))))
         (($ <toplevel-define> src mod name val)
          (error "nested toplevel-define" src mod name val))
         (exp exp))
       exp))

    ;; Walk the chain of <seq> and <toplevel-define> to extract
    ;; definitions and statements.
    (define (visit-top-level exp bindings)
      (match exp
        (($ <toplevel-define> src mod name val)
         (match (lookup-definition defs name #f)
           (($ <lexical> sym)
            (add-definition name sym (rewrite-toplevels val)
                            bindings))))

        (($ <seq> src head tail)
         (visit-top-level tail (visit-top-level head bindings)))

        ;; Could fold in let and letrec* bindings.  Dunno.
        (_ (add-statement (rewrite-toplevels exp) bindings))))

    (define (patch-primitives exp)
      ;; Fix up two kinds of anamolies in expanded code:
      ;;
      ;;   1. Primcalls introduced by the expander, but which might not
      ;;      correspond to primitives for the target.  For example,
      ;;      list->vector as emitted by #'#(foo).
      ;;
      ;;   2. Reference to top-level host bindings in the expander
      ;;      itself, as in #'(list->vector foo).  This happens a lot in
      ;;      Guile's expander.
      (define (patch exp)
        (match exp
          (($ <primitive-ref> src name)
           (match (rewrite-primitive exp make-namespaced-module-ref)
             (#f (error "bad rewrite-primitive return"))
             ((and exp ($ <primitive-ref>)) exp)
             (exp (patch exp))))
          (($ <primcall> src name args)
           (match (patch (make-primitive-ref src name))
             (($ <primitive-ref> src name)
              (make-primcall src name args))
             (exp (make-call src exp args))))
          (($ <module-ref> src (? host-modname? mod) name #f)
           ;; A primitive reference introduced by a primitive syntax
           ;; expander.
           (match (rewrite-host-reference exp make-namespaced-module-ref)
             (#f (error "bad rewrite-host-reference return"))
             (($ <module-ref> src (? host-modname? mod) name #f)
              (error "residual host reference after rewrite" src mod name))
             (exp (patch exp))))
          (($ <call> src ($ <primitive-ref> _ name) args)
           (make-primcall src name args))
          (_ exp)))
      (post-order patch exp))

    (visit-top-level (patch-primitives exp) bindings))

  (define (srcv-filename srcv)
    (match srcv
      (#f #f)
      (#(filename line column) filename)))

  (define (module->reversed-bindings src modname version imports exports
                                     replacements duplicate-handler body expand)
    (define filename (srcv-filename src))
    (define ctmod
      (make-expand-time-module modname filename version imports exports
                               replacements duplicate-handler))
    (define expanded
      (expand call-with-target ctmod #`(begin . #,body)
                      #:residualize-syntax-transformers?
                      residualize-syntax-transformers?))
    (define-values (lift add-statement add-definition lower)
      (residualize-handlers src modname version
                            imports (append exports replacements)
                            duplicate-handler
                            make-namespaced-module-ref
                            make-namespaced-module-set))
    (lower
     (tree-il->reversed-bindings expanded modname imports exports replacements
                                 duplicate-handler
                                 add-statement add-definition
                                 (lift '()))))

  (define (library->reversed-bindings library bindings)
    "Given the R6RS library @var{form}, as a syntax object, parse out the
imports and exports, create a compile-time module, and expand the body
of the library within that module.  Collect residual definitions and
statements into a reversed list."
    (match library
      (($ <library> src modname version trusted? duplicates exports
                    replacements isets body)
       (define imports (parse-isets isets trusted?))
       (define duplicate-handler (make-duplicate-handler duplicates))
       (append (module->reversed-bindings src modname version imports exports
                                          replacements duplicate-handler body
                                          expand-library)
               bindings))))

  (define (program->reversed-bindings program bindings)
    "Same as @code{library->reversed-bindings}, but for a program.
@var{imports} is already parsed, as a list of @code{<import>}.  A new
module with a fresh name will be defined for the purposes of expanding"
    (match program
      (($ <program> src trusted? duplicates isets body)
       (define modname (list (gensym "library-group-program")))
       (define imports (parse-isets isets trusted?))
       (define duplicate-handler (make-duplicate-handler duplicates))
       (append (module->reversed-bindings src modname '() imports '() '()
                                          duplicate-handler body expand-program)
               bindings))))

  (define (resolve-references bindings)
    (define (resolve exp)
      ;; Check for unbound top-levels.
      (tree-il-for-each
       (match-lambda
         (($ <module-ref> src mod name public?)
          (unless (or (host-modname? mod)
                      (let ((defs (lookup-module-definitions
                                   (strip-modname mod))))
                        (lookup-definition defs name public?)))
            (error "unbound macro-introduced top-level for module"
                   src (strip-modname mod) name))
          (values))
         (($ <module-set> src mod name public? val)
          (unless (let ((defs (lookup-module-definitions
                               (strip-modname mod))))
                    (lookup-definition defs name public?))
            (error "unbound macro-introduced top-level for module"
                   src (strip-modname mod) name))
          (values))
         (_ (values)))
       exp)

      ;; Resolve explicit cross-module references to lexical-ref or
      ;; primitive-ref.  Do this now instead of while processing modules
      ;; one by one to allow for cyclical references introduced by the
      ;; expander.
      (define (resolve-one exp)
        (match exp
          (($ <module-ref> src mod name public?)
           (let ((defs (lookup-module-definitions (strip-modname mod))))
             (match (lookup-definition defs name public?)
               (($ <lexical> sym) (make-lexical-ref src name sym))
               (($ <primitive> name) (make-primitive-ref src name))
               (($ <host-primitive> name)
                (resolve-one
                 (rewrite-host-primitive src name
                                         make-namespaced-module-ref)))
               (($ <expand-time-value>)
                (error "reference to expansion-time value in generated code"
                       src mod name)))))
          (($ <module-set> src mod name public? val)
           (let ((defs (lookup-module-definitions (strip-modname mod))))
             (match (lookup-definition defs name public?)
               (($ <lexical> sym) (make-lexical-set src name sym val))
               (($ <expand-time-value>)
                (error "reference to expansion-time value in generated code"
                       src mod name)))))
          ((or ($ <toplevel-ref>) ($ <toplevel-set>) ($ <toplevel-define>))
           (error "unexpected toplevel" exp))
          (($ <call> src ($ <primitive-ref> _ name) args)
           (expand-primcall (make-primcall src name args)))
          (_ exp)))

      (post-order resolve-one exp))

    (map (match-lambda
           (($ <statement> exp)
            (make-statement (resolve exp)))
           (($ <definition> name sym exp)
            (make-definition name sym (resolve exp))))
         bindings))

  (define (ensure-tail-expression reversed-bindings)
    (match reversed-bindings
      ((($ <statement>) . _) reversed-bindings)
      (_
       (cons (make-statement (make-void #f)) reversed-bindings))))

  (define reversed-bindings
    (match group
      (($ <library-group> src libraries programs)
       (ensure-tail-expression
        (resolve-references
         (fold program->reversed-bindings
               (fold library->reversed-bindings '() libraries)
               programs))))))

  ;; Remove the modules we just expanded from the global module tree.
  (hashq-remove! (module-submodules (resolve-module '(%))) namespace)

  (match reversed-bindings
    ((($ <statement> tail) . bindings)
     (let ((bindings (reverse bindings)))
       (make-letrec (library-group-src group)
                    #t                  ; in-order?
                    (map (match-lambda
                           (($ <definition> name sym val) name)
                           (($ <statement> exp) '_))
                         bindings)
                    (map (match-lambda
                           (($ <definition> name sym val) sym)
                           (($ <statement> exp) (gensym "_")))
                         bindings)
                    (map (match-lambda
                           (($ <definition> name sym val) val)
                           (($ <statement> exp)
                            (if (void? exp)
                                exp
                                (make-seq #f exp (make-void #f)))))
                         bindings)
                    tail)))))
