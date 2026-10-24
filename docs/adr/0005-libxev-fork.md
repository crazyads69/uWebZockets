# 0005. libxev downstream fork policy

- Status: Accepted
- Date: 2026-10-24
- Deciders: build/vendor, transport/runtime, verification
- Release: unreleased (next libxev dependency update; update during migration)

## Context

ADR 0004 carried the Windows IOCP `AcceptEx` ownership fix as an audit patch
plus a pre-generated overlay rather than forking or editing `zig-pkg`. That
choice kept the package hash unchanged and made the current defect visible,
but an overlay only mirrors one upstream file. It has no durable history for
multiple downstream patches, no branch relationship to upstream, and no
general way to carry a compatible fix that upstream has not released.

The constraints have not resolved in the overlay's favor:

- Upstream issue <https://github.com/mitchellh/libxev/issues/252> remains open,
  so no upstream release contains the AcceptEx ownership fix.
- The project remains on Zig 0.16.0. Upstream `main` at
  `451a2bc03644c2b70fb28a808313d12989bfa8e3` ("update to Zig 0.17", upstream
  PR #249) is not compatible with this project's Zig 0.16.0 build, although
  upstream manifest metadata still declares a 0.16.0 minimum. Following
  upstream `main` would break the pinned toolchain.
- `farbenbuilds/libxev` is already a GitHub fork of `mitchellh/libxev`. Its
  default branch `main` exactly mirrors upstream `main` at `451a2bc`, but it
  has no integration branch or tags yet.
- Windows IOCP accept ownership is a downstream correctness requirement that
  must survive future dependency updates with an auditable lineage.

The project needs a maintained downstream home for that fix, not a new overlay
for every future divergence.

## Decision

Adopt <https://github.com/farbenbuilds/libxev> as the maintained downstream
libxev fork.

- The fork's `main` is an exact read-only mirror of `mitchellh/libxev` `main`.
  It is fast-forward only, carries no downstream commits, and is never built or
  pinned.
- The integration branch `uwz/zig-0.16` is based on the newest upstream commit
  compatible with Zig 0.16.0. It carries auditable `uwz(<area>): ...` patch
  commits. The migration creates it at the current validated
  `9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf` pin.
- A future toolchain upgrade creates `uwz/zig-0.17`. A Zig 0.17-only upstream
  `main` is never merged into the 0.16 branch.
- The integration branch is append-only from first push. Compatible upstream
  commits are merged with `--no-ff`; history is never force-pushed or
  rewritten.
- `build.zig.zon` pins only a full 40-hex commit, all four manifest views move
  together, and the update records the fork commit, upstream base, and hashes.
  Branches, tags, and short SHAs are never authoritative.
- Optional annotated tags may mark tested integration commits for humans; they
  do not participate in resolution.
- Upstream `mitchellh/libxev` is fetch-only. This project does not push, open
  issues or pull requests, comment, or contribute changes there.
- Every sync is a security and provenance review, and every patch commit
  carries a ledger ID, upstream reference, invariant, test evidence, and
  retirement criterion.

Implementation is deferred to the next libxev dependency update. Until that
migration lands, `build.zig.zon` remains pinned to upstream `9ce8e8e6...` and
the ADR 0004 overlay and patch remain authoritative. The migration checklist
is in [docs/libxev_fork.md](../libxev_fork.md).

This ADR supersedes only ADR 0004's "Fork libxev and pin the fork" alternative.
It does not supersede ADR 0004's current overlay decision, which remains in
force until the migration lands.

## Alternatives considered

- **Keep the overlay only**: rejected as the long-term model. It has no patch
  history, no upstream relationship, and no bounded way to carry more than one
  downstream change. It remains correct only as the interim state.
- **Vendor libxev source into this repository**: rejected. It would duplicate
  upstream history, enlarge the packaged source, complicate license and
  provenance tracking, and make future upstream review harder than a fork
  commit plus a ledger.
- **Wait for an upstream release**: rejected. Issue 252 is open, upstream
  `main` at `451a2bc` carries the Zig 0.17 update (PR #249) and is not
  compatible with this build, and the Windows IOCP ownership defect would
  block a supported runtime path without the overlay.
- **Pin a fork branch or tag**: rejected. A branch or tag can move, so it
  cannot supply the immutable dependency pin that the build and release
  provenance require.
- **Contribute the fix upstream and remove the overlay after release**:
  rejected by project policy. Upstream is read-only, and downstream behavior
  cannot depend on an external review or release schedule.
- **Edit the fetched package under `zig-pkg`**: rejected in ADR 0004 and still
  rejected. The cache is shared, content-addressed, and outside a clean-clone
  build.

## Consequences

- The current manifest remains on upstream `9ce8e8e6...`; no document or build
  step may claim the fork is already in use.
- The ADR 0004 overlay remains authoritative until the migration lands. Patch
  retirement now follows the fork integration branch rather than waiting for
  an upstream release.
- The next libxev dependency update must execute the migration checklist:
  mirror sync, integration branch creation, branch protection, XEV-001 test
  and import, manifest and view updates, all-four-views provenance check,
  overlay and patch removal, notices, CI, current-state sweep, and native
  Windows validation.
- During migration, update this ADR's `Release` field and every current-state
  assertion listed in the policy checklist.
- After migration, the fork integration history is the source of truth for
  downstream libxev behavior. The overlay and audit patch are deleted.
- No upstream contribution is made. Downstream fixes stay in the fork ledger.
- Future Zig upgrades create a new integration branch instead of merging
  incompatible upstream history into the current one.
- The build/vendor owner maintains the mirror and integration branch;
  transport/runtime reviews IOCP completions; verification owns the gates.

## References

- [docs/libxev_fork.md](../libxev_fork.md): normative policy, ledger, sync
  commands, and migration checklist.
- [ADR 0004](0004-windows-iocp-accept-and-queued-close.md): current Windows
  IOCP overlay and queued-close decision.
- <https://github.com/farbenbuilds/libxev>: maintained downstream fork.
- <https://github.com/mitchellh/libxev/issues/252>: upstream accept-lifecycle
  issue.
- `build.zig.zon`, `patches/libxev_iocp_accept_socket.patch`,
  `vendor/libxev_overlay/src/backend/iocp.zig`, and
  `scripts/check_vendor_overlay.sh`.
