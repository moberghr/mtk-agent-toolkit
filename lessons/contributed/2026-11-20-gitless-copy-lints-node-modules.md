# Linting a git-less copy lints node_modules

- **Rule:** Ignore `node_modules` explicitly on the linter's command line
  (`oxlint --ignore-pattern node_modules`), in the project's lint script and in ad-hoc runs;
  `.oxlintrc.json` `ignorePatterns` does not stop the directory walk (oxlint 1.75). To tell new
  errors from pre-existing ones, lint the changed files and keep only errors on lines the diff
  touched — no HEAD copy needed.
- **Why:** oxlint takes its ignores from `.gitignore` only inside a git repository. In a copy
  it walked a symlinked node_modules (≈7,800 files vs 268), and type-aware linting
  (tsgolint) peaked at 10–12 GB, OOM-killing the agent's terminal session.
- **Applies when:** checking whether lint/type errors predate the current change.
- **Evolution:** tech-stack-typescript Lint bullet (applied); optionally setup-refresh flags an
  oxlint lint script without the ignore flag.
- **Source:** contributed 2026-11-20 (anonymized)
