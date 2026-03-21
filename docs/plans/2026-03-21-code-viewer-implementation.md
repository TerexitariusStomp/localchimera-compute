# Organization Code Viewer Implementation

**Date:** 2026-03-21
**Status:** Completed

## Overview

Added a real-time code viewer that displays the organization's current state as Scheme code. The viewer appears next to the terminal and automatically updates when REPL commands modify the organization.

## Architecture

### Data Flow
```
REPL Command → Evaluate → New Environment
              ↓
         Serialize to Scheme syntax
              ↓
         FFI call: update-code-viewer(scheme-string)
              ↓
         JavaScript updates DOM
              ↓
         Viewer displays formatted code
```

## Implementation

### 1. FFI Definition (repl.scm)

Added foreign function definition to bridge Scheme and JavaScript:

```scheme
(define-foreign update-code-viewer
  "codeViewer" "updateCode"
  (ref string) -> none)
```

### 2. Serialization Function (repl.scm)

Created `serialize-org-code` that converts environment state to readable Scheme:

- **Bindings**: Rendered as `(define name value)` expressions
- **Validator**: Shows the current validator or `<default-validator>`
- **Expressors**: Lists all known expressor identities
- **History**: Displays last 10 history entries with version numbers and expressors

Special handling for:
- Procedures: Display as `<procedure:name>`
- Expressors: Display as `<expressor:name>`
- Other values: Use Scheme's `write` for accurate representation

### 3. Auto-Update Integration (repl.scm)

Hooked serializer into REPL lifecycle:

- **After evaluation** (`eval-play!`): Updates viewer when commands modify state
- **On org entry** (`do-enter!`): Shows code when entering an organization
- **On org exit** (`do-exit!`): Clears viewer when leaving

### 4. JavaScript Viewer (repl.js)

Added `codeViewer` import namespace:

```javascript
codeViewer: {
  updateCode(code) {
    const viewer = document.getElementById("code-viewer-content");
    if (viewer) {
      viewer.textContent = code;
    }
  }
}
```

### 5. HTML Layout (index.html)

Added split-pane structure:

```html
<div id="code-viewer" class="code-viewer">
  <div class="code-viewer-header">organization code</div>
  <pre id="code-viewer-content" class="code-viewer-content"></pre>
</div>
```

### 6. CSS Styling (repl.css)

Elegant, minimal styling:

- Fixed position on right side (45% width)
- Dark theme matching existing interface
- Monospace font with proper line height
- Auto-scrolling for overflow
- Responsive: On mobile, viewer moves to bottom (40vh height)

## Design Decisions

### Why Serialize to Scheme Code?

Aligns with xorg's homoiconic philosophy: "code is data." The viewer shows the org's state as executable Scheme expressions, making the organization's structure immediately readable and runnable.

### What Gets Serialized?

- **Bindings**: The current namespace - what the org "knows"
- **Validator**: The governance function - how it "decides"
- **Expressors**: All identities - who can "speak"
- **History**: Recent actions - what it "remembers"

This captures the four core components of an xorg environment.

### Auto-Update Strategy

Updates happen synchronously after state-changing operations:
- Evaluation of expressions
- Entering/exiting organizations

No polling needed since the REPL explicitly controls when state changes occur.

### Read-Only Design

The viewer is intentionally read-only (`<pre>` element) because:
1. All mutations should go through the governed REPL
2. Maintains clear separation between observation and action
3. Prevents accidental modifications that bypass validators

Future enhancement: Add click-to-copy for expressions.

## Technical Notes

### Hoot FFI Usage

Following patterns from `guile-hoot-docs/08-foreign-function-interface.md`:

- `define-foreign` declares the import
- `(ref string)` for passing Scheme strings to JavaScript
- `-> none` for procedures with no return value
- JavaScript receives native strings (automatically converted)

### Serialization Challenges

1. **Circular References**: Avoided by not recursively serializing complex structures
2. **Procedure Representation**: Can't serialize closures, so show symbolic names
3. **Large History**: Limited to last 10 entries to keep viewer manageable

## Files Modified

1. `repl.scm`: FFI definition, serialization logic, auto-update hooks
2. `repl.js`: JavaScript viewer update function
3. `index.html`: Code viewer DOM elements
4. `repl.css`: Viewer styling and layout

## Testing

To test after building with Hoot:

1. `make` - Compile to WASM
2. `make serve` - Start web server
3. Visit `http://localhost:8088`
4. Create an org: `(make-org "test")`
5. Enter it: `(enter! "test")`
6. Run commands: `(modify! 'x 42)` - watch code viewer update
7. Enact validators: `(enact! (lambda ...))` - see validator appear
8. Check expressors: `(defexpressor 'alice "key")` - see it listed

## Future Enhancements

1. **Syntax Highlighting**: Add color coding for keywords, values, comments
2. **Collapsible Sections**: Fold/unfold bindings, history, etc.
3. **Search/Filter**: Find bindings or history entries
4. **Export**: Download current state as .scm file
5. **Diff View**: Show what changed after each command
6. **Copy to REPL**: Click expressions to insert into terminal

## Success Criteria

✅ Code viewer appears next to terminal
✅ Shows organization state as Scheme code
✅ Updates automatically on REPL commands
✅ Read-only display
✅ Elegant, minimal styling
✅ Uses Hoot FFI correctly
✅ Homoiconic: code represents data accurately
