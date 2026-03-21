# Guile Reflection

The `(hoot reflect)` module enables inspection and manipulation of Scheme values within WebAssembly modules compiled by Hoot.

## Core Module Functions

**Module Instantiation & Loading:**
- `hoot-instantiate`: Creates a new Hoot module with optional imports and reflection configuration
- `hoot-load`: Invokes the load thunk and returns reflected results

**Convenience Compilation:**
- `compile-value`: Compiles an expression and returns its result
- `compile-call`: Compiles and executes a procedure with arguments

## Module Inspection

Predicates for module structures:
- `hoot-module?`: Identifies Hoot modules
- `hoot-module-reflector`: Retrieves the reflection module
- `hoot-module-instance`: Accesses the WebAssembly instance

## Type Predicates & Accessors

The module provides comprehensive type checking for Hoot heap objects:

**Numeric Types:** Complex numbers and fractions with accessor functions for components

**Collections:** Pairs, vectors, bytevectors, and bitvectors—each with length/reference operations and mutability variants

**Symbols & Keywords:** Type checking with name extraction capabilities

**Advanced Types:** Procedures, variables, atomic boxes, hash tables, weak tables, fluids, dynamic states, syntax objects, ports, and structs

## Procedure Operations

- `hoot-apply`: Executes Hoot procedures synchronously
- `hoot-apply-async`: Enables asynchronous execution with resolution/rejection callbacks
