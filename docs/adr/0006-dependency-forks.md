# 0006. Maintained lsquic and h1spec forks

- Status: Accepted
- Date: 2026-10-24
- Deciders: build/vendor, QUIC/HTTP3, HTTP/1.1, verification
- Release: 2.2.0

## Context

ADR 0005 adopted `farbenbuilds/libxev` as the maintained downstream fork for
the event loop. The same pattern now applies to the two remaining dependencies
that still required local patches or generated overlays:

- `litespeedtech/lsquic` at `a9616720af78b9aab895145c1792d5305c480ae8`
  (v4.10.2) needed `patches/lsquic_h3_message_error.patch` and the
  pre-generated `vendor/lsquic_overlay` tree. The patch keeps positive header
  callback results and ambiguous content lengths stream-scoped, and the
  overlay supplies the generated version table because the upstream tree does
  not ship it.
- `uNetworking/h1spec` at `f0a5650a20c575fbea0f7179a3a9cfa50f20ba6e` needed
  `patches/h1spec_deno_cleanup.patch` in the compliance workflow to unref and
  close completed Deno connections.

Both local mechanisms work, but they keep downstream changes outside the
dependency history, force CI to apply `patch`, and leave `vendor/` as a mix of
compatibility inputs and generated sources. ADR 0001 also deferred HTTP/3
datagrams and WebTransport because the pinned lsquic build did not expose the
server-side WebTransport surface. A maintained fork lets the project carry
those changes as reviewable commits instead of waiting for an upstream release.

## Decision

Adopt the same maintained-fork policy already used for libxev:

- `farbenbuilds/lsquic` is the maintained downstream lsquic fork. Its
  `master` branch is an exact read-only mirror of `litespeedtech/lsquic`
  `master`. Downstream work lives on `uwz/main`, based on the validated
  v4.10.2 commit, and is pinned at the full 40-hex commit
  `85bd081c9103c077a7cc98271d09334d0f1043d4`.
- `farbenbuilds/h1spec` is the maintained downstream h1spec fork. Its `main`
  branch is an exact read-only mirror of `uNetworking/h1spec` `main`.
  Downstream work lives on `uwz/main` and is pinned at the full 40-hex commit
  `999ba9e8f318b1c0ebbff1278b98bc5833f1af18`.
- The lsquic integration branch carries LSQ-001 (stream-scoped QPACK header
  errors) and LSQ-002 (generated version table). The h1spec branch carries
  H1S-001 (close and unref completed test connections).
- `build.zig.zon` pins the lsquic fork commit and all four dependency views
  move together. `vendor/h1spec` remains the only vendor submodule and points
  at the h1spec fork commit.
- `patches/` and `vendor/lsquic_overlay` are deleted. The build imports the
  pinned dependency trees directly; no build or CI step runs `patch` or Perl.
- Upstream `litespeedtech/lsquic` and `uNetworking/h1spec` are fetch-only.
  This project does not push, open issues or pull requests, comment, or submit
  patches there.
- Every downstream commit carries a ledger ID, upstream reference, invariant,
  test evidence, and retirement criterion. Every sync is a security review
  with branch protection, full-commit resolution, and an archived pin.
- ADR 0001's deferral is lifted. The lsquic fork is the vehicle for the
  server-side WebTransport surface, and v2.2.0 owns the live activation and
  compliance gate.

The normative procedure, branch table, and patch ledger are in
[docs/dependency_forks.md](../dependency_forks.md).

## Alternatives considered

- **Keep the local patches and overlays**: rejected. They work today, but they
  keep downstream behavior outside the dependency history and require `patch`
  in CI.
- **Vendor lsquic or h1spec source into this repository**: rejected. It would
  duplicate upstream history, enlarge the packaged source, and complicate
  license and provenance review.
- **Wait for upstream releases**: rejected. The WebTransport surface is gated
  behind a build option and missing server APIs, and the h1spec cleanup is a
  test-runner concern rather than an upstream feature request.
- **Pin a fork branch or tag**: rejected. Branches and tags move; the build
  needs an immutable full commit.
- **Contribute the changes upstream**: rejected by project policy. Upstream is
  read-only, and downstream behavior must not depend on an external review or
  release schedule.

## Consequences

- The lsquic pin moves from upstream v4.10.2 to the fork integration commit.
  The source is still based on v4.10.2, with two ledgered downstream commits.
- The h1spec submodule URL and gitlink move to the fork. The compliance job
  runs the checked-out tree directly and no longer applies a patch.
- `patches/` and `vendor/lsquic_overlay` disappear from the package and the
  build graph. `vendor/h1spec` remains as the single compliance submodule.
- CI gains `scripts/check_dependency_forks.sh`, which runs the libxev, lsquic,
  and h1spec provenance checks against `scripts/dependency_mirrors.env`.
  Release tags and the weekly `Dependency Mirrors` workflow require exact live
  upstream equality with `--exact-mirrors`.
- ADR 0001 moves from deferred to accepted implementation. Live WebTransport
  activation remains gated by the v2.2.0 compliance work; the current
  `SECURITY.md` statement stays true until that work lands.
- Future lsquic or h1spec bumps follow the same sync, review, pin, and rollback
  procedure as libxev.

## References

- [docs/dependency_forks.md](../dependency_forks.md): normative fork policy,
  branch model, patch ledger, and sync procedure.
- [ADR 0005](0005-libxev-fork.md): libxev fork adoption.
- [ADR 0001](0001-http3-datagram-and-webtransport.md): HTTP/3 datagrams and
  WebTransport activation.
- <https://github.com/farbenbuilds/lsquic>: maintained lsquic fork.
- <https://github.com/farbenbuilds/h1spec>: maintained h1spec fork.
- `build.zig.zon`, `.gitmodules`, `builds/vendor/lsquic.zig`, and
  `scripts/check_dependency_forks.sh`.
