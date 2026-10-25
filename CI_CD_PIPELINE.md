# µWebZockets CI/CD Pipeline

The pipeline verifies formatting, bounded protocol behavior, multiple
optimization modes, standards compliance, cross-target compilation, and
release metadata. A passing pipeline is evidence for the tested configurations;
it is not a proof that all memory or security defects are absent.

## Workflows

| Workflow | Trigger | Environment | Purpose |
| --- | --- | --- | --- |
| `lint.yml` | pushes and pull requests to `main`, manual | `Linting` | Zig formatting and repository conventions |
| `test.yml` | pushes and pull requests to `main`, manual | `Testing` | Parallel Debug, sanitizer, fuzz, ReleaseSafe, and ReleaseFast verification |
| `windows.yml` | manual, reusable from tagged publishing | `Testing` | Native `x86_64-windows-gnu` ReleaseSafe compilation, static-library build, and runtime test suite |
| `oss_fuzz.yml` | pushes and pull requests to `main`, manual, reusable | `Testing` | OSS-Fuzz-compatible ASan/libFuzzer build and execution |
| `autobahn_compliance.yml` | pushes and pull requests to `main`, manual | `autobahn Compliance` | RFC 6455 server compliance |
| `h1spec_compliance.yml` | pushes and pull requests to `main`, manual | `h1spec Compliance` | HTTP/1.1 compliance |
| `http3_compliance.yml` | pushes and pull requests to `main`, manual | `HTTP3 Compliance` | curl/ngtcp2 and aioquic HTTP/3 interoperability |
| `benchmark.yml` | pull requests to `main`, nightly, manual | `Benchmarking` | HTTP throughput regression |
| `dependency_mirrors.yml` | weekly, manual | `Linting` | Exact live equality of every maintained fork mirror |
| `publish.yml` | `v*` tag push | `Publish` | Exact-tag verification and seven-target static-library release |

Every workflow uses a GitHub environment so repository deployments and any
environment protection rules remain visible in GitHub.

`test.yml`, `autobahn_compliance.yml`, and `h1spec_compliance.yml` share the
`.github/actions/setup-build` composite action. It caches the Zig global package
cache and the content-addressed local build cache under a
per-optimization-mode key, so a cache hit reuses the compiled BoringSSL,
lsquic, libdeflate, and zlib objects instead of rebuilding them. `benchmark.yml`
uses the same approach for its candidate and baseline checkouts.

## Lint

The lint job installs Zig 0.16.0 directly instead of entering the Nix
development shell, and uses the runner's ripgrep for the convention scan
(installing it only if absent). It runs:

```sh
zig fmt --check build.zig src examples tests fuzz
sh scripts/check_conventions.sh
sh scripts/check_dependency_forks.sh
sh scripts/check_release_version.sh
sh scripts/check_docs.sh
```

The convention scanner checks project source filenames, Zig function and
variable names, and text files for prohibited emoji code points. Vendored
sources are excluded because their upstream conventions are preserved. The
dependency-fork check resolves the libxev and lsquic commits, verifies the
h1spec submodule gitlink, and rejects branches, tags, short SHAs, local
patches, and stale overlays. The release metadata check keeps the Zig package,
Nix package, C ABI, tests, changelog, and versioned documentation synchronized.
The documentation link check resolves every relative Markdown target in the
top-level documents and `docs/**/*.md` against the checkout, ignoring external
URLs, anchor-only targets, and fenced code blocks.

## Unit and build verification

The test workflow fans the checks out into parallel jobs: Debug tests, ASan and
UBSan, MemorySanitizer, ReleaseSafe compilation, the downstream package
consumer, the bounded fuzz run, and ReleaseFast artifacts. Each job checks out
the h1spec submodule and restores the shared build cache before entering the Nix
development shell. A final `Checks & Tests` job aggregates the parallel results,
so one status reflects the whole workflow. The jobs run:

```sh
zig build test --summary all
zig build test -Dsanitize=true -Doptimize=ReleaseSafe --summary all
zig build msan -Dmemory-sanitize=true -Doptimize=ReleaseSafe --summary all
zig build test-compile -Doptimize=ReleaseSafe --summary all
zig build fuzz --fuzz=100K -Doptimize=ReleaseSafe
zig build oss-fuzz-objects -Doptimize=ReleaseSafe --summary all
zig build lib -Doptimize=ReleaseFast --summary all
(cd tests/package_consumer && zig build check -Doptimize=ReleaseSafe)
sh scripts/check_package_paths.sh
```

`scripts/check_package_paths.sh` reconstructs the package from the `.paths`
entries in `build.zig.zon`, fetches that copy with `zig fetch`, and compiles the
same downstream fixture from the fetched package. The path dependency above
exercises the module; the clean-package check also proves the manifest carries
every file the build reads.

Debug tests cover parser limits, malformed framing, partial reads and writes,
pool ownership, router method behavior, handshake validation, close codes,
fragmentation, streaming UTF-8, SIMD masking, pub/sub cleanup, and large
WebSocket messages. Code that allocates in tests uses leak-detecting test
allocators where applicable. Most hot-path tests use caller-provided fixed
storage and therefore allocate nothing to begin with.

ReleaseSafe compiles the same test graph with safety checks and optimization.
ReleaseFast proves the production static-library graph and all pinned C/C++
dependencies compile at the speed-oriented mode. The downstream fixture proves
that the published Zig package can be consumed through `b.dependency` without
repository-relative vendor paths.

The sanitizer pass is native Linux only. The Nix shell supplies matching LLVM
sanitizer, glibc, and dynamic-linker paths. `build.zig` sets coherent RPATHs
and launches sanitizer executables through that matching loader, instruments
BoringSSL, lsquic, libdeflate, zlib, and the local C ABI shim with ASan/UBSan, enables
Zig's full C-UB checks, preserves frame pointers, and isolates the vendor cache.
CI enables ASan leak detection and makes both ASan and UBSan fail fast. A
separate x86_64 Linux pass rebuilds the pinned C/C++ dependencies and local C
shim with MemorySanitizer and origin tracking, then runs a focused C
dependency-boundary smoke. It does not instrument Zig code or execute the full
C ABI suite, and MSan cannot be combined with ASan. Full-suite MemorySanitizer
coverage of the TLS and cluster paths stays out of scope while BoringSSL is
built uninstrumented; the dependency-boundary smoke remains the MSan contract.
The in-tree test runs set `use_sigaltstack=0` for sanitizer builds, because
ASan's thread teardown munmaps whichever alternate signal stack it finds and
Zig's thread-local stack is not page aligned; leak detection and halt-on-error
stay enabled.

### MemorySanitizer contract (permanent, 2026-10-19)

The dependency-boundary smoke is the permanent MemorySanitizer contract, not an
interim placeholder. Zig 0.16 emits no MSan instrumentation for Zig code, and
instrumenting BoringSSL would require building and maintaining a second TLS
toolchain whose runtime and allocator behavior differ from the shipped one.
The current gate therefore rebuilds the pinned C/C++ dependencies and the local
C shim with MSan and origin tracking, then runs the focused boundary smoke. It
does not claim full-suite MSan coverage of the TLS or cluster paths.

Changing this contract requires a new milestone and an ADR that supplies a
toolchain emitting Zig MSan instrumentation, a supported instrumented BoringSSL
build, and a full-suite run. The decision is repeated in
[docs/deployment.md](docs/deployment.md#6-platforms) and linked from
[docs/roadmap.md](docs/roadmap.md).

The fuzz job runs Zig's native fuzzer for 100,000 iterations over bounded
HTTP, HTTP/3 metadata, WebSocket extension, and zslay receive-state targets.
Seed corpora include valid, fragmented, malformed, and control-frame inputs.
It separately compiles the five sanitizer-coverage libFuzzer objects used by
OSS-Fuzz for HTTP framing, WebSocket masking, QUIC packet boundaries, query
parsing, and cookie parsing.

## OSS-Fuzz compatibility

The reusable `oss_fuzz.yml` workflow uses ClusterFuzzLite, so it does not
assume or claim enrollment in the hosted OSS-Fuzz service. Its external-project
Docker build copies the exact revision under test, verifies the Zig 0.16.0
archive checksum, builds all five `LLVMFuzzerTestOneInput` entrypoints, links
them with the OSS-Fuzz-provided Clang flags and libFuzzer engine, and retains
all targets for the bad-build check. A bounded batch then executes every target
in the OSS-Fuzz runner environment.

The fuzz-target metadata enables address builds only. Zig 0.16 emits sanitizer
coverage for these objects and `ReleaseSafe` keeps Zig safety checks, but
Clang's flags do not instrument Zig-generated loads and stores. The workflow
therefore does not claim standalone UBSan or MSan instrumentation; those names
refer only to the separate C/C++ dependency checks described above.

## Autobahn WebSockets compliance

The Autobahn job builds `autobahn_server` in ReleaseSafe, then the Deno runner
starts it, waits until port 9001 is accepting connections, and launches the
digest-pinned
`crossbario/autobahn-testsuite:0.8.2@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074`
container as a fuzzing client. The runner uses Deno's native process API and
has no runtime JavaScript dependencies. It always terminates the server, and
the container writes reports as the invoking POSIX user so repeated local runs
can replace them safely. It runs the base protocol cases together and each
compression dataset in a fresh container, then merges their results before
checking the complete baseline. A batch killed with exit code 137 is retried
once from a clean report directory and a fresh server process; protocol failures
and repeated kills fail immediately. The workflow uploads every batch's
HTML/JSON report plus the merged JSON report even when the gate fails.

The configuration selects groups 1-7, 9-13 with no exclusions. The report gate
requires the verified 1.0.0 aggregate baseline: all 517 cases, with 514 `OK`
and 3 `INFORMATIONAL` results for both protocol and close behavior. Any failed,
`NON-STRICT`, missing, additional, or reclassified result fails the job. RFC
7692 groups 12 and 13 pass through negotiated no-context-takeover per-message
deflate; no case is excluded or suppressed.

## h1spec compliance

The h1spec job builds the HTTP target in ReleaseSafe, waits for port 8000, and
runs the pinned repository submodule with Deno. On failure it uploads the
server log. Deterministic HTTP adversarial cases also remain in the Zig unit
suite so malformed-input coverage does not depend solely on an external tool.

## Cross-target checks

`flake.nix` defines native GNU or macOS packages and Linux musl packages. Its
Nixpkgs input is pinned to the 26.05 release so all four supported host systems,
including x86_64-darwin, remain evaluable. Checks compile tests for both native
and musl targets without attempting to execute foreign binaries. The native
targets are:

- x86_64-linux-gnu
- x86_64-linux-musl (compile check)
- aarch64-linux-gnu (compile check)
- aarch64-linux-musl (compile check)
- x86_64-macos
- aarch64-macos

Releases publish source tags only: no per-platform static-library archives are
built or uploaded, and consumers use `zig fetch` so their own toolchain builds
the pinned dependencies.

The reusable Windows workflow runs separately on `windows-2025`. It installs
the exact Zig release, compiles the ReleaseSafe test and C ABI graph plus the
ReleaseFast static libraries, and runs `zig build test --summary all` in a
second native job. Windows remains compile-checked in the support claim until
that runtime job is green for the release commit; no Windows binaries are
published.

The 1.9.0 work removes both runtime blockers. The pinned libxev fork carries
XEV-001, which clears `internal_accept_socket` on the success and error paths,
so a re-armed accept allocates a fresh socket instead of calling `AcceptEx` on
a connected one. The transport submits queued IOCP
completions before canceling them, so a connection closed in the callback that
queued its read or write reaches `CancelIoEx` and its target callback clears
`read_active`/`is_writing`. The decision and rollback path are in
[ADR 0004](docs/adr/0004-windows-iocp-accept-and-queued-close.md); the blocker
history is in
[docs/roadmap.md](docs/roadmap.md#windows-runtime-blocker-details). The cluster
TLS tests read the bound port through `ws2_32.getsockname` and bound one client
read with `SO_RCVTIMEO`, so they execute on the native job rather than skip.

The default build also compiles the bounded `http3_server` example. The HTTP/3
gate drives it independently with pinned curl/ngtcp2/nghttp3 and aioquic,
checks valid requests and trailers plus duplicate pseudo-header, pseudo-header
ordering, and connection-specific header rejection cases. Each malformed
request must receive `H3_MESSAGE_ERROR` while a concurrent sibling succeeds on
the same connection; a final health request then verifies continued service.
The gate retains server logs, traces, versions, results, and qlogs. The
runner generates a one-run localhost certificate in a private temporary
directory and deletes its key during cleanup, so clean checkouts do not depend
on ignored developer certificates.

## Maintained dependency provenance

`build.zig.zon` pins the maintained forks
<https://github.com/farbenbuilds/libxev> at
`cbf01bc432a84cd91a99c1cb1031b46416d044c7` on `uwz/zig-0.16` and
<https://github.com/farbenbuilds/lsquic> at
`85bd081c9103c077a7cc98271d09334d0f1043d4` on `uwz/main`. The h1spec
submodule points at <https://github.com/farbenbuilds/h1spec> commit
`999ba9e8f318b1c0ebbff1278b98bc5833f1af18` on `uwz/main`. The libxev ledger
carries XEV-001 and XEV-002; lsquic carries LSQ-001 and LSQ-002; h1spec carries
H1S-001 ([ADR 0005](docs/adr/0005-libxev-fork.md),
[ADR 0006](docs/adr/0006-dependency-forks.md)). `patches/` and
`vendor/lsquic_overlay` are deleted.

CI verifies every pin with `scripts/check_dependency_forks.sh`, including the
libxev and lsquic URL, revision, Zig hash, and Nix hash across all four views,
the h1spec `.gitmodules` URL and gitlink, remote resolution of every full
commit, integration-branch ancestry, and the reviewed mirror record in
`scripts/dependency_mirrors.env`. Branches, tags, and short SHAs are rejected.
Exact live upstream equality runs in the release workflow and the weekly
`Dependency Mirrors` workflow via `--exact-mirrors`. Regeneration alone is not
proof because `scripts/update_zon_files.sh` can skip when zon2nix or nix is
absent. Lint also
runs the stale-phrase grep. Before release, resolve every pinned commit from a
second machine and against the retained archive or local bare mirror. Release
and benchmark provenance record the fork commits and their upstream bases;
tags are never authoritative. Every mirror and integration branch requires
branch protection; mirrors are exact read-only mirrors and integration
branches are append-only. The normative procedure and patch ledger are in
[docs/dependency_forks.md](docs/dependency_forks.md).

## Performance regression

The benchmark workflow checks the pull request and its `main` base out into
separate directories, then builds each checkout from its own working directory
with ReleaseFast on the same Ubuntu runner. Both checkouts restore the shared
benchmark build cache, and the pull-request trigger is limited to
build-relevant paths so documentation-only changes do not spend a runner on the
comparison. Candidate and baseline builds use
three bounded attempts with 10- and 20-second backoff so a transient immutable
dependency fetch does not discard the comparison.

The versioned [`http-throughput-v1`](benchmarks/http_throughput_guarantee.md)
contract runs three 10-second `wrk` samples against each `hello_world` server,
compares median requests per second, and fails when the candidate falls below
90 percent of the baseline. Pull-request raw reports remain available as
30-day workflow artifacts. Scheduled and manual mainline runs additionally
append the canonical JSON record and raw evidence to the durable
`benchmark-data` branch. Records include runner, toolchain, source, flake-lock,
and contract provenance and are described by the published v1 schema.

The tolerance accounts for shared-runner variance. This is an explicit relative
regression guarantee, not a portable absolute-capacity claim; absolute history
must only be compared within matching runner and toolchain cohorts.

The separate [`h2-tls-scaling-v1`](benchmarks/h2_tls_scaling_guarantee.md)
contract characterizes HTTP/2-over-TLS at 64 through 2,048 connections against
the single-application, plaintext-cluster, and TLS-cluster controls. It ships
with `scripts/benchmark_h2_tls.sh`. The 1.9.0 characterization ran the full
sweep on the repository host and stored raw artifacts, host metadata, and the
filled hypothesis table under
[`benchmarks/results/h2_tls_scaling_v1/2026_10_19/`](benchmarks/results/h2_tls_scaling_v1/2026_10_19/README.md).

The contract remains intentionally out of `benchmark.yml`: shared runners
cannot satisfy the quiet-host evidence contract, and mixing their numbers with
the dedicated-host series would be invalid. When a dedicated quiet runner
exists, add a `workflow_dispatch`-only, non-gating job that uploads raw
artifacts and records provenance; never compare its numbers to shared runners.
`http-throughput-v1` remains the only CI-enforced performance guarantee.

## Publishing

A `v*` tag gates four release phases.

1. A native verification job checks formatting and conventions, runs the
   centralized Debug and ASan/UBSan suite plus the MSan dependency-boundary
   smoke, compiles ReleaseSafe tests and all OSS-Fuzz objects, and builds the
   downstream package consumer from the exact tagged source. The reusable
   Autobahn, h1spec, HTTP/3, and OSS-Fuzz compatibility workflows run in
   parallel against that same tag. Release creation cannot start until all five
   verification paths pass.
2. The tag must be valid Semantic Versioning and match the Zig package,
   centralized Nix version, C ABI macros/string, C/C++ smoke tests, changelog,
   and versioned documentation before the release job runs.
3. The release job enters the `Publish` environment, extracts the matching
   changelog section, and creates or updates the GitHub release through `gh`
   with the title `uWebZockets v<version>`. Versions containing a hyphen are
   marked as prereleases; stable versions are marked latest.
4. Releases carry no binary assets: the tagged source is the distribution, and
   consumers fetch it with `zig fetch` so the package manager builds the
   pinned dependencies.

Release notes are idempotent: rerunning a tag workflow refreshes the notes for
the same tag.

## Release checklist

- Update all release surfaces and run `sh scripts/check_release_version.sh`.
- Run formatting, convention, and documentation link checks.
- Run Debug tests and ReleaseSafe/ReleaseFast build checks.
- Run the native Linux ASan/UBSan/LeakSanitizer and MSan passes.
- Run the ClusterFuzzLite bad-build check and bounded batch for all five
  OSS-Fuzz targets.
- Run Autobahn and h1spec compliance.
- Verify third-party revisions and licenses. For a libxev fork pin, resolve the
  pinned commit from a second machine and against the retained archive.
- Create and push `v<version>` only after the release commit is final.
- Confirm the release notes render the changelog and the tag resolves through
  `zig fetch`; there are no archives or checksums to review.

The benchmark workflow is advisory for release tags because it runs on pull
requests and nightly rather than on `publish.yml`. Performance claims must cite
the retained configuration and raw results.
