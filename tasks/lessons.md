# Lessons Learned

> This file captures patterns and mistakes discovered during AI-assisted development.
> It is read at the start of every `/mtk` workflow.
> Commit this file — it is institutional memory for the team.
>
> **Structured mirror (v7.5.0+):** every lesson here is also stored in
> `.mtk/learnings.jsonl` (gitignored, machine-readable) for 5-layer retrieval
> at the start of specs and fixes. New lessons added via `correction-capture`
> or `promote-lesson` flow through `scripts/learnings.sh add` and write to
> both stores. Manual edits to this markdown file remain canonical for the
> team; the JSON store is rebuildable. See
> `.claude/references/learnings-schema.md`.

## 2026-04-23 — marketplace.json is a third version file the validator checks

**What happened:** After bumping `manifest.json` and `plugin.json` to 7.1.0, `validate-toolkit.sh` still failed with "Version mismatch: manifest=7.1.0 marketplace=7.0.0". The `.claude-plugin/marketplace.json` is a third file that must stay in sync.

**Rule:** When bumping version, update all three: `manifest.json`, `plugin.json`, AND `marketplace.json`. The spec change manifest must list all three.

**Why:** The validator checks all three version fields. Omitting one from the spec/plan means the bump is incomplete.

**Applies to:** Any version bump task — add `marketplace.json` to the change manifest alongside manifest.json and plugin.json.

---

## 2026-04-23 — Hook test assertions inside subshells lose their counters

**What happened:** The first version of `test-context-estimator.sh` used `(...)` subshells to isolate `source "$HOOK_IO"`. Assertions inside those subshells incremented local `pass`/`fail` counters that were never seen by the parent, producing "4/4 passed" despite 7 assertions running.

**Rule:** Hook benchmark tests must use exit-1-on-failure patterns (like existing tests), not accumulating counters. Any counter-based approach requires writing counts to a temp file and reading them back in the parent.

**Why:** Bash subshells don't propagate variable changes to the parent. Sourcing hook-io inside a subshell correctly isolates namespace but silently loses counters.

**Applies to:** Any new test in `tests/hooks/` that needs to source `hook-io.sh` and assert results.

---

## 2026-04-11 — TaskCompleted hook blocks task completion

**What happened:** The `TaskCompleted` prompt hook in `settings.json` prevents tasks from being marked `completed`. The hook fires on the event and its evaluation interferes with the state transition. Tasks stayed stuck at `in_progress` despite repeated `TaskUpdate(completed)` calls. `deleted` worked because no hook fires on deletion.

**Rule:** Do not use prompt hooks on `TaskCompleted` events — they block completion state transitions. Use the `Stop` hook for verification reminders instead, which fires on agent response completion without interfering with task state.

**Why:** Prompt hooks on state-change events can interfere with the state change itself. The `TaskCompleted` hook was designed to be informational but it silently prevents tasks from reaching `completed` status.

**Applies to:** Any settings.json configuration that uses hooks on TaskCompleted events.

## 2026-05-19 — Quoted heredoc in $(...) still tokenizes backticks

**What happened:** `$(python3 - <<'PY' ... PY)` with backticks inside the PY heredoc body caused bash on macOS to fail with "unexpected EOF while looking for matching `". Even though `<<'PY'` (quoted delimiter) should suppress expansion, the tokenizer inside `$(...)` still trips on raw backticks in the body.

**Rule:** Avoid literal backticks inside any heredoc nested in `$(...)`. Use `BT = chr(96)` in Python or write the script to a temp file with `cat > "$f" <<'PY'` and `python3 "$f"` instead of inlining.

**Why:** Triggers a confusing failure that looks like a heredoc-termination bug but is actually `$(...)` tokenization. Cost ~15 minutes of debugging.

**Applies to:** Any bash script that embeds Python or shell snippets containing backticks via heredoc within command substitution.

## Idempotency guards on JSON trails must match structurally, not by grep
- **What happened:** `spec-archive.sh` used `grep -q "\"slug\":\"$SLUG\""` to detect already-archived slugs. `$SLUG` is a regex to grep, so a slug with a metachar (e.g. `a.b`) could falsely match a different slug (`aXb`) and silently drop the archive — caught in compliance review.
- **Rule:** When checking "did I already process X?" against a JSON/JSONL trail, match with `jq -e --arg s "$X" 'select(.field == $s)'`, not `grep`. If grep is unavoidable, use `grep -F`.
- **Why it matters:** Silent NO-OP on a divergent match breaks the audit trail the feature exists to guarantee — a data-integrity failure, not a cosmetic one.
- **When it applies:** Any idempotency/dedup guard that scans a structured log keyed by a user-supplied identifier.

## Linter guard packs are ERE (grep -Ei), not PCRE — and reject empty alternation
- **What happened:** Writing `core/docdrift.txt`, I used PCRE-isms (`(?i)`, negative lookahead `(?!…)`) copied from `slopwatch.txt`, and an empty alternation branch `\]\((|#|todo)\)`. `pre-commit-linters.sh` matches with `grep -qEi`, so `(?i)`/lookahead are silently inert (case is already handled by `-i`) and the empty branch makes grep abort with "empty (sub)expression". Caught by the pack's own test.
- **Rule:** Author pack regexes as POSIX ERE. No `(?i)`/`(?!…)`. Never write an empty alternation branch — use `([x]?|a|b)` to express "optional/empty or alternatives". Always ship a `tests/hooks/test-*-pack.sh` with a positive match per rule **and** a clean negative control (e.g. `\bpan\b` must not match "Japan").
- **Why it matters:** A pattern that silently never matches is worse than no rule — it gives false confidence the smell is guarded.
- **When it applies:** Any new or edited `hooks/linter-patterns/**/*.txt` rule.

## Hard-coded sed line ranges in usage()/help silently truncate when you add lines
- **What happened:** `workflow-artifact.sh`'s `usage()` did `sed -n '4,18p'`. Adding the `remediation` subcommand's comment lines pushed `abandon` to line 21, so `--help` silently dropped it. I bumped to `4,20p` and *still* clipped `abandon` (line 21) — caught in architecture review.
- **Rule:** When a header/help block is rendered by a hard-coded line range, re-count after adding lines — or better, render to a sentinel (`sed -n '/^# Subcommands:/,/^$/p'`) so it never regresses.
- **Why it matters:** Truncated help hides real capabilities from users with no error.
- **When it applies:** Any script whose `usage()` slices its own header by absolute line numbers.

## A lesson recorded only in tasks/lessons.md doesn't stop the mistake from recurring — it needs to live in the enforced rule text too
- **What happened:** The 2026-04-23 lesson "marketplace.json is a third version file the validator checks" was already documented in this file. During the v7.17.0 release batch, the version bump was still done as a two-file operation (manifest.json + plugin.json) — `marketplace.json` was missed again and only caught because `validate-toolkit.sh` failed. The lesson existed but wasn't consulted at spec-writing time, because `CLAUDE.md` C0.1 and `.claude/rules/toolkit-structure.md` S1.4 — the rule text actually read during spec/plan drafting — still only described a two-file sync.
- **Rule:** When a `tasks/lessons.md` entry documents a gap in a Critical Rule or a numbered rule (Cx.x/S1.x/etc.), don't stop at the lesson — also fix the rule text itself. The lesson describes an incident; the rule is what future work actually reads and enforces.
- **Why it matters:** `tasks/lessons.md` is read as background context, but the rule text is what's cited and load-bearing at spec time. A lesson that never updates the rule it's about will recur indefinitely — this is the second time this exact mistake shipped.
- **When it applies:** Any lesson whose root cause is "a documented rule was incomplete," not just "an agent forgot a step." Check whether the referenced rule (CLAUDE.md, `.claude/rules/*.md`) needs a companion fix before closing the lesson.

## bash -c child shells do not inherit pipefail — verification engines report piped failures as success
- **What happened:** `verify-commands.sh` ran commands via `bash -c "$command"` under a parent `set -euo pipefail`. The child shell starts fresh: `false | tee /dev/null` exited 0 and was reported `verified` — the exact stamp the script exists to guarantee. Caught by silent-failure-hunter with a reproduced fixture.
- **Rule:** When executing user/config-supplied command strings in a child shell whose exit code you interpret, invoke `bash -o pipefail -c "$cmd"`. Parent-shell `set -o pipefail` never propagates.
- **Why it matters:** Piping through `tee`/`grep`/`tail` is a common build/test pattern; without child pipefail every such command is un-verifiable, silently.
- **When it applies:** Any script that runs assembled command strings and records verified/failed status (verify-commands.sh, future CI wrappers, eval executors).

## Skill prose that delegates verification to a script must define the engine-absent and engine-failed branches
- **What happened:** Three findings in one review wave were the same class: bootstrap's command verification had no branch for `verify-commands.sh` missing (exit 127 → agents improvise silence); converge read weak-claims JSON without checking `verify-claims.sh`'s exit code (engine crash indistinguishable from "zero findings", could read a stale file); `--update-guidelines` hashed curl error pages into the provenance pin (no `-f`, no SHA validation).
- **Rule:** Every skill step that calls a verification/provenance engine must state explicitly: (1) what happens when the engine is absent (annotate as unverified + report, never silent), (2) what happens when it exits non-zero (abort loudly; never proceed to interpret possibly-stale output), (3) network fetches feeding pins use `curl -fsSL`, validate formats (`^[0-9a-f]{40}$`), and write only after all inputs succeeded.
- **Why it matters:** A verification layer whose own failure reads as "all clear" is worse than no verification — it converts engine bugs into false confidence, defeating the feature's purpose.
- **When it applies:** Any SKILL.md step invoking verify-claims.sh / verify-commands.sh / audit-drift-check.sh or fetching pinned external content.

## Run prior-work-check before trusting a "borrow"/feature backlog — capability often already ships
- **What happened:** A competitive-analysis backlog (docs/competitive-analysis-2026-07.md) listed 5 P0 items to "borrow" from other plugins into MTK. Dogfooding it through `/mtk implement` and doing the Phase-0 recon revealed 3 of the 5 already existed: `scope-guard.sh` already parsed the spec manifest (only gap: advisory, never blocked), `verify-completion` already enforced completion evidence, and `verify-commands.sh` already ran named commands. Only the poison-floor lint was a genuine gap. The backlog had been written without auditing `hooks/`, so it recommended re-building existing capability.
- **Rule:** Before starting implementation from any externally-derived backlog (competitive analysis, "borrow" list, ticket import), run `prior-work-check` against `hooks/`, `scripts/`, and existing skills/agents. Re-scope each item to enhance-existing vs build-new *before* writing the spec, not after. An idea sourced from outside the repo has not been reconciled with the repo.
- **Why it matters:** Building a parallel implementation of an existing hook is pure waste and a drift/duplication risk (two guards, two behaviours). The single genuine gap gets diluted by four redundant items.
- **When it applies:** Any implement/batch-fix run whose task list came from outside the codebase — especially research/borrow backlogs where the author did not read the current source first.

## Global `replace_all` on a counter token rewrites the helper's own definition into infinite recursion
- **What happened:** Refactoring `run-benchmarks.sh` to add per-section tallies, I wrote `_tally_pass() { PASS=$((PASS + 1)); CUR_PASS=... }`, then ran a global replace of `PASS=$((PASS + 1))` → `_tally_pass` to convert the ~10 call sites. The replace also matched the body of the definition I had just written, producing `_tally_pass() { _tally_pass; ... }` — unbounded recursion. It was invisible in the diff summary and only caught because the harness echoed the modified file back.
- **Rule:** When a global find/replace maps token X → helper `f`, and `f`'s own body contains X, write the definition with a *different* spelling first (e.g. `PASS=$(( PASS + 1 ))` with inner spaces), or exclude the definition line, or do the replace before adding the definition. After any `replace_all`, re-read the definition site specifically.
- **Why it matters:** Self-referential rewrites produce a script that passes `bash -n` (syntax is valid) and only fails at runtime, potentially as a hang rather than an error. Any "extract this into a helper" refactor done by global replace has this shape.
- **When it applies:** Every `Edit(replace_all: true)` where the replacement introduces a call to a function whose body contains the searched token — counters, loggers, accumulators, wrappers.

## A mutating `gh`/`git` command piped to `tail` turns an interactive prompt into a silent 3-minute timeout
- **What happened:** `gh pr merge 272 --squash 2>&1 | tail -5` ran to the full Bash-tool timeout and returned `(No output)`. The merge itself had already succeeded (the PR showed `MERGED` seconds later) — `gh` then blocked on its post-merge `Delete the branch?` prompt waiting on stdin, and `tail` buffers until EOF, so the prompt text never surfaced. Diagnosed as a permission denial at first, because the only visible signals were a long stall and an empty result.
- **Rule:** For any *mutating* `gh`/`git` invocation: (1) pass the flags that remove the prompt — `gh pr merge` needs `--delete-branch` or `--no-delete-branch` on top of `--squash`; (2) redirect stdin with `< /dev/null` so a surviving prompt fails fast instead of blocking; (3) do **not** pipe it through `tail`/`head` — buffering hides the prompt and the error. Reserve pipe-to-`tail` for read-only chatty commands. Prompt-proof the environment too: `GH_PROMPT_DISABLED=1`, `GIT_TERMINAL_PROMPT=0`, `GH_PAGER=cat`, `GIT_PAGER=cat` (the pager is the same hang class — `gh pr view` / `git log` block in `less` whenever a TTY is detected).
- **Why it matters:** The failure presents as the *tool layer* misbehaving (hang, then denial) rather than the command waiting for input, so the real cause is invisible and debugging goes to hooks and permissions. Worse, the mutation already landed — retrying a merge/push that "timed out" risks acting on state that already changed. Windows shells (Git Bash/ConPTY) misreport TTY status more often, so `gh`'s own non-interactive detection cannot be relied on.
- **When it applies:** Every agent-issued `gh pr merge` / `gh pr create` / `gh release create` / `git push` / `git rebase`, and any command whose output is piped while it might still ask a question.

## A benchmark whose assertion cannot fail is worse than a missing benchmark
- **What happened:** `run-benchmarks.sh` had `VAL_OUT=$(bash scripts/validate-toolkit.sh 2>&1 || true)` followed by `VAL_EXIT=$?`. The `|| true` lives *inside* the command substitution, so the assignment always succeeds and `$?` is always 0 — the assertion `validate-toolkit passes (exit 0)` had never been capable of failing. Found while making benchmark numbers publishable; publishing it would have published a guaranteed-green result as evidence.
- **Rule:** `VAR=$(cmd)` sets `$?` from the *assignment*, and `|| true` inside the substitution pins it to 0. To capture a real exit code: `rc=0; OUT=$(cmd) || rc=$?`. Audit every `X=$?` that follows a command substitution.
- **Why it matters:** A vacuous assertion is a false negative generator that also reads as coverage. It is strictly worse than no test, because it suppresses the instinct to add a real one.
- **When it applies:** Any bash test harness, CI gate, or verification script that captures both output and exit status from one command.

## A gate that flakes on innocent files is a gate people learn to skip
- **What happened:** `.claude/settings.json` hook commands were re-anchored on `${CLAUDE_PLUGIN_ROOT}` — a variable that only resolves in a plugin's `hooks/hooks.json` — breaking all 13 hooks at once. `validate-toolkit.sh` has a deterministic `check_hook_anchor` guard for exactly this (added after the same breakage in `aafae79`), but its S3.1 scan ran `head -15 "$script" | grep -q` under `set -o pipefail`: when grep matched and exited, head took SIGPIPE (141) and pipefail reported a *spurious* S3.1 violation on a random file each run. The validator was crying wolf, and the real regression sat unnoticed in the working tree.
- **Rule:** Never pipe a producer into an early-exiting consumer (`grep -q`, `grep -m1`, `head -1`) under `pipefail` — the consumer's success becomes the producer's SIGPIPE becomes a false failure. Reshape as `grep -q pattern <(head -N file)` (process substitution discards the producer's status) or use a consumer that reads to EOF (`grep -c`). And when a validation gate reports a failure that looks impossible, re-run it twice before believing it: a *moving* accusation is a race in the gate, not N broken files.
- **Why it matters:** The repo's C0.8 makes this validator the gate for every change. A gate with a false-positive race erodes exactly the habit it exists to build — the second occurrence of the anchor breakage landed in a tree where the gate was already distrusted noise.
- **When it applies:** Any `set -euo pipefail` script piping into `grep -q`/`head`; any CI or pre-commit gate whose failures are nondeterministic or name a different culprit per run.
