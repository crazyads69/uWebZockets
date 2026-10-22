# Codex Agent Team

Codex custom agents in `.codex/agents/` mirror the eight specialists in
`.opencode/agents/` and add four workflow roles. The matching OpenCode workflow
agents live in `.opencode/agents/`. Root project instructions remain in
`AGENTS.md`; domain details stay with their specialist so context remains
focused.

## Procedure

1. `architect` reads the request, relevant instructions, and specialist
   ownership boundaries. It returns assumptions, a scoped plan, dependencies,
   and acceptance criteria. It does not edit files.
2. `developer` implements the assigned slice. For protocol or subsystem work,
   the root agent selects the matching domain specialist as the developer or
   asks it for focused guidance. Independent slices may run in parallel only
   when they do not edit the same files.
3. `reviewer` receives the final diff and verification evidence after
   implementation. It is read-only and reports actionable findings with
   file/line references. Findings return to the developer; changed work gets
   another review.
4. `integrator` takes the architect plan, developer report, and reviewer
   findings; checks ownership boundaries, scope, required commands, and the
   final diff; then prepares the delivery summary. Integration does not
   override project gates or silently discard findings.

The root agent owns orchestration and the final response. No phase is complete
until its output is returned. Apply relevant existing skills from
`.agents/skills/` and project instructions in `AGENTS.md` and
`CODING_CONVENTION.md`. Report commands and their actual outcomes; never claim
checks that were not run.

Architecture work may use `codebase-design`,
`improve-codebase-architecture`, `domain-modeling`, and `grilling`; the
architect owns the vocabulary and the plan. Reviewers may add
`thermo-nuclear-code-quality-review` as a second lens on structural diffs.
`install-anti-slop` is limited to JS/TS tooling. Project overrides in
`AGENTS.md` win over vendored defaults, including the no-emoji rule and the
scratch-only architecture report.
