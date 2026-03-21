# Foreign Function Interface (Guile Hoot)

## Overview

WebAssembly modules operate within a capability security model, requiring hosts to provide capabilities through declared imports. Hoot's FFI, found in `(hoot ffi)`, enables embedding import declarations directly in Scheme code.

## Core Concept

The FFI converts between Scheme and WebAssembly values. Modules declare imports with type signatures, which hosts fulfill at instantiation time.

## Basic Example

```scheme
(define-foreign make-text-node
  "document" "createTextNode"
  (ref string) -> (ref extern))
```

This declares a procedure `make-text-node` that calls the "createTextNode" function in the "document" namespace.

## Host Integration

**JavaScript (Browser):**
```javascript
Scheme.load_main("hello.wasm", {
  user_imports: {
    document: {
      createTextNode: (text) => document.createTextNode(text)
    }
  }
});
```

**Hoot Interpreter:**
```scheme
(use-modules (hoot reflect))
(hoot-instantiate (call-with-input-file "hello.wasm" parse-wasm)
  `(("document" . (("createTextNode" . ,(lambda (str) `(text ,str)))))))
```

## Using External References

```scheme
(define hello (make-text-node "Hello, world!"))

(external? hello)        ; => #t
(external-null? hello)   ; => #f
```

## Type-Safe Wrapping

Define wrapper types to distinguish foreign value kinds:

```scheme
(define-external-type <text-node>
  text-node? wrap-text-node unwrap-text-node)

(define-foreign %make-text-node
  "document" "createTextNode"
  (ref string) -> (ref extern))

(define (make-text-node str)
  (wrap-text-node (%make-text-node str)))

(external? hello)                    ; => #f
(text-node? hello)                   ; => #t
```

## API Reference

### `define-foreign`
Declares a Wasm import with specified type signature.

**Valid parameter types:** i32, i64, f32, f64, (ref string), (ref extern), (ref null extern), (ref eq)

**Valid result types:** none, i32, i64, f32, f64, (ref string), (ref null string), (ref extern), (ref null extern), (ref eq)

### Predicates & Functions

- `external?` — Tests if object is external reference
- `external-null?` — Tests if external value is null
- `external-non-null?` — Tests if external value is not null
- `procedure->external` — Wraps Scheme procedure as callable external function

### `define-external-type`
Creates record types for wrapping external values with optional custom printing.
