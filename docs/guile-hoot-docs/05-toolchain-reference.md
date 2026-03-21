# Toolchain Reference

## Overview

Hoot represents more than just a Scheme-to-WASM compiler. As described in the documentation, it functions as "a self-contained and general purpose WASM toolchain" that operates independently without relying on external tools like binaryen, wabt, or emscripten.

The entire system is constructed using Scheme modules, enabling developers to:
- Automate WASM-focused build processes
- Benefit from unified implementation across the toolchain
- Leverage Guile's REPL-driven development approach for interactive learning
- Explore WASM concepts through hands-on experimentation

## Toolchain Components

The Hoot toolchain comprises the following specialized modules:

1. **Data types** - Core type definitions
2. **GWAT** - WASM text format handling
3. **Resolver** - Symbol and reference resolution
4. **Linker** - Module linking functionality
5. **Assembler** - WASM assembly operations
6. **Binary Parser** - WASM binary format parsing
7. **Printer** - Output formatting
8. **Interpreter** - Runtime execution environment

---

## Data Types

### Module: `(wasm types)`

The `(wasm types)` module provides core data structures for WebAssembly modules, organized hierarchically.

### Modules

A WASM module serves as the top-level container. Key procedures include:

- `wasm?` checks if an object is a module
- Accessor functions retrieve components: `wasm-types`, `wasm-imports`, `wasm-funcs`, `wasm-tables`, `wasm-memories`, `wasm-globals`, `wasm-exports`, `wasm-elems`, `wasm-datas`, `wasm-tags`, `wasm-strings`, `wasm-custom`
- `wasm-start` returns the entry function index

### Type System

WASM supports four numeric types: `i32`, `i64`, `f32`, and `f64`, plus the unsupported `v128` vector type.

Reference types include:

**Function types:** `func` (references), `nofunc` (bottom type)

**External types:** `extern`, `noextern`

**Internal types:** `any` (top), `eq`, `i31`, `array`, `struct`, and `none` (bottom)

Type objects associate identifiers with function signatures or reference descriptors. The `type?` predicate identifies type objects, while `type-id` and `type-val` retrieve their properties.

Recursive type groups enable circular references. "Structurally identical type groups across WASM modules are canonicalized at runtime."

### Functions

Functions contain signatures, parameters, locals, and executable bodies.

- `func-sig` returns the function signature
- `func-sig-params` and `func-sig-results` describe input/output types
- Parameters and locals pair identifiers with type descriptors

### Globals, Memory & Tables

Globals support mutable and immutable variables with initialization instructions. Memory objects specify linear byte chunks in 64KiB pages. Tables store typed heap references.

### Data & Element Segments

Data segments initialize memory regions, operating in active or passive modes. Element segments similarly initialize table regions, supporting active, passive, or declarative modes.

### Limits

Both memories and tables use limit constraints with minimum values and optional maximum bounds.

---

## GWAT (Guile WebAssembly Text Format)

### Module: `(wasm wat)`

GWAT is a variant of WebAssembly Text (WAT) format integrated into Hoot. The name reflects its origin: "G" stands for "Guile."

### Core Concept

Rather than parsing traditional WAT syntax, GWAT represents WebAssembly code as Scheme expressions. This approach enables:
- Direct embedding of WAT within Scheme code
- Programmatic WAT generation using quasiquote templating
- Enhanced expressiveness compared to standard WAT

### Additional Features

GWAT extends standard WAT capabilities by supporting:
- String constants
- Bytevectors for data segments
- i32/i64 constants (signed or unsigned ranges)

### Syntax Variants

**Unfolded Form** - Instructions appear in linear sequence, matching the resulting binary structure:

```scheme
'(module
  (func (export "add") (param $a i32) (param $b i32) (result i32)
        (local.get $a)
        (local.get $b)
        (i32.add)))
```

**Folded Form** - Instructions nest within each other, resembling Scheme procedure calls:

```scheme
'(module
  (func (export "add") (param $a i32) (param $b i32) (result i32)
        (i32.add (local.get $a)
                 (local.get $b))))
```

The folded form is generally preferred for readability and reasoning.

### API Functions

**wat->wasm** _expr_: Parses GWAT expressions and returns a WASM module while preserving named references.

**wasm->wat** _wasm_: Disassembles WASM modules back into symbolic WAT form.

---

## Resolver

### Module: `(wasm resolve)`

The Resolver component is responsible for preparing WASM modules for the subsequent assembly or interpretation stages. It "lowers WASM modules into a form that can be used by the assembler or interpreter."

### Key Responsibilities

The resolver handles three main transformation tasks:

1. **Named Reference Resolution** - Converts symbolic names to their corresponding integer indices
2. **Type Table Population** - Fills out the complete type table for the module
3. **Constant Normalization** - Adjusts i32 and i64 constants into their canonical form

### API

**resolve-wasm** _mod_

Takes a WASM module and produces a normalized version suitable for assembly or interpretation. The procedure generates a new module without modifying the input.

---

## Linker

### Module: `(wasm link)`

The linker module serves to enhance a WASM module by integrating the necessary standard library components. In the Hoot compilation pipeline, it incorporates the Scheme runtime into compiled user code.

### Key Features

**Tree-shaking optimization**: The linker employs tree-shaking techniques to eliminate unused code, ensuring that only dependencies actually referenced by the base module are included in the final output.

### API

**add-stdlib** _wasm stdlib_

Merges two WASM modules together, creating a new combined module from the input `wasm` module and the provided `stdlib` module.

---

## Assembler

### Module: `(wasm assemble)`

The assembler component is responsible for converting WASM modules into their binary representation. It "lower[s] WASM modules into the WASM binary format," enabling the transformation of structured WASM code into executable bytecode.

### API

**assemble-wasm** _wasm_

Returns a bytevector containing the assembled binary representation of the provided WASM module.

---

## Printer

### Module: `(wasm dump)`

The Printer is a component that generates detailed textual representations of WebAssembly modules.

### API

**dump-wasm** _mod_ [#:port] [#:dump-func-defs? #t]

Outputs comprehensive information about a WASM module's structure and contents.

**Parameters:**
- `mod`: The WebAssembly module to analyze
- `#:port` (optional): Destination for output; defaults to current output port if unspecified
- `#:dump-func-defs?` (optional, default `#t`): Controls whether function definitions are included

When `dump-func-defs?` is enabled, the procedure includes all function definitions along with their instruction bodies.

---

## Interpreter

### Module: `(wasm vm)`

The `(wasm vm)` module provides a virtual machine for interpreting WebAssembly functions. "The interpreter only accepts validated WASM."

### Validation

Before interpretation, WASM modules must be validated for type safety. Key procedures include:

- **validate-wasm**: Validates a WASM module and wraps it to indicate successful validation
- **load-and-validate-wasm**: Parses a WASM binary and performs validation in one step; accepts `<wasm>` records, bytevectors, or input ports
- **validated-wasm?**: Tests whether an object is a validated WASM module
- **validated-wasm-ref**: Extracts the underlying WASM module from a validated wrapper

### Instantiation

Once validated, a WASM module requires instantiation to create runtime data:

- **instantiate-wasm**: Creates a new instance from a validated module; accepts an optional `#:imports` parameter for providing imported functions, globals, memories, and tables

Exported WASM functions then become callable as Scheme procedures. The system enforces runtime type checking on each call since WASM functions are statically typed.

### Runtime Components

**Globals** - Manage WASM global variables through procedures like `make-wasm-global`, `wasm-global-ref`, `wasm-global-set!`, and `wasm-global-mutable?`.

**Memories** - Handle linear memory through 64KiB page units via `make-wasm-memory`, `wasm-memory-size`, and `wasm-memory-grow!`.

**Tables** - Manage reference tables with `make-wasm-table`, `wasm-table-ref`, `wasm-table-set!`, and `wasm-table-grow!`.

### Observation

The `current-instruction-listener` parameter allows instrumentation of WASM execution by observing each instruction before evaluation.
