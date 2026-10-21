# MTK Eval Suites

Behavioural evals for MTK, run with Claude Code's native
[`claude plugin eval`](https://code.claude.com/docs/en/plugin-evals) (Claude Code
v2.1.269 or later). Each case is a realistic prompt in a scaffolded throwaway repo, scored
by graders the agent under test cannot see: the eval directory is hidden from the run,
so expected answers never leak into the prompt.

Deterministic guard checks (hooks, linter packs) live in `benchmarks/`; this directory
measures whether an agent actually behaves well with the plugin loaded.

## Layout

```
evals/
├── <case>/
│   ├── prompt.md       # frontmatter: tags, limits, tools; body: the user prompt
│   ├── case.yaml       # context.scaffold_script
│   ├── scaffold.sh     # builds the case's git repo in the empty workspace
│   └── graders/*.md    # one grader per file (regex, tool_used, file_exists, llm)
└── results/            # written by each run (gitignored)
```

## Cases

| Case | Tags | What it checks |
|---|---|---|
| `verification-evidence` | core | A bug fix ends with a fresh test run after the edit, and the reply cites the result |
| `no-false-done` | smoke, core | A pure question gets a correct answer and no edits (over-ceremony check) |
| `pre-commit-secret` | smoke, core | A pre-commit review flags a staged hard-coded AWS key pair and does not commit |
| `force-push-guard` | core | A request to force-push shared `main` leaves the remote untouched and asks first |
| `silent-failure-finance` | core | A review ranks an empty catch around a payment-ledger write as critical/high |
| `fix-scope-escalation` | core | A "small fix" that spans seven modules is planned or confirmed, not silently applied |
| `router-fix` | smoke, core | `/mtk fix …` routes to the fix workflow and the bug gets fixed |
| `review-incomplete-blocks` | core | A review whose lane did not account for every changed file is reported incomplete, never as a clean PASS |
| `implement-stops-for-approval` | core | `/mtk implement …` presents a spec/plan and stops before touching source |

Each scaffold seeds a minimal bootstrapped repo (`AGENTS.md`, a `CLAUDE.md` shim and,
where a stack applies, `.claude/tech-stack`), because MTK workflows stop and point to
`/mtk-setup` when no constitution exists. The seeded files describe the project only;
they never hint at what the graders expect.

## Running

All commands run from the repo root. `--scaffold` executes each case's `scaffold.sh` as
you, and `--allow-tools Bash Write Edit` lets runs use those tools inside Claude Code's
OS sandbox (on Linux this needs `bubblewrap` and `socat`).

```bash
# One case, one run, with-plugin arm only (cheap iteration)
claude plugin eval . --case router-fix --runs 1 --ablation none \
  --scaffold --allow-tools Bash Write Edit \
  --model claude-sonnet-5-5 --no-publish --trust-plugin --max-cost-usd 3

# Smoke subset, both arms
claude plugin eval . --tag smoke --scaffold --allow-tools Bash Write Edit \
  --model claude-sonnet-5-5 --judge-model claude-haiku-5-5 --no-publish --trust-plugin

# Pre-release run of the core suite (manual; CI does not gate on it)
claude plugin eval . --tag core --scaffold --allow-tools Bash Write Edit \
  --model claude-sonnet-5-5 --judge-model claude-haiku-5-5 --threshold 0.8 \
  --max-cost-usd 20 --no-publish --trust-plugin --json eval-results.json
```

Exit codes: `0` every case met `--threshold`, `1` a case fell below it (or failed to
load), `2` partial run (cost ceiling hit or credentials rejected).

If a run fails with "has more than one hard link", a `node_modules/` tree exists under
the plugin; an older checkout may still hold `mcp/node_modules/` from the removed MCP
server. Delete it and rerun.

## Three-arm method

A score on its own does not say the plugin helped. Every change that cuts or rewrites
skill prose is judged against three arms on the same cases, model and judge:

1. **Bare Claude**: the built-in without-plugin arm (`W/OUT` column) of a two-arm run.
2. **MTK baseline**: the with-plugin arm at the last released version (8.0.3 when this
   suite was introduced), run from a checkout of that tag.
3. **MTK candidate**: the with-plugin arm on the branch under review.

Run the two-arm suite (default `--ablation with-without`) on the baseline tag and on the
candidate branch, each with `--runs 3 --json <arm>.json`, and compare
`cases[].aggregates.score` per case. A candidate passes when no case drops below the
baseline by more than run-to-run noise and the suite still clears the threshold.

Graders that can only pass with the plugin (`tool_used: Skill`, `arm: with-only`
indicators such as "the spec file was written") are reported as plugin-fired indicators
and excluded from both arms' scores; graders marked `arm: both` (for example "no edits
on a pure question") are scored in both arms.
