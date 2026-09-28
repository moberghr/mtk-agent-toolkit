# `how-it-works.html` — how it's built and kept fresh

`how-it-works.html` is a generated, feature-by-feature reference for MTK
(what each skill/agent/hook does, an example, and how & why it works). It is part
of the marketing site and reuses the exact `<style>` block from `index.html`,
so a design change there flows into this page on the next build.

The site lives on the `gh-pages` branch (GitHub Pages serves it from the branch root), kept
out of `main` so the plugin folder stays within the Claude directory's file-count and
file-size limits. `--check` reads skills, agents, and hooks from the toolkit checkout that
`MTK_REPO_ROOT` points at (default: this folder's parent).

## Files

| File | Role |
|---|---|
| `how-it-works.data.json` | **Content source of truth** — one object per feature (`what` / `example` / `how` / `why` / `key_files`). Edit prose here. |
| `build-how-it-works.py` | Generator. Renders the JSON into `how-it-works.html`; reuses `index.html`'s styles. |
| `how-it-works.html` | **Generated output — do not hand-edit.** Regenerate instead. |

## Rebuild after editing content

```bash
MTK_REPO_ROOT=<toolkit checkout> python3 build-how-it-works.py
```

## Keep it fresh

```bash
MTK_REPO_ROOT=<toolkit checkout> python3 build-how-it-works.py --check     # exit 1 on drift
```

`--check` compares the documented features against the skills, agents, and hooks
actually on disk and reports:

- **Undocumented** — a skill/agent exists but has no entry in the JSON (**fails**).
- **Stale reference** — a feature's `key_files` points at a file that no longer
  exists in this repo (**fails**). Files that setup/runtime generate into *target*
  repos (e.g. `architecture-principles.md`, `.claude/tech-stack`) are recognised
  and reported as expected, not failures.
- Hooks not individually documented are listed as advisory only.

Wire `--check` into CI (e.g. a step in `.github/workflows/validate.yml`) to fail
a PR that adds or removes a skill/agent without updating the page.

**Scope note:** `--check` catches *structural* drift (a feature added or removed).
It cannot tell that a skill's behaviour changed while its file still exists — for
that, re-derive the affected entries from their source files and update the JSON.
The initial data set was extracted from the source under `.claude/` and `hooks/`
and adversarially fact-checked against those files.

## Preview locally

```bash
python3 -m http.server 8756 --directory docs
# → http://localhost:8756/how-it-works.html
```
