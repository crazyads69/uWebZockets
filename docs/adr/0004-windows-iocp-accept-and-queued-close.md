# 0004. Windows IOCP accept lifecycle and queued-close completion policy

- Status: Accepted; superseded in part by [ADR 0005](0005-libxev-fork.md)
- Date: 2026-10-19
- Deciders: transport/runtime, build/vendor, verification
- Release: 1.9.0

## Context

The v1.8.9 handoff left Windows runtime coverage blocked by two defects. The
first is upstream: after a successful `AcceptEx`, libxev returns the accepted
socket but does not clear `op.accept.internal_accept_socket`. A persistent
accept loop re-arms the completion, `start_completion` calls `AcceptEx` on the
already-connected socket, Winsock returns `WSAEINVAL (10022)`, and libxev
panics while mapping the unmapped code. The pinned revision
`9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf` was upstream `main` when this ADR
was accepted; upstream `main` is now
`451a2bc03644c2b70fb28a808313d12989bfa8e3` ("update to Zig 0.17", upstream
PR #249). No fixed revision or merged pull request exists for issue 252.

The second defect is in this repository. `Completion.state()` maps both
`.adding` (queued, not yet submitted) and `.active` to `.active`. When a
connection closes in the callback that queued its read or write, the Windows
close path cannot tell that the completion has not reached `CancelIoEx`. libxev
marks the unsubmitted target `.dead`, fires only the cancel callback, and the
connection keeps `read_active` or `is_writing` set, so the pool slot never
returns and shutdown reports `ShutdownIncomplete`.

## Decision

Carry the upstream accept fix as an auditable overlay instead of forking or
patching files inside `zig-pkg`:

- `patches/libxev_iocp_accept_socket.patch` is the reviewable diff against the
  pinned revision.
- `vendor/libxev_overlay/src/backend/iocp.zig` is the pre-generated applied
  result.
- `builds/targets/native.zig` copies the pinned dependency tree and replaces
  the single overlaid file before creating the `xev_impl` module, so a clean
  clone builds without `patch`, Perl, or a modified package cache.
- `scripts/check_vendor_overlay.sh` regenerates the overlay from the pinned
  source and fails if the pre-generated file drifts.
- `THIRD_PARTY_NOTICES.md` records the downstream modification.

Fix the local close path by submitting queued IOCP completions before canceling
them. `xev.submit` is a no-op on backends without a submission step; on IOCP it
moves `.adding` targets to `.active`, after which `CancelIoEx` reaches them and
the target callback clears `read_active` or `is_writing` exactly once. Other
platforms keep their existing paths.

Add a native `windows-2025` job to `windows.yml` that runs
`zig build test --summary all` in addition to the compile gates. The cluster TLS
tests already read the bound port through `ws2_32.getsockname` and bound client
reads with `SO_RCVTIMEO`, so they must execute rather than skip.

The upstream report is
<https://github.com/mitchellh/libxev/issues/252>.

## Alternatives considered

- **Wait for an upstream release**: rejected because upstream `main` still has
  the defect and Windows runtime coverage cannot make progress without the fix.
- **Fork libxev and pin the fork**: rejected because it hides the change in a
  second repository and makes the dependency views harder to audit.
  - 2026-10-24: superseded in part by [ADR 0005](0005-libxev-fork.md), which
    adopts `farbenbuilds/libxev` under a full-commit pin and a patch ledger.
    The overlay decision in this ADR remains in force until the migration
    lands.
- **Patch the fetched package in place**: rejected because the cache is shared,
  content-addressed, and not part of a clean-clone build.
- **Submit before every close on every backend**: rejected as unnecessary
  churn. Only IOCP queues completions this way; POSIX backends start or register
  operations during `add`, and kqueue cancellation is already a documented
  no-op.

## Consequences

- Windows builds use a patched libxev source without changing the package hash
  or the four dependency manifests; the audit patch and overlay are the source
  of truth.
- The accept loop allocates one fresh accept socket per re-arm on Windows and
  never passes a connected socket back to `AcceptEx`.
- A queued read or write canceled by the same callback that created it can no
  longer strand a pool slot.
- Historical trigger (2026-10-19): when upstream merges the fix, delete the
  overlay and patch, move the pin to the fixed revision, update every
  dependency view and hash, and rerun the native Windows job. ADR 0004 then
  becomes historical. The 2026-10-24 note below and ADR 0005 now govern
  retirement.
- 2026-10-24: [ADR 0005](0005-libxev-fork.md) adopts the maintained fork. The
  overlay remains in force until the migration lands, and retirement now
  follows the fork `uwz/zig-0.16` integration branch rather than an upstream
  release.
- Windows is promoted from compile-only to runtime-supported only when the
  native job is green for the release commit.

## References

- `docs/roadmap.md` Windows runtime blocker details.
- `src/core/tcp.zig`, `src/core/xev.zig`, `builds/targets/native.zig`.
- `patches/libxev_iocp_accept_socket.patch`,
  `vendor/libxev_overlay/src/backend/iocp.zig`.
- `.github/workflows/windows.yml`, `CI_CD_PIPELINE.md`.
