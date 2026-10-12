# Plan — Directory-ready `plugin` release branch — 2026-10-01

Spec: `docs/specs/2026-10-01-plugin-release-branch.md` (+ `.json` sidecar)

## B1 — Portal findings (frontmatter, icon)
- Quote `argument-hint` in `mtk-doctor` and `mtk-setup`.
- `validate-toolkit.sh`: fail on a frontmatter value matching `^key: [ ... ] <more>` (unquoted
  flow sequence followed by text). Negative case proven by running the check on a temp copy.
- `.claude-plugin/icon.svg`: the Moberg favicon (from `gh-pages:assets/favicon.svg`) with
  `width`/`height` 128, viewBox unchanged.
- Verify: `bash scripts/validate-toolkit.sh`.

## B2 — Build script (TDD)
- Write `tests/hooks/test-build-plugin-branch.sh` first against a fixture repo (manifest listing
  kept and dropped files, `scripts/generate-checksums.sh` copied in); run it red.
- `scripts/build-plugin-branch.sh`: `git archive <source> | tar -x` into a temp dir; drop
  dev-only paths and unlisted `docs/`; trim manifest `files` to present sources; run the exported
  tree's own `generate-checksums.sh`; build a tree with a temporary index; `commit-tree` on the
  local or `origin/` tip of the target branch (root commit if neither); `update-ref`. No-op when
  the tree is unchanged. Never pushes, never touches the caller's branch.
- Verify: the test, then a real-repo build into `plugin-dryrun` (deleted afterwards).

## B3 — Wiring
- `release.yml`: after "Create tag and GitHub release", fetch `plugin` if it exists, run the
  script, `git push origin plugin` (no force). Same `exists == 'false'` condition.
- Manifest entries for the three new files; CHANGELOG `[Unreleased]`.
- Verify: `validate-toolkit`, full `tests/hooks/test-*.sh` loop, `claude plugin validate . --strict`.
