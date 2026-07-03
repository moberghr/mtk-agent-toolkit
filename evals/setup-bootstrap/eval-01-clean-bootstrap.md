---
category: positive
skill: setup-bootstrap
signal: grounded-lean-generation
---

# Clean bootstrap of a small single-stack fixture repo

## Scenario

A fresh, never-bootstrapped fixture repo: single-stack **dotnet**, ~20 files —
one `.sln`, two `.csproj` (one app project, one xUnit test project), a handful
of handler classes, no existing `CLAUDE.md`, `.claude/`, or `AGENTS.md`. No
prior MTK artifacts of any kind.

Two additions to the base fixture (T-F004/T-F005):

- A `.cursorrules` file at the repo root with one concrete rule (e.g. "Never
  use `DateTime.Now` — always `DateTime.UtcNow`.") — the only AI-assistant
  config present.
- The xUnit test project's `.csproj` is deliberately broken (e.g. a
  `<PackageReference>` to a NuGet package that doesn't exist), so the
  `dotnet test` command STEP 3.5a detects and verifies genuinely fails when
  run. The app project's `.sln`/`dotnet build` still succeeds.

## Prompt

```prompt
Bootstrap this repo for MTK. Run /mtk-setup.
```

## Expected Signals

- `scripts/setup-detect.sh --json` (or the STEP 0 detection it replaces) is
  consulted before generation — the report states the detected stack as
  `dotnet` sourced from the detection output, not guessed.
- Root `CLAUDE.md` is generated at **≤120 lines** (target 60–80) and carries
  the `mtk-setup: vX.Y.Z` provenance footer stamp.
- `verify-references.sh` and `verify-claims.sh` (or the STEP 3.5a verification
  pass that wraps them) run against the generated docs, and the report states
  **zero** stale/unresolved references.
- The STEP 3.5c secret-scan gate ran before any file write (reported, not
  merely implied).
- A preservation report is printed in STEP 5 — for a from-scratch repo with
  nothing pre-existing, "none found" (or equivalent) is an acceptable value;
  the section must still be present, not omitted.
- `CODE_INDEX.md` (if generated) has no placeholder/ghost rows — every row
  points at a file that actually exists in the fixture repo.
- The STEP 5 report includes a command-verification line (`Command
  verification: N verified, N unverified, N skipped` or the explicit
  `--no-verify-commands` opt-out note) — never silently absent.
- The failing `dotnet test` command is never published as a bare,
  unannotated line in the CLAUDE.md Tech Stack section — it carries an
  inline `[UNVERIFIED — <reason>]` tag naming why it failed, and the STEP 5
  command-verification line's unverified/failed count includes it.
- STEP 2.7 ingests the `.cursorrules` rule into the generated CLAUDE.md (or
  the appropriate `.claude/rules/*.md`) with an `Evidence: migrated from
  .cursorrules` tag, and the STEP 5 report explicitly lists the ingested
  file (never folded into CLAUDE.md silently, and never omitted from the
  "Ingested AI configs" line).

## Grading Rubric

- **PASS** — all nine signals present; CLAUDE.md within the line cap; zero
  stale references; secret scan and command verification both reported; the
  failing command is annotated `[UNVERIFIED — <reason>]` and counted; the
  `.cursorrules` rule is ingested with its `Evidence:` tag and listed in the
  report.
- **PARTIAL** — CLAUDE.md and detection are grounded and in-cap, but one
  mechanical signal (verify pass, secret-scan report, preservation report,
  command-verification line, failing-command annotation, or `.cursorrules`
  ingestion) is missing or unreported.
- **FAIL** — CLAUDE.md exceeds 120 lines, contains ungrounded/aspirational
  rules, stale references are left unresolved, the secret-scan gate is
  skipped without the documented escape hatch, OR the failing `dotnet test`
  command appears in CLAUDE.md as a bare, unannotated command (i.e. not
  flagged `[UNVERIFIED — <reason>]`).
