# JavaScript Reflection in Guile Hoot

## Core Runtime Class

The `Scheme` class manages Hoot binary loading and reflection initialization.

## Static Method: `load_main`

"Fetch and execute the Hoot Wasm binary at the URL source and return an array of Scheme values produced by the program."

**Parameters:**
- `source`: URL, typed array, or ArrayBuffer containing Wasm binary
- `abi`: Application binary interface (set to `{}` for first binary)
- `reflect_wasm_dir`: Directory for helper modules (default: ".")
- `user_imports`: Object mapping imported function names to implementations

**Example usage:**
```javascript
Scheme.load_main("hello.wasm", {
  user_imports: {
    document: {
      createTextNode: Document.prototype.createTextNode.bind(document)
    }
  }
});
```

## Instance Method: `load_extension`

Loads additional Hoot binaries sharing the same ABI, with optional user-defined imports.

## Reflected Scheme Types

All fundamental Scheme types have associated JavaScript classes. The `repr()` function returns Scheme-like string representation.

### Primitive Types
- `Char`: Unicode character
- `Eof`: End-of-file marker
- `Null`: Empty list
- `Unspecified`: Unspecified value
- `Complex`: Complex numbers
- `Fraction`: Exact fractions

### Heap Objects

Parent class `HeapObject` contains a `reflector` property referencing the `Scheme` instance, enabling extension loading.

**Procedure types:**
- `Procedure`: Invoked via `call()` or `call_async()` methods
- `Pair`, `MutablePair`: Cons cells
- `Vector`, `MutableVector`: Arrays
- `Bytevector`, `MutableBytevector`: Byte sequences
- `Bitvector`, `MutableBitvector`: Bit sequences
- `MutableString`, `Sym`, `Keyword`: Text types
- `Variable`, `AtomicBox`: Mutable storage
- `HashTable`, `WeakTable`: Hash structures
- `Fluid`, `DynamicState`: Dynamic variables
- `Syntax`: Syntax objects
- `Port`: I/O ports
- `Struct`: User-defined structures
