# Spec — Directory-ready `plugin` release branch — 2026-10-01

Scope: new-feature · security_impact: none · sidecar: `2026-10-01-plugin-release-branch.json`

## Problem

The Claude plugin directory portal times out ("The request took too long") validating
`moberghr/mtk-agent-toolkit@main`, whose plugin folder is the whole repo (475 files). A
bisect on throwaway `dirtest/*` branches showed every half and a 277-file runtime-only tree
validate in seconds, while main minus any single component still times out — the cost is
the total payload, not one file. The portal reports also surfaced two blocking frontmatter
findings and a "No icon" warning.

## Approach

Keep developing on `main`. On every release, build a slim `plugin` branch holding only what
the plugin ships, with a manifest and checksums that match it, and point the directory at
that branch.

## Requirements

- The build script shall export the tree of a given source ref without modifying the
  current branch, index, or working tree.
- The build script shall omit `tests/`, `evals/`, `examples/`, `.github/`, `docs/specs/`,
  `docs/plans/`, and every other `docs/` file the manifest does not list.
- The build script shall write a `.claude/manifest.json` whose `files` entries all exist in
  the exported tree.
- The build script shall regenerate `checksums.sha256` so `generate-checksums.sh --verify`
  reports 0 mismatched and 0 missing on the exported tree.
- When the exported tree differs from the current `plugin` tip, the build script shall add
  one commit whose parent is that tip.
- If the exported tree equals the current `plugin` tip tree, then the build script shall
  create no commit and exit 0.
- When the release workflow runs on `main`, the workflow shall build the `plugin` branch from
  the current version's tag and push it without force, so a failed or skipped publish heals on
  the next run.
- The validator shall fail on a skill or agent frontmatter value that starts with `[` and
  continues after the closing `]` without quotes.
- The plugin shall ship a square `.claude-plugin/icon.svg` declared at 128px or larger.

## Change manifest

| Path | Action | Purpose |
|---|---|---|
| `.claude/skills/mtk-doctor/SKILL.md` | modify | quote `argument-hint` (blocking finding) |
| `.claude/skills/mtk-setup/SKILL.md` | modify | quote `argument-hint` (blocking finding) |
| `scripts/validate-toolkit.sh` | modify | reject unquoted multi-bracket frontmatter values |
| `.claude-plugin/icon.svg` | create | directory listing icon (Moberg favicon at 128px) |
| `tests/hooks/test-validate-frontmatter-yaml.sh` | create | regression test for the frontmatter check (added after review, engineer-approved) |
| `scripts/build-plugin-branch.sh` | create | build the slim `plugin` branch |
| `tests/hooks/test-build-plugin-branch.sh` | create | fixture-repo tests for the build script |
| `.github/workflows/release.yml` | modify | build and push `plugin` after tagging |
| `.claude/manifest.json` | modify | register the three new files |
| `CHANGELOG.md` | modify | `[Unreleased]` entry |

## Out of scope

Policy holds from the portal report (credential reads, broad `allowed-tools`, scripts the
validator can't follow, the 605 KiB MCP bundle); pointing `moberg-plugins` at `plugin`;
deleting the `dirtest/*` branches (separate OK).

## Assumptions and risks

- [ASSUMED] The 290-file slim tree validates within the portal's time budget like the
  277-file `dirtest/runtime` did. Verified only after the first `plugin` build is pushed.
- Risk: the release workflow's `GITHUB_TOKEN` may be blocked from pushing `plugin` by a
  branch rule. Mitigation: the step fails loudly; the tag and release still exist.
