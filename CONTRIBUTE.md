# Contributing to µWebZockets

µWebZockets accepts focused changes that preserve bounded resource use,
protocol correctness, and a shallow data-oriented design.

Read [CODEBASE.md](CODEBASE.md), [CODING_CONVENTION.md](CODING_CONVENTION.md),
and [CI_CD_PIPELINE.md](CI_CD_PIPELINE.md) before changing the transport or
protocol paths. Report security defects privately as described in
[SECURITY.md](SECURITY.md).

## Development environment

Use the pinned Nix shell when possible. Clone recursively when working on the
vendored h1spec compliance suite:

```sh
git clone --recurse-submodules https://github.com/farbenbuilds/uWebZockets.git
cd uWebZockets
nix develop
```

The flake pins Nixpkgs 26.05 and provides Zig 0.16.0 plus development tooling.
Every C and C++ dependency is fetched and compiled by Zig, so no CMake, Ninja,
Go, Perl, Python, `patch`, or zlib installation is required.

clangd users run `zig build clangd` after the first fetch. It writes a
gitignored `compile_flags.txt` at the repository root with the resolved include
roots for `src/c.h`, the lsquic shim, and the C ABI tests.

## Coding agent integrations

Codex and OpenCode use a repository-local Graphify integration. Install the CLI
with MCP support and build the ignored graph before querying it:

```sh
uv tool install "graphifyy[mcp]"
graphify extract . --code-only
```

Both assistants load the checked-in skills under `.codex/skills/graphify/` and
`.opencode/skills/graphify/`. The MCP entries in `.codex/config.toml` and
`.opencode/opencode.json` read `graphify-out/graph.json` relative to the
workspace root, so start the assistant from the repository root. After
upgrading the CLI, refresh both registrations:

```sh
graphify install --project --platform codex
graphify install --project --platform opencode
```

Codex loads the project `.codex/` layer only for trusted projects. Trust the
checkout once, then use `/hooks` to review the no-op Graphify hook.

Project skills live under `.agents/skills/` and are pinned by
`skills-lock.json`. Install or refresh them with `npx skills add ...`; do not
hand-edit a vendored `SKILL.md`. `AGENTS.md` routes architecture review, plan
grilling, strict maintainability review, and JS/TS anti-slop tooling, and its
project overrides take precedence over vendored defaults.

## Engineering requirements

- Do not allocate in request parsing, frame parsing, masking, routing, or
  network write callbacks. Allocate fixed application storage at startup.
- Cap every peer-controlled length, count, queue, and subscription.
- Prefer parallel arrays or compact slabs when a hot loop reads only a subset
  of fields. Do not force Struct of Arrays onto small one-off records.
- Keep parsing and validation functions pure where practical. Pass mutable I/O
  state explicitly at the event-loop boundary.
- Finish route registration before starting either listener; route arrays are
  immutable once `listen` or `listen_udp` succeeds.
- Keep route captures within the 16-slot request bound, parameter patterns
  within the 64-route bound, and middleware within its 32-entry fixed array.
- Treat asynchronous response tokens as event-loop-confined, exactly-once
  borrows. Marshal cross-thread completion back to the owning loop and test
  stale-token, double-completion, disconnect, and pipelining paths.
- Use early returns and short error paths. Never silently swallow an error.
- Follow [CODING_CONVENTION.md](CODING_CONVENTION.md) sections 7 and 8 in every
  edit: no OOP or hidden state, pure transformations at the core, explicit named
  types instead of `anytype` at module boundaries, named callback and event
  aliases instead of inline anonymous types, no `std.debug.print` outside
  tests, no dead code or TODO markers, and no forwarding wrappers.
- Use `snake_case` for project files, functions, and variables. Preserve raw C
  identifiers only at the FFI boundary.
- Keep comments concise and explain constraints or non-obvious tradeoffs.
- Do not add emoji characters anywhere in the repository.
- Put every ordinary Zig unit test under `src/tests/` and import it from
  `src/tests/main.zig`. Production modules must not import the centralized test
  root. The `src/tests/fuzz_main.zig` Smith corpus runs once in the ordinary
  suite and for the requested iteration count under `zig build fuzz`.
- Support cross-platform targets cleanly across Linux, macOS, Windows
  (`x86_64-windows-gnu` / MinGW ABI), FreeBSD, NetBSD, OpenBSD, and
  DragonFlyBSD. Ensure platform-specific I/O branches remain isolated to
  transport abstractions (POSIX and Windows IOCP via `libxev`).
- Downstream fixes for libxev, lsquic, and h1spec live as `uwz` commits on
  their maintained forks, never as local patches or upstream submissions.
  The upstream repositories are fetch-only. See
  [docs/dependency_forks.md](docs/dependency_forks.md).

## Local checks

Run all relevant checks before opening a pull request:

```sh
zig fmt --check build.zig src examples tests fuzz
sh scripts/check_conventions.sh
sh scripts/check_dependency_forks.sh
sh scripts/check_release_version.sh
sh scripts/check_package_paths.sh
zig build test --summary all
zig build test -Dsanitize=true -Doptimize=ReleaseSafe --summary all
zig build msan -Dmemory-sanitize=true -Doptimize=ReleaseSafe --summary all
zig build test-compile -Doptimize=ReleaseSafe --summary all
zig build fuzz --fuzz=100K -Doptimize=ReleaseSafe
zig build oss-fuzz-objects -Doptimize=ReleaseSafe --summary all
zig build oss-fuzz-smoke -Doptimize=ReleaseSafe --summary all
zig build lib -Doptimize=ReleaseFast --summary all
```

Sanitizer commands require native Linux; MemorySanitizer additionally requires
x86_64 and cannot be combined with `-Dsanitize=true`. `nix develop` exports
matching sanitizer, glibc, and dynamic-linker paths automatically. Non-Nix
setups must
pass `-Dsanitizer-lib-dir=/path/to/compiler/runtime/lib`. When that runtime
uses a different glibc than the host, also pass matching
`-Dsanitizer-libc-dir` and `-Dsanitizer-dynamic-linker` paths.

On Windows, compile the ReleaseSafe test graph plus the ReleaseFast library
build with `-Dtarget=x86_64-windows-gnu`; the bundled zlib package supplies the
MinGW static library.

Changes to WebSocket parsing or I/O must also run the Autobahn target. Changes
to HTTP parsing, dispatch, or response framing must run h1spec. Changes to
HTTP/2 or HPACK must exercise the centralized malformed-frame, flow-control,
Huffman, table-size, header-list, and pseudo-header tests. Changes to HTTP/3
must compile `http3_server`, exercise centralized QPACK/framing tests, and run
the pinned curl/ngtcp2 and aioquic cross-implementation gate. The exact CI
commands and report gate are documented in [CI_CD_PIPELINE.md](CI_CD_PIPELINE.md).

Tests should use fixed caller-owned storage for hot paths. If the unit under
test allocates, use `std.testing.allocator` or another leak-detecting allocator
and prove all success and error paths release ownership.

New external-byte parsers or framing transformations must have deterministic
Smith coverage and, when they form a network trust boundary, an
`LLVMFuzzerTestOneInput` target compatible with Google OSS-Fuzz. Add bounded
seed corpora, dictionaries where grammar tokens help, and a smoke driver that
runs without libFuzzer. FFI changes must preserve exact C layout checks, keep
`include/uWebZockets.h` synchronized with implemented exports, and include
malformed and capacity-exhaustion cases.

## Pull requests

- Explain the protocol, ownership, or performance invariant being changed.
- Include regression tests for bugs and malformed-input tests for parsers.
- Document API, limit, configuration, or compatibility changes.
- Separate measured performance results from estimates.
- Note breaking changes explicitly in the pull request and changelog.
- Assign the pull request to its owner and apply at least one existing
  repository label before requesting review. An unassigned or unlabeled pull
  request is not ready for review.
- Keep commits concise and follow
  [.github/COMMIT_CONVENTION.md](.github/COMMIT_CONVENTION.md).

## Dependency updates

For Zig dependencies, update all generated package views together:

- `build.zig.zon`
- `build.zig.zon.json`
- `build.zig.zon.nix`
- `build.zig.zon.txt`

Record the upstream version, immutable URL or revision, Zig package hash, Nix
hash, license, and any API migration. Rebuild from an empty Zig/vendor cache so
a stale artifact cannot hide a dependency problem.

### Maintained dependency fork updates

libxev, lsquic, and h1spec are maintained at
<https://github.com/farbenbuilds/libxev>,
<https://github.com/farbenbuilds/lsquic>, and
<https://github.com/farbenbuilds/h1spec>. Upstream `mitchellh/libxev`,
`litespeedtech/lsquic`, and `uNetworking/h1spec` are fetch-only: do not push,
open issues or pull requests, comment, or send patches there.

| Dependency | Integration branch | Current pin | Downstream ledger |
| --- | --- | --- | --- |
| libxev | `uwz/zig-0.16` | `cbf01bc432a84cd91a99c1cb1031b46416d044c7` | XEV-001, XEV-002 |
| lsquic | `uwz/main` | `85bd081c9103c077a7cc98271d09334d0f1043d4` | LSQ-001, LSQ-002 |
| h1spec | `uwz/main` | `999ba9e8f318b1c0ebbff1278b98bc5833f1af18` | H1S-001 |

For every maintained dependency:

1. Synchronize the fork mirror with a fast-forward merge, push it, then fetch
   the remote mirror and prove it resolves to the upstream default branch.
   Record any mirror-repair incident.
2. Fetch the integration branch, create a `sync/...-YYYYMMDD` branch from it,
   and merge the newest compatible upstream commit with `git merge --no-ff`.
   Keep the branch append-only from first push and keep downstream patches as
   `uwz(<area>): ...` commits with a ledger ID, upstream reference, invariant,
   test evidence, and retirement criterion.
3. Push the tested sync branch, open a PR to the integration branch, merge
   after gates, then fetch the resulting integration commit and record its
   archive or local bare mirror. Never leave a tested local commit unpushed.
4. Pin the full 40-hex commit:
   - libxev and lsquic: update `build.zig.zon`, regenerate all four zon views,
     compare the URL, revision, Zig hash, and Nix hash, and record the fork
     commit, upstream base, and hashes. Regeneration alone is not proof.
   - h1spec: update `.gitmodules` and the submodule gitlink, then verify the
     checked-out HEAD matches the gitlink. Do not apply a patch in CI.
5. Rebuild from an empty cache, run the owning gates, and update notices and
   provenance. Never rewrite a pinned commit; add a revert or follow-up commit.

For libxev, keep `uwz/zig-0.16` on the newest upstream commit compatible with
Zig 0.16.0 and run the native Windows runtime job. For lsquic, keep
`lsquic_versions_to_string.c` committed in the fork, run the HTTP/3
cross-implementation gate, and update the generated table with LSQ-002 when
the upstream version enum changes. For h1spec, run the compliance job from the
checked-out submodule and retire H1S-001 only when upstream performs the same
cleanup.

`scripts/check_dependency_forks.sh` verifies the libxev, lsquic, and h1spec
pins. Do not reintroduce `patches/`, `vendor/lsquic_overlay`, or a CI `patch`
step for a maintained dependency.

For C/C++ package sources, retain immutable commits and Zig package hashes,
native source lists, and static-library outputs. Keep lsquic's ls-qpack and
ls-hpack revisions synchronized with the pinned lsquic source. The
`vendor/h1spec` submodule remains a compliance input rather than a packaged
library dependency. Do not add global compiler or linker flags when
target-local settings work.

When bumping BoringSSL, libdeflate, or zlib, update the source list or flags in
the matching `builds/` module if upstream added or removed a translation unit.

## Releasing

1. Update all versioned surfaces and run `sh scripts/check_release_version.sh`.
2. Add a dated `CHANGELOG.md` section with breaking changes and limitations;
   do not leave an `Unreleased` placeholder in a final release snapshot.
3. Verify `THIRD_PARTY_NOTICES.md` and every packaged license. For any
   maintained fork pin, resolve the pinned commit from a second machine and
   against the retained archive.
4. Pass local formatting, convention, test, and build checks.
5. Pass ASan/UBSan/leak, MemorySanitizer, Smith fuzz, OSS-Fuzz object/smoke,
   Autobahn, h1spec, and HTTP/3 cross-implementation checks on the release
   commit.
6. Tag the final commit as `v<version>` and push the tag.
7. Confirm the release notes render the changelog, `scripts/check_package_paths.sh`
   passes on the release commit, and the tag resolves through `zig fetch` before
   announcing the release. Releases publish source only; there are no archives
   or `SHA256SUMS` to review.
