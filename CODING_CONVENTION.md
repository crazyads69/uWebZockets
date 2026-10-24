# µWebZockets Coding Conventions

These conventions adapt the spirit of the Linux Kernel Coding Style to Zig 0.16.0, focusing on pragmatism, performance, and readability.

## 1. General Rules
- **No Emojis**: Emojis are strictly forbidden anywhere in the codebase, including documentation, comments, and commit messages.
- **`zig fmt`**: All code must pass `zig fmt`. While Linux style has specific brace rules, Zig's formatter is the final authority on indentation (4 spaces) and brace placement.
- **Short and Readable Comments**: Avoid telling *how* the code works; the code should be clear enough. Comment *why* a particular approach was taken, especially for non-obvious performance optimizations or network protocol edge cases.

## 2. Control Flow & Linux Style Adaptations
- **Early Returns & Minimal Indentation**: Prefer returning early to avoid deep nesting. Keep the "happy path" un-indented.
  ```zig
  // Bad
  if (condition) {
      // ... do work ...
  } else {
      return error.Failed;
  }

  // Good
  if (!condition) return error.Failed;
  // ... do work ...
  ```
- **Control Flow Spacing**: Put a space after keywords (`if`, `switch`, `while`, `for`).
- **Variable Scoping**: Declare variables as close to their first use as possible.
- **Switch Statements**: Use `switch` over long `if/else` chains. Exhaustive switching is a Zig strength; leverage it.

## 3. Data-Oriented Design (DoD) & Functional Programming
- **Zero Object-Oriented Programming (OOP)**: OOP is strictly forbidden. Do not try to emulate classes or bind hidden state to behavior. Separate pure data structures from the functions that transform them.
- **Pure Functions**: Favor pure functions that take explicit inputs and return explicit outputs without side effects. Pass state explicitly rather than relying on hidden contexts.
- **Data Locality**: Organize data for cache efficiency. Prefer Struct of Arrays (SoA) via `std.MultiArrayList` over Array of Structs (AoS) for large collections of entities processed in bulk.
- **Zero Allocations & Purity**: Network fast-paths must not allocate dynamically. Functional pipelines (e.g., map/filter concepts) must be implemented via zero-allocation iterators or comptime metaprogramming, never generating intermediate heap allocations.
- **Alignment and Padding**: Be conscious of struct sizes and padding. Order struct fields from largest to smallest to minimize padding, unless a specific memory layout is required for C interop or hardware constraints.

The rules above are mandatory and machine-checked where possible; see
[section 7](#7-functional-purity--anti-slop-enforcement-mandatory) for the
enforceable details.

## 4. Naming Conventions (Linux Style Override)
- **File Naming**: Linux file naming (`snake_case`) is strictly enforced for all files.
- **Functions & Variables**: `snake_case` is strictly enforced for all functions and variables to align with Linux kernel styling preferences, explicitly overriding standard Zig `camelCase`.
- **Types**: `PascalCase` for structs, enums, unions, and error sets (Standard Zig).
- **C Interop**: When wrapping C libraries (BoringSSL, libsquic), preserve the original C names in the raw bindings, but provide a clean `snake_case` Zig wrapper for the public API.

## 5. C Interop & FFI
- Use `@cImport` judiciously, or prefer translating C headers ahead-of-time using `translate-c` for better compilation speeds and type safety.
- Clearly separate raw C bindings from idiomatic Zig wrappers in the directory structure (e.g., `src/c/` or `src/ffi/`).

## 6. Error Handling
- Use Zig's native error sets (`!Type`).
- Never swallow errors silently. If an error is expected and ignored, document *why* with a comment.
- Use `catch unreachable` only when you can mathematically prove the error will never occur, and document the proof.

## 7. Functional Purity & Anti-Slop Enforcement (Mandatory)

These rules are enforced by `scripts/check_conventions.sh`, `zig fmt`, and code
review. A change that violates them is rejected, not negotiated.

### 7.1 Object Model
- Object-oriented programming is forbidden: no classes, `this`, inheritance,
  virtual dispatch, or behavior bound to hidden state. C++ or Objective-C is
  permitted only at vendor and FFI boundaries, never in Zig source.
- Zig structs are plain data. Functions transform data and receive every input
  explicitly; the receiver is just the first parameter.
- No container-level mutable state (`var` at file scope). The only exceptions
  are hardware or OS singletons, which must be documented and accessed
  atomically or under a lock.

### 7.2 Pure Functions
- Parsing, validation, encoding, and transition logic must be pure: identical
  inputs produce identical outputs with no I/O, allocation, logging, clock,
  random, or environment access.
- Effects belong at the boundary: event-loop callbacks, FFI shims, and `main`.
- A function may mutate caller-owned state only when that mutation is its
  documented purpose (for example `consume`); it must not hide additional
  effects.
- Prefer returning values over mutating globals or out-parameters that are not
  required for zero-allocation guarantees.

### 7.3 Explicit Types
- Do not use `anytype` in public or module-boundary APIs when the accepted type
  set is known. Name the type and use it (for example HTTP/2 event payloads).
- `anytype` is allowed only for genuinely polymorphic entry points such as
  `json_buf`, RPC `result`, and comptime builders. Each use must be covered by
  a concrete contract in the doc comment.
- Do not use `@TypeOf` or `@typeInfo` reflection to hide an unstated type
  contract.

### 7.4 No Console Logging
- `std.debug.print` is banned outside test code. Library diagnostics use
  `std.log.scoped(<module>)` with the correct severity.
- Library code must never write directly to stdout or stderr.
- Log messages include the operation and the error; bare `"error"` strings are
  not acceptable.

### 7.5 No Dead Code
- Delete unused files, functions, imports, constants, and commented-out code in
  the same change that makes them unused.
- No `TODO`, `FIXME`, `XXX`, or `HACK` markers. File an issue or land the fix.
- Every source file must be reachable from `src/root.zig`, a `build.zig` root,
  or the test suite.

### 7.6 Flat Control Flow
- Use guard clauses and early returns. Keep the happy path unindented.
- Control flow must not nest more than three levels inside a function. Extract a
  named helper instead of nesting deeper.
- Use `switch` for multi-way branching; never build long `if`/`else if` chains.

### 7.7 No Redundant Abstractions
- One layer of indirection is enough. A wrapper must add an invariant, a bound,
  or a type guarantee; otherwise inline it.
- No getters or setters that only forward a field. Public fields are fine.
- Do not add an abstraction to prepare for a use case that does not exist.

### 7.8 Error Discipline
- Errors flow outward. `catch {}` is allowed only for an explicitly best-effort
  operation and must carry a comment stating why it is safe to ignore.
- `catch unreachable` requires a written proof in the comment above it.
- Never swallow an error to satisfy the compiler.

### 7.9 Verification
- Run `zig fmt`, `sh scripts/check_conventions.sh`, and `zig build test` before
  requesting review.
- Reviewers verify that a change does not weaken these rules, delete or skip
  tests, or silence a lint. The lint gate is the quality contract.

## 8. Type Readability (Mandatory)

Readability wins over cleverness. A reader must understand a type without
reconstructing it from reflection, anonymous structure, or nesting.

- Every value that crosses a function boundary has a named type. Do not use an
  inline `struct { ... }` as a union payload, struct field, or collection
  element; declare a named alias with a one-line doc comment (`GoAwayEvent`,
  `ContextualRoute`).
- Function-pointer fields and parameters use named callback aliases
  (`CloseCallback`, `WsMessageCallback`). Optionality belongs on the field
  (`close: ?WsCloseCallback = null`), not inside the alias.
- Partial-update records are explicit named structs with optional fields
  (`ServerConfig.Overrides`), not `anytype` plus `@typeInfo`.
- Comptime specialization is limited to capacity and platform parameters
  (`freelist_pool`, `Scheduler`, `configured_service`). Do not build
  types through reflection when a named type can state the contract.
- Aliases are zero-cost. Never add a wrapper, vtable, or runtime indirection
  for readability alone.
- Do not alias primitives or plain slices. Alias anonymous or nested types, or
  a repeated compound type whose name states a protocol bound
  (`ControlFrameBuffer = [125]u8`).
- Extraction is additive: keep exported names, field names, and defaults
  stable. Renaming an exported symbol is a breaking change that needs a
  changelog entry and a migration note.
