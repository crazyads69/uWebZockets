---
name: uwebzockets-workflow
description: Master high-performance workflow integrating all specialized skills for the µWebZockets project.
---

# µWebZockets High-Performance Master Workflow

This document outlines the unified workflow combining the specialized skills in
`.agents/skills/*` with the repository-local `graphify` integration to build a
blazingly fast, zero-allocation WebSocket/HTTP library.

Route work by phase (`using-agent-skills`): load the narrowest skill set that
fits the current step and never stack processes that do not apply.

## 1. Mindset & Optimization (`ponytail`, `caveman`, `dod`, `functional-programming-fundamentals`)
- **Functional & Pure (No OOP)**: Zero Object-Oriented Programming allowed. Emphasize pure functions, explicit state passing, and immutability where it doesn't cost performance. Never bind state and behavior into "classes".
- **Anti-Slop Gate**: `CODING_CONVENTION.md` sections 7 and 8 are mandatory. No `anytype` at module boundaries when the type set is known, no inline anonymous union payloads or callback fields, no `std.debug.print` outside tests, no dead code or TODO markers, no forwarding wrappers, and no weakening of lints or tests. Run `sh scripts/check_conventions.sh` before review.
- **Data-Oriented Design (`dod`)**: Performance starts with memory. Group data by access pattern, not by object. Use Struct of Arrays (SoA) to maximize CPU cache utilization and minimize pointer chasing. Functional pipelines must operate over these DOD-optimized structures without allocating.
- **Ponytail Mode (`ponytail`)**: Embrace extreme laziness and simplicity. Ask "Do we even need this?" before writing any code. Prefer native Zig language features over dependencies. Keep solutions minimal.
- **Caveman Mode (`caveman`)**: Keep communication dense and concise. High signal-to-noise ratio in documentation, commit messages, and PRs.

## 2. Core Architecture (`zig-0.16`)
- **Zero-Allocation Hot Paths**: The request/response cycle must not allocate memory dynamically. Allocate contiguous fixed-capacity connection, message, and output storage during application startup and reuse it for every callback.
- **Event Loop & IO**: Utilize `mitchellh/libxev` for a robust, cross-platform, non-blocking event loop.
- **Parsing**: Leverage the pinned `farbenbuilds/zslay` 0.2.1 frame state
  machine and keep µWebZockets' handshake, message, and UTF-8 limits explicit.
- **Zig 0.16 Primitives (`zig-0.16`)**: Strictly adhere to the latest `std.io` patterns and deprecations.

## 3. Implementation & Build (`zig-best-practices`, `zig-comptime`, `zig-build-system`)
- **Idiomatic Zig (`zig-best-practices`)**: Follow standard Zig naming, error handling (native error sets), and explicit memory management. Combine with our Linux-style coding conventions (early returns, minimal indentation, and strictly Linux file naming `snake_case`).
- **Compile-Time Evaluation (`zig-comptime`)**: Use `comptime` for application capacities, storage sizing, and specialization. Keep route lookup in the fixed-capacity runtime radix structure so applications can register routes during startup.
- **Build Infrastructure (`zig-build-system`, `nix-best-practices`)**: Write lean `build.zig` scripts. Utilize Nix for reproducible developer environments to ensure identical cross-platform builds.

## 4. FFI, C/C++ Ecosystem & Cross-Compilation (`zig-cinterop`, `zig-cross`, `gcc`, `c-systems-programming`, `cpp-coding-standards`, `cpp-modules`)
- **C Interoperability (`zig-cinterop`)**: Integrate `BoringSSL`, `lsquic`, `libdeflate`, and `zlib`. Prefer using `translate-c` to convert headers to Zig for improved type safety and faster compilation over raw `@cImport`.
- **C/C++ Build Orchestration (`gcc`, `c-systems-programming`)**: Compile pinned C and C++ dependencies directly with Zig's `zig cc` and `zig c++` toolchain from `builds/*.zig` source lists. Keep generated artifacts pre-generated under `vendor/` so no external generator runs at build time.
- **Low-Level C/C++ (`c-systems-programming`, `cpp-coding-standards`, `cpp-modules`)**: Apply strict modern C/C++ standards when modifying or wrapping any native code, utilizing C++20 modules where applicable, and understanding low-level OS interaction.
- **Targeting (`zig-cross`)**: Ensure the library can cross-compile flawlessly to diverse target architectures using Zig's native cross-compilation toolchain.

## 5. Debugging & QA (`zig-testing`, `zig-debugging`, `zig-compiler`)
- **Zero-Leak Testing (`zig-testing`)**: Use `std.testing.allocator` whenever the code under test owns allocations. Exercise fixed-buffer paths with caller-owned storage, malformed-input corpora, Autobahn, and h1spec compliance tests.
- **Compiler Optimization (`zig-compiler`)**: Distinguish between `ReleaseFast` and `ReleaseSafe`. Always ensure safe runtime checks during development, optimizing to `ReleaseFast` only for proven hot paths.

## 6. Engineering Process (`using-agent-skills`, `interview-me`, `idea-refine`, `spec-driven-development`, `planning-and-task-breakdown`, `incremental-implementation`, `test-driven-development`, `context-engineering`)
- **Route first (`using-agent-skills`)**: Identify the phase before acting; a bug fix does not need a spec, a new protocol surface does.
- **Refine the ask (`interview-me`, `idea-refine`)**: When a requirement is underspecified, close the gap before designing anything.
- **Spec the contract (`spec-driven-development`)**: For new surfaces write the observable contract first: capacities, error names, ownership, RFC clauses, platform matrix.
- **Slice the work (`planning-and-task-breakdown`, `incremental-implementation`)**: Land thin, verifiable slices; never mix a refactor with a protocol change.
- **Prove behavior (`test-driven-development`)**: New behavior starts as a failing test under `src/tests/`; bug fixes start as a failing reproduction. RED, then GREEN, then refactor, using the project's own commands.
- **Engineer context (`context-engineering`)**: Keep sessions scoped; reload `AGENTS.md`, `CODEBASE.md`, and the owning module before cross-cutting edits.

## 7. Quality, Security & Performance (`code-review-and-quality`, `doubt-driven-development`, `debugging-and-error-recovery`, `security-and-hardening`, `performance-optimization`, `observability-and-instrumentation`, `code-simplification`, `constraint-driven-development`)
- **Review before merge (`code-review-and-quality`)**: check correctness, ownership, tests, docs, and gate integrity, in that order.
- **Doubt the hard parts (`doubt-driven-development`)**: Crypto, C ABI, framing, completion ordering, and release changes get a fresh-context adversarial pass before landing.
- **Debug to root cause (`debugging-and-error-recovery`)**: reproduce, isolate, fix, and prevent; never paper over a failure with a retry.
- **Harden (`security-and-hardening`)**: threat-model every input boundary (TLS, HTTP, WebSocket, QUIC, C ABI) for smuggling, injection, replay, timing, and exhaustion; fail closed.
- **Measure (`performance-optimization`)**: prove hot-path claims with the benchmark contract and allocator evidence, never with assertions.
- **Instrument (`observability-and-instrumentation`)**: counters and timers stay zero-cost when disabled and truthful when enabled.
- **Simplify (`code-simplification`, `ponytail`)**: prefer the smallest correct change; delete code before adding it.
- **Guard the bar (`constraint-driven-development`)**: never lower a gate, threshold, or baseline to land a change.

## 8. Delivery & Documentation (`api-and-interface-design`, `source-driven-development`, `documentation-and-adrs`, `deprecation-and-migration`, `git-workflow-and-versioning`, `ci-cd-and-automation`, `shipping-and-launch`)
- **Design interfaces (`api-and-interface-design`)**: public surfaces are contracts: fixed capacities, explicit ownership, specific error names, additive evolution.
- **Cite sources (`source-driven-development`)**: ground RFC and upstream API decisions in the pinned specs and headers, not memory.
- **Record decisions (`documentation-and-adrs`)**: non-obvious choices land in `CODEBASE.md`, `docs/`, or `CHANGELOG.md`, not buried in code comments.
- **Migrate deliberately (`deprecation-and-migration`)**: removals ship with a migration path, a changelog entry, and a consumer rebuild.
- **Version atomically (`git-workflow-and-versioning`)**: one logical change per commit, conventional prefixes, synchronized version surfaces.
- **Automate (`ci-cd-and-automation`)**: workflows stay pinned, deterministic, and cache-correct; never weakened to pass.
- **Ship (`shipping-and-launch`)**: releases follow the documented checklist, and rollback precedes announcement.

## 9. Knowledge Graph (`graphify`, Codex and OpenCode)
- Ask the graph first: for architecture, file-relationship, or "how does X work" questions, use the `graphify` MCP tools or `graphify query` against `graphify-out/graph.json` instead of re-scanning the tree.
- Rebuild only on explicit request (`/graphify`); never regenerate the graph as a side effect of a scoped code change.
- `graphify-out/` is generated and git-ignored; do not commit it.
- Treat graph answers as navigation hints and confirm behavior in the source.
