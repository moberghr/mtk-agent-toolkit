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
| `fires-fix`, `quiet-fix` | routing, fires/quiet, fix | A failing-test report loads `fix`; a question about how a function handles failure does not |
| `fires-code-review-and-quality`, `quiet-code-review-and-quality` | routing, fires/quiet, code-review-and-quality | A patch pasted into the prompt loads the review skill; "what does the uncommitted diff change?" does not |
| `fires-security-and-hardening`, `quiet-security-and-hardening` | routing, fires/quiet, security-and-hardening | Adding an API key to every call of a payment client loads the security skill; raising a model token limit, which touches no auth or secret, does not |
| `fires-research-context`, `quiet-research-context` | routing, fires/quiet, research-context | A question about the current major version and its migration path loads web research; the pinned version, which the repo answers, does not |
| `fires-code-simplification`, `quiet-code-simplification` | routing, fires/quiet, code-simplification | Tidying a working, tested function loads the simplification skill; renaming one variable does not |
| `fires-brainstorming`, `quiet-brainstorming` | routing, fires/quiet, brainstorming | Asking to compare approaches to an open problem loads brainstorming; a fully specified one-line change does not |

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
candidate branch, each with `--runs 3 --json <arm>.json`, and compare the two files with
`scripts/eval-compare.sh` (see "Comparing two runs" below). Arm 1 is in each file: the
`W/OUT` column of the run's summary, `cases[].aggregates.scoreWithout` and the lift
`cases[].aggregates.delta`. A candidate passes when no case drops below the baseline by
more than run-to-run noise and the suite still clears the threshold.

Graders that can only pass with the plugin (`tool_used: Skill`, `arm: with-only`
indicators such as "the spec file was written") are reported as plugin-fired indicators
and excluded from both arms' scores; graders marked `arm: both` (for example "no edits
on a pure question") are scored in both arms. Under `--ablation none` nothing is
excluded, so a single-arm score and a two-arm score of the same case do not compare.

## Routing pairs

The lexical check under "Checking skill routing" shows that a description's words point
at its skill. It cannot show that a live model loads the skill. The cases tagged `routing`
do, in pairs: for a model-invoked skill, one `fires-<skill>` case whose everyday prompt
should load it, and one `quiet-<skill>` case whose prompt is a plausible near miss that
should not. No prompt names its skill or uses a slash command. Pairs exist for `fix`,
`code-review-and-quality`, `security-and-hardening`, `research-context`,
`code-simplification` and `brainstorming`. The review pair pastes its patch into the
prompt instead of leaving it in the repo, because pasted content is a known case where
skills fail to load.

Every routing case carries the skill name, `routing` and `fires` or `quiet` in its
`tags`, so `--tag routing` selects the set and `eval-coverage.sh` counts it.
`validate-toolkit.sh` checks that shape. Each case has one routing grader, a `regex` over
the trace that matches a Skill tool call for the skill or a Read of its `SKILL.md`,
plugin-namespaced or not:

- `graders/routing-fired.md` in a fires case is an indicator (`arm: with-only`). Only the
  with-plugin arm can load the skill, so scoring it would pull the without-plugin arm to
  0 and inflate the lift. The case is scored instead on a grader both arms can pass in a
  few turns: it opened the file the prompt is about (`reads-source`), or, for review, the
  reply names the defect in the pasted patch.
- `graders/routing-quiet.md` in a quiet case is scored (`arm: both`, `match:
  not_contains`). The without-plugin arm passes it by construction, so a plugin that
  loads the skill when it should not shows up as a lower score and a negative lift. Each
  quiet case also has a free check on the result, such as the token limit really being
  raised.

Every case has at least one scored grader that only a run which did the work can pass.
"No edit" and "the skill did not load" also pass on a run that crashed in its first turn,
so a case scored on those alone would turn a crash into a pass. Such a grader may sit next
to a result check, never alone. The result check must also need the work the prompt asks
for: the diff-summary case checks for the old timeout, which only the diff shows, not for
a name the current file already holds.

A pair is only fair when the skill's own description claims the fires prompt more than
any other skill's does. Where two skills are both defensible (a small config change that
`fix` could also claim, a rename that is arguably a clean-up), the case's `description`
says so.

`scripts/eval-compare.sh` reads both graders by file name, so keep the names. Turn caps
are low (8 for fires, 10 for quiet) because a skill loads in the first turns. A fires run
often hits the cap or its timeout before it finishes the task, and that is expected: the
work itself is not graded. The research-context pair lists `WebSearch` and `WebFetch`,
and its quiet case scores using neither.
Without a grant they are removed from the session, so the model chooses a web-research
skill without a web tool, which real sessions always have. Grant `WebSearch` when you run
the routing set:

```bash
claude plugin eval . --tag routing --runs 3 --scaffold \
  --allow-tools Bash Write Edit WebSearch \
  --model claude-sonnet-5-5 --judge-model claude-haiku-5-5 \
  --no-publish --trust-plugin --max-cost-usd 15 --json evals/results/candidate.json
```

When a fires case does not fire or a quiet case does, that is the finding. Change the
skill's description in a separate change and compare the two runs; never reword a
prompt or a grader to make the pair pass.

## Comparing two runs

`bash scripts/eval-compare.sh <baseline.json> <candidate.json>` compares two
`claude plugin eval --json` files. It needs only python3 and makes no model calls.

1. Make a baseline checkout and give it the candidate's cases, so both runs answer the
   same prompts. The plugin code under test stays the baseline's:

   ```bash
   git worktree add ../mtk-baseline v9.5.0
   git -C ../mtk-baseline checkout <candidate-branch> -- evals
   ```

2. Run the same command on both, with the same model, judge, filter, `--runs` and
   ablation mode, writing into the gitignored `evals/results/`:

   ```bash
   claude plugin eval ../mtk-baseline --tag routing --runs 3 --scaffold \
     --allow-tools Bash Write Edit WebSearch \
     --model claude-sonnet-5-5 --judge-model claude-haiku-5-5 \
     --no-publish --trust-plugin --max-cost-usd 15 --json evals/results/baseline.json
   # then the candidate: the routing command above, with target .
   ```

3. Compare them, then remove the worktree:

   ```bash
   bash scripts/eval-compare.sh evals/results/baseline.json evals/results/candidate.json
   git worktree remove ../mtk-baseline
   ```

For each case in both files it prints the with-plugin score in each, the delta and FIRED
in each: graded runs in which the plugin fired out of graded with-plugin runs. A run that
ended on an error (a timeout, an API error) is not graded: it is left out of the score,
FIRED and both rates and listed under WARNINGS, because a crashed run passes "no edit" and
"stayed quiet" graders on nothing done. The score is the mean over the graded runs. FIRED comes from
`routing-fired` in a fires case and from `routing-quiet` failing in a quiet case, so a
quiet case should show 0. In other cases it comes from any indicator grader (`arm:
with-only`, or `tool_used: Skill` without `arm: both`). The totals give the mean score over
the shared cases, the fires rate over the fires cases and the stays-quiet rate over the
quiet cases.

It exits 1 on a regression: a case score that drops by more than `--noise`, a FIRED rate
that drops by more than `--noise` (or rises, on a quiet case), or a fires or stays-quiet
rate that drops by more than `--noise`. The default noise of 0.2 treats one grader verdict
flipping in one of three runs as noise (0.17 on a two-grader case) and flags a whole run
going from pass to fail (0.33). An indicator is one verdict per run, so one run in three
that stops firing is flagged. A case in the baseline that is missing from the candidate is
a regression too, since a case that no longer runs measures nothing; pass
`--allow-missing` when it was removed on purpose. A case only in the candidate is listed
and not compared.

It exits 2, and compares nothing, when either file is not a complete run: `partial: true`
(cost ceiling, interrupt, rejected credential), cases missing from
`aggregates.casesTotal`, a case with no with-plugin runs, a case whose runs all ended on
an error, a run whose judge graders were skipped, or a graded run with no true-or-false
verdict for one of its case's graders (a null or missing `passed` is a missing verdict,
not a failed one). It also exits 2 when the two files used different
ablation modes. A different model, judge or Claude Code version is a warning, and so are
a case whose grader definitions differ between the files (a grader change, not the
plugin, may explain its delta) and a case run a different number of times. `--json`
prints the same report for scripts, and `-h` prints the fields it reads.

## Reading coverage

`bash scripts/eval-coverage.sh` lists the skills under `.claude/skills/` that no case here
exercises. It reads the case files only: no results, no model calls. `--json` prints the
same report for scripts, and `--evals-dir` / `--skills-dir` point it elsewhere. It exits 0
when the report printed and 2 on a usage error, a missing directory or a missing python3.

"Exercises" is a heuristic, stated in `--help` and in the report header. A case covers a
skill when the skill name is one of its `tags`, the prompt invokes `/<skill>`,
`/mtk <skill>` or `/mtk:<skill>`, or a grader names `skills/<skill>/` (or is a
`tool: Skill` grader naming the skill). Prose mentions do not count, so a model-invoked
skill that a case triggers only implicitly is listed as uncovered. To declare coverage
exactly, add the skill name to the case's `tags:`. `tags` is a documented field and
`--tag` filtering keeps working. Do not add a `covers:` key, because `prompt.md`
frontmatter rejects unknown keys.

The script reads case files only, so it reports no scores and no lift. The lift
(with-plugin minus without-plugin) is in each run's own result, as
`cases[].aggregates.delta`, and in the `Δ` column of its summary.
`scripts/eval-compare.sh` compares two runs (see "Comparing two runs").

## Checking skill routing

`bash scripts/routing-check.sh` checks offline that skill descriptions route. It reads
the `name` and `description` of every skill under `.claude/skills/` and the prompts in
`tests/fixtures/skill-routing.json`. It needs only python3 and makes no model calls, so
`validate-toolkit.sh` and `run-fixtures.sh` both run it. It reports:

- **Collisions.** The similarity of every pair of descriptions. A pair warns at 0.50 and
  fails at 0.75, unless the fixture's `allow_pairs` lists it with a reason. An allow-list
  entry for a pair below the warn line warns that it can be removed.
- **Positive prompts.** Each one passes when its skill ranks in the top 3. A tie counts
  against it. The rank-1 rate is reported too, and `min_rank1` (90% today, `--min-rank1`
  to override) fails the run when it drops below the floor.
- **Name-free prompts.** A positive prompt that shares no word with its skill's name.
  The name is weighted double, so a prompt that repeats it ("fix this bug" for `fix`)
  scores partly on the echo. A name-free prompt reaches its skill through the description
  alone. Its rank-1 rate is reported on its own and has its own floor,
  `min_rank1_name_free` (89% today, `--min-rank1-name-free` to override).
- **Negative prompts.** Each names a skill that must not rank first (a tie counts as
  first) and, optionally, an `owner` that must outrank it. A negative whose named skill
  scores 0 can never fail, so it warns.
- **Coverage.** Every skill needs `min_positive_per_skill` positive prompts (2), with at
  least `min_name_free_per_skill` of them name-free (1), unless `exempt` lists it with a
  reason. An exempt entry for a skill that meets both anyway warns that it can be removed.
- **Frontmatter.** It reads a description written as a plain value (on one line or
  several), a value starting on the next line, a single- or double-quoted value, or a
  `|` or `>` block. Any other shape, a missing frontmatter block or an empty description
  fails the run and names the skill, so nothing is scored as silently empty.

`--json` prints the same report for scripts, including the description text each skill
was scored on. `--quiet` prints only the warnings, failures and summary line, and
`--skills-dir` / `--prompts` point it elsewhere. `--warn`, `--fail` and `--top-k`
override the fixture's thresholds. It exits 0 on a pass, 1 when a check fails, and 2 on a
usage error, a number that is not finite, a bad fixture or a missing python3. The report
is ASCII. A prompt with other characters is printed escaped when the terminal cannot
show it.

The score is a lexical proxy. Each text becomes a stemmed TF-IDF vector, with the name
counted twice and common words dropped, and the vectors are compared by cosine
similarity. A pass shows that the words in a description point at its skill. It does
not show that a live model picks the skill. That is what the cases in this directory
measure. When a prompt misroutes, reword the description so it says what the skill does
in the words engineers use. Rewording the prompt toward the description only hides the
problem. Some prompts share no words with any honest description, for example "this
throws a NullReferenceException when the cart is empty". Leave those out of the fixture
and cover them with an eval case.
